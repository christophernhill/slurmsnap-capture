# script-form/

Every `*.sh` file here passes `shellcheck`. The rules for working here are in `AGENTS.md`.

| File | What it is |
|---|---|
| `squeue-snapshot.sh` | `scripts/squeue-snapshot.sh OUT_DIR`: one squeue snapshot, gzipped into a dated file. Four stages: discover the fields from `squeue --helpFormat`, build a `--Format` from them, run squeue once, write the file (a few `# key: value` lines, a header row, one record per job; TAB+0x1f between fields, 0x1e ending each record). Nothing about fields is hardcoded: downstream reads the header. Uses `snapshot-lib.sh`; needs bash, squeue, scontrol, gzip. Meant for a systemd timer. |
| `scontrol-snapshot.sh` | `scripts/scontrol-snapshot.sh OUT_DIR node\|partition\|reservation\|config\|job`: one `scontrol show` snapshot, gzipped into `OUT_DIR/scontrol-<OBJECT>-<UTC time>.txt.gz`. The `# key: value` lines are followed by scontrol's stdout unchanged. node, partition, reservation and config are text in the default multi-line layout (not `--oneliner`, so free-text values such as `OS=` and `Reason=` keep their own lines); job is one line of JSON (`--json`, `SLURM_JSON=compact`). Times are epoch (`SLURM_TIME_FORMAT=%s`); `--all` includes hidden partitions. Exits with scontrol's status, or 2 for a usage error. Design: `snapshot-plans/C03-scontrol-show-node.md`. |
| `sacctmgr-snapshot.sh` | `scripts/sacctmgr-snapshot.sh OUT_DIR assoc\|qos`: one sacctmgr snapshot as one line of JSON (`--json`, `SLURM_JSON=compact`; sacctmgr has no field list and no delimiter, and JSON names every field). assoc is scoped to `cluster=<ClusterName>` (regex-checked, never unscoped; exit 1 without a valid name); qos covers every QOS. Exits with sacctmgr's status, or 2 for a usage error. Design: `snapshot-plans/C12-sacctmgr-assoc.md`, `C13-sacctmgr-qos.md`. |
| `sprio-snapshot.sh` | `scripts/sprio-snapshot.sh OUT_DIR`: the priority factors of every eligible pending job, once per partition, in one call. Every letter from `sprio --helpformat` is used, normalized (lowercase) and weighted (uppercase) side by side. The header row holds the specifiers (`%A`, `%a`, …), matched case-sensitively, and `# names:` gives sprio's titles. No `-w` call: `sprio --weights` segfaults on `%c` (26.05.5), and the weights are in the config snapshot. If sprio is killed by a signal, each letter is probed and the bad ones blanked (`# blanked:`). Records layout as squeue. Design: `snapshot-plans/C14-C16-sprio.md`. |
| `sacct-snapshot.sh` | `scripts/sacct-snapshot.sh OUT_DIR [SINCE]`: every job, array task and step active from SINCE to now (default `now-2hours`; short forms such as `now-1d`, `now-24h` and `now-90m` are rewritten into the whole-word units sacct requires, and anything unrecognised exits 2), all users, this cluster, every field from `sacct --helpformat`, `--noconvert`, epoch times. Fields are split by `--delimiter=$'\t\x1f'`, and the script adds the 0x1e record terminator once a record holds every separator, so values with newlines stay in their record (an empty line inside a value counts no separators; fixed 2026-11-13 after the orcd bundle showed 12 records swallowing the next). Exits with sacct's status, 3 if the output ends inside a record, or 2 for a usage error. Replaces the per-array sacct calls and seff (`snapshot-plans/C11-sacct-array-tasks.md`, `C17-seff.md`). |
| `sshare-snapshot.sh` | `scripts/sshare-snapshot.sh OUT_DIR`: fair-share shares and usage for every account and user (`sshare --all`), every field from `sshare --helpformat`. It uses `--delimiter` when `sshare --help` offers it; otherwise it translates `--parsable2`'s `\|`, after checking every line's field count. A mismatch writes nothing and exits 3. Account indentation (tree depth) is kept. Records layout as squeue. Design: `snapshot-plans/sshare-fairshare.md`. |
| `snapshot-bundle.sh` | `scripts/snapshot-bundle.sh ROOT_DIR [SINCE]`: one snapshot cycle for a systemd timer. Runs the eleven snapshot calls of `command-list`, in that order, into `ROOT_DIR/YYYY/MM/DD/<cluster>-<UTC time>/` (UTC, from one clock reading; `snap-` when there is no valid cluster name), writes a `manifest.txt` (the `# key: value` lines, then step, exit status, seconds and file per step), then tars and gzips the directory to `<cluster>-<UTC time>.tgz` next to it (written as `.tmp` and renamed) and removes the directory. A failing step does not stop the cycle. SINCE goes to `sacct-snapshot.sh` (default `now-2hours`). Exits 0 when all is well, 1 when the tarball was written but a step failed, 3 when tar failed (the directory is kept), 2 for a usage error. Design: `snapshot-plans/bundle-driver.md`. |
| `systemd/` | Two pairs of `slurm-snapshot.service` (oneshot running `snapshot-bundle.sh`, `TimeoutStartSec=14min`) and `slurm-snapshot.timer` (`OnCalendar=*:0/15`, `Persistent=no`). `system/`: installed by root under `/etc/systemd/system/`, runs as a dedicated `User=`, sandboxed. `user/`: installed by an ordinary account under `~/.config/systemd/user/`, no root; the scripts path, work root and sacct window come from `slurm-snapshot.env` next to the units (`slurm-snapshot.env.example` is the template), with `%h` defaults when the file is absent. See "Running under systemd" below. |
| `snapshot-lib.sh` | Sourced by the snapshot scripts, never run. Shared functions: `show_command` (prints a command as wrapped, pasteable `# command:` header lines); `snapshot_stamp` (the UTC time, read once per run); `cluster_name` (ClusterName from `scontrol show config`, or nothing); `join_fields` (joins names into a `--format` or header row); `write_snapshot` (the common header lines plus the body, gzipped to `.tmp` and renamed, path printed). Sets no shell options and touches no variables of the caller. |
| `AGENTS.md` | Instructions for anyone working here: scope (snapshot gathering only; parsing, analysis and presentation are other projects), the file contract, design rules, known traps, and how to test against the Docker cluster. `CLAUDE.md` points to it. |
| `snapshot-plans/` | Design notes: one markdown file per command step, describing its snapshot script. Start at `snapshot-plans/README.md`. |

## How to run the checks

```bash
shellcheck *.sh
```

Then run the scripts inside the Docker test cluster, as `AGENTS.md` §7 describes:

```bash
docker cp /path/to/script-form slurmctld:/tmp/snap
docker exec slurmctld /tmp/snap/sprio-snapshot.sh /tmp/out
docker cp slurmctld:/tmp/out ./docker-out
docker exec slurmctld rm -rf /tmp/snap /tmp/out
```

For a change to how a script processes a body (the sacct awk pass, the sshare translation),
also replay the real orcd bundle in `../example-output-bundles/` as `AGENTS.md` §7 shows; the
Docker cluster's few rows never contain the awkward values that a production cluster's do.

To test the driver, run it the same way and look inside the result; the only file left under
`/tmp/out` should be `YYYY/MM/DD/linux-<stamp>.tgz`:

```bash
docker exec slurmctld /tmp/snap/snapshot-bundle.sh /tmp/out
docker exec slurmctld find /tmp/out -type f
tar -tzf docker-out/2026/11/21/linux-<stamp>.tgz
tar -xzOf docker-out/2026/11/21/linux-<stamp>.tgz linux-<stamp>/manifest.txt
```

## Running under systemd

Two ways, same driver. Both find the snapshot scripts and `snapshot-lib.sh` next to
`snapshot-bundle.sh`, so copy the whole directory. In both cases check that `PrivateData` lets
the account see every job and association.

**As a system service (root installs it, a dedicated account runs it):**

1. Copy this directory to the login node, e.g. `/opt/slurm-snapshot/`.
2. Create the output root (e.g. `/var/lib/slurm-snapshot`) and a service account that may run the
   Slurm client commands and write there.
3. Edit `User=` and the two paths in `ExecStart=` of `systemd/system/slurm-snapshot.service`, copy
   both units from `systemd/system/` to `/etc/systemd/system/`, then:

   ```bash
   systemctl daemon-reload
   systemctl enable --now slurm-snapshot.timer
   systemctl list-timers slurm-snapshot.timer
   systemctl start slurm-snapshot.service      # one cycle now, to check
   journalctl -u slurm-snapshot                # a failing step's stderr lands here
   ```

**As an ordinary user (no root):** the units in `systemd/user/` run under the account's own
systemd manager (`systemctl --user`). They have no `User=` line and no sandboxing. Where the
scripts and the work root live is a parameter: the service reads `SNAPSHOT_SCRIPTS`,
`SNAPSHOT_ROOT` and `SNAPSHOT_SINCE` from `~/.config/systemd/user/slurm-snapshot.env`
(`slurm-snapshot.env.example` is the template). Without that file it falls back to
`~/slurm-snapshot`, `~/slurm-snapshot-data` and `now-2hours`. Write absolute paths in the file:
systemd expands no `~`, `$HOME` or other variables there.

```bash
SCRIPTS=/path/of/your/choice/slurm-snapshot          # where the scripts will live
ROOT=/scratch/$USER/slurm-snapshot-data              # the work root for the bundles
cp -r scripts "$SCRIPTS"
mkdir -p "$ROOT" ~/.config/systemd/user
cp "$SCRIPTS"/systemd/user/slurm-snapshot.{service,timer} ~/.config/systemd/user/
printf 'SNAPSHOT_SCRIPTS=%s\nSNAPSHOT_ROOT=%s\nSNAPSHOT_SINCE=now-2hours\n' "$SCRIPTS" "$ROOT" \
  > ~/.config/systemd/user/slurm-snapshot.env
systemctl --user daemon-reload
systemctl --user show -p Environment slurm-snapshot.service   # the values in effect
systemctl --user enable --now slurm-snapshot.timer
systemctl --user list-timers slurm-snapshot.timer
systemctl --user start slurm-snapshot.service        # one cycle now, to check
journalctl --user -u slurm-snapshot
loginctl enable-linger                               # see below
```

To move the work root later, edit the env file and run `systemctl --user daemon-reload`; the
next cycle uses the new path.

The user manager, and with it the timer, normally stops when the account's last session ends.
`loginctl enable-linger` keeps it running; the default policy lets an account enable linger
for itself, but a site may restrict it, in which case ask the administrator to run
`loginctl enable-linger USER`. If `systemctl --user` answers "Failed to connect to bus", the
login node runs no user manager (no `pam_systemd`); then the system units are the way, or as a
last resort a crontab line, which must take its own lock since cron does not stop overlapping
runs:

```
*/15 * * * * flock -n ROOT/.lock SCRIPTS/snapshot-bundle.sh ROOT now-2hours >/dev/null
```

with `ROOT` and `SCRIPTS` written out as the same absolute paths as in the env file.

Each cycle leaves one `ROOT/YYYY/MM/DD/<cluster>-<stamp>.tgz`. `TimeoutStartSec=` bounds the
cycle: keep it well above 2 minutes (scontrol retries for 60 s per call when Slurm is broken) and
below the interval; tune it from the `seconds` column of the manifests. systemd never starts
the oneshot while the previous cycle still runs. Removing old tarballs is not the driver's job;
use a `tmpfiles.d` age rule or a separate `find -mtime` timer.

## What a reviewer checks

For `snapshot-bundle.sh`:
- every step's argv is a literal (no step list read from a file, no `eval`);
- a failing step is recorded in the manifest and the cycle goes on;
- the tarball is written as `.tmp` and renamed, and the directory is removed only after that.

For the `*-snapshot.sh` scripts:
- one bulk Slurm call per file (sprio may add the probes of its crash fallback);
- fields come from the command at run time where it can list them (`--helpFormat` /
  `--helpformat`), never from a pasted list;
- every dynamic value is validated before it reaches an argv;
- `set -euo pipefail` comes straight after the header comment;
- the common header goes through `write_snapshot`.

The fake-slurm shims cannot replay their argvs, so run them in the Docker test cluster
(`snapshot-plans/README.md`, "Test cluster").

## Keeping this README current

Update this file when a `*-snapshot.sh` script changes its usage, its argv, its file layout or
its exit statuses, and update the matching `snapshot-plans/` doc in the same change.
