#!/usr/bin/env bash
# smb_lab_server_setup.sh, Revision 2, 2026-10-28
# Runs with sudo on the lab server. Installs Samba and publishes one share,
# //192.168.77.10/archive, to the lab network only. Safe to run again.
#
# Revision 1 (2026-10-28) produced the server half of
# ../smb_lab_run_2026-10-28.txt. Revision 2 renames the file for
# publication; no command changed. It reads the Samba account from a
# credentials file (username= and password= lines) that the lab host copies
# in and that never leaves the lab.
set -u;
exec 2>&1;

credentials_file="/home/lab/smb_lab_credentials";
share_directory="/srv/smb/archive";
smb_config="/etc/samba/smb.conf";
share_marker="# revisualized_lab archive share";

if [ "$(id -u)" -ne 0 ]; then
  echo "STOP: run with sudo";
  exit 1;
fi;
smb_user="$(sed -n 's/^username=//p' "${credentials_file}")";
smb_password="$(sed -n 's/^password=//p' "${credentials_file}")";
if [ -z "${smb_user}" ] || [ -z "${smb_password}" ]; then
  echo "STOP: ${credentials_file} has no username= or password= line";
  exit 1;
fi;

echo "== Samba install";
export DEBIAN_FRONTEND=noninteractive;
if ! apt-get update -qq || ! apt-get install -y -qq samba > /dev/null; then
  echo "STOP: apt-get could not install samba";
  exit 1;
fi;
echo "samba: $(smbd --version)";

echo "== Share";
if ! id "${smb_user}" > /dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin "${smb_user}";
  echo "created system user ${smb_user}";
fi;
mkdir -p "${share_directory}";
printf 'written by r002_smb_server_setup.sh on %s\n' "$(date '+%F %T %z')" > "${share_directory}/readme.txt";
chown -R "${smb_user}:" "${share_directory}";
if ! grep -qF "${share_marker}" "${smb_config}"; then
  cat >> "${smb_config}" << SHARE

${share_marker}
[archive]
   path = ${share_directory}
   read only = no
   valid users = ${smb_user}
   hosts allow = 192.168.77.
SHARE
  echo "added [archive] to ${smb_config}";
else
  echo "[archive] already in ${smb_config}";
fi;
printf '%s\n%s\n' "${smb_password}" "${smb_password}" | smbpasswd -a -s "${smb_user}" > /dev/null;
echo "samba password set for ${smb_user}";
if ! testparm -s > /dev/null 2>&1; then
  echo "STOP: testparm rejects ${smb_config}";
  testparm -s 2>&1 | tail -n 5;
  exit 1;
fi;
systemctl restart smbd;
echo "smbd: $(systemctl is-active smbd)";
echo "-- share as smbd sees it:";
testparm -s --section-name=archive 2>/dev/null;
