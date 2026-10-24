#!/usr/bin/env bats
#
# ---------------------------------------------------------------------
# Path:         test/mount_audit_reporter.bats
# Filename:     mount_audit_reporter.bats
# Project:      mount-audit-reporter
# Description:  Behavioural tests for option matching, every finding
#               type, stacked and hidden mounts, manifest validation,
#               findmnt failures, generate mode, and the no-mount-change
#               guarantee.
# Status:       lab-tested
# Revision:     16
# Updated:      2026-10-22
# Requires:     bats, bash 4.2 or newer
# Included by:  test/run_all_tests.sh
# ---------------------------------------------------------------------
#
# Every test runs against test/shim/findmnt, a stand-in that reads a
# fixture mount table, so no test needs root or a real NFS or SMB mount.
# The shim is copied into a scratch directory and marked executable
# there, because the upload path these repositories use drops the
# executable bit from committed files.
#
# Run with:  bats test/
#

setup() {
    work_directory="$(mktemp -d)";
    shim_directory="${work_directory}/bin";
    mkdir -p "${shim_directory}";
    cp "${BATS_TEST_DIRNAME}/shim/findmnt" "${shim_directory}/findmnt";
    chmod +x "${shim_directory}/findmnt";

    # Recording stand-ins for every command that could change a mount.
    # If the script ever calls one, the call lands in this log.
    state_change_log="${work_directory}/state_change_calls.log";
    for state_changing_command in mount umount; do
        printf '#!/usr/bin/env bash\necho "%s $*" >> "%s";\n' \
            "${state_changing_command}" "${state_change_log}" \
            > "${shim_directory}/${state_changing_command}";
        chmod +x "${shim_directory}/${state_changing_command}";
    done;

    PATH="${shim_directory}:${PATH}";
    export PATH;
    FINDMNT_FIXTURE="${work_directory}/mount_table";
    export FINDMNT_FIXTURE;
    script_path="${BATS_TEST_DIRNAME}/../mount_audit_reporter.sh";

    # A small client: one hard NFS mount, one deliberately soft scratch
    # mount, one read-only SMB mount.
    # The root comes first, as on a real host: a mount at / made after the
    # others would cover them.
    cat > "${FINDMNT_FIXTURE}" <<'MOUNT_TABLE'
/ ext4 rw,relatime /dev/sda1
/mnt/projects nfs4 rw,relatime,vers=4.1,rsize=1048576,hard,proto=tcp,sec=sys filer01.example.net:/export/projects
/mnt/scratch nfs4 rw,relatime,vers=4.2,soft,proto=tcp,sec=sys filer01.example.net:/export/scratch
/data/backups cifs ro,relatime,vers=3.1.1,sec=ntlmssp //backup01.example.net/archive
MOUNT_TABLE
}

teardown() {
    rm -rf -- "${work_directory}";
}

write_manifest() {
    printf '%s\n' "$@" > "${work_directory}/manifest";
}

run_audit() {
    run bash "${script_path}" "${work_directory}/manifest";
}

# Loads the reporter's functions without running it. One source line, so
# one directive covers it. SC1091 is shellcheck saying it will not open the
# sourced file unless run with -x; the library is linted on its own, and
# "shellcheck -x --source-path=SCRIPTDIR/.. test/mount_audit_reporter.bats"
# follows it and comes back clean.
load_reporter_functions() {
    # shellcheck source=mount_audit_reporter.sh disable=SC1091
    MOUNT_AUDIT_LIB_ONLY=1 source "${script_path}";
}

# ---------------------------------------------------------------------
# Exact-token option matching
# ---------------------------------------------------------------------

@test "option matching finds a token at the start, middle, and end" {
    load_reporter_functions;
    option_is_present rw "rw,hard,vers=4.1";
    option_is_present hard "rw,hard,vers=4.1";
    option_is_present vers=4.1 "rw,hard,vers=4.1";
}

@test "soft does not match softerr or softreval" {
    load_reporter_functions;
    run option_is_present soft "rw,softerr,proto=tcp";
    [ "${status}" -eq 1 ];
    run option_is_present soft "rw,hard,softreval";
    [ "${status}" -eq 1 ];
}

@test "an option value must match exactly" {
    load_reporter_functions;
    run option_is_present vers=4.1 "rw,vers=4.2,hard";
    [ "${status}" -eq 1 ];
}

@test "a glob character in a token is matched literally" {
    load_reporter_functions;
    run option_is_present "vers=*" "rw,vers=4.2,hard";
    [ "${status}" -eq 1 ];
}

# ---------------------------------------------------------------------
# Audit results
# ---------------------------------------------------------------------

@test "a manifest that matches the live table exits 0" {
    write_manifest \
        "/mnt/projects nfs4 hard,vers=4.1 soft" \
        "/mnt/scratch nfs4 soft -" \
        "/data/backups cifs ro rw";
    run_audit;
    [ "${status}" -eq 0 ];
    [[ "${output}" == "MOUNT AUDIT OK: 3 mount(s) match expectations"* ]];
}

@test "a declared mount that is absent is reported as not mounted" {
    write_manifest "/mnt/archive nfs4 hard -";
    run_audit;
    [ "${status}" -eq 1 ];
    [[ "${output}" == *"/mnt/archive: not mounted"* ]];
}

@test "a path inside a mount is not that mount" {
    write_manifest "/mnt/projects/team nfs4 hard -";
    run_audit;
    [ "${status}" -eq 1 ];
    [[ "${output}" == *"/mnt/projects/team: not mounted"* ]];
}

@test "a wrong filesystem type is reported with both values" {
    write_manifest "/mnt/projects nfs hard -";
    run_audit;
    [ "${status}" -eq 1 ];
    [[ "${output}" == *"/mnt/projects: fstype is nfs4, expected nfs"* ]];
}

@test "a missing required option is reported" {
    write_manifest "/mnt/scratch nfs4 hard -";
    run_audit;
    [ "${status}" -eq 1 ];
    [[ "${output}" == *"/mnt/scratch: required option missing: hard"* ]];
}

@test "a present forbidden option is reported" {
    write_manifest "/data/backups cifs - ro";
    run_audit;
    [ "${status}" -eq 1 ];
    [[ "${output}" == *"/data/backups: forbidden option present: ro"* ]];
}

@test "every finding is reported in one run" {
    write_manifest \
        "/mnt/projects nfs hard,vers=4.2 -" \
        "/mnt/scratch nfs4 hard soft" \
        "/mnt/archive nfs4 hard -";
    run_audit;
    [ "${status}" -eq 1 ];
    [[ "${output}" == "MOUNT AUDIT: 5 finding(s) across 3 mount(s)"* ]];
    [[ "${output}" == *"/mnt/projects: fstype is nfs4, expected nfs"* ]];
    [[ "${output}" == *"/mnt/projects: required option missing: vers=4.2"* ]];
    [[ "${output}" == *"/mnt/scratch: required option missing: hard"* ]];
    [[ "${output}" == *"/mnt/scratch: forbidden option present: soft"* ]];
    [[ "${output}" == *"/mnt/archive: not mounted"* ]];
}

@test "a stack is audited through its visible mount, and the stack is a note" {
    printf '%s\n' "/mnt/projects nfs4 rw,vers=4.2,soft" >> "${FINDMNT_FIXTURE}";
    write_manifest "/mnt/projects nfs4 hard -";
    run_audit;
    [ "${status}" -eq 1 ];
    [[ "${output}" == "MOUNT AUDIT: 1 finding(s)"* ]];
    [[ "${output}" == *"/mnt/projects: required option missing: hard"* ]];
    [[ "${output}" == *"note: /mnt/projects: 2 mounts stacked; audited the visible one"* ]];
}

@test "a stack whose visible mount matches exits 0, with the note" {
    printf '%s\n' "/mnt/projects nfs4 rw,vers=4.1,hard filer01.example.net:/export/projects" >> "${FINDMNT_FIXTURE}";
    write_manifest "/mnt/projects nfs4 hard - filer01.example.net:/export/projects";
    run_audit;
    [ "${status}" -eq 0 ];
    [[ "${output}" == "MOUNT AUDIT OK: 1 mount(s)"* ]];
    [[ "${output}" == *"note: /mnt/projects: 2 mounts stacked"* ]];
}

@test "the visible mount is chosen the same way whatever order findmnt prints" {
    printf '%s\n' "/mnt/projects nfs4 rw,vers=4.2,soft" >> "${FINDMNT_FIXTURE}";
    write_manifest "/mnt/projects nfs4 hard -";
    FINDMNT_REVERSE=1 run_audit;
    [ "${status}" -eq 1 ];
    [[ "${output}" == *"/mnt/projects: required option missing: hard"* ]];
}

@test "a stack with no single visible mount is an error, never a guess" {
    printf '#!/usr/bin/env bash\necho "201 1 /mnt/projects nfs4 rw,hard a:/x";\necho "202 1 /mnt/projects nfs4 rw,soft b:/x";\nexit 0;\n' > "${shim_directory}/findmnt";
    chmod +x "${shim_directory}/findmnt";
    write_manifest "/mnt/projects nfs4 hard -";
    run_audit;
    [ "${status}" -eq 2 ];
    [[ "${output}" == *"ERROR: /mnt/projects: cannot tell which of 2 stacked mounts is visible"* ]];
    [[ "${output}" != *"required option missing"* ]];
}

@test "the forbidden column may be omitted" {
    write_manifest "/mnt/projects nfs4 hard";
    run_audit;
    [ "${status}" -eq 0 ];
}

@test "comments, blank lines, and a last line with no newline are handled" {
    printf '%s\n' "# client mounts" "" "/mnt/projects nfs4 hard  # trailing note" > "${work_directory}/manifest";
    printf '%s' "/mnt/scratch nfs4 soft" >> "${work_directory}/manifest";
    run_audit;
    [ "${status}" -eq 0 ];
    [[ "${output}" == "MOUNT AUDIT OK: 2 mount(s)"* ]];
}

# ---------------------------------------------------------------------
# Expected source
# ---------------------------------------------------------------------

@test "a matching source passes" {
    write_manifest "/mnt/projects nfs4 hard - filer01.example.net:/export/projects";
    run_audit;
    [ "${status}" -eq 0 ];
}

@test "a different source is reported with both values" {
    write_manifest "/mnt/projects nfs4 hard - filer02.example.net:/export/projects";
    run_audit;
    [ "${status}" -eq 1 ];
    [[ "${output}" == *"/mnt/projects: source is filer01.example.net:/export/projects, expected filer02.example.net:/export/projects"* ]];
}

@test "a source of - is not checked" {
    write_manifest "/data/backups cifs ro rw -";
    run_audit;
    [ "${status}" -eq 0 ];
}

@test "the source of a stacked mount is read from the visible one" {
    printf '%s\n' "/mnt/projects nfs4 rw,vers=4.1,hard filer02.example.net:/export/projects" >> "${FINDMNT_FIXTURE}";
    write_manifest "/mnt/projects nfs4 hard - filer01.example.net:/export/projects";
    run_audit;
    [ "${status}" -eq 1 ];
    [[ "${output}" == *"source is filer02.example.net:/export/projects, expected filer01.example.net:/export/projects"* ]];
}

# ---------------------------------------------------------------------
# Manifest errors exit 2 before anything is audited
# ---------------------------------------------------------------------

@test "a missing manifest exits 2" {
    run bash "${script_path}" "${work_directory}/absent";
    [ "${status}" -eq 2 ];
    [[ "${output}" == *"manifest missing or unreadable"* ]];
}

@test "a line with too few columns exits 2" {
    write_manifest "/mnt/projects nfs4";
    run_audit;
    [ "${status}" -eq 2 ];
    [[ "${output}" == *"line 1: needs at least"* ]];
}

@test "a line with six columns exits 2" {
    write_manifest "/mnt/projects nfs4 hard soft filer01.example.net:/export/projects extra";
    run_audit;
    [ "${status}" -eq 2 ];
    [[ "${output}" == *"line 1: more than five columns"* ]];
}

@test "a relative mountpoint exits 2" {
    write_manifest "mnt/projects nfs4 hard -";
    run_audit;
    [ "${status}" -eq 2 ];
    [[ "${output}" == *"must be an absolute path"* ]];
}

@test "an empty option between commas exits 2" {
    write_manifest "/mnt/projects nfs4 hard,,vers=4.1 -";
    run_audit;
    [ "${status}" -eq 2 ];
    [[ "${output}" == *"required column must be - alone or options separated by single commas"* ]];
}

@test "a - inside an option list exits 2 before findmnt runs, in either column and any position" {
    printf '#!/usr/bin/env bash\necho "findmnt was called" >&2;\nexit 0;\n' > "${shim_directory}/findmnt";
    chmod +x "${shim_directory}/findmnt";
    for bad_line in "/mnt/absent tmpfs rw,-" "/mnt/absent tmpfs -,rw" "/mnt/absent tmpfs rw,-,nodev" \
        "/mnt/absent tmpfs rw rw,-" "/mnt/absent tmpfs rw -,nodev" "/mnt/absent tmpfs rw nosuid,-,nodev"; do
        write_manifest "${bad_line}";
        run_audit;
        [ "${status}" -eq 2 ];
        [[ "${output}" == *"must be - alone or options separated by single commas"* ]];
        [[ "${output}" != *"findmnt was called"* ]];
        [[ "${output}" != *"not mounted"* ]];
    done;
}

@test "a mountpoint declared twice exits 2" {
    write_manifest "/mnt/projects nfs4 hard -" "/mnt/projects nfs4 vers=4.1 -";
    run_audit;
    [ "${status}" -eq 2 ];
    [[ "${output}" == *"line 2: /mnt/projects already declared on line 1"* ]];
}

@test "an option both required and forbidden exits 2" {
    write_manifest "/mnt/projects nfs4 hard,vers=4.1 soft,hard";
    run_audit;
    [ "${status}" -eq 2 ];
    [[ "${output}" == *"hard is both required and forbidden"* ]];
}

@test "a manifest that declares nothing exits 2" {
    write_manifest "# nothing declared yet" "";
    run_audit;
    [ "${status}" -eq 2 ];
    [[ "${output}" == *"manifest declares no mounts"* ]];
}

@test "a malformed line after a failing line reports no findings" {
    write_manifest "/mnt/archive nfs4 hard -" "/mnt/projects";
    run_audit;
    [ "${status}" -eq 2 ];
    [[ "${output}" != *"not mounted"* ]];
}

# ---------------------------------------------------------------------
# findmnt failures, comments, repeated runs (critique round 1)
# ---------------------------------------------------------------------

# Replaces the fixture-reading stand-in with one that fails the way a
# broken findmnt does: a message on stderr and a non-zero exit.
use_failing_findmnt() {
    printf '#!/usr/bin/env bash\necho "findmnt: %s" >&2;\nexit %s;\n' "${1}" "${2}" \
        > "${shim_directory}/findmnt";
    chmod +x "${shim_directory}/findmnt";
}

@test "a findmnt error stops the audit with exit 2 and reports nothing as mounted or missing" {
    use_failing_findmnt "simulated read failure" 1;
    write_manifest "/mnt/projects nfs4 hard -";
    run_audit;
    [ "${status}" -eq 2 ];
    [[ "${output}" == *"ERROR: findmnt exited 1: findmnt: simulated read failure"* ]];
    [[ "${output}" != *"not mounted"* ]];
    [[ "${output}" != *"MOUNT AUDIT OK"* ]];
}

@test "a silent exit 1 is an error too, never a not-mounted finding" {
    printf '#!/usr/bin/env bash\nexit 1;\n' > "${shim_directory}/findmnt";
    chmod +x "${shim_directory}/findmnt";
    write_manifest "/mnt/projects nfs4 hard -";
    run_audit;
    [ "${status}" -eq 2 ];
    [[ "${output}" == *"ERROR: findmnt exited 1"* ]];
    [[ "${output}" != *"not mounted"* ]];
}

@test "a findmnt that dies silently with an unexpected exit code stops the audit" {
    printf '#!/usr/bin/env bash\nexit 3;\n' > "${shim_directory}/findmnt";
    chmod +x "${shim_directory}/findmnt";
    write_manifest "/mnt/projects nfs4 hard -";
    run_audit;
    [ "${status}" -eq 2 ];
    [[ "${output}" == *"findmnt exited 3"* ]];
}

@test "an audit reads the mount table once, however many mounts it declares" {
    FINDMNT_CALLS="${work_directory}/findmnt_calls";
    export FINDMNT_CALLS;
    mv "${shim_directory}/findmnt" "${shim_directory}/findmnt_fixture";
    cat > "${shim_directory}/findmnt" <<COUNTING_FINDMNT
#!/usr/bin/env bash
echo "\$(( \$(cat "\${FINDMNT_CALLS}" 2>/dev/null || echo 0) + 1 ))" > "\${FINDMNT_CALLS}";
exec "${shim_directory}/findmnt_fixture" "\$@";
COUNTING_FINDMNT
    chmod +x "${shim_directory}/findmnt";
    write_manifest "/mnt/projects nfs4 hard -" "/mnt/scratch nfs4 soft -" "/data/backups cifs ro -";
    run_audit;
    [ "${status}" -eq 0 ];
    [ "$(cat "${FINDMNT_CALLS}")" -eq 1 ];
}

@test "a findmnt error message with no final newline is still an error" {
    printf '#!/usr/bin/env bash\nprintf "%%s" "lookup failed" >&2;\nexit 1;\n' > "${shim_directory}/findmnt";
    chmod +x "${shim_directory}/findmnt";
    write_manifest "/mnt/test tmpfs rw - -";
    run_audit;
    [ "${status}" -eq 2 ];
    [[ "${output}" == *"ERROR: findmnt exited 1: lookup failed"* ]];
    [[ "${output}" != *"not mounted"* ]];
}

@test "findmnt output is kept apart from its error lines" {
    printf '#!/usr/bin/env bash\necho "205 1 /mnt/scratch tmpfs rw,nodev tmpfs";\necho "findmnt: a warning" >&2;\nexit 0;\n' > "${shim_directory}/findmnt";
    chmod +x "${shim_directory}/findmnt";
    write_manifest "/mnt/scratch tmpfs nodev - tmpfs";
    run_audit;
    [ "${status}" -eq 0 ];
}

@test "a row findmnt prints that the script cannot read stops the audit" {
    printf '#!/usr/bin/env bash\necho "205 1 /mnt/scratch tmpfs rw tmpfs";\necho "x 1 /mnt/projects nfs4 rw,hard a:/x";\nexit 0;\n' > "${shim_directory}/findmnt";
    chmod +x "${shim_directory}/findmnt";
    write_manifest "/mnt/scratch tmpfs rw -";
    run_audit;
    [ "${status}" -eq 2 ];
    [[ "${output}" == *"ERROR: unexpected row from findmnt: x 1 /mnt/projects"* ]];
    [[ "${output}" != *"MOUNT AUDIT OK"* ]];
}

@test "a stack the table cannot resolve does not stop the other mounts being audited" {
    printf '#!/usr/bin/env bash\necho "201 1 /mnt/projects nfs4 rw,hard a:/x";\necho "202 1 /mnt/projects nfs4 rw,soft b:/x";\necho "203 1 /data/backups cifs ro b:/y";\nexit 0;\n' > "${shim_directory}/findmnt";
    chmod +x "${shim_directory}/findmnt";
    write_manifest "/mnt/projects nfs4 hard -" "/data/backups cifs rw -";
    run_audit;
    [ "${status}" -eq 2 ];
    [[ "${output}" == *"MOUNT AUDIT INCOMPLETE: 1 finding(s) across 1 mount(s); 1 mount(s) could not be checked"* ]];
    [[ "${output}" == *"  - /data/backups: required option missing: rw"* ]];
    [[ "${output}" == *"ERROR: /mnt/projects: cannot tell which of 2 stacked mounts is visible"* ]];
}

# ---------------------------------------------------------------------
# Mounts hidden by a later mount above them (critique round 8)
# ---------------------------------------------------------------------

@test "a mount whose parent path was mounted over later is a hidden finding" {
    printf '%s\n' "/srv ext4 rw" "/srv/tree/data tmpfs rw,nodev" "/srv tmpfs rw" >> "${FINDMNT_FIXTURE}";
    write_manifest "/srv/tree/data tmpfs nodev";
    run_audit;
    [ "${status}" -eq 1 ];
    [[ "${output}" == *"/srv/tree/data: hidden: a later mount at /srv covers it"* ]];
    [[ "${output}" != *"MOUNT AUDIT OK"* ]];
    # Two levels up: /srv/a/b sits on /srv/a, and the later /srv covers /srv/a.
    printf '%s\n' "/ ext4 rw,relatime /dev/sda1" "/srv ext4 rw" "/srv/a tmpfs rw" "/srv/a/b tmpfs rw,nodev" "/srv tmpfs rw" > "${FINDMNT_FIXTURE}";
    write_manifest "/srv/a/b tmpfs nodev";
    run_audit;
    [ "${status}" -eq 1 ];
    [[ "${output}" == *"/srv/a/b: hidden: a later mount at /srv covers it"* ]];
    # A later mount over / itself covers everything mounted on the old root.
    printf '%s\n' "/ ext4 rw,relatime /dev/sda1" "/data tmpfs rw,nodev" "/ tmpfs rw" > "${FINDMNT_FIXTURE}";
    write_manifest "/data tmpfs nodev";
    run_audit;
    [ "${status}" -eq 1 ];
    [[ "${output}" == *"/data: hidden: a later mount at / covers it"* ]];
}

@test "a later mount at a directory between a mount and its parent hides it" {
    printf '%s\n' "/srv ext4 rw" "/srv/tree/data tmpfs rw,nodev" "/srv/tree tmpfs rw" >> "${FINDMNT_FIXTURE}";
    write_manifest "/srv/tree/data tmpfs nodev";
    run_audit;
    [ "${status}" -eq 1 ];
    [[ "${output}" == *"/srv/tree/data: hidden: a later mount at /srv/tree covers it"* ]];
}

@test "the same mounts made in the usual order are visible and pass" {
    printf '%s\n' "/srv ext4 rw" "/srv/tree tmpfs rw" "/srv/tree/data tmpfs rw,nodev" >> "${FINDMNT_FIXTURE}";
    write_manifest "/srv/tree/data tmpfs nodev" "/srv/tree tmpfs rw";
    run_audit;
    [ "${status}" -eq 0 ];
}

@test "a hidden mount is found whatever order findmnt prints" {
    printf '%s\n' "/srv ext4 rw" "/srv/tree/data tmpfs rw,nodev" "/srv tmpfs rw" >> "${FINDMNT_FIXTURE}";
    write_manifest "/srv/tree/data tmpfs nodev";
    FINDMNT_REVERSE=1 run_audit;
    [ "${status}" -eq 1 ];
    [[ "${output}" == *"/srv/tree/data: hidden: a later mount at /srv covers it"* ]];
}

@test "a later mount at /srv does not hide /srvdata, which only shares the prefix" {
    printf '%s\n' "/srvdata tmpfs rw,nodev" "/srv tmpfs rw" >> "${FINDMNT_FIXTURE}";
    write_manifest "/srvdata tmpfs nodev";
    run_audit;
    [ "${status}" -eq 0 ];
}

@test "a path mounted, covered by a later mount above it, and mounted again audits the reachable one" {
    # The WSL2 layout on the lab workstation: /tmp/.X11-unix, then a tmpfs
    # over /tmp, then /tmp/.X11-unix again on the new /tmp.
    printf '%s\n' "/tmp/.X11-unix tmpfs ro,nodev wslg_first" "/tmp tmpfs rw,nosuid,nodev tmpfs" "/tmp/.X11-unix tmpfs ro,relatime wslg_second" >> "${FINDMNT_FIXTURE}";
    write_manifest "/tmp/.X11-unix tmpfs ro - wslg_second";
    run_audit;
    [ "${status}" -eq 0 ];
    [[ "${output}" == *"note: /tmp/.X11-unix: 2 mounts stacked; audited the visible one"* ]];
    write_manifest "/tmp/.X11-unix tmpfs nodev - wslg_second";
    run_audit;
    [ "${status}" -eq 1 ];
    [[ "${output}" == *"/tmp/.X11-unix: required option missing: nodev"* ]];
}

@test "the reachable mount is found the same way whatever order findmnt prints" {
    printf '%s\n' "/tmp/.X11-unix tmpfs ro wslg_first" "/tmp tmpfs rw tmpfs" "/tmp/.X11-unix tmpfs ro wslg_second" >> "${FINDMNT_FIXTURE}";
    write_manifest "/tmp/.X11-unix tmpfs ro - wslg_second";
    FINDMNT_REVERSE=1 run_audit;
    [ "${status}" -eq 0 ];
}

@test "generate records the reachable mount at a path that was covered and mounted again" {
    printf '%s\n' "/tmp/.X11-unix tmpfs ro wslg_first" "/tmp tmpfs rw tmpfs" "/tmp/.X11-unix tmpfs ro wslg_second" >> "${FINDMNT_FIXTURE}";
    run bash "${script_path}" --generate tmpfs;
    [ "${status}" -eq 0 ];
    [[ "${output}" == *$'\n/tmp/.X11-unix  tmpfs  ro  -  wslg_second'* ]];
    [[ "${output}" != *"wslg_first"* ]];
    [[ "${output}" != *"skipped: /tmp/.X11-unix"* ]];
}

# Prints the rows given as arguments, one per line, as findmnt's whole table.
use_findmnt_rows() {
    printf '#!/usr/bin/env bash\n' > "${shim_directory}/findmnt";
    printf 'echo "%s";\n' "$@" >> "${shim_directory}/findmnt";
    chmod +x "${shim_directory}/findmnt";
}

@test "a cover is named the same way whatever order findmnt prints, and it is the outermost" {
    use_findmnt_rows "1 1 / ext4 rw /dev/sda1" "2 1 /srv/lab/data tmpfs rw a" "3 1 /srv/lab tmpfs rw b" "4 1 /srv tmpfs rw c";
    write_manifest "/srv/lab/data tmpfs rw";
    run_audit;
    [ "${status}" -eq 1 ];
    [[ "${output}" == *"/srv/lab/data: hidden: a later mount at /srv covers it"* ]];
    use_findmnt_rows "1 1 / ext4 rw /dev/sda1" "2 1 /srv/lab/data tmpfs rw a" "4 1 /srv tmpfs rw c" "3 1 /srv/lab tmpfs rw b";
    run_audit;
    [ "${status}" -eq 1 ];
    [[ "${output}" == *"/srv/lab/data: hidden: a later mount at /srv covers it"* ]];
    # Two covered candidates at one path, covered by /x and by /x/y: the
    # outermost is named in either print order.
    use_findmnt_rows "1 1 / ext4 rw /dev/sda1" "2 1 /x/y/d tmpfs rw a" "3 1 /x tmpfs rw x1" "4 3 /x/y/d tmpfs rw b" "5 3 /x/y tmpfs rw c";
    write_manifest "/x/y/d tmpfs rw";
    run_audit;
    [ "${status}" -eq 1 ];
    [[ "${output}" == *"/x/y/d: hidden: a later mount at /x covers it"* ]];
    use_findmnt_rows "1 1 / ext4 rw /dev/sda1" "5 3 /x/y tmpfs rw c" "4 3 /x/y/d tmpfs rw b" "3 1 /x tmpfs rw x1" "2 1 /x/y/d tmpfs rw a";
    run_audit;
    [ "${status}" -eq 1 ];
    [[ "${output}" == *"/x/y/d: hidden: a later mount at /x covers it"* ]];
}

@test "a cover decides it before two mounts at one path on one parent, in either order" {
    use_findmnt_rows "88 88 / ext4 rw /dev/sda1" "200 88 /srv tmpfs rw a" "210 200 /srv/data tmpfs rw b" "211 200 /srv/data tmpfs rw c" "212 200 /srv tmpfs rw d";
    write_manifest "/srv/data tmpfs rw";
    run_audit;
    [ "${status}" -eq 1 ];
    [[ "${output}" == *"/srv/data: hidden: a later mount at /srv covers it"* ]];
    use_findmnt_rows "88 88 / ext4 rw /dev/sda1" "200 88 /srv tmpfs rw a" "212 200 /srv tmpfs rw d" "210 200 /srv/data tmpfs rw b" "211 200 /srv/data tmpfs rw c";
    run_audit;
    [ "${status}" -eq 1 ];
    [[ "${output}" == *"/srv/data: hidden: a later mount at /srv covers it"* ]];
}

@test "two mounts at one path on one parent, with nothing covering them, are an error" {
    use_findmnt_rows "88 88 / ext4 rw /dev/sda1" "200 88 /srv tmpfs rw a" "210 200 /srv/data tmpfs rw b" "211 200 /srv/data tmpfs rw c";
    write_manifest "/srv/data tmpfs rw";
    run_audit;
    [ "${status}" -eq 2 ];
    [[ "${output}" == *"two mounts at /srv/data share one parent"* ]];
}

@test "a mount covered below an ambiguous level is hidden, since it is unreachable either way" {
    use_findmnt_rows "1 1 / ext4 rw /dev/sda1" "2 1 /a tmpfs rw a" "3 2 /a/b/c tmpfs rw b" "4 2 /a/b tmpfs rw c" "5 1 /a tmpfs rw d";
    write_manifest "/a/b/c tmpfs rw";
    run_audit;
    [ "${status}" -eq 1 ];
    [[ "${output}" == *"/a/b/c: hidden: a later mount at /a/b covers it"* ]];
}

@test "a parent loop is an error even when a cover would be found first" {
    use_findmnt_rows "1 1 / ext4 rw /dev/sda1" "2 3 /a/b/c tmpfs rw a" "3 2 /a tmpfs rw b" "4 3 /a/b tmpfs rw c";
    write_manifest "/a/b/c tmpfs rw";
    # A time limit, so a lost loop check fails this test instead of hanging the suite.
    run timeout 20 bash "${script_path}" "${work_directory}/manifest";
    [ "${status}" -eq 2 ];
    [[ "${output}" == *"form a loop"* ]];
}

@test "a findmnt row with an extra column stops the audit" {
    use_findmnt_rows "88 88 / ext4 rw,relatime /dev/root EXTRA";
    write_manifest "/ ext4 rw,relatime - /dev/root";
    run_audit;
    [ "${status}" -eq 2 ];
    [[ "${output}" == *"unexpected row from findmnt"* ]];
    [[ "${output}" != *"MOUNT AUDIT OK"* ]];
}

@test "a findmnt row whose target is not an absolute path stops the audit" {
    use_findmnt_rows "1 1 tmpfs rw - -";
    write_manifest "/tmp tmpfs rw";
    run_audit;
    [ "${status}" -eq 2 ];
    [[ "${output}" == *"unexpected row from findmnt"* ]];
    [[ "${output}" != *"not mounted"* ]];
}

@test "a root mount that is its own parent is audited normally" {
    printf '#!/usr/bin/env bash\necho "21 21 / ext4 rw,relatime /dev/sda1";\necho "22 21 /mnt/scratch tmpfs rw tmpfs";\nexit 0;\n' > "${shim_directory}/findmnt";
    chmod +x "${shim_directory}/findmnt";
    write_manifest "/ ext4 rw - /dev/sda1" "/mnt/scratch tmpfs rw";
    run_audit;
    [ "${status}" -eq 0 ];
}

@test "a second mount that is its own parent is an error, never a second root" {
    printf '#!/usr/bin/env bash\necho "21 21 / ext4 rw,relatime /dev/sda1";\necho "22 22 /mnt/data tmpfs rw,relatime tmpfs";\nexit 0;\n' > "${shim_directory}/findmnt";
    chmod +x "${shim_directory}/findmnt";
    write_manifest "/mnt/data tmpfs rw - tmpfs";
    run_audit;
    [ "${status}" -eq 2 ];
    [[ "${output}" == *"more than one mount in the table is its own parent"* ]];
    [[ "${output}" != *"MOUNT AUDIT OK"* ]];
}

@test "parent IDs that form a loop are an error, never a hang" {
    printf '#!/usr/bin/env bash\necho "201 202 /a tmpfs rw x";\necho "202 201 /b tmpfs rw y";\nexit 0;\n' > "${shim_directory}/findmnt";
    chmod +x "${shim_directory}/findmnt";
    write_manifest "/a tmpfs rw";
    run timeout 20 bash "${script_path}" "${work_directory}/manifest";
    [ "${status}" -eq 2 ];
    [[ "${output}" == *"form a loop"* ]];
}

@test "a trailing slash on a mountpoint matches the mount" {
    write_manifest "/mnt/projects/ nfs4 hard -";
    run_audit;
    [ "${status}" -eq 0 ];
}

@test "a mountpoint with a backslash exits 2 instead of reading as not mounted" {
    write_manifest '/mnt/a\x20b tmpfs rw';
    run_audit;
    [ "${status}" -eq 2 ];
    [[ "${output}" == *"line 1: a mountpoint with a backslash cannot be matched"* ]];
}

@test "generate stops with exit 2 when findmnt fails" {
    use_failing_findmnt "simulated read failure" 1;
    run bash "${script_path}" --generate;
    [ "${status}" -eq 2 ];
    [[ "${output}" == *"findmnt exited 1: findmnt: simulated read failure"* ]];
}

@test "a # inside a source or a mountpoint is data, not a comment" {
    printf '%s\n' '/mnt/team#2 tmpfs rw server#A' >> "${FINDMNT_FIXTURE}";
    write_manifest "/mnt/team#2 tmpfs rw - server#A";
    run_audit;
    [ "${status}" -eq 0 ];
}

@test "a # after a tab starts a comment" {
    printf '/mnt/projects nfs4 hard\t# trailing note\n' > "${work_directory}/manifest";
    run_audit;
    [ "${status}" -eq 0 ];
}

@test "a sourced caller can run two manifests and get two independent results" {
    write_manifest "/mnt/projects nfs4 soft -";
    cp "${work_directory}/manifest" "${work_directory}/first.manifest";
    write_manifest "/mnt/projects nfs4 hard -";
    load_reporter_functions;
    run_manifest "${work_directory}/first.manifest" || first_status="$?";
    run_manifest "${work_directory}/manifest";
    second_status="$?";
    [ "${first_status:-0}" -eq 1 ];
    [ "${second_status}" -eq 0 ];
}

# ---------------------------------------------------------------------
# Command line and environment
# ---------------------------------------------------------------------

@test "a missing findmnt exits 2" {
    empty_bin="${work_directory}/empty_bin";
    mkdir -p "${empty_bin}";
    write_manifest "/mnt/projects nfs4 hard -";
    run env PATH="${empty_bin}" "${BASH}" "${script_path}" "${work_directory}/manifest";
    [ "${status}" -eq 2 ];
    [[ "${output}" == *"findmnt not found"* ]];
}

@test "no arguments, an unknown flag, or extra arguments exit 2" {
    run bash "${script_path}";
    [ "${status}" -eq 2 ];
    run bash "${script_path}" --verbose;
    [ "${status}" -eq 2 ];
    run bash "${script_path}" --fix;
    [ "${status}" -eq 2 ];
    write_manifest "/mnt/projects nfs4 hard -";
    run bash "${script_path}" "${work_directory}/manifest" extra;
    [ "${status}" -eq 2 ];
}

# ---------------------------------------------------------------------
# Generate mode
# ---------------------------------------------------------------------

@test "generate lists network mounts by default and nothing else" {
    run bash "${script_path}" --generate;
    [ "${status}" -eq 0 ];
    [[ "${output}" == *"/mnt/projects  nfs4  rw,relatime,vers=4.1,rsize=1048576,hard,proto=tcp,sec=sys  -  filer01.example.net:/export/projects"* ]];
    [[ "${output}" == *"/data/backups  cifs  "* ]];
    [[ "${output}" != *"ext4"* ]];
}

@test "generate honors a type list" {
    run bash "${script_path}" --generate ext4;
    [ "${status}" -eq 0 ];
    [[ "${output}" == *"/  ext4  rw,relatime  -  /dev/sda1"* ]];
    [[ "${output}" != *"nfs4  "* ]];
}

@test "a generated manifest passes its own audit" {
    bash "${script_path}" --generate > "${work_directory}/manifest";
    run_audit;
    [ "${status}" -eq 0 ];
    [[ "${output}" == "MOUNT AUDIT OK: 3 mount(s)"* ]];
}

@test "generate records the visible mount of a stack, in either print order" {
    printf '%s\n' "/mnt/projects nfs4 rw,vers=4.2,soft filer02.example.net:/export/projects" >> "${FINDMNT_FIXTURE}";
    FINDMNT_REVERSE=1 run bash "${script_path}" --generate;
    [ "${status}" -eq 0 ];
    [[ "${output}" == *"/mnt/projects  nfs4  rw,vers=4.2,soft  -  filer02.example.net:/export/projects"* ]];
    run bash "${script_path}" --generate;
    [ "${status}" -eq 0 ];
    [[ "${output}" == *"# note: 2 mounts stacked at /mnt/projects; the visible one is recorded"* ]];
    [[ "${output}" == *"/mnt/projects  nfs4  rw,vers=4.2,soft  -  filer02.example.net:/export/projects"* ]];
    [ "$(grep -c '^/mnt/projects ' <<< "${output}")" -eq 1 ];
}

@test "generate skips a mountpoint it cannot express" {
    printf '%s\n' '/mnt/team\x20share cifs rw,vers=3.1.1' >> "${FINDMNT_FIXTURE}";
    run bash "${script_path}" --generate;
    [ "${status}" -eq 0 ];
    [[ "${output}" == *'# skipped: /mnt/team\x20share'* ]];
    [ "$(grep -c '^/mnt/team' <<< "${output}")" -eq 0 ];
}

@test "generate keeps a # inside a source, and the result audits clean" {
    printf '%s\n' '/mnt/odd tmpfs rw,relatime server#A' >> "${FINDMNT_FIXTURE}";
    run bash "${script_path}" --generate tmpfs;
    [ "${status}" -eq 0 ];
    [[ "${output}" == *"/mnt/odd  tmpfs  rw,relatime  -  server#A"* ]];
    bash "${script_path}" --generate tmpfs > "${work_directory}/manifest";
    run_audit;
    [ "${status}" -eq 0 ];
}

@test "generate writes a source it cannot record as - with a note, never silently" {
    printf '%s\n' '/mnt/hashsource tmpfs rw #fs-source' '/mnt/dashsource tmpfs rw -' '/mnt/nosource tmpfs rw' \
        '/mnt/plain tmpfs rw,nodev plain-source' > "${FINDMNT_FIXTURE}";
    run bash "${script_path}" --generate tmpfs;
    [ "${status}" -eq 0 ];
    [[ "${output}" == *"# note: source of /mnt/hashsource is #fs-source, which this format cannot record; written as - (not checked)"* ]];
    [[ "${output}" == *"# note: source of /mnt/dashsource is -, which this format cannot record"* ]];
    [[ "${output}" == *"# note: source of /mnt/nosource is empty, which this format cannot record"* ]];
    [[ "${output}" == *"/mnt/plain  tmpfs  rw,nodev  -  plain-source"* ]];
}

@test "generate skips a mount whose type or options begin with #" {
    printf '%s\n' '/mnt/hashoptions tmpfs #odd,rw src' '/mnt/plain tmpfs rw src' > "${FINDMNT_FIXTURE}";
    run bash "${script_path}" --generate tmpfs;
    [ "${status}" -eq 0 ];
    [[ "${output}" == *"# skipped: /mnt/hashoptions (its type or options begin with #"* ]];
    run grep -c '^/mnt/hashoptions' <<< "${output}";
    [ "${output}" = "0" ];
}

@test "generate decides on the visible member of a stack, never a hidden one" {
    printf '%s\n' '/mnt/stack tmpfs rw old-source' '/mnt/stack tmpfs #top rw' > "${FINDMNT_FIXTURE}";
    run bash "${script_path}" --generate tmpfs;
    [[ "${output}" != *"old-source"* ]];
    [[ "${output}" == *"# skipped: /mnt/stack"* ]];
    printf '%s\n' '/mnt/stack tmpfs rw old-source' '/mnt/stack tmpfs rw #top-source' > "${FINDMNT_FIXTURE}";
    run bash "${script_path}" --generate tmpfs;
    [[ "${output}" != *"old-source"* ]];
    [[ "${output}" == *"# note: source of /mnt/stack is #top-source"* ]];
}

@test "generate skips a mount hidden by a later mount above it, and says why" {
    printf '%s\n' "/srv ext4 rw" "/srv/tree/data nfs4 rw,hard a:/x" "/srv tmpfs rw" >> "${FINDMNT_FIXTURE}";
    run bash "${script_path}" --generate;
    [ "${status}" -eq 0 ];
    [[ "${output}" == *"# skipped: /srv/tree/data (hidden by a later mount at /srv)"* ]];
    [[ "${output}" != *$'\n/srv/tree/data '* ]];
}

@test "generate skips a path whose visible mount is not a type it was asked for" {
    printf '%s\n' "/mnt/projects tmpfs rw" >> "${FINDMNT_FIXTURE}";
    run bash "${script_path}" --generate;
    [ "${status}" -eq 0 ];
    [[ "${output}" == *"# skipped: /mnt/projects (the visible mount there is tmpfs)"* ]];
    [[ "${output}" != *$'\n/mnt/projects '* ]];
}

@test "generate skips a stack with no single visible mount, and says why" {
    printf '#!/usr/bin/env bash\necho "201 1 /mnt/projects nfs4 rw,hard a:/x";\necho "202 1 /mnt/projects nfs4 rw,soft b:/x";\necho "203 1 /mnt/scratch nfs4 rw,soft b:/y";\nexit 0;\n' > "${shim_directory}/findmnt";
    chmod +x "${shim_directory}/findmnt";
    run bash "${script_path}" --generate;
    [ "${status}" -eq 0 ];
    [[ "${output}" == *"# skipped: /mnt/projects (cannot tell which stacked mount is visible)"* ]];
    [[ "${output}" != *$'\n/mnt/projects '* ]];
}

@test "a manifest with a carriage return exits 2 before findmnt runs" {
    printf '#!/usr/bin/env bash\necho "findmnt was called" >&2;\nexit 0;\n' > "${shim_directory}/findmnt";
    chmod +x "${shim_directory}/findmnt";
    printf '/mnt/projects nfs4 hard\r\n' > "${work_directory}/manifest";
    run_audit;
    [ "${status}" -eq 2 ];
    [[ "${output}" == *"line 1: carriage return found"* ]];
    [[ "${output}" != *"findmnt was called"* ]];
}

@test "generate exits 2 when every matching mount had to be skipped" {
    printf '%s\n' '/mnt/team\x20share cifs rw,vers=3.1.1 //server/share' > "${FINDMNT_FIXTURE}";
    run bash "${script_path}" --generate cifs;
    [ "${status}" -eq 2 ];
    [[ "${output}" == *'# skipped: /mnt/team\x20share'* ]];
    [[ "${output}" == *"every matching mount was skipped"* ]];
}

@test "generate with no matching mounts exits 2" {
    run bash "${script_path}" --generate xfs;
    [ "${status}" -eq 2 ];
    [[ "${output}" == *"no live mounts of type xfs"* ]];
}

# ---------------------------------------------------------------------
# Read-only guarantee
# ---------------------------------------------------------------------

@test "neither mode calls mount or umount, and no temporary file is left behind" {
    scratch_temporary="${work_directory}/scratch_tmp";
    mkdir -p "${scratch_temporary}";
    write_manifest "/mnt/projects nfs hard -" "/mnt/archive nfs4 hard -";
    TMPDIR="${scratch_temporary}" run_audit;
    [ "${status}" -eq 1 ];
    TMPDIR="${scratch_temporary}" run bash "${script_path}" --generate;
    [ "${status}" -eq 0 ];
    [ ! -e "${state_change_log}" ];
    [ -z "$(ls -A "${scratch_temporary}")" ];
}

@test "a failing findmnt leaves no temporary file behind either" {
    scratch_temporary="${work_directory}/scratch_tmp";
    mkdir -p "${scratch_temporary}";
    use_failing_findmnt "simulated read failure" 1;
    write_manifest "/mnt/projects nfs4 hard -";
    TMPDIR="${scratch_temporary}" run_audit;
    [ "${status}" -eq 2 ];
    [ -z "$(ls -A "${scratch_temporary}")" ];
}

@test "reading the table from a sourced caller leaves no temporary file" {
    mkdir -p "${work_directory}/tmp";
    TMPDIR="${work_directory}/tmp";
    export TMPDIR;
    load_reporter_functions;
    load_mount_table;
    # shellcheck disable=SC2154  # set by the sourced load_mount_table
    [ "${#mount_table_ids[@]}" -eq 4 ];
    [ -z "$(ls -A "${work_directory}/tmp")" ];
}

@test "sourcing with MOUNT_AUDIT_LIB_ONLY runs nothing" {
    run bash -c "MOUNT_AUDIT_LIB_ONLY=1 source '${script_path}' && echo sourced";
    [ "${status}" -eq 0 ];
    [ "${output}" = "sourced" ];
}
