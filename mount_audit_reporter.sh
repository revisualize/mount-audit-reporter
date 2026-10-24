#!/usr/bin/env bash
#
# ---------------------------------------------------------------------
# Path:         mount_audit_reporter.sh
# Filename:     mount_audit_reporter.sh
# Project:      mount-audit-reporter
# Description:  Compare the mounts visible in the current mount namespace
#               against a manifest of what should be mounted: from which
#               source, with which filesystem type, which options present,
#               and which absent. Never changes mount state.
# Status:       lab-tested
# Revision:     14
# Updated:      2026-10-22
# Requires:     Bash 4.2 or newer, findmnt and mktemp
# Included by:  standalone command line tool; sourceable for testing
# Provides:     option_is_present, run_findmnt, load_mount_table,
#               mount_is_covered, find_visible_mount,
#               audit_one_mount, parse_manifest, run_manifest,
#               generate_manifest
# ---------------------------------------------------------------------
#
# What this script changes: no mount state. It never calls mount,
# umount, or a remount. Its only write is one temporary file per run,
# made with mktemp under TMPDIR (default /tmp), holding findmnt's error
# output. It is removed right after findmnt exits, and a trap removes it
# if the run is interrupted; a SIGKILL cannot be trapped and can leave it.
#
# Usage:
#   bash mount_audit_reporter.sh <manifest_file>
#   bash mount_audit_reporter.sh --generate [fstype_csv]
#
# Audit mode reads the manifest, reads the whole mount table once with
# findmnt, finds the mount a process actually reaches at each declared
# mountpoint, and reports every finding at once. Mountpoints are matched
# exactly as the table spells them: no symlink is followed. It sees the
# mounts of the mount namespace it runs in, and only the mountpoints the
# manifest declares.
#
# Generate mode prints a candidate manifest to standard output from the
# visible mount table, for the filesystem types given (default:
# nfs,nfs4,cifs,smb3). Run it on a host you know is correct, then prune
# what you hold no expectation about.
#
# Manifest columns (whitespace separated):
#   <mountpoint> <fstype> <required_csv> [forbidden_csv] [source]
# A # at the start of a line, or after whitespace, starts a comment.
# Inside a value it is data, so server#A and opt#1 are ordinary text.
# Use - for "none" in an option column, or for "do not check" in the
# source column. A missing forbidden column means -. To give a source,
# give the forbidden column too.
#
# Exit codes:
#   0  audit: every expectation met; generate: manifest printed
#   1  audit: one or more findings
#   2  usage error, missing findmnt, malformed or empty manifest, a
#      mount table that could not be read, a declared path where the
#      table cannot say which mount is visible, or generate found
#      nothing usable. In that last audit case the other mounts are
#      still audited, and their findings are printed first.
#
# Environment:
#   MOUNT_AUDIT_LIB_ONLY   set to 1 to source the functions for testing
#                          without running anything
#

set -u;

mount_audit_finding_messages=();
mount_audit_note_messages=();
mount_audit_mounts_checked=0;
mount_audit_query_error="";
mount_audit_query_errors=();
mount_audit_error_file="";
mount_audit_default_generate_types="nfs,nfs4,cifs,smb3";

# Filled by load_mount_table, keyed by mount ID.
mount_table_ids=();
declare -gA mount_table_parent=();
declare -gA mount_table_target=();
declare -gA mount_table_fstype=();
declare -gA mount_table_options=();
declare -gA mount_table_source=();
# Space-separated mount IDs at each path, so a lookup reads only the rows
# it needs.
declare -gA mount_table_at_target=();

# Filled by parse_manifest, one entry per manifest line, same index.
manifest_mountpoints=();
manifest_fstypes=();
manifest_required=();
manifest_forbidden=();
manifest_sources=();

add_finding() {
    mount_audit_finding_messages+=("${1}");
};

add_note() {
    mount_audit_note_messages+=("${1}");
};

# option_is_present <option_token> <live_options_csv>
#
# Exact-token match. "soft" matches the token "soft" and nothing else,
# so it does not match "softerr" or "softreval", and "vers=4.1" does not
# match "vers=4.2". Wrapping both sides in commas makes the first and
# last options match the same way as the middle ones. The token sits
# inside quotes in the pattern, so a "*" or "?" in it is literal.
option_is_present() {
    local option_token="${1}";
    local live_options_csv="${2}";
    case ",${live_options_csv}," in
        *",${option_token},"*) return 0 ;;
    esac;
    return 1;
};

remove_error_file() {
    if [ -n "${mount_audit_error_file}" ]; then
        rm -f -- "${mount_audit_error_file}";
    fi;
    mount_audit_error_file="";
};

# run_findmnt <findmnt arguments...>
#
# Runs findmnt once and sets findmnt_output. Returns 0 on success and 2
# on any other exit, with the reason in mount_audit_query_error. The
# script only ever asks for the whole table, which always has rows, so
# there is no "nothing matched" exit to tell apart from a failure.
# Standard error goes to a temporary file, so output, errors, and
# status all come from the same single run.
run_findmnt() {
    local findmnt_status;
    local error_line;
    local findmnt_error="";

    findmnt_output="";
    if ! mount_audit_error_file="$(mktemp "${TMPDIR:-/tmp}/mount_audit_reporter.XXXXXX")"; then
        mount_audit_error_file="";
        mount_audit_query_error="could not create a temporary file for findmnt's error output";
        return 2;
    fi;
    findmnt_output="$(findmnt "$@" 2> "${mount_audit_error_file}")";
    findmnt_status="$?";
    while IFS= read -r error_line || [ -n "${error_line}" ]; do
        findmnt_error="${findmnt_error:+${findmnt_error}; }${error_line}";
    done < "${mount_audit_error_file}";
    remove_error_file;

    if [ "${findmnt_status}" -ne 0 ]; then
        mount_audit_query_error="findmnt exited ${findmnt_status}${findmnt_error:+: ${findmnt_error}}";
        findmnt_output="";
        return 2;
    fi;
    return 0;
};

# load_mount_table
#
# Reads the whole mount table of this namespace with one findmnt call,
# so every mount in a run is judged against the same listing. The kernel
# does not promise that listing is atomic: it releases its lock between
# reads, so a mount or unmount made while findmnt reads can show in it
# partly. Fills
# mount_table_ids (in the order printed) and the mount_table_* arrays,
# keyed by mount ID. Returns 2, with the reason in
# mount_audit_query_error, when findmnt fails, prints nothing, or prints
# a row this script does not understand, or a table whose parent IDs
# cannot all lead to the top of one tree.
#
# SOURCE is the last column on purpose: of the columns asked for, it is
# the one that can be empty, and an empty last field cannot shift the
# fields before it when the row is split on spaces. --raw writes any
# space inside a value as \x20, so no other field contains one.
load_mount_table() {
    local live_line row_id row_parent row_target row_fstype row_options row_source row_extra;
    local chain_id steps_left;
    local self_parent_count=0;

    mount_table_ids=();
    mount_table_parent=();
    mount_table_target=();
    mount_table_fstype=();
    mount_table_options=();
    mount_table_source=();
    mount_table_at_target=();

    run_findmnt --noheadings --raw --output ID,PARENT,TARGET,FSTYPE,OPTIONS,SOURCE || return 2;
    while IFS= read -r live_line; do
        [ -z "${live_line}" ] && continue;
        row_source="";
        row_extra="";
        read -r row_id row_parent row_target row_fstype row_options row_source row_extra <<< "${live_line}";
        if ! [[ "${row_id}" =~ ^[0-9]+$ && "${row_parent}" =~ ^[0-9]+$ ]] \
            || [[ "${row_target}" != /* ]] || [ -z "${row_options}" ] || [ -n "${row_extra}" ] \
            || [ -n "${mount_table_target[${row_id}]:-}" ]; then
            mount_audit_query_error="unexpected row from findmnt: ${live_line}";
            return 2;
        fi;
        mount_table_ids+=("${row_id}");
        mount_table_parent["${row_id}"]="${row_parent}";
        mount_table_target["${row_id}"]="${row_target}";
        mount_table_fstype["${row_id}"]="${row_fstype}";
        mount_table_options["${row_id}"]="${row_options}";
        mount_table_source["${row_id}"]="${row_source}";
        mount_table_at_target["${row_target}"]+=" ${row_id}";
    done <<< "${findmnt_output}";
    if [ "${#mount_table_ids[@]}" -eq 0 ]; then
        mount_audit_query_error="findmnt listed no mounts";
        return 2;
    fi;
    # Every parent chain must reach the top of the tree: a mount that is its
    # own parent, or whose parent is outside the table. A chain that runs
    # longer than the table has rows is a loop, and nothing read from such
    # a table can be trusted. Only the root of the namespace is its own
    # parent (proc_pid_mountinfo(5)), so a second such row is refused too.
    for row_id in "${mount_table_ids[@]}"; do
        if [ "${mount_table_parent[${row_id}]}" = "${row_id}" ]; then
            self_parent_count=$((self_parent_count + 1));
            if [ "${self_parent_count}" -gt 1 ]; then
                mount_audit_query_error="more than one mount in the table is its own parent";
                return 2;
            fi;
        fi;
        chain_id="${row_id}";
        steps_left="${#mount_table_ids[@]}";
        while [ "${mount_table_parent[${chain_id}]}" != "${chain_id}" ] \
            && [ -n "${mount_table_target[${mount_table_parent[${chain_id}]}]:-}" ]; do
            chain_id="${mount_table_parent[${chain_id}]}";
            steps_left=$((steps_left - 1));
            if [ "${steps_left}" -lt 0 ]; then
                mount_audit_query_error="the parent IDs in the mount table form a loop";
                return 2;
            fi;
        done;
    done;
    return 0;
};

# mount_is_covered <mount_id>
#
# Returns 0 when nothing covers the mount, 3 when a later mount over a
# directory above it hides it (the covering path in hidden_by_target),
# and 2 when the table cannot say (mount_audit_query_error). It climbs
# the parents: at each level, a sibling mounted on the same parent at a
# directory above the mount's path was mounted later and covers it.
# Every level is read before deciding, so the answer is the same in any
# print order. A cover anywhere on the way up decides it: the mount is
# unreachable whichever mount wins at a higher level. Of several covers,
# the outermost is named, since it was mounted last. Only when nothing
# covers the mount does a sibling at the same path on the same parent
# make it an error. load_mount_table has already rejected loops, so the
# climb ends at the top of the tree.
mount_is_covered() {
    local lower_id="${1}";
    local parent_id sibling_id sibling_target lower_target candidate_path;
    local cover_target="";
    local ambiguous_target="";

    parent_id="${mount_table_parent[${lower_id}]}";
    while [ "${parent_id}" != "${lower_id}" ] && [ -n "${mount_table_target[${parent_id}]:-}" ]; do
        lower_target="${mount_table_target[${lower_id}]}";
        # A cover sits at the mount's own path or a directory above it, so
        # only those few paths are looked up, never every sibling.
        candidate_path="${lower_target}";
        while :; do
            for sibling_id in ${mount_table_at_target[${candidate_path}]:-}; do
                # A root that is its own parent is not a child of itself.
                [ "${sibling_id}" != "${lower_id}" ] || continue;
                [ "${sibling_id}" != "${parent_id}" ] || continue;
                [ "${mount_table_parent[${sibling_id}]}" = "${parent_id}" ] || continue;
                sibling_target="${candidate_path}";
                if [ "${sibling_target}" = "${lower_target}" ]; then
                    ambiguous_target="${ambiguous_target:-${lower_target}}";
                elif [ -z "${cover_target}" ] || [ "${#sibling_target}" -lt "${#cover_target}" ]; then
                    cover_target="${sibling_target}";
                fi;
            done;
            [ "${candidate_path}" = "/" ] && break;
            candidate_path="${candidate_path%/*}";
            candidate_path="${candidate_path:-/}";
        done;
        lower_id="${parent_id}";
        parent_id="${mount_table_parent[${lower_id}]}";
    done;
    if [ -n "${cover_target}" ]; then
        hidden_by_target="${cover_target}";
        return 3;
    fi;
    if [ -n "${ambiguous_target}" ]; then
        mount_audit_query_error="two mounts at ${ambiguous_target} share one parent; cannot tell which is visible";
        return 2;
    fi;
    return 0;
};

# find_visible_mount <mountpoint>
#
# Finds the mount a process actually reaches at <mountpoint>, using the
# table load_mount_table read. Sets visible_mount_id and live_mount_count
# (how many mounts the table lists at that exact path). Returns:
#   0  one visible mount
#   1  nothing is mounted at that path
#   2  the table cannot say which mount is visible (mount_audit_query_error)
#   3  every mount there is covered by a later mount over a directory
#      above it; the outermost covering path is in hidden_by_target
#
# proc_pid_mountinfo(5) gives both rules. A mount made on top of another
# records that mount as its parent, so of the mounts stacked at one path
# a candidate for the top is one that is no other's parent, whatever
# order findmnt prints them in. And a top is reachable only if no later
# mount covers a directory above it, which mount_is_covered checks. A
# path can hold more than one candidate: WSL2 mounts /tmp/.X11-unix,
# then a tmpfs over /tmp, then /tmp/.X11-unix again, so the first mount
# is still listed but unreachable. Covered candidates are dropped; one
# left is the visible mount, more than one is an error, never a guess.
find_visible_mount() {
    local wanted_target="${1}";
    local row_id covered_status;
    local first_hidden_by="";
    local -a member_ids=();
    local -A member_parents=();

    visible_mount_id="";
    hidden_by_target="";
    for row_id in ${mount_table_at_target[${wanted_target}]:-}; do
        member_ids+=("${row_id}");
        [ "${mount_table_parent[${row_id}]}" = "${row_id}" ] || member_parents["${mount_table_parent[${row_id}]}"]=1;
    done;
    live_mount_count="${#member_ids[@]}";
    [ "${live_mount_count}" -eq 0 ] && return 1;

    for row_id in "${member_ids[@]}"; do
        [ -n "${member_parents[${row_id}]:-}" ] && continue;
        mount_is_covered "${row_id}";
        covered_status="$?";
        if [ "${covered_status}" -eq 2 ]; then
            return 2;
        fi;
        if [ "${covered_status}" -eq 3 ]; then
            if [ -z "${first_hidden_by}" ] || [ "${#hidden_by_target}" -lt "${#first_hidden_by}" ]; then
                first_hidden_by="${hidden_by_target}";
            fi;
            continue;
        fi;
        if [ -n "${visible_mount_id}" ]; then
            visible_mount_id="";
            mount_audit_query_error="cannot tell which of ${live_mount_count} stacked mounts is visible";
            return 2;
        fi;
        visible_mount_id="${row_id}";
    done;
    hidden_by_target="${first_hidden_by}";
    if [ -n "${visible_mount_id}" ]; then
        return 0;
    fi;
    if [ -n "${hidden_by_target}" ]; then
        return 3;
    fi;
    mount_audit_query_error="cannot tell which of ${live_mount_count} stacked mounts is visible";
    return 2;
};

# audit_one_mount <mountpoint> <fstype> <required_csv> <forbidden_csv> <source>
#
# A "-" in either option column means no options of that kind. A "-" in
# the source column means the source is not checked.
audit_one_mount() {
    local expected_mountpoint="${1}";
    local expected_fstype="${2}";
    local required_options_csv="${3}";
    local forbidden_options_csv="${4}";
    local expected_source="${5}";
    local option_token;
    local -a option_tokens=();
    local lookup_status;
    local live_fstype live_options live_source;

    find_visible_mount "${expected_mountpoint}";
    lookup_status="$?";
    if [ "${lookup_status}" -eq 2 ]; then
        return 2;
    fi;
    mount_audit_mounts_checked=$((mount_audit_mounts_checked + 1));
    if [ "${lookup_status}" -eq 1 ]; then
        add_finding "${expected_mountpoint}: not mounted";
        return 0;
    fi;
    if [ "${lookup_status}" -eq 3 ]; then
        add_finding "${expected_mountpoint}: hidden: a later mount at ${hidden_by_target} covers it";
        return 0;
    fi;
    live_fstype="${mount_table_fstype[${visible_mount_id}]}";
    live_options="${mount_table_options[${visible_mount_id}]}";
    live_source="${mount_table_source[${visible_mount_id}]}";

    # A stack is worth knowing about, but on its own it is not a breach of
    # the manifest: the checks below run against the visible mount.
    if [ "${live_mount_count}" -gt 1 ]; then
        add_note "${expected_mountpoint}: ${live_mount_count} mounts stacked; audited the visible one";
    fi;

    if [ "${live_fstype}" != "${expected_fstype}" ]; then
        add_finding "${expected_mountpoint}: fstype is ${live_fstype}, expected ${expected_fstype}";
    fi;

    if [ "${expected_source}" != "-" ] && [ "${live_source}" != "${expected_source}" ]; then
        add_finding "${expected_mountpoint}: source is ${live_source:-<none>}, expected ${expected_source}";
    fi;

    if [ "${required_options_csv}" != "-" ]; then
        IFS=',' read -r -a option_tokens <<< "${required_options_csv}";
        for option_token in "${option_tokens[@]}"; do
            if ! option_is_present "${option_token}" "${live_options}"; then
                add_finding "${expected_mountpoint}: required option missing: ${option_token}";
            fi;
        done;
    fi;

    if [ "${forbidden_options_csv}" != "-" ]; then
        IFS=',' read -r -a option_tokens <<< "${forbidden_options_csv}";
        for option_token in "${option_tokens[@]}"; do
            if option_is_present "${option_token}" "${live_options}"; then
                add_finding "${expected_mountpoint}: forbidden option present: ${option_token}";
            fi;
        done;
    fi;
    return 0;
};

manifest_error() {
    printf 'ERROR: %s\n' "${1}" >&2;
};

# option_column_is_valid <csv>
#
# "-" alone, or one or more non-empty tokens separated by single commas.
# A "-" inside a list (rw,-) is rejected: "-" means "none" only when it
# is the whole column.
option_column_is_valid() {
    local option_csv="${1}";
    [ "${option_csv}" = "-" ] && return 0;
    case ",${option_csv}," in
        *",,"*|*",-,"*) return 1 ;;
    esac;
    return 0;
};

# parse_manifest <manifest_file>
#
# Reads and validates every line before anything is audited, and fills
# the manifest_* arrays. Returns 0 when the whole manifest is usable and
# 2 otherwise. An audit against a half-read manifest reports a clean
# result for the lines it never reached, so a bad line stops everything.
parse_manifest() {
    local manifest_file="${1}";
    local manifest_line;
    local line_number=0;
    local mountpoint_field fstype_field required_field forbidden_field source_field extra_field;
    local option_token;
    local -a required_tokens=();
    local -A first_seen_line=();

    manifest_mountpoints=();
    manifest_fstypes=();
    manifest_required=();
    manifest_forbidden=();
    manifest_sources=();

    if [ -z "${manifest_file}" ] || [ ! -r "${manifest_file}" ]; then
        manifest_error "manifest missing or unreadable: ${manifest_file:-<none given>}";
        return 2;
    fi;

    while IFS= read -r manifest_line || [ -n "${manifest_line}" ]; do
        line_number=$((line_number + 1));
        # A carriage return would end up inside the last field ("rw\r") and
        # turn a correct mount into a false finding, so it stops the run.
        if [[ "${manifest_line}" == *$'\r'* ]]; then
            manifest_error "line ${line_number}: carriage return found; save the manifest with Unix (LF) line endings";
            return 2;
        fi;
        # A # starts a comment only at the start of a line or after
        # whitespace. %% removes the longest matching suffix, which is the
        # one starting at the earliest whitespace-then-# position.
        if [[ "${manifest_line}" == "#"* ]]; then
            manifest_line="";
        fi;
        manifest_line="${manifest_line%%[[:space:]]#*}";
        mountpoint_field="";
        fstype_field="";
        required_field="";
        forbidden_field="";
        source_field="";
        extra_field="";
        read -r mountpoint_field fstype_field required_field forbidden_field source_field extra_field \
            <<< "${manifest_line}" || true;

        [ -z "${mountpoint_field}" ] && continue;

        if [ -z "${fstype_field}" ] || [ -z "${required_field}" ]; then
            manifest_error "line ${line_number}: needs at least mountpoint, fstype, and required options (use - for none)";
            return 2;
        fi;
        if [ -n "${extra_field}" ]; then
            manifest_error "line ${line_number}: more than five columns";
            return 2;
        fi;
        if [ "${mountpoint_field#/}" = "${mountpoint_field}" ]; then
            manifest_error "line ${line_number}: mountpoint must be an absolute path: ${mountpoint_field}";
            return 2;
        fi;
        # Mountpoints are compared with the table as findmnt --raw writes
        # it, which escapes a backslash, so a path holding one could
        # never match. Say so instead of reporting it as not mounted.
        if [[ "${mountpoint_field}" == *\\* ]]; then
            manifest_error "line ${line_number}: a mountpoint with a backslash cannot be matched: ${mountpoint_field}";
            return 2;
        fi;
        while [ "${mountpoint_field}" != "/" ] && [ "${mountpoint_field%/}" != "${mountpoint_field}" ]; do
            mountpoint_field="${mountpoint_field%/}";
        done;
        forbidden_field="${forbidden_field:--}";
        source_field="${source_field:--}";
        if ! option_column_is_valid "${required_field}"; then
            manifest_error "line ${line_number}: required column must be - alone or options separated by single commas: ${required_field}";
            return 2;
        fi;
        if ! option_column_is_valid "${forbidden_field}"; then
            manifest_error "line ${line_number}: forbidden column must be - alone or options separated by single commas: ${forbidden_field}";
            return 2;
        fi;
        if [ -n "${first_seen_line[${mountpoint_field}]:-}" ]; then
            manifest_error "line ${line_number}: ${mountpoint_field} already declared on line ${first_seen_line[${mountpoint_field}]}";
            return 2;
        fi;
        if [ "${required_field}" != "-" ] && [ "${forbidden_field}" != "-" ]; then
            IFS=',' read -r -a required_tokens <<< "${required_field}";
            for option_token in "${required_tokens[@]}"; do
                if option_is_present "${option_token}" "${forbidden_field}"; then
                    manifest_error "line ${line_number}: ${option_token} is both required and forbidden";
                    return 2;
                fi;
            done;
        fi;

        first_seen_line["${mountpoint_field}"]="${line_number}";
        manifest_mountpoints+=("${mountpoint_field}");
        manifest_fstypes+=("${fstype_field}");
        manifest_required+=("${required_field}");
        manifest_forbidden+=("${forbidden_field}");
        manifest_sources+=("${source_field}");
    done < "${manifest_file}";

    if [ "${#manifest_mountpoints[@]}" -eq 0 ]; then
        manifest_error "manifest declares no mounts: ${manifest_file}";
        return 2;
    fi;
    return 0;
};

# run_manifest <manifest_file>
#
# Returns 0 when every expectation is met, 1 on findings, 2 when the
# manifest cannot be trusted, the mount table cannot be read, or the
# table cannot say which mount is visible at a declared path. That last
# case does not stop the run: the other mounts are still audited, the
# error is kept in mount_audit_query_errors, and the caller prints
# findings and errors together.
run_manifest() {
    local manifest_file="${1}";
    local entry_index;

    # Each run starts clean, so a sourced caller can run more than once.
    mount_audit_finding_messages=();
    mount_audit_note_messages=();
    mount_audit_mounts_checked=0;
    mount_audit_query_error="";
    mount_audit_query_errors=();

    parse_manifest "${manifest_file}" || return 2;
    if ! load_mount_table; then
        manifest_error "${mount_audit_query_error}";
        return 2;
    fi;

    for entry_index in "${!manifest_mountpoints[@]}"; do
        if ! audit_one_mount "${manifest_mountpoints[${entry_index}]}" \
            "${manifest_fstypes[${entry_index}]}" \
            "${manifest_required[${entry_index}]}" \
            "${manifest_forbidden[${entry_index}]}" \
            "${manifest_sources[${entry_index}]}"; then
            # The table could not say which mount is visible. Record it
            # and go on with the other mounts.
            mount_audit_query_errors+=("${manifest_mountpoints[${entry_index}]}: ${mount_audit_query_error}");
        fi;
    done;

    [ "${#mount_audit_query_errors[@]}" -gt 0 ] && return 2;
    [ "${#mount_audit_finding_messages[@]}" -gt 0 ] && return 1;
    return 0;
};

report_audit_result() {
    local manifest_file="${1}";
    local audit_status="${2}";
    local query_error_message;

    if [ "${audit_status}" -eq 2 ]; then
        printf 'MOUNT AUDIT INCOMPLETE: %d finding(s) across %d mount(s); %d mount(s) could not be checked (%s)\n' \
            "${#mount_audit_finding_messages[@]}" "${mount_audit_mounts_checked}" \
            "${#mount_audit_query_errors[@]}" "${manifest_file}";
    elif [ "${audit_status}" -eq 1 ]; then
        printf 'MOUNT AUDIT: %d finding(s) across %d mount(s) (%s)\n' \
            "${#mount_audit_finding_messages[@]}" "${mount_audit_mounts_checked}" "${manifest_file}";
    else
        printf 'MOUNT AUDIT OK: %d mount(s) match expectations (%s)\n' \
            "${mount_audit_mounts_checked}" "${manifest_file}";
    fi;
    if [ "${#mount_audit_finding_messages[@]}" -gt 0 ]; then
        printf '  - %s\n' "${mount_audit_finding_messages[@]}";
    fi;
    if [ "${#mount_audit_note_messages[@]}" -gt 0 ]; then
        printf '  note: %s\n' "${mount_audit_note_messages[@]}";
    fi;
    if [ "${#mount_audit_query_errors[@]}" -gt 0 ]; then
        for query_error_message in "${mount_audit_query_errors[@]}"; do
            manifest_error "${query_error_message}";
        done;
    fi;
    return "${audit_status}";
};

# generate_manifest [fstype_csv]
#
# Prints a candidate manifest. Every option findmnt reports is written as
# required and the source is recorded where the format can hold it,
# because the tool cannot know which of them anyone cares about; the
# header tells the reader to prune. It reads the same whole table as the
# audit and records, for each path, the mount find_visible_mount says a
# process reaches there.
#
# A path is skipped with a comment when the format cannot hold it (findmnt
# --raw prints it with an escape, for whitespace or another special
# character), when the type or options begin with #, which the parser
# would read as a comment, when no single mount is visible there, when
# the mount there is hidden by a later mount above it, or when the
# visible mount is of a type that was not asked for. A source the format
# cannot hold (empty, "-", or beginning with #) is written as - (not
# checked) with a note saying so.
generate_manifest() {
    local generate_types="${1:-${mount_audit_default_generate_types}}";
    local row_id row_target row_type row_options row_source;
    local -a target_order=();
    local -A target_seen=();
    local -a skipped_comments=();
    local written_count=0;
    local lookup_status;
    local note_line;

    if ! load_mount_table; then
        manifest_error "${mount_audit_query_error}";
        return 2;
    fi;

    for row_id in "${mount_table_ids[@]}"; do
        row_target="${mount_table_target[${row_id}]}";
        case ",${generate_types}," in
            *",${mount_table_fstype[${row_id}]},"*) ;;
            *) continue ;;
        esac;
        [ -n "${target_seen[${row_target}]:-}" ] && continue;
        target_seen["${row_target}"]=1;
        case "${row_target}" in
            *\\x*)
                skipped_comments+=("# skipped: ${row_target} (whitespace or a special character in the path)");
                continue
                ;;
        esac;
        target_order+=("${row_target}");
    done;

    if [ "${#target_order[@]}" -eq 0 ] && [ "${#skipped_comments[@]}" -eq 0 ]; then
        manifest_error "no live mounts of type ${generate_types}; nothing to generate";
        return 2;
    fi;

    printf '# Generated by mount_audit_reporter.sh --generate\n';
    printf '# Host: %s  Time (UTC): %s  Types: %s\n' \
        "$(uname -n)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${generate_types}";
    printf '#\n';
    printf '# This records what the host is doing, not what anyone decided.\n';
    printf '# Every reported option is listed as required. Before using it:\n';
    printf '#   1. delete each option you hold no expectation about, including\n';
    printf '#      ones that change by themselves (addr=, clientaddr=, rsize=,\n';
    printf '#      wsize=, and timeo= on network mounts),\n';
    printf '#   2. add options that must never appear in column four,\n';
    printf '#   3. replace a source with - where any source is acceptable,\n';
    printf '#   4. delete any mount that should not be on this host at all.\n';
    printf '#\n';
    printf '# <mountpoint> <fstype> <required_csv> [forbidden_csv] [source]\n';

    if [ "${#target_order[@]}" -gt 0 ]; then
        for row_target in "${target_order[@]}"; do
            find_visible_mount "${row_target}";
            lookup_status="$?";
            if [ "${lookup_status}" -eq 2 ]; then
                skipped_comments+=("# skipped: ${row_target} (cannot tell which stacked mount is visible)");
                continue;
            fi;
            if [ "${lookup_status}" -eq 3 ]; then
                skipped_comments+=("# skipped: ${row_target} (hidden by a later mount at ${hidden_by_target})");
                continue;
            fi;
            row_type="${mount_table_fstype[${visible_mount_id}]}";
            row_options="${mount_table_options[${visible_mount_id}]}";
            row_source="${mount_table_source[${visible_mount_id}]}";
            case ",${generate_types}," in
                *",${row_type},"*) ;;
                *)
                    skipped_comments+=("# skipped: ${row_target} (the visible mount there is ${row_type})");
                    continue
                    ;;
            esac;
            if [[ "${row_type}" == "#"* || "${row_options}" == "#"* ]]; then
                skipped_comments+=("# skipped: ${row_target} (its type or options begin with #, which this format reads as a comment)");
                continue;
            fi;
            if [ "${live_mount_count}" -gt 1 ]; then
                printf '# note: %d mounts stacked at %s; the visible one is recorded\n' \
                    "${live_mount_count}" "${row_target}";
            fi;
            if [ -z "${row_source}" ] || [ "${row_source}" = "-" ] || [[ "${row_source}" == "#"* ]]; then
                note_line="# note: source of ${row_target} is ${row_source:-empty}, which this format cannot record; written as - (not checked)";
                printf '%s\n' "${note_line}";
                row_source="-";
            fi;
            printf '%s  %s  %s  -  %s\n' "${row_target}" "${row_type}" "${row_options}" "${row_source}";
            written_count=$((written_count + 1));
        done;
    fi;
    if [ "${#skipped_comments[@]}" -gt 0 ]; then
        printf '%s\n' "${skipped_comments[@]}";
    fi;
    if [ "${written_count}" -eq 0 ]; then
        manifest_error "every matching mount was skipped; nothing usable to generate";
        return 2;
    fi;
    return 0;
};

print_usage() {
    printf 'usage: mount_audit_reporter.sh <manifest_file>\n' >&2;
    printf '       mount_audit_reporter.sh --generate [fstype_csv]\n' >&2;
};

main() {
    local audit_status;

    if ! command -v findmnt > /dev/null 2>&1; then
        printf 'ERROR: findmnt not found (part of util-linux)\n' >&2;
        return 2;
    fi;
    # The temporary file must not outlive a run that is stopped early.
    trap remove_error_file EXIT;
    trap 'remove_error_file; exit 2' INT TERM HUP;

    case "${1:-}" in
        "")
            print_usage;
            return 2
            ;;
        --generate)
            if [ "$#" -gt 2 ]; then
                print_usage;
                return 2;
            fi;
            generate_manifest "${2:-}";
            return "$?"
            ;;
        -*)
            print_usage;
            return 2
            ;;
    esac;

    if [ "$#" -ne 1 ]; then
        print_usage;
        return 2;
    fi;

    run_manifest "${1}";
    audit_status="$?";
    if [ "${audit_status}" -eq 2 ] && [ "${#mount_audit_query_errors[@]}" -eq 0 ]; then
        # The manifest itself was rejected; parse_manifest said why.
        return 2;
    fi;
    report_audit_result "${1}" "${audit_status}";
    return "$?";
};

if [ "${MOUNT_AUDIT_LIB_ONLY:-0}" != "1" ]; then
    main "$@";
    exit "$?";
fi;
