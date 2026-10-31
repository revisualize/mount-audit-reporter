#!/usr/bin/env bash
# nfs_lab_audit_client.sh, Revision 2, 2026-10-28
# Runs on the lab NFS client. Clones mount-audit-reporter, runs its test
# suite, then audits real NFS mounts from the lab server and compares each
# exit code with what the README and project page predict. Mounts only under
# /mnt/lab and unmounts everything there before it exits.
#
# Revision 1 (2026-10-28) produced ../nfs_lab_run_2026-10-28.txt. Revision 2
# renames the file for publication and adds one shellcheck directive; no
# command changed. It assumes the lab layout in ../lab_runs_2026-10-28.md:
# server 192.168.77.10 exporting /srv/nfs/projects, client user with
# passwordless sudo, mount points under /mnt/lab.
set -u;
exec 2>&1;

server_address="192.168.77.10";
export_path="/srv/nfs/projects";
nfs_source="${server_address}:${export_path}";
mount_parent="/mnt/lab";
mount_target="/mnt/lab/projects";
repository_url="https://github.com/revisualize/mount-audit-reporter";
released_script_sha256="2778d1c629cb";
work_directory="$(mktemp -d "${HOME}/r002_run.XXXXXX")";
repository_directory="${work_directory}/mount-audit-reporter";
script_path="${repository_directory}/mount_audit_reporter.sh";
check_count=0;
mismatch_count=0;

# Pops every mount under /mnt/lab, top first, so a stack or a cover comes
# off before the mount beneath it.
unmount_lab_mounts() {
  local attempt;
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if mountpoint -q "${mount_parent}"; then
      sudo umount "${mount_parent}";
    elif mountpoint -q "${mount_target}"; then
      sudo umount "${mount_target}";
    else
      return 0;
    fi;
  done;
  echo "WARN: mounts still present under ${mount_parent} after ${attempt} attempts:";
  findmnt -R "${mount_parent}";
};
trap unmount_lab_mounts EXIT;

# check_audit <label> <manifest line> <predicted exit status>
check_audit() {
  local label="${1}";
  local manifest_line="${2}";
  local predicted_status="${3}";
  local manifest_file="${work_directory}/check.manifest";
  local actual_status;
  printf '%s\n' "${manifest_line}" > "${manifest_file}";
  echo "  -- ${label}";
  echo "     manifest: ${manifest_line}";
  bash "${script_path}" "${manifest_file}" | sed 's/^/     /';
  actual_status="${PIPESTATUS[0]}";
  check_count=$((check_count + 1));
  if [ "${actual_status}" = "${predicted_status}" ]; then
    echo "     exit ${actual_status}, page predicts ${predicted_status}: MATCH";
  else
    mismatch_count=$((mismatch_count + 1));
    echo "     exit ${actual_status}, page predicts ${predicted_status}: MISMATCH";
  fi;
};

# mount_nfs [options]  (no argument: mount with the kernel's defaults)
mount_nfs() {
  if [ -n "${1:-}" ]; then
    sudo mount -t nfs4 -o "${1}" "${nfs_source}" "${mount_target}";
  else
    sudo mount -t nfs4 "${nfs_source}" "${mount_target}";
  fi;
};

echo "== Client environment";
echo "date: $(date '+%F %T %z')";
echo "hostname: $(hostname)";
# shellcheck source=/dev/null
. /etc/os-release;
echo "os: ${PRETTY_NAME}";
echo "kernel: $(uname -r)";
echo "findmnt: $(findmnt --version)";
echo "bash: ${BASH_VERSION}";
echo "bats: $(bats --version 2>&1)";
echo "chronic: $(command -v chronic || echo missing)";
echo "git: $(git --version 2>&1)";
echo "-- shares offered by ${server_address}:";
showmount -e "${server_address}";

if mountpoint -q "${mount_parent}" || mountpoint -q "${mount_target}"; then
  echo "STOP: something is already mounted under ${mount_parent}; nothing tested";
  findmnt -R "${mount_parent}";
  trap - EXIT;
  exit 1;
fi;

echo "== Repository";
if ! git clone -q --depth 1 "${repository_url}" "${repository_directory}"; then
  echo "STOP: git clone failed";
  exit 1;
fi;
echo "commit: $(git -C "${repository_directory}" log -1 --format='%h %ad %s' --date=iso)";
script_sha256="$(sha256sum "${script_path}" | cut -c1-12)";
if [ "${script_sha256}" = "${released_script_sha256}" ]; then
  echo "script sha256: ${script_sha256} (the released Revision 14)";
else
  echo "script sha256: ${script_sha256} (NOT the released ${released_script_sha256})";
fi;

echo "== Test suite on this VM";
suite_log="${work_directory}/suite.log";
( cd "${repository_directory}" && bash test/run_all_tests.sh ) > "${suite_log}" 2>&1;
suite_status=$?;
echo "suite exit: ${suite_status}";
echo "tests passed: $(grep -c '^ok ' "${suite_log}"), failed: $(grep -c '^not ok ' "${suite_log}")";
grep '^not ok ' "${suite_log}";
grep 'executed:' "${suite_log}";

echo "== Real NFS mounts from ${nfs_source}";
require_hard="${mount_target} nfs4 hard - ${nfs_source}";
forbid_soft="${mount_target} nfs4 - soft ${nfs_source}";
check_audit "nothing mounted yet" "${require_hard}" 1;
for mode in default hard soft softerr; do
  case "${mode}" in
    default) mount_options=""; predicted_hard=0; predicted_soft=0 ;;
    hard) mount_options="hard"; predicted_hard=0; predicted_soft=0 ;;
    soft) mount_options="soft"; predicted_hard=1; predicted_soft=1 ;;
    softerr) mount_options="softerr"; predicted_hard=1; predicted_soft=0 ;;
  esac;
  echo "-- mode: ${mode} (mount -o ${mount_options:-none given})";
  if ! mount_nfs "${mount_options}"; then
    echo "   MOUNT FAILED for ${mode}";
    mismatch_count=$((mismatch_count + 1));
    continue;
  fi;
  echo "   findmnt: $(findmnt -n -o FSTYPE,SOURCE,OPTIONS "${mount_target}")";
  echo "   generate prints: $(bash "${script_path}" --generate | grep -F "${mount_target} ")";
  check_audit "require hard (${mode})" "${require_hard}" "${predicted_hard}";
  check_audit "forbid soft (${mode})" "${forbid_soft}" "${predicted_soft}";
  sudo umount "${mount_target}";
done;

echo "-- wrong source, stacked mount, hidden mount (NFS mounted hard underneath)";
if mount_nfs "hard"; then
  check_audit "manifest names a different server" "${mount_target} nfs4 hard - 192.168.77.99:${export_path}" 1;
  sudo mount -t tmpfs -o size=1m lab_stack "${mount_target}";
  check_audit "tmpfs stacked on top of the NFS mount" "${require_hard}" 1;
  sudo umount "${mount_target}";
  sudo mount -t tmpfs -o size=1m lab_cover "${mount_parent}";
  check_audit "tmpfs over /mnt/lab hides the NFS mount" "${require_hard}" 1;
  sudo umount "${mount_parent}";
  check_audit "NFS mount visible again" "${require_hard}" 0;
  sudo umount "${mount_target}";
else
  echo "   MOUNT FAILED for the stack and cover checks";
  mismatch_count=$((mismatch_count + 1));
fi;

echo "== SUMMARY: ${check_count} audits run, ${mismatch_count} differed from the page or failed to mount";
echo "suite: exit ${suite_status}; log kept at ${suite_log}";
echo "date: $(date '+%F %T %z')";
