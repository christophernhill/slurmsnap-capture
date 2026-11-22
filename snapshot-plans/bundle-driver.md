# Bundle driver (new) → `snapshot-bundle.sh ROOT_DIR [SINCE]`

This is **not a snapshot of a Slurm command**. It is the driver that runs every snapshot script
once, so that a systemd timer can produce one complete bundle per cycle without a person at the
keyboard. It replaces running `command-list` by hand.

## 1. Today

`command-list` is the user's own sequence of the eleven calls that make one bundle, run by hand
into a directory named by hand (`sq-20261113-test001`), and tarred by hand afterwards
(`../example-output-bundles/sq-20261113-test002.tgz` is one such tarball). Nothing names the
directory from the clock, keeps cycles apart, or records which step failed.

## 2. Counterpart

**Implemented:** [`../snapshot-bundle.sh`](../snapshot-bundle.sh) (2026-11-21), shellcheck-clean
and run end-to-end inside the Docker `slurmctld` container, with the example units in
[`../systemd/`](../systemd/).

```
snapshot-bundle.sh ROOT_DIR [SINCE]      -> ROOT_DIR/YYYY/MM/DD/<cluster>-<stamp>.tgz
```

Decisions taken with the user (2026-11-21):
- **every cycle runs all eleven snapshots**, in `command-list` order. Every bundle is complete
  and self-contained; the cost is the hourly-class queries (config, partition, assoc, qos,
  sacct) on every cycle;
- **the timer fires every 15 minutes**; the sacct window defaults to `now-2hours` so windows
  overlap (downstream deduplicates by `JobIDRaw` and step);
- **the loose directory is removed** after a successful tar; it is kept when tar fails;
- **the bundle is named `<cluster>-<stamp>`**, e.g. `eofe7-20261121T141500Z`, falling back to
  `snap-<stamp>` when `cluster_name` prints nothing or an invalid name. Downstream uses the
  base name without `.tgz` as the bundle name.

## 3. Stages

1. **Discover.** `started=$(snapshot_stamp)`, read once for the whole cycle, and
   `cluster=$(cluster_name)`, checked against `^[A-Za-z0-9_.-]{1,64}$` (the regex of
   `sacctmgr-snapshot.sh`) before it becomes part of a path.
2. **Build.** From that one stamp: the name `<cluster>-<YYYYMMDDTHHMMSSZ>` and the day
   directory `ROOT_DIR/YYYY/MM/DD`. Both are UTC, like the stamps in the file names, so the
   hierarchy and the files never disagree across midnight. Four-digit year, two-digit month
   and day sort the same for `ls`, `find` and a person.
3. **Run once.** Each snapshot script is run once, between `set +e` and `set -e`, through
   `run_step LABEL WORD...`. Each step's argv is a literal in the script (rule 6: arrays, never
   strings; so the step list is **not** read from `command-list` or any other file).
   **Hardcoded: no runtime option.** Which snapshots make a bundle is a design decision
   ([README.md § Cadence](README.md#cadence)); Slurm cannot list it. A failing step does not stop
   the cycle: the other ten files are still worth having, and each file carries its own
   `# exit:`. Its stderr passes through to the journal.
4. **Write.** `tar -C DAY_DIR -cf - NAME | gzip > NAME.tgz.tmp`, then rename, then
   `rm -rf DAY_DIR/NAME`. The tarball appears whole or not at all. `tar | gzip` rather than
   `tar -z`, so the gzip is the same binary the snapshots use and the pipeline's status is
   checked under `pipefail`.

## 4. Layout

```
ROOT_DIR/
└── 2026/
    └── 11/
        └── 21/
            ├── eofe7-20261121T140000Z.tgz
            ├── eofe7-20261121T141500Z.tgz
            └── eofe7-20261121T143000Z/        only while a cycle runs, or after tar failed
```

Inside a tarball, one directory with the eleven `<source>-<stamp>.txt.gz` files and
`manifest.txt`. The members are `<name>/<file>`, exactly the layout of the example bundle.

`manifest.txt` uses the snapshots' `# key: value` style, then one TAB-separated line per step:

```
# bundle: linux-20261121T225206Z
# started: 2026-11-21T22:52:06Z
# host: slurmctld
# cluster: linux
# command:
#   snapshot-bundle.sh /tmp/out
# steps: 11
# columns: step	exit	seconds	file
squeue-snapshot.sh	0	0	squeue-20261121T225206Z.txt.gz
scontrol-snapshot.sh job	0	0	scontrol-job-20261121T225206Z.txt.gz
…
sacct-snapshot.sh now-2hours	0	0	sacct-20261121T225206Z.txt.gz
# finished: 2026-11-21T22:52:06Z
# failed: 0
# exit: 0
```

`file` is `-` when the step printed no path (it wrote nothing). `# exit:` is 0 when every step
exited 0, else 1; it is the driver's own exit status if the tar then succeeds.

The downstream reader (`../../conv-to-duckdb-and-meta`, `bundle.py: _classify`) matches member
names against `<source>-<stamp>.txt.gz`; `manifest.txt` is reported as one `ignored_file`
issue and otherwise skipped (VERIFIED 2026-11-21 with `slurmsnap-ingest check`). Whether it
should be whitelisted there is downstream's call; not something to change from here.

## 5. Exit statuses

| Status | Meaning | Left on disk |
|---|---|---|
| 0 | every step and the tar succeeded | `NAME.tgz` |
| 1 | tarball written, one or more steps failed (`# failed:` in the manifest) | `NAME.tgz` |
| 3 | tar or gzip failed | the directory `NAME/`, no `.tgz`, no `.tmp` |
| 2 | usage error | nothing |

A bad `SINCE` is caught by `sacct-snapshot.sh` (exit 2) and shows up as that one step failing
(driver exit 1), not as a driver usage error: the accepted forms live in the sacct script's unit
table and are not duplicated here.

## 6. systemd

Two pairs of units, one driver:

| | `../systemd/system/` | `../systemd/user/` |
|---|---|---|
| Installed by | root, into `/etc/systemd/system/` | the account itself, into `~/.config/systemd/user/` |
| Runs as | `User=slurmsnap` (edit for the site) | the account; a user unit has no `User=` |
| Paths | `/opt/slurm-snapshot`, `/var/lib/slurm-snapshot` (edit the unit) | `SNAPSHOT_SCRIPTS`, `SNAPSHOT_ROOT`, `SNAPSHOT_SINCE` from `~/.config/systemd/user/slurm-snapshot.env` (template `slurm-snapshot.env.example`); `%h/slurm-snapshot`, `%h/slurm-snapshot-data`, `now-2hours` when the file is absent. Absolute paths only: an `EnvironmentFile=` expands no `~` or `$HOME` |
| Sandboxing | `ProtectSystem=strict`, `ReadWritePaths=`, `PrivateTmp=`, `NoNewPrivileges=` | none: these need namespaces an unprivileged user manager may not create; the account's permissions bound the scripts anyway |
| Keeps running after logout | always | only with `loginctl enable-linger` |
| Commands | `systemctl …`, `journalctl -u slurm-snapshot` | `systemctl --user …`, `journalctl --user -u slurm-snapshot` |

Both services are `Type=oneshot` with `ExecStart=… snapshot-bundle.sh ROOT SINCE` and
`TimeoutStartSec=14min`; both timers are `OnCalendar=*:0/15`, `Persistent=no`. The user variant
(added 2026-11-21 at the user's request) is for a login node where no one will install a system
unit; it needs a user manager (`pam_systemd`), and the README gives a crontab line with `flock`
for nodes that have none. Its paths are parameters (also 2026-11-21, at the user's request):
`Environment=` lines give `%h` defaults, and `EnvironmentFile=-…/slurm-snapshot.env`, applied
after them, overrides whatever the file sets; the leading `-` makes a missing file a non-error.
`ExecStart=` uses `${VAR}` (braces), so each value stays one argument even with spaces.
systemd expands variables only in the arguments, never in the executable, which must be a
literal absolute path (`systemd-analyze verify` rejects `${SNAPSHOT_SCRIPTS}/snapshot-bundle.sh`
there; VERIFIED docker 2026-11-21). So the executable is `/usr/bin/env`, which execs its first
argument, the driver, with the rest as arguments.

- systemd never starts a oneshot while the previous activation still runs, so cycles cannot
  overlap and the driver takes no lock. A cycle longer than the interval skips the next tick.
- `Persistent=no`: a snapshot is a point in time; a cycle missed while the node was down is not
  worth running late.
- `TimeoutStartSec=` bounds the cycle (rule 8: no `timeout` inside the scripts). With a broken
  Slurm configuration scontrol retries for up to 60 s per call, so it must be well over 2 min,
  and under the interval. Tune it from the `seconds` column of the manifests.
- The hardening lines (`ProtectSystem=strict`, `ReadWritePaths=`, `PrivateTmp=yes`) assume the
  scripts write only under the output root plus `mktemp` files.

## 7. Pitfalls

- **`tar --wildcards`** is GNU-only; bsdtar (macOS) rejects it. The header comment names the
  member explicitly: `tar -xzOf NAME.tgz NAME/manifest.txt`.
- **`path=$(cmd)` under `set -e`** would abort the driver when a step fails. `run_step` wraps the
  capture in `set +e` / `set -e`, as the snapshot scripts do for their Slurm call.
- **Two cycles in one second** would share a name. With a 15-minute timer that cannot happen;
  by hand, the second run would overwrite the first tarball.

## 8. Verified

VERIFIED docker (2026-11-21, Slurm 26.05.5, cluster `linux`):
- a plain run writes only `ROOT/2026/11/21/linux-<stamp>.tgz` (no loose directory), exit 0;
  the tarball holds 11 `*.txt.gz` members plus `manifest.txt` under one directory; every
  member's `# exit:` is 0 and agrees with the manifest;
- no arguments, or three: usage, exit 2, nothing created;
- an `sshare` stub adding a `|` value: that step exits 3 with `-` as its file, 10 files in the
  tarball, `# failed: 1`, driver exit 1;
- a `tar` stub exiting 1: the directory with 11 files is kept, no `.tgz` and no `.tmp`, exit 3;
- `slurmsnap-ingest check` on the tarball: every snapshot `ok`, the manifest `skipped
  ignored_file:1`.

## 9. Still to verify

- **On orcd-login:** cycle duration and tarball size at scale (the example bundle's eleven files
  total about 2 MB; a cycle there took roughly 20 s by the file stamps), to set
  `TimeoutStartSec=` with margin;
- that the service user sees everything (`PrivateData`), same as for the single scripts;
- that `ProtectSystem=strict` does not block anything the Slurm clients need (they read
  `slurm.conf` and may use a Munge socket); system units only;
- for the user units: that the login node runs a user manager (`systemctl --user status`
  answers), and that `loginctl enable-linger` is permitted for the account.

## 10. Cadence

Every 15 minutes, all eleven snapshots. Retention (removing old tarballs) is not part of the
driver; a `tmpfiles.d` age rule or a `find -mtime` in a separate timer can do it later.
