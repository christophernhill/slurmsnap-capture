# slurmsnap-capture

Bash scripts that take snapshots of a Slurm cluster and pack them into dated bundles.

## 1. What this repository is

This repository holds bash scripts that take snapshots of the current state of a Slurm cluster.
Each script does one bulk, read-only Slurm query and writes one gzipped file. The file describes
itself: it says what ran, when, where, and how to split it. One run of every script gives one
snapshot bundle.

A bundle is the raw material for later work. It holds the data that says which jobs run or wait,
why they wait, and why their priorities differ. This repository only captures that data. Other
repositories parse it, load it into a database, and present it. Refer to section 10.

The scripts run on a Slurm login node. They need bash 4.3 or later, the Slurm client commands,
gzip, and GNU tar. A systemd timer can run them without a person at the keyboard, but systemd is
optional. The scripts change nothing in Slurm. They use no Slurm command or flag that changes
state.

## 2. What a snapshot bundle contains

A bundle is one tarball with eleven snapshot files and a manifest. The driver writes it into a
date hierarchy under a work root that you choose:

```
ROOT/
└── 2026/
    └── 11/
        └── 21/
            ├── eofe7-20261121T141500Z.tgz
            └── eofe7-20261121T143000Z.tgz
```

The year, month and day are UTC, the same as the time stamps in the file names. The name before
the stamp is the cluster name that Slurm reports. The tarball holds one directory with the same
name:

```
eofe7-20261121T141500Z/
├── manifest.txt
├── squeue-20261121T141500Z.txt.gz
├── scontrol-job-20261121T141501Z.txt.gz
├── sprio-20261121T141503Z.txt.gz
├── sshare-20261121T141503Z.txt.gz
├── scontrol-node-20261121T141504Z.txt.gz
├── scontrol-partition-20261121T141505Z.txt.gz
├── scontrol-reservation-20261121T141505Z.txt.gz
├── scontrol-config-20261121T141505Z.txt.gz
├── sacctmgr-assoc-20261121T141506Z.txt.gz
├── sacctmgr-qos-20261121T141507Z.txt.gz
└── sacct-20261121T141508Z.txt.gz
```

### 2.1 The header of a snapshot file

Every snapshot file starts with the same header lines. The header ends at the `# exit:` line.
The body comes after it.

```
# captured: 2026-11-21T14:15:00Z     one clock reading, also the source of the file name
# host: login006                     the node that ran the command
# cluster: eofe7                     the cluster name that scontrol reports
# slurm: slurm 26.05.4               the version of the command that ran
# command:                           the command as it ran, environment included
#   SLURM_TIME_FORMAT=%s squeue --all --array --noheader --states=all --Format=...
# format: records                    records, text or json
# times: epoch seconds ...           command-specific lines come here
# exit: 0                            the exit status of the Slurm command
```

A body line can also start with `#`, for example a shell comment in a job's submit line. Thus a
reader must cut the header at the `# exit:` line, not at the last line that starts with `#`.

### 2.2 The three body kinds

The body kind depends on what the Slurm command offers:

| Kind | Scripts | What the body is |
|---|---|---|
| records | squeue, sprio, sacct, sshare | A header row of field names, then one record per object |
| text | scontrol node, partition, reservation, config | The output of `scontrol show`, unchanged, in its multi-line layout |
| json | scontrol job, sacctmgr assoc, sacctmgr qos | One line of JSON |

In a records body, the fields of a record are separated by a TAB and the byte 0x1f. Each record
ends with the byte 0x1e and a newline. These two control bytes never occur in Slurm output.
Thus a job name or comment that contains a tab, a comma, a pipe or a newline cannot shift a
column or split a record. A value can contain a newline. A reader must split records at
0x1e+newline, never at a newline alone.

This command shows the first field of each record in a records file:

```bash
gzip -dc FILE | sed '1,/^# exit:/d' | tr -d '\n' | tr '\036' '\n' | awk -F $'\t\037' '{print $1}'
```

Times are epoch seconds wherever Slurm obeys `SLURM_TIME_FORMAT=%s`. Values are never
truncated.

## 3. The parts of the repository

The repository has five kinds of file: six snapshot scripts, one shared library, one driver, the
systemd units, and the documents.

| File | What it does | Body |
|---|---|---|
| `squeue-snapshot.sh` | Every job in every state, array tasks expanded, every field | records |
| `scontrol-snapshot.sh` | One `scontrol show` dump: node, partition, reservation, config or job | text or json |
| `sacctmgr-snapshot.sh` | The associations of this cluster, or every QOS | json |
| `sprio-snapshot.sh` | The priority factors of every pending job, per partition | records |
| `sacct-snapshot.sh` | Every job, array task and step that was active in a time window | records |
| `sshare-snapshot.sh` | Fair-share shares and usage for every account and user | records |
| `snapshot-lib.sh` | The functions that the scripts share. Sourced, never run | |
| `snapshot-bundle.sh` | The driver: runs the eleven snapshot calls and writes one bundle | tarball |
| `systemd/` | Timer and service units for the driver, for root or for an ordinary account | |
| `snapshot-plans/`, `AGENTS.md`, `CLAUDE.md`, `command-list`, `LICENSE` | The documents | |

Each snapshot script has the same shape. It asks Slurm which fields it knows, builds a format
from the answer, runs the Slurm command once, and writes the file. The field list is never
written into a script. Each script writes `OUT_DIR/<name>-<UTC stamp>.txt.gz` as a `.tmp` file
and then renames it, so the file appears whole or not at all. Each script prints the path of the
file and exits with the exit status of the Slurm command. Two exit statuses are the script's
own: 2 for a usage error, and 1 when a discovery step finds nothing.

### 3.1 `squeue-snapshot.sh`

```
squeue-snapshot.sh OUT_DIR          -> OUT_DIR/squeue-<UTC stamp>.txt.gz
```

What it captures: every job, in every state, in hidden partitions too, with array tasks
expanded, and every field that `squeue --helpFormat` lists.

What makes the file safe to read: every field has width `:0`, so no value is truncated. The
field separator and the record terminator are the control bytes of section 2.2. The header row
names every column.

Exit status: the status of squeue, 1 if squeue lists no fields, or 2 for a usage error.

Design note: this script is the model that the other scripts copy. The rules are in
[snapshot-plans/README.md](snapshot-plans/README.md).

### 3.2 `scontrol-snapshot.sh`

```
scontrol-snapshot.sh OUT_DIR OBJECT  -> OUT_DIR/scontrol-<OBJECT>-<UTC stamp>.txt.gz
OBJECT: node | partition | reservation | config | job
```

What it captures: every object of one kind, with every field, hidden partitions included.

What makes the file safe to read: for node, partition, reservation and config the body is the
output of `scontrol show` in its default multi-line layout. That layout keeps each free-text
value, for example `OS=` or `Reason=`, on its own line. The one-line layout would join them with
spaces and make the end of a value a guess. For job the body is JSON. The text form of a job has
values with spaces and equals signs, and no delimiter can make them unambiguous.

Exit status: the status of scontrol, or 2 for a usage error.

Design notes: [C03 node](snapshot-plans/C03-scontrol-show-node.md),
[C04 partition](snapshot-plans/C04-scontrol-show-partition.md),
[C07 job](snapshot-plans/C07-scontrol-show-job.md),
[C08 reservation](snapshot-plans/C08-scontrol-show-reservation.md),
[C10 config](snapshot-plans/C10-scontrol-show-config.md).

### 3.3 `sacctmgr-snapshot.sh`

```
sacctmgr-snapshot.sh OUT_DIR assoc   -> OUT_DIR/sacctmgr-assoc-<UTC stamp>.txt.gz
sacctmgr-snapshot.sh OUT_DIR qos     -> OUT_DIR/sacctmgr-qos-<UTC stamp>.txt.gz
```

What it captures: the association tree of this cluster, or every QOS, as one line of JSON.

What makes the file safe to read: sacctmgr has no field list and no delimiter option. JSON is
the only form that names every field. The assoc query always has the scope `cluster=<name>`.
The script takes the name from scontrol at run time and checks it against a pattern before it
uses it. Without a valid name the script writes nothing.

Exit status: the status of sacctmgr, 1 when assoc finds no valid cluster name, or 2 for a usage
error.

Design notes: [C12 assoc](snapshot-plans/C12-sacctmgr-assoc.md),
[C13 qos](snapshot-plans/C13-sacctmgr-qos.md).

### 3.4 `sprio-snapshot.sh`

```
sprio-snapshot.sh OUT_DIR           -> OUT_DIR/sprio-<UTC stamp>.txt.gz
```

What it captures: the priority factors of every eligible pending job, once per partition. Each
factor appears in two columns, normalized and weighted, side by side. A `# names:` header line
gives the column titles that sprio prints.

What makes the file safe to read: every format letter from `sprio --helpformat` is in the
format, with no width. The script makes no `sprio --weights` call, because that call crashes on
Slurm 26.05.5. The weights are in the config snapshot instead. If sprio dies from a signal, the
script tries each letter alone and blanks the bad ones. A `# blanked:` line records them.

Exit status: the status of sprio, 1 if sprio lists no letters, or 2 for a usage error.

Design note: [C14-C16 sprio](snapshot-plans/C14-C16-sprio.md).

### 3.5 `sacct-snapshot.sh`

```
sacct-snapshot.sh OUT_DIR [SINCE]   -> OUT_DIR/sacct-<UTC stamp>.txt.gz
```

What it captures: every job, array task and step that was active in a time window, for all
users of this cluster. The window starts at SINCE and ends at the time of the call. The file has
every field that `sacct --helpformat` lists. SINCE has the default `now-2hours`. Short forms such as `now-1d` or `now-90m` are permitted. The script
rewrites them into the whole-word units that sacct accepts.

What makes the file safe to read: sacct has no option to end a record. The script counts the
field separators on each line and adds the record terminator when a record is complete. Thus a
submit line with embedded newlines stays in its record. The script rejects a SINCE that it does
not know, so no unchecked text reaches the command line.

Exit status: the status of sacct, 3 if the output ends inside a record, or 2 for a usage error.
In the cut-short case the file is still written and has a `# warning:` line.

Design notes: [C11 sacct](snapshot-plans/C11-sacct-array-tasks.md),
[C17 seff](snapshot-plans/C17-seff.md).

### 3.6 `sshare-snapshot.sh`

```
sshare-snapshot.sh OUT_DIR          -> OUT_DIR/sshare-<UTC stamp>.txt.gz
```

What it captures: the configured shares and the decayed usage of every account and user, with
every field that `sshare --helpformat` lists. The indentation of the account tree is kept.

What makes the file safe to read: the script asks `sshare --help` whether this version has a
`--delimiter` option. If it has one, the script uses it. If not, the script takes the
pipe-separated output and translates each pipe into the field separator. Before that, it makes
sure that every line has the expected number of fields. If a line has more, a value contained a
pipe, and the script writes nothing.

Exit status: the status of sshare, 3 when a value contained a pipe, or 2 for a usage error.

Design note: [sshare fair share](snapshot-plans/sshare-fairshare.md).

### 3.7 `snapshot-lib.sh`

The snapshot scripts source this library. It defines five functions and nothing else:

- `show_command` prints a command as `# command:` header lines, wrapped so that you can paste it
  back.
- `snapshot_stamp` prints the UTC time. Each script reads it once, so the header and the file
  name agree.
- `cluster_name` prints the cluster name from `scontrol show config`, or nothing.
- `join_fields` joins field names into a format string or a header row.
- `write_snapshot` writes the header lines and the body, gzipped, as a `.tmp` file, then renames
  it.

### 3.8 `snapshot-bundle.sh`

```
snapshot-bundle.sh ROOT_DIR [SINCE]  -> ROOT_DIR/YYYY/MM/DD/<cluster>-<UTC stamp>.tgz
```

The driver runs one cycle. It reads the clock once and asks scontrol for the cluster name. From
these it builds the bundle name and the day directory of section 2. Then it runs the eleven
snapshot calls, one after another, into that directory. Then it writes the directory as a
tarball, compressed with gzip, as a `.tmp` file and renames it. Last, it removes the directory.

A step that fails does not stop the cycle. The other files still have value, and each file has
its own `# exit:` line. The manifest records what happened:

```
# bundle: eofe7-20261121T141500Z
# started: 2026-11-21T14:15:00Z
# host: login006
# cluster: eofe7
# command:
#   snapshot-bundle.sh /var/lib/slurm-snapshot now-2hours
# steps: 11
# columns: step	exit	seconds	file
squeue-snapshot.sh	0	3	squeue-20261121T141500Z.txt.gz
scontrol-snapshot.sh job	0	1	scontrol-job-20261121T141503Z.txt.gz
...
sacct-snapshot.sh now-2hours	0	9	sacct-20261121T141530Z.txt.gz
# finished: 2026-11-21T14:15:39Z
# failed: 0
# exit: 0
```

The exit status of the driver says what is on disk:

| Exit status | Meaning | What is on disk |
|---|---|---|
| 0 | Every step and the tar succeeded | The tarball |
| 1 | The tarball was written, but one or more steps failed | The tarball, with `# failed:` in the manifest |
| 3 | tar or gzip failed | The directory with its files, no tarball |
| 2 | Usage error | Nothing |

Design note: [bundle driver](snapshot-plans/bundle-driver.md).

### 3.9 `systemd/`

Two pairs of units run the same driver every 15 minutes. The pair in `systemd/system/` is for a
site where root installs a service and a dedicated account runs it. The pair in `systemd/user/`
is for an ordinary account that has no root access. Section 5 gives the steps for each.

### 3.10 The documents

- `snapshot-plans/` holds the design notes, one per Slurm command and one for the driver. Its
  `README.md` gives the rules, the file layout and the test results.
- `AGENTS.md` holds the instructions for anyone who changes this repository: scope, the file
  contract, the design rules, the known traps, and the tests.
- `CLAUDE.md` points an AI agent at `AGENTS.md`.
- `command-list` is the sequence of the eleven snapshot calls, as a person runs them by hand.
  The driver replaces it.
- `LICENSE` is the MIT License.

## 4. Run a snapshot by hand

You can run any script by hand before you install a timer:

1. Copy this directory to a login node.
2. Run one script with an output directory as its argument:

   ```bash
   ./squeue-snapshot.sh /tmp/snap-test
   ```

3. Look at the file that the script printed:

   ```bash
   gzip -dc /tmp/snap-test/squeue-*.txt.gz | head -12
   ```

To run one full cycle, give the driver a work root:

```bash
./snapshot-bundle.sh /tmp/snap-test
find /tmp/snap-test -type f
```

The second command lists one tarball under a date path.

## 5. Run on a timer with systemd

Two sets of units run the same driver. The driver finds the snapshot scripts and the library
next to itself, so copy the whole directory. Before you install either set, make sure that the
account has permission to read every job and association. The Slurm setting `PrivateData` can
hide them.

### 5.1 As a system service

Root installs the units. A dedicated account runs the driver.

1. Copy this directory to the login node, for example to `/opt/slurm-snapshot/`.
2. Create the work root, for example `/var/lib/slurm-snapshot`.
3. Create a service account that can run the Slurm client commands and write to the work root.
4. In `systemd/system/slurm-snapshot.service`, edit `User=` and the two paths in `ExecStart=`.
5. Copy the two units from `systemd/system/` to `/etc/systemd/system/`.
6. Enable the timer and do one check:

   ```bash
   systemctl daemon-reload
   systemctl enable --now slurm-snapshot.timer
   systemctl list-timers slurm-snapshot.timer
   systemctl start slurm-snapshot.service      # one cycle now
   journalctl -u slurm-snapshot                # the output of a failed step is here
   ```

### 5.2 As an ordinary user

The units in `systemd/user/` run under the systemd manager of your own account. You install
them with `systemctl --user`. They have no `User=` line and no sandbox. The paths are
parameters. The service reads them from `~/.config/systemd/user/slurm-snapshot.env`:

| Variable | Meaning | Default when the file is absent |
|---|---|---|
| `SNAPSHOT_SCRIPTS` | The copy of this directory | `~/slurm-snapshot` |
| `SNAPSHOT_ROOT` | The work root for the bundles | `~/slurm-snapshot-data` |
| `SNAPSHOT_SINCE` | The sacct window | `now-2hours` |

Write absolute paths in that file. systemd does not expand `~`, `$HOME` or other variables
there. The file `systemd/user/slurm-snapshot.env.example` is a template.

1. Choose the two paths and copy the directory:

   ```bash
   SCRIPTS=/path/of/your/choice/slurm-snapshot
   ROOT=/scratch/$USER/slurm-snapshot-data
   cp -r scripts "$SCRIPTS"
   mkdir -p "$ROOT" ~/.config/systemd/user
   ```

2. Install the units and write the parameter file:

   ```bash
   cp "$SCRIPTS"/systemd/user/slurm-snapshot.{service,timer} ~/.config/systemd/user/
   printf 'SNAPSHOT_SCRIPTS=%s\nSNAPSHOT_ROOT=%s\nSNAPSHOT_SINCE=now-2hours\n' "$SCRIPTS" "$ROOT" \
     > ~/.config/systemd/user/slurm-snapshot.env
   ```

3. Enable the timer and do one check:

   ```bash
   systemctl --user daemon-reload
   systemctl --user show -p EnvironmentFiles slurm-snapshot.service   # the file is known
   systemctl --user enable --now slurm-snapshot.timer
   systemctl --user list-timers slurm-snapshot.timer
   systemctl --user start slurm-snapshot.service        # one cycle now
   journalctl --user -u slurm-snapshot -n 5             # the last line is the tarball path
   ```

   The tarball path must start with your `SNAPSHOT_ROOT`. That is the proof that the parameter
   file is in effect. The property `Environment` shows only the defaults from the unit file,
   because systemd reads the parameter file when it starts the service, not when it loads the
   unit.

4. Keep the timer alive after you log out:

   ```bash
   loginctl enable-linger
   ```

The user manager normally stops when your last session ends, and the timer stops with it.
Linger keeps the manager alive. The default policy lets an account enable linger for itself. If
your site does not permit this, ask the administrator to run `loginctl enable-linger USER`.

To move the work root later, edit the parameter file and run `systemctl --user daemon-reload`.
The next cycle uses the new path.

If `systemctl --user` answers "Failed to connect to bus", the login node runs no user manager.
Then the system units of section 5.1 are the way. As a last resort, a crontab line can run the
driver. Cron starts a second run while the first still runs, so the line must take a lock:

```
*/15 * * * * flock -n ROOT/.lock SCRIPTS/snapshot-bundle.sh ROOT now-2hours >/dev/null
```

Write `ROOT` and `SCRIPTS` as the same absolute paths as in the parameter file.

### 5.3 What to expect in operation

Each cycle leaves one tarball under the date path. systemd does not start a cycle while the
previous cycle still runs, so cycles never overlap. The setting `TimeoutStartSec=` is the only
time limit on a cycle. Keep it above 2 minutes, because scontrol retries for 60 seconds per call
when Slurm is down. Keep it below the timer interval. The `seconds` column of the manifests shows
how long each step takes.

The driver does not remove old tarballs. A `tmpfiles.d` age rule or a separate `find -mtime`
timer can do that.

## 6. Check that a bundle is complete

Three checks tell you that a bundle is complete. Replace NAME with the base name of the tarball,
without `.tgz`.

1. The tarball is under the date path and holds twelve members:

   ```bash
   tar -tzf ROOT/2026/11/21/NAME.tgz
   ```

2. The manifest shows exit status 0 for every step and `# failed: 0` at the end:

   ```bash
   tar -xzOf ROOT/2026/11/21/NAME.tgz NAME/manifest.txt
   ```

3. Each snapshot file has `# exit: 0` in its header:

   ```bash
   for m in $(tar -tzf ROOT/2026/11/21/NAME.tgz | grep 'txt.gz$'); do
     printf '%s %s\n' "$m" "$(tar -xzOf ROOT/2026/11/21/NAME.tgz "$m" | gzip -dc | grep -m1 '^# exit:')"
   done
   ```

## 7. Where the design reasoning is

Every design decision has a document. [snapshot-plans/README.md](snapshot-plans/README.md)
holds the rules that every script obeys, the file layout, and the parse rule for text bodies.
It also holds the cadence table and the facts that were checked on a test cluster. One note per
Slurm command
says why the script has its argument list, its body kind and its flags. The note
[bundle-driver.md](snapshot-plans/bundle-driver.md) does the same for the driver.

The scripts were tested on a local Docker Slurm cluster, version 26.05.5, and against one bundle
from a production cluster with about 39,000 sacct records. `AGENTS.md` describes the test
cluster and the test procedure.

## 8. For contributors

The rules for changes to this repository are in [AGENTS.md](AGENTS.md). That file gives the
scope, the file contract, the design rules, the known traps, the tests, and the checks that a
reviewer does. Every `*.sh` file passes `shellcheck`.

## 9. Related repositories

This repository is the first of the `slurmsnap-*` family:

| Repository | What it does |
|---|---|
| `slurmsnap-capture` | Captures the raw snapshot bundles. This repository. |
| `slurmsnap-ingest` | Regularizes the bundles and loads them into a DuckDB store. |
| The analysis repository | Analyzes and presents the information in the store. |

## 10. License

MIT. Refer to [LICENSE](LICENSE).
