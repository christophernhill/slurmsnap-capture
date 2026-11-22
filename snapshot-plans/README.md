# snapshot-plans/

Design notes for building a **counterpart of `squeue-snapshot.sh` for every other Slurm command in
`capture-raw.sh`**, plus two that capture-raw lacks but that explain priority and pending reasons:
`sshare` and reservations. Each doc covers one capture-raw command step. It says what the step
does today, which script replaces it, and how that script works.

`capture-raw.sh` was removed from `script-form/` on 2026-11-13. It now lives only in
`../slurmview-collect/scripts/capture-raw.sh`, a git-tracked copy. The docs' "What
capture-raw.sh does today" sections describe that copy, and are kept as design history.

**Status (2026-11-12): every planned script is implemented** in `script-form/`, next to
`squeue-snapshot.sh`. Each is shellcheck-clean and was run end-to-end in the Docker test
cluster (see [Test cluster](#test-cluster)). What is still open is listed under
[Still to verify](#still-to-verify).

## Why

`squeue-snapshot.sh` is a small, clear pattern:

1. **discover**: ask the command which fields it knows (`squeue --helpFormat`);
2. **build**: an untruncated format from that list;
3. **run once**: one call, every object;
4. **write**: one gzipped, self-describing file (`# key: value` lines, a header row, records),
   which appears whole through a `.tmp` rename.

`capture-raw.sh` mixes several concerns:
- ULIDs and a JSON manifest;
- argvs hardcoded byte for byte to match core's catalog;
- data_parser negotiation;
- four **per-object follow-up loops**, each capped at `--max-details` (50):

| Loop | Command | Run for |
|---|---|---|
| C07 | `scontrol show job <key>` | each PENDING job |
| C14, C15 | `sprio -j <id>` and `sprio -n -j <id>` | each PENDING job |
| C11 | `sacct --jobs=<array>` | each array |
| C17 | `seff <key>` | each COMPLETED job |

That is up to 250 calls per capture (5 commands × 50), and still only a sample of the jobs.
Every one of these commands has a bulk form. With the counterparts below, the follow-up count is **0**.

## Index

| Doc | capture-raw step | Counterpart (all implemented) | Body |
|---|---|---|---|
| [C01-scontrol-json-list.md](C01-scontrol-json-list.md) | C01 data_parser negotiation | **none** (not needed) | — |
| [C10-scontrol-show-config.md](C10-scontrol-show-config.md) | C10 | `scontrol-snapshot.sh OUT_DIR config` | text |
| [C03-scontrol-show-node.md](C03-scontrol-show-node.md) | C03 | `scontrol-snapshot.sh OUT_DIR node` | text |
| [C04-scontrol-show-partition.md](C04-scontrol-show-partition.md) | C04 | `scontrol-snapshot.sh OUT_DIR partition` | text |
| [C07-scontrol-show-job.md](C07-scontrol-show-job.md) | C07 loop | `scontrol-snapshot.sh OUT_DIR job` | json |
| [C08-scontrol-show-reservation.md](C08-scontrol-show-reservation.md) | *(not in capture-raw)* | `scontrol-snapshot.sh OUT_DIR reservation` | text |
| [C12-sacctmgr-assoc.md](C12-sacctmgr-assoc.md) | C12 | `sacctmgr-snapshot.sh OUT_DIR assoc` | json |
| [C13-sacctmgr-qos.md](C13-sacctmgr-qos.md) | C13 | `sacctmgr-snapshot.sh OUT_DIR qos` | json |
| [C14-C16-sprio.md](C14-C16-sprio.md) | C14, C15 loops; C16 (weights → config snapshot) | `sprio-snapshot.sh OUT_DIR` | records |
| [C11-sacct-array-tasks.md](C11-sacct-array-tasks.md) | C11 loop | `sacct-snapshot.sh OUT_DIR [SINCE]` | records |
| [C17-seff.md](C17-seff.md) | C17 loop | **none** (derived from the sacct snapshot) | — |
| [sshare-fairshare.md](sshare-fairshare.md) | *(not in capture-raw)* | `sshare-snapshot.sh OUT_DIR` | records |
| *(existing script)* | C02 | `squeue-snapshot.sh OUT_DIR` (now uses the shared helpers) | records |
| [bundle-driver.md](bundle-driver.md) | *(the whole of `command-list`, run by hand)* | `snapshot-bundle.sh ROOT_DIR [SINCE]`: all of the above once, into one `.tgz` per cycle, for a systemd timer | tarball |

**Script count: five new scripts** (`scontrol-`, `sacctmgr-`, `sprio-`, `sacct-` and
`sshare-snapshot.sh`) plus the existing `squeue-snapshot.sh`. All of them share `snapshot-lib.sh`.
`snapshot-bundle.sh` (2026-11-21) runs them all; the units in `../systemd/` schedule it.

**Verification markers.** "VERIFIED docker" means checked on the local Docker Slurm 26.05.5 on
2026-11-12 (see [Test cluster](#test-cluster)). "TO VERIFY" means still open; check it on Docker
first, then on orcd-login.

## Design rules

0. **Ask Slurm at runtime; don't assume.** When a command can report its own fields or names, the
   script asks it on **every run** and never hardcodes them:
   - field lists: `squeue --helpFormat`, `sprio --helpformat`, `sacct --helpformat`, `sshare --helpformat`;
   - column titles: sprio's own header row;
   - the cluster name: `scontrol show config`;
   - option support that varies by release (sshare `--delimiter`): probe `<cmd> --help` at runtime.

   Docker checks confirm *behaviour* (truncation, delimiters, line layout). They are never a source
   of field lists to paste into a script. Anything still hardcoded is labelled
   **"hardcoded: no runtime option"** with its reason. Today there are five cases:
   - the scontrol object table;
   - the sacctmgr entity table;
   - the sacct `SINCE` unit table ([C11](C11-sacct-array-tasks.md));
   - the free-text key list in the [text parse rule](#text-parse-rule);
   - the step list of `snapshot-bundle.sh` ([bundle-driver.md](bundle-driver.md)): which
     snapshots make a bundle is a design decision, and each step's argv must be a literal.
1. **One bulk call per file, all objects.** No loops over jobs, arrays, partitions or users.
2. **Four stages** as in squeue-snapshot.sh: discover → build → run once → write. When a command
   has nothing to discover, its doc says why.
3. **The body kind follows the command:**
   - **records**, for commands with a format language and a field list (squeue, sprio, sacct,
     sshare). Fields are separated by TAB + 0x1f, each record ends with 0x1e + newline, and the
     file has a header row. The control bytes never occur in Slurm output, so no value can shift
     a column or split a record.
   - **text**, for `scontrol --all show node|partition|reservation|config` under
     `SLURM_TIME_FORMAT=%s`. scontrol's output is kept **unchanged**, in the default multi-line
     form, **not `-o`/`--oneliner`**:
     - the multi-line form puts each free-text field (`OS=`, `Reason=`, `Comment=`, `Extra=`) on
       its own indented line;
     - `-o` joins everything with single spaces, so where a free-text value ends becomes a guess
       (see [C03](C03-scontrol-show-node.md#why-not--o));
     - compared with `--json`: the same data from the same RPC, about half the size, no
       `serializer/json` dependency, and no layout changes between data_parser versions.
   - **json**, for sacctmgr assoc/qos and for `scontrol show job`:
     - sacctmgr has no field discovery and no `--delimiter`, so JSON is the only form that is both
       complete and unambiguous;
     - job text has free text with `=` inside values (`SubmitLine=… --mem=100M …`), and it lacks
       keys JSON has (see [C07](C07-scontrol-show-job.md)).

     Use plain `--json` with the default parser, under `SLURM_JSON=compact` (one line;
     VERIFIED docker for scontrol and sacctmgr). The envelope's `meta.plugin.data_parser`,
     `meta.slurm.release` and `meta.slurm.cluster` describe the output.
4. **Same metadata header everywhere** (see [File layout](#file-layout)).
5. **Usage and output:** `<name>-snapshot.sh OUT_DIR [ARG]`. The script writes
   `OUT_DIR/<name>-<UTC stamp>.txt.gz`, prints the path, and exits with the Slurm command's status.
   It is read-only, and runs as a systemd oneshot service plus a timer. Like
   squeue-snapshot.sh, it uses no `timeout` or byte cap: the unit's `TimeoutStartSec=` bounds the
   run.
6. **Validate every dynamic value** before it reaches an argv: the cluster name
   `^[A-Za-z0-9_.-]{1,64}$`, the sacct `SINCE` (its accepted forms are listed in [C11](C11-sacct-array-tasks.md)), the scontrol object name. No argv may contain a
   mutating token (`MUTATING_TOKENS` in `slurmview-core/src/slurmview_core/commands/catalog.py`).

## File layout

Every file starts with the same metadata lines. Command-specific lines (`# times:`,
`# separators:`, `# window:`, `# records:`, `# names:`, `# blanked:`, `# translated:`,
`# warning:`) go between `# format:` and `# exit:`:

```
# captured: 2026-11-12T22:41:07Z
# host: login1
# cluster: linux
# slurm: slurm 26.05.5
# command:
#   SLURM_TIME_FORMAT=%s scontrol --all show node
# format: text                      (records | text | json)
# exit: 0
<body>
```

- **records** add `# separators: TAB+0x1f between fields, 0x1e then newline after each record`.
  The header row comes first, then the records, as in squeue-snapshot.sh.
  - **A value may contain a raw newline**, for example a squeue `Comment` or a sacct
    `SubmitLine`. A record ends only at 0x1e followed by a newline, so split records on that,
    never on a newline alone.
  - **A body line may start with `#`** (a shell comment inside a sacct `SubmitLine`; 19 of them
    in the orcd bundle). The metadata is only the lines up to and including `# exit:`, so strip
    those and nothing else.
  - The viewing command `tr -d '\n' | tr '\036' '\n'` joins such a value onto one line, which
    is fine for eyeballing.
- **text**: the body is scontrol's stdout, unchanged.
- **json**: the body is one compact JSON document. Strip the metadata lines before parsing.

To read any file's body: `gzip -dc FILE | sed '1,/^# exit:/d'` (never `grep -v '^#'`, which
also drops body lines that start with `#`). To read the format:
`gzip -dc FILE | grep -m1 '^# format:'`.

## Text parse rule

This rule is for downstream code reading the **text** bodies. The script never parses them.

1. Objects are separated by blank lines. An object starts with an unindented `NodeName=`,
   `PartitionName=` or `ReservationName=` line. Config is a single object of `Key = Value` lines;
   see [C10](C10-scontrol-show-config.md).
2. Continuation lines are indented by three spaces.
3. If a line's **first** key is a free-text key, the rest of the line is its value.
   **Hardcoded: no runtime option.** The keys are `OS`, `Reason`, `Comment` and `Extra` for
   nodes, and `Comment` for reservations. Each doc lists the keys for its object.
4. Otherwise, split the line on runs of spaces. Each token is `Key=Value`, split at the **first**
   `=`. Keys can contain `:` and `/` (`AllocNode:Sid=`, `CPUs/Task=`).
5. A line that is neither indented nor the start of an object continues the previous value. This
   covers a newline inside a free-text value, which is rare.
6. Times are epoch seconds (`SLURM_TIME_FORMAT=%s`), except the words `None`, `Unknown`, `N/A`
   and `INFINITE`. Durations keep Slurm's `[D-]HH:MM:SS` form.

## Shared helpers (`snapshot-lib.sh`)

These sit next to `show_command`. The library stays function-only: it sets no shell options and
touches no variables of the caller, so helpers print results rather than set globals.
**Status:** all four are implemented (2026-11-12), and every snapshot script uses them.

| Function | Does |
|---|---|
| `snapshot_stamp` | Prints the UTC time as `2026-11-12T22:41:07Z`. The caller reads it **once** (`captured=$(snapshot_stamp)`) and passes it to `write_snapshot`, which derives the file name's `20261112T224107Z` from it. Before the switch, squeue-snapshot.sh called `date` twice, so the two could differ |
| `cluster_name` | Prints `ClusterName` from `scontrol show config`, or nothing, and always returns 0, so `name=$(cluster_name)` is safe under `set -e`. This is the awk from squeue-snapshot.sh line 59, **without `exit`**, which would SIGPIPE under pipefail |
| `join_fields PREFIX SUFFIX SEP END` | Reads names on stdin and prints `PREFIX name SUFFIX`, joined by `SEP`, with `END` after the last. It generalizes squeue-snapshot.sh lines 39–42: squeue `('' ':0' "$fs," "$rs")`, sprio `('' '' "$fs" "$rs")` (the letters already carry `%`), header rows `('' '' "$fs" "$rs")`, sacct/sshare `--format` `('' '' ',' '')` |
| `write_snapshot OUT_DIR NAME CAPTURED FORMAT STATUS BODY EXTRA WORD...` | Writes `OUT_DIR/NAME-<stamp>.txt.gz`. The common lines are `# captured` (CAPTURED), `# host` (`hostname -s`), `# cluster` (`cluster_name`), `# slurm` (`<exe> --version`, where exe is the first WORD without `=`), `# command` (`show_command WORD...`), `# format`, then EXTRA (newline-separated `# key: value` lines, or `""`), then `# exit` (STATUS as given), then BODY unchanged. It gzips to `.tmp`, renames, and prints the path |

**squeue-snapshot.sh uses these helpers too (done 2026-11-12).** Diffed against the previous
version's output in Docker, it changes in two ways only: one timestamp instead of two, and a new
`# format: records` line. Core's C02 parser (`slurmview_core/parsers/c02_squeue.py`) strips every
leading `#` line, and it still parses the new file.

Each script keeps its own stage 1–3 code. The table above is all that is shared.

## Cadence

| Interval | Snapshots | Why |
|---|---|---|
| 5 min | squeue, `scontrol job`, sprio, sshare | Queue, priority factors and fair-share usage move with every scheduler pass. `PriorityCalcPeriod` defaults to 5 min |
| 5–15 min | `scontrol node` | Node state and allocation change often. Upstream calls this the heaviest call |
| 15–60 min | `scontrol reservation` | Reservations change rarely |
| 1 h | `scontrol partition`, `scontrol config`, sacctmgr assoc/qos | Configuration changes rarely |
| 1 h | sacct, `SINCE=now-2hours` | The windows overlap. Downstream deduplicates by `JobIDRaw` (plus the step id), keeping the newest snapshot |

**What runs today (decided 2026-11-21):** `snapshot-bundle.sh` runs **all eleven snapshots every
15 minutes** (`systemd/system/` or `systemd/user/`, `OnCalendar=*:0/15`), sacct with `now-2hours`.
Every bundle is complete and self-contained; the tiers above say which files could be thinned
out later if the hourly-class queries prove costly. See [bundle-driver.md](bundle-driver.md).

## Test cluster

A local Docker Slurm is running:
- image `slurm-docker-cluster:26.05.5`;
- containers `slurmctld`, `slurmdbd`, `slurmrestd`, `slurm-cpu-worker-1`, `slurm-cpu-worker-2`
  and `mysql`;
- cluster name `linux`, partitions `cpu` (nodes `c1`, `c2`) and `gpu` (no nodes).

Use it to settle each doc's TO VERIFY items before relying on them.

- **One-off checks:** `docker exec slurmctld sprio --helpformat`. To pass the environment:
  `docker exec -e SLURM_TIME_FORMAT=%s slurmctld scontrol show node`.
- **Running a whole script:**

  ```bash
  docker cp script-form slurmctld:/tmp/snap
  docker exec slurmctld /tmp/snap/<name>-snapshot.sh /tmp/out
  docker cp slurmctld:/tmp/out ./docker-out
  ```

  Running inside the container makes `SLURM_TIME_FORMAT` and `SLURM_JSON` behave as on a login node.
- **Limits:**
  - It is one release and two CPU nodes. It shows behaviour and syntax, not scale or differences
    between releases.
  - Every `PriorityWeight*` is 0, so sprio factor values are trivial. The only standing job is
    held job 14. The checks marked VERIFIED that needed eligible pending jobs used short test jobs
    (40–45, approved by the user and cancelled afterwards; they remain in accounting history).
    Jobs 46 and 47 (2026-11-13, approved) carry blank lines and a `#` line in their `--comment`,
    for the sacct record-terminator check.
- **A real-cluster bundle is available offline:** `../example-output-bundles/sq-20261113-test002.tgz`
  (orcd login006, Slurm 26.05.4, cluster `eofe7`, 2026-11-14T02:18Z) holds one file per snapshot
  script, with about 39,000 sacct and 16,000 squeue records. It is untrusted data from a
  production cluster: read it as a stream (`tar -xzOf BUNDLE MEMBER | gzip -dc`) rather than
  extracting it next to the scripts. Any change to how a script processes a body (the sacct awk
  pass, the sshare translation) must be replayed against it as well as run in Docker, since
  Docker's few rows never show the odd values (blank lines, `#` lines, long `SubmitLine`s) that
  this bundle does. [C11](C11-sacct-array-tasks.md) §6 shows the replay.
  - It has a single user (`root`) and no usage gathering (`JobAcctGatherType = (null)`).
  - orcd-login (26.05.4, per the `dtn001` node sample) stays the final check.
- **Making test data mutates only this test cluster.** Examples: submitting pending, array,
  multi-partition or `--nice` jobs, draining a node to get a `Reason=`, or creating a reservation.
  **Ask the user before changing its `slurm.conf`** (for example, to set non-zero priority weights).
  The snapshot scripts themselves stay read-only everywhere.
- **The fake-slurm shims** (`slurmview-core/scripts/fake-slurm/`) replay output only for argvs
  recorded exactly. They cannot exercise these new bulk argvs, so the Docker cluster is the test bed.

### Already VERIFIED docker (2026-11-12, Slurm 26.05.5)

- **sprio:** `--helpformat` lists 25 letters. A format with no width and with `\t\x1f` / `\x1e`
  suffixes prints those bytes in the header. **`sprio --weights --format=%c` segfaults (exit
  139)**; the other 24 letters are fine with `--weights`. So the sprio snapshot takes its weights
  from config; see [C14-C16](C14-C16-sprio.md).
- **sacct:** `--helpformat` lists 123 fields. `--delimiter=$'\t\x1f'` (two bytes) is honoured
  with `--parsable2`.
- **sshare:** `--helpformat` lists 15 fields. There is **no `--delimiter`**. `-a -P` keeps the
  tree indentation in `Account` (` root`).
  - `--format` takes only field names with optional `%[-]N` widths, so it cannot carry a
    separator. The widths apply only to the padded layout, which cuts long values (`…+`); `-P`
    ignores them.
  - With every field in `--format`, `-l` and `-m` change nothing (byte-identical output).
  - Checked on 2026-11-13, with the schedmd source (25.05.4) for the delimiter logic; see
    [sshare-fairshare.md](sshare-fairshare.md).
- **sshare on orcd login006** (2026-11-13, from the user's paste of `--usage` and
  `--helpformat`): no `--delimiter`, and the same 15 fields. So the `|` translation is orcd's path.
- **scontrol text:** `SLURM_TIME_FORMAT=%s` turns times into epoch seconds. In multi-line output
  `OS=` sits on its own line, and in `-o` output the line breaks become one or two spaces.
- **Empty reservations:** `scontrol show reservation` with none prints
  `No reservations in the system` on stdout and exits 0.
- **sacctmgr:** `--json show assoc cluster=nosuch` returns `"associations": []`, so the filter
  is honoured. `SLURM_JSON=compact` makes sacctmgr JSON one line.
- **Jobs:** job JSON has 137 keys, including `priority_by_partition`, `job_resources`,
  `gres_detail` and `state_description`. Job text has `SubmitLine=` with spaces and `=` in the value.
  `-d` changes nothing in the JSON, even for a running two-node job.
- **sprio with job rows:** `%c` prints `(null)` and every letter exits 0 in the jobs call, so only
  `--weights` crashes. A multi-partition job gives one row per partition. Cells are unpadded.
- **sacct with test jobs:**
  - Pending array tasks are expanded and step rows (`40.batch`) are kept.
  - A newline inside `SubmitLine` stays inside its record.
  - A **blank line** inside `SubmitLine` stays inside its record too (2026-11-13, jobs 46 and
    47, after the fix described in [C11](C11-sacct-array-tasks.md) §2; before it, awk's
    `split("")` = 0 made an empty line count −1 separators, and the record swallowed the start
    of the next one. The orcd bundle showed 12 such records out of 38,954).
  - The window catches jobs that were pending or running in it, whenever they were submitted.
  - A never-eligible held job is not in sacct at all.
  - `Comment` is empty because `AccountingStoreFlags` lacks `job_comment`.
- **Failure paths:** each was checked with a stub that the script picks up first on `PATH`:
  - sprio killed by a signal → the bad letter is blanked;
  - sacct output cut short → exit 3 and a `# warning:` line;
  - an sshare value containing `|` → exit 3, no file;
  - a bad or empty cluster name for assoc → exit 1;
  - a broken `SLURM_CONF` → scontrol's exit 1, with the file still written.

- **Bundle driver** (2026-11-21, [bundle-driver.md](bundle-driver.md) §8): a run writes only
  `ROOT/2026/11/21/linux-<stamp>.tgz` (11 members plus `manifest.txt`, no loose directory, exit
  0); a failing step (sshare stub) is recorded and the cycle goes on (exit 1); a failing tar
  keeps the directory and exits 3; `slurmsnap-ingest check` reads the tarball and skips the
  manifest as `ignored_file`.

## Still to verify

None of these need a script change unless the check fails.

- **On orcd-login (read-only):**
  - `snapshot-bundle.sh` cycle duration and tarball size, to set `TimeoutStartSec=`; the service
    user's `PrivateData` view; whether `ProtectSystem=strict` blocks anything the Slurm clients
    need ([bundle-driver.md](bundle-driver.md) §9);
  - long user, account and partition names print in full in sprio (Docker has only `root`);
  - `PrivateData` visibility for the timer's user (squeue, sprio, sacct, sshare, sacctmgr);
  - hidden partitions are included by `--all`;
  - `-d` on GPU nodes;
  - plugin section headings in `scontrol show config`;
  - the `sprio -w` weights against `PriorityWeight*`;
  - the seff formula, and a seff cross-check on 3 completed jobs;
  - run times and sizes at scale;
  - `sshare -m` with partition-specific associations, if orcd has any (Docker has none; with
    every field in `--format` it changes nothing there);
  - sshare row count, and that no value contains `|` (see [sshare-fairshare.md](sshare-fairshare.md) §6).
- **On Docker, needing approval (they change state beyond short jobs):**
  - drain a node, to see where `Reason=` sits;
  - create a reservation, for its layout and `Comment=`;
  - set association and QOS limits and flags, to confirm the text-to-JSON key mapping in C12 and C13.

## How to check the docs

For each doc:
- the four stages map onto squeue-snapshot.sh;
- there is no per-object loop;
- every argv is read-only and validated;
- every field list comes from a runtime query where the command offers one (rule 0);
- the "Verify" section lists `docker exec slurmctld …` commands first, then orcd-login.
