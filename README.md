# mount-audit-reporter

[![ci](https://github.com/revisualize/mount-audit-reporter/actions/workflows/ci.yml/badge.svg)](https://github.com/revisualize/mount-audit-reporter/actions/workflows/ci.yml)
[![test](https://github.com/revisualize/mount-audit-reporter/actions/workflows/test.yml/badge.svg)](https://github.com/revisualize/mount-audit-reporter/actions/workflows/test.yml)
[![shellcheck](https://github.com/revisualize/mount-audit-reporter/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/revisualize/mount-audit-reporter/actions/workflows/shellcheck.yml)
[![bash-compat](https://github.com/revisualize/mount-audit-reporter/actions/workflows/bash-compat.yml/badge.svg)](https://github.com/revisualize/mount-audit-reporter/actions/workflows/bash-compat.yml)
[![markdown-lint](https://github.com/revisualize/mount-audit-reporter/actions/workflows/markdown-lint.yml/badge.svg)](https://github.com/revisualize/mount-audit-reporter/actions/workflows/markdown-lint.yml)
[![links](https://github.com/revisualize/mount-audit-reporter/actions/workflows/links.yml/badge.svg)](https://github.com/revisualize/mount-audit-reporter/actions/workflows/links.yml)
[![content-policy](https://github.com/revisualize/mount-audit-reporter/actions/workflows/content-policy.yml/badge.svg)](https://github.com/revisualize/mount-audit-reporter/actions/workflows/content-policy.yml)
[![license: all rights reserved](https://img.shields.io/badge/license-all%20rights%20reserved-lightgrey)](LICENSE)

**Project page:** [revisualized.com/projects/mount-audit-reporter](https://revisualized.com/projects/mount-audit-reporter)

A Bash auditor that compares the mounts visible in its current Linux mount namespace with a manifest you review: each declared mountpoint, its filesystem type, its source, the options that must be present, and the options that must never appear. It reports every mismatch in one run with one exit code, and it reads mount state without ever changing it.

A nightly comparison with yesterday can say what changed. This answers a different question: does the mount table match the contract someone wrote down? A wrong state is still wrong if it was already there when a baseline was accepted.

## Quick start

```sh
bash mount_audit_reporter.sh --generate > client_mounts.manifest
bash mount_audit_reporter.sh client_mounts.manifest
```

Generate mode prints a candidate manifest from the mounts this host has now. It lists every option `findmnt` reports as required, so edit it before relying on it: delete options you hold no expectation about, especially ones that change by themselves on network mounts (`addr=`, `clientaddr=`, negotiated `rsize` and `wsize`), and add the options that must never appear. A generated manifest records what the host is doing; it becomes a statement of intent only after a person has edited it.

To run it nightly, put a time limit on it and let cron mail only a failed run. `timeout` is from coreutils; `chronic` is from moreutils and prints a command's output only when it exits non-zero. Keep its `-v` flag: an audit that `timeout` stops has printed nothing yet, and `-v` adds the exit status, so even that run produces mail.

```sh
17 2 * * * chronic -v timeout --kill-after=10 120 bash /opt/mount-audit-reporter/mount_audit_reporter.sh /etc/mount_audit/client_mounts.manifest
```

A `RETVAL: 124` in that mail means the audit hit the time limit; 137 means it was still running 10 seconds after that and was killed. Cron mails only where the host has mail delivery set up. A `note:` line, such as a stacked path, prints in a run that exits 0 too, and `chronic` keeps that run silent, so notes reach you only when you run the audit by hand.

## The manifest

```text
# <mountpoint>  <fstype>  <required_csv>  [forbidden_csv]  [source]
/var/tmp/build  tmpfs  nodev,noexec,nosuid       -
/mnt/projects   nfs4   hard,vers=4.1,proto=tcp   -    filer01.example.net:/export/projects
/data/backups   cifs   ro                        rw   //backup01.example.net/archive
```

One mount per line, columns separated by spaces or tabs. A `#` at the start of a line or after whitespace starts a comment; inside a value, such as `server#A`, it is ordinary text. Use `-` in an option column for none, and in the source column to skip the source check. A missing forbidden column means `-`; to give a source, give the forbidden column too. The NFS and SMB lines above are illustrative, written from nfs(5) and mount.cifs(8) rather than from a generate run; see Evidence below. The full example is `examples/client_mounts.manifest`.

A mountpoint is matched exactly as the mount table spells it. A trailing slash is ignored, but a symlink is never followed: write `/run`, not `/var/run`.

The source column catches what options cannot: every option can be right while the mount points at the wrong server or export. It is compared as a plain string, so a server named by address in one place and by name in another counts as different. Write it the way generate mode prints it.

## Options are matched as findmnt reports them

Options are matched as whole tokens against the option string `findmnt` returns for the mount. `soft` matches `soft` alone, never `softerr`, and `vers=4.1` never matches `vers=4.2`. The tool knows nothing about option meanings or defaults, on purpose.

`findmnt` builds that string from the kernel's mount table for the current namespace (`/proc/self/mountinfo`), joining the per-mount and per-filesystem options; the typed mount command and `/etc/fstab` play no part. The kernel normalizes what it is given: a tmpfs mounted with `size=1m,nodev,noexec,nosuid` reads back as `rw,nosuid,nodev,noexec,relatime,size=1024k`. Defaults shown only by their absence, such as `exec`, `suid`, and `dev`, never appear in it, so to require an executable mount, forbid `noexec`. For the same reason an NFSv4 mount reports the filesystem type `nfs4` even when it was mounted with `-t nfs`. Start from generate mode rather than from memory.

`findmnt --raw` hex-escapes unusual characters. A WSL2 drive mount, for example, reports `path=C:\x5c` where the path holds one backslash. Write such options exactly as generate mode prints them.

### NFS: prefer requiring the safe option

nfs(5) documents three recovery modes: `hard`, `soft`, and `softerr`. A rule that forbids `soft` misses `softerr`. In Linux 6.18, the NFS client writes `hard` into the option string whenever neither of the others is set ([fs/nfs/super.c, lines 484 and 485 at v6.18](https://github.com/torvalds/linux/blob/v6.18/fs/nfs/super.c#L484-L485)), so on such a kernel requiring `hard` catches both. No NFS mount has been audited with this tool yet, so confirm with generate mode on your host.

## What it reports

| Finding | Meaning |
|---|---|
| `not mounted` | Nothing is mounted at exactly that path |
| `fstype is X, expected Y` | A different filesystem type is mounted there |
| `source is X, expected Y` | Something else is mounted there: another server, export, share, or device |
| `required option missing: X` | A required token is absent from the option string |
| `forbidden option present: X` | A forbidden token is present |
| `hidden: a later mount at X covers it` | A mount is listed at that path, but a later mount over a directory above it means a process reaches something else there |

When a second mount is made on a path that already has one, both stay in the mount table and only the newer one is visible. The audit checks the visible mount and prints a `note:` line saying the path is stacked; the note leaves the exit code alone. The rule for finding it comes from [proc_pid_mountinfo(5)](https://man7.org/linux/man-pages/man5/proc_pid_mountinfo.5.html): a mount made on top of another records that mount as its parent, so of the mounts at one path the visible one is the one that is no other's parent, whatever order `findmnt` prints them in.

The same page adds a condition: that mount is reachable only if no later mount covers a directory above it. A mount at `/srv/data` stays in the table after someone mounts over `/srv`, while `/srv/data` now leads into the new mount. The audit climbs the parent IDs from each declared mount, and a mount covered this way is a `hidden` finding. A path can also list two mounts side by side, neither the parent of the other: WSL2 mounts `/tmp/.X11-unix`, then a tmpfs over `/tmp`, then `/tmp/.X11-unix` again, so the first stays in the table but is unreachable. Covered mounts are dropped before the visible one is chosen. A cover anywhere above a mount decides it, and the outermost cover is the one named, so the finding is the same in any print order. If the table still cannot single out one mount at a path, that path is an error rather than a guess.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Every expectation met (notes may still be printed). For generate: manifest printed |
| 1 | One or more findings |
| 2 | Usage error, `findmnt` missing, manifest missing, unreadable, malformed, or empty, a mount table that could not be read, a path where the table cannot single out one visible mount, or generate found nothing usable |

A malformed manifest stops the run before anything is audited. The script rejects a line with a carriage return, fewer than three or more than five columns, a relative mountpoint, an empty option between commas, a `-` mixed into an option list, a mountpoint declared twice, a mountpoint containing a backslash, or an option both required and forbidden. A manifest that declares nothing exits 2: an audit that checked nothing never reports success.

Each run reads the whole mount table with one `findmnt` call that names its columns, so every mount is judged against the same listing and a missing mount is a path with no row. The listing is not an atomic snapshot: the kernel releases its lock between reads, so a mount or unmount made while `findmnt` reads can show in it partly. Any non-zero exit from that call, a row the script cannot parse (a non-numeric ID, a target without a leading slash, a missing or extra column), parent IDs that form a loop, or more than one mount that is its own parent stops the run with exit 2 and an `ERROR` line. When the table cannot say which of several mounts at one path is visible, the other mounts are still audited: the run prints `MOUNT AUDIT INCOMPLETE` with their findings and an `ERROR` line for that path, and exits 2.

`findmnt`'s error output goes to a temporary file made by `mktemp` under `TMPDIR` (default `/tmp`). It is removed as soon as `findmnt` exits, and a trap removes it if the run is interrupted. A `SIGKILL`, such as the one `timeout --kill-after` sends, cannot be trapped and can leave it behind.

## Known limitations

- It audits only the mountpoints the manifest declares. A mount that appears anywhere else produces no finding; use a baseline comparison for that.
- It sees the mount namespace it runs in. Inside a container, or under a service with a private mount namespace, that may not be the host's mount table. Generate and audit from the same namespace.
- It checks mount-table metadata, not whether the filesystem works. A matching mount can still be unreachable, stale, or unwritable.
- Paths managed by autofs are a poor fit. The audit never touches a path, so it never triggers an automount, and an idle automounted path reads as `autofs` or as not mounted.
- The manifest cannot express a mountpoint that `findmnt --raw` prints with an escape, such as one containing whitespace, or a value that begins with `#` or is exactly `-`. Generate mode skips or marks each such case with a comment, and a manifest mountpoint with a backslash is rejected.
- Mountpoints are matched as the table spells them, so a path reached through a symlink, such as `/var/run`, reads as not mounted.
- Run time grows with the size of the mount table, slowly. Measured on a synthetic table of 1,000 mounts: an audit of 20 declared mounts took about 0.15 seconds and generate mode about half a second; at 2,000 mounts, about 0.3 and 1.2 seconds. Each lookup reads only the mounts at the path and the directories above it.
- Exact tokens age with the kernel: an upgrade that changes how options are reported produces findings until the manifest is regenerated and reviewed.
- Tested on util-linux 2.39 and 2.41. The script needs only a full listing with the ID, PARENT, TARGET, FSTYPE, OPTIONS, and SOURCE columns; a `findmnt` that rejects any of them makes the run stop with exit 2.

## Evidence

The bats suite runs against `test/shim/findmnt`, a stand-in that reads a fixture mount table and assigns parent IDs the way the kernel does, so every finding type, stacked mounts in either print order, mounts hidden by a later mount above them, every manifest error, failing `findmnt` runs, and generate mode are tested without root or real NFS and SMB servers. Stand-ins for `mount` and `umount` first on `PATH` prove neither is ever called, and a scratch `TMPDIR` shows no temporary file left behind on the normal and failing paths. As a check on the tests themselves, 63 deliberate defects were put back into a copy of the script one at a time; the suite failed for every one.

The suite has passed under Bash 4.2 through 5.3. The bash-compat workflow builds each of those releases from source; the lab runs also used the workstation's own Bash 5.3. The script has run against real mount tables: ext4, tmpfs, and 9p mounts on a WSL2 workstation, including a path stacked by the system, and tmpfs mounts arranged for the test, both stacked on one path and hidden by a later mount above them, on that workstation (util-linux 2.41) and in a disposable test environment (2.39). No NFS or SMB mount has been audited, and it has not been run under sustained scheduling.

## Requirements

Bash 4.2 or newer, and `findmnt` from util-linux (tested on 2.39 and 2.41) and `mktemp`. Generate mode also uses `uname` and `date`. No root needed. For the nightly line above, `timeout` from coreutils and `chronic` from moreutils, in a version with `-v`.

```sh
bash test/run_all_tests.sh
```

## Continuous integration

Each badge above is its own GitHub Actions workflow in `.github/workflows/`. Every workflow runs on each push and pull request, can be re-run by hand from the Actions tab, and links to its run history.

| Workflow | A green badge means |
|---|---|
| [`ci`](https://github.com/revisualize/mount-audit-reporter/actions/workflows/ci.yml) | `bash test/run_all_tests.sh` passed on Python 3.9 and 3.12 and reported a non-zero count of executed tests, and shellcheck found nothing at style severity. |
| [`test`](https://github.com/revisualize/mount-audit-reporter/actions/workflows/test.yml) | `bash test/run_all_tests.sh` passed on Python 3.9 and 3.12. The run fails if any suite fails or if zero tests executed, and the job summary lists each suite with its test count. |
| [`shellcheck`](https://github.com/revisualize/mount-audit-reporter/actions/workflows/shellcheck.yml) | Every shell script outside `test/fixtures/` parses with `bash -n` and has no shellcheck findings at style severity. |
| [`bash-compat`](https://github.com/revisualize/mount-audit-reporter/actions/workflows/bash-compat.yml) | The test suite passed under every Bash release from the floor stated in Requirements through 5.3, each built from its release source. |
| [`markdown-lint`](https://github.com/revisualize/mount-audit-reporter/actions/workflows/markdown-lint.yml) | Every Markdown file passes markdownlint. |
| [`links`](https://github.com/revisualize/mount-audit-reporter/actions/workflows/links.yml) | Every link in every Markdown file resolved on the latest run. It also runs weekly, because a link can break with no commit here. |
| [`content-policy`](https://github.com/revisualize/mount-audit-reporter/actions/workflows/content-policy.yml) | Every tracked file meets the publishing rules: UTF-8, LF line endings, no em dashes, scripts documented as `bash name.sh`, and vendor-neutral wording. |

A badge reports the latest run of those checks. What the tool needs on your own host is listed under Requirements.

## License

See [LICENSE](LICENSE). This code is published for viewing as a sample of the author's work. All rights reserved.
