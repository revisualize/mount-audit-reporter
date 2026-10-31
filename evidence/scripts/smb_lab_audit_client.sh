#!/usr/bin/env bash
# smb_lab_audit_client.sh, Revision 2, 2026-10-28
# Runs on the lab client. Installs cifs-utils, clones mount-audit-reporter,
# mounts //192.168.77.10/archive several ways, and audits each mount. Checks
# with a prediction print MATCH or MISMATCH; checks with none print
# OBSERVED. Mounts only at /mnt/lab/archive and unmounts it before it exits.
#
# Revision 1 (2026-10-28) produced the client half of
# ../smb_lab_run_2026-10-28.txt. Revision 2 renames the file for
# publication; no command changed. The password is read only to check that
# it never appears in the mount's option string; it is never printed.
set -u;
exec 2>&1;

smb_source="//192.168.77.10/archive";
credentials_file="/home/lab/smb_lab_credentials";
mount_target="/mnt/lab/archive";
repository_url="https://github.com/revisualize/mount-audit-reporter";
released_script_sha256="2778d1c629cb";
work_directory="$(mktemp -d "${HOME}/r002_smb_run.XXXXXX")";
repository_directory="${work_directory}/mount-audit-reporter";
script_path="${repository_directory}/mount_audit_reporter.sh";
smb_password="$(sed -n 's/^password=//p' "${credentials_file}")";
check_count=0;
mismatch_count=0;

unmount_lab_archive() {
  local attempt;
  for attempt in 1 2 3 4 5; do
    if mountpoint -q "${mount_target}"; then
      sudo umount "${mount_target}";
    else
      return 0;
    fi;
  done;
  echo "WARN: ${mount_target} still mounted after ${attempt} attempts";
};
trap unmount_lab_archive EXIT;

# check_audit <label> <manifest line> <predicted exit status, or observe>
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
  if [ "${predicted_status}" = "observe" ]; then
    echo "     exit ${actual_status}: OBSERVED (the page makes no prediction here)";
  elif [ "${actual_status}" = "${predicted_status}" ]; then
    echo "     exit ${actual_status}, page predicts ${predicted_status}: MATCH";
  else
    mismatch_count=$((mismatch_count + 1));
    echo "     exit ${actual_status}, page predicts ${predicted_status}: MISMATCH";
  fi;
};

# mount_smb <type> <options>  (credentials are always added)
mount_smb() {
  sudo mount -t "${1}" -o "credentials=${credentials_file},${2}" "${smb_source}" "${mount_target}";
};

# describe_mount: prints what findmnt and generate report, and whether the
# credentials show up in the option string.
describe_mount() {
  local options;
  options="$(findmnt -n -o OPTIONS "${mount_target}")";
  echo "   findmnt: $(findmnt -n -o FSTYPE,SOURCE "${mount_target}") ${options}";
  echo "   generate prints: $(bash "${script_path}" --generate | grep -F "${mount_target} ")";
  if [ -n "${smb_password}" ] && printf '%s' "${options}" | grep -qF "${smb_password}"; then
    echo "   password in findmnt options: YES (must be fixed before publishing anything)";
    mismatch_count=$((mismatch_count + 1));
  else
    echo "   password in findmnt options: no";
  fi;
  if printf '%s' "${options}" | grep -q 'username='; then
    echo "   username in findmnt options: yes";
  else
    echo "   username in findmnt options: no";
  fi;
};

echo "== Client environment";
echo "date: $(date '+%F %T %z')";
echo "hostname: $(hostname)";
echo "kernel: $(uname -r)";
echo "findmnt: $(findmnt --version)";

if [ -z "${smb_password}" ]; then
  echo "STOP: ${credentials_file} has no password= line";
  trap - EXIT;
  exit 1;
fi;
if mountpoint -q "${mount_target}"; then
  echo "STOP: something is already mounted at ${mount_target}; nothing tested";
  trap - EXIT;
  exit 1;
fi;
echo "== cifs-utils";
if ! sudo apt-get update -qq || ! sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cifs-utils > /dev/null; then
  echo "STOP: apt-get could not install cifs-utils";
  trap - EXIT;
  exit 1;
fi;
echo "mount.cifs: $(mount.cifs -V 2>&1)";
sudo mkdir -p "${mount_target}";

echo "== Repository";
if ! git clone -q --depth 1 "${repository_url}" "${repository_directory}"; then
  echo "STOP: git clone failed";
  exit 1;
fi;
script_sha256="$(sha256sum "${script_path}" | cut -c1-12)";
echo "script sha256: ${script_sha256} (released: ${released_script_sha256})";

echo "== Real SMB mounts from ${smb_source}";
read_only_contract="${mount_target} cifs ro rw ${smb_source}";
check_audit "nothing mounted yet" "${read_only_contract}" 1;

echo "-- mount -t cifs -o vers=3.1.1,ro";
if mount_smb cifs "vers=3.1.1,ro"; then
  describe_mount;
  check_audit "page example contract: cifs, require ro, forbid rw" "${read_only_contract}" 0;
  check_audit "manifest names a different share" "${mount_target} cifs ro rw //192.168.77.10/other" 1;
  check_audit "manifest requires vers=3.1.1" "${mount_target} cifs vers=3.1.1 - ${smb_source}" observe;
  sudo umount "${mount_target}";
else
  echo "   MOUNT FAILED (cifs, ro)";
  mismatch_count=$((mismatch_count + 1));
fi;

echo "-- mount -t cifs -o vers=3.1.1,rw";
if mount_smb cifs "vers=3.1.1,rw"; then
  describe_mount;
  check_audit "page example contract against a read-write mount" "${read_only_contract}" 1;
  sudo umount "${mount_target}";
else
  echo "   MOUNT FAILED (cifs, rw)";
  mismatch_count=$((mismatch_count + 1));
fi;

echo "-- mount -t smb3 -o ro (which filesystem type does findmnt report?)";
if mount_smb smb3 "ro"; then
  describe_mount;
  check_audit "page example contract (type cifs) against a -t smb3 mount" "${read_only_contract}" observe;
  check_audit "same contract written with type smb3" "${mount_target} smb3 ro rw ${smb_source}" observe;
  sudo umount "${mount_target}";
else
  echo "   MOUNT FAILED (smb3, ro)";
  mismatch_count=$((mismatch_count + 1));
fi;

echo "== SUMMARY: ${check_count} audits run, ${mismatch_count} differed from the page, failed to mount, or exposed the password";
echo "date: $(date '+%F %T %z')";
