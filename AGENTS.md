# AGENTS.md: script-form/

Instructions for anyone, human or agent, working in this directory. Read it all before changing
anything.

## 1. What this directory is

A small set of **bash scripts that take snapshots of a Slurm cluster's current state**. Each
script runs **one bulk, read-only Slurm query**, for every job, node, partition, association and
so on at once. It writes the result to **one gzipped, self-describing file** in an output
directory. The files from one run of all the scripts together form a **snapshot bundle**.

The bundle is meant to be the complete raw material for later explaining what the cluster is
doing: which jobs run or pend, why they pend, and why their relative priorities differ. The
scripts are designed to run unattended, from a systemd oneshot service plus a timer on a Slurm
login node, using only bash and the Slurm client commands.

## 2. Scope: snapshot gathering only

**In scope:**
- running Slurm query commands and capturing their output completely and faithfully;
- the file layout of the snapshots (metadata header, body formats, separators, file naming);
- the scripts, the shared library, their design notes (`snapshot-plans/`) and their testing.

**Out of scope.** These are separate projects; do not do them here:
- parsing snapshot files into tables or data models;
- analysis: priority explanation, pending-reason diagnosis, limit checks, efficiency (seff-style)
  numbers, trends;
- presentation: TUIs, web pages, reports, dashboards;
- storage or ingest pipelines (Parquet, databases, bundling for transfer).

Consequences:
- **Do not add parsers, readers or analysis code** to this directory. The bodies are left as
  Slurm printed them on purpose. The one exception is the record terminator that
  `sacct-snapshot.sh` adds, and the `|` translation in `sshare-snapshot.sh`; both exist only to
  make the format unambiguous.
- **Do not edit the downstream repositories** (`../slurmview-core`, `../slurmview-collect`, …) as
  part of snapshot work, even if you notice a problem there. Mention it to the user instead.
- **Never change a snapshot's format to suit a downstream reader.** If a reader mishandles a
  valid snapshot, the reader is wrong. Example: a raw newline inside a squeue `Comment` is valid
  snapshot data.
- **The test of "done well":** each file is complete (every object, every field the command
  offers), unambiguous (no value can shift a column or split a record), self-describing (it says
  what ran, when, where, and how to split it) and cheap to produce.

## 3. Directory map

| Path | What it is |
|---|---|
| `squeue-snapshot.sh` | Every job, every state, hidden partitions, array tasks expanded; all `squeue --helpFormat` fields. **records** |
| `scontrol-snapshot.sh OUT_DIR node\|partition\|reservation\|config\|job` | One `scontrol show` dump. Text for node, partition, reservation and config (default multi-line layout); JSON for job |
| `sacctmgr-snapshot.sh OUT_DIR assoc\|qos` | Associations (this cluster only) or QOS. **json** |
| `sprio-snapshot.sh` | Priority factors of every eligible pending job, once per partition, normalized and weighted. **records** |
| `sacct-snapshot.sh OUT_DIR [SINCE]` | Every job, array task and step active in a window ending now; all `sacct --helpformat` fields. **records** |
| `sshare-snapshot.sh` | Fair-share shares and usage for every account and user. **records** |
| `snapshot-bundle.sh ROOT_DIR [SINCE]` | The driver for a systemd timer: every snapshot above once, in `command-list` order, into `ROOT_DIR/YYYY/MM/DD/<cluster>-<stamp>/`, plus a `manifest.txt`; then tarred and gzipped to `<cluster>-<stamp>.tgz` and the directory removed. Design: `snapshot-plans/bundle-driver.md` |
| `systemd/` | Example `slurm-snapshot.service` (oneshot) and `slurm-snapshot.timer` (`OnCalendar=*:0/15`) for the driver: `system/` for a root-installed service account, `user/` for an ordinary account's `systemctl --user` |
| `snapshot-lib.sh` | Sourced, never run. `show_command`, `snapshot_stamp`, `cluster_name`, `join_fields`, `write_snapshot` |
| `snapshot-plans/` | Design notes: one doc per command step, plus `README.md` (rules, file layout, cadence, test cluster, open items). **The reference for design decisions** |
| `README.md` | The reader's guide: what the repository is, what a bundle contains, each file, how to run by hand and under systemd. Written in Simplified Technical English (ASD-STE100) as far as the subject permits |
| `command-list` | The user's own list of commands for one bundle run. Don't edit it unless asked |

The legacy `capture-raw.sh` (the old per-job capture, which the `snapshot-plans/` docs compare
against) and `uv-env.sh` were removed from here on 2026-11-13. Their copies are tracked in
`../slurmview-collect/scripts/`. `command-list` and the `snapshot-plans/README.md` index now say
which commands a bundle needs.

This directory **became a git repository on 2026-11-21** (branch `main`; one commit per
component, so `git log` reads as a tour of the system). Don't commit or push anything without
being asked. Commit messages name Claude's role with the phrase "Claude assisted"; they carry no
authorship or co-author line for it.

## 4. The snapshot file contract

Every script writes `OUT_DIR/<name>-<UTC stamp>.txt.gz`, e.g.
`scontrol-node-20261113T015316Z.txt.gz`, and prints its path.
- **Atomic:** the file is written as `.tmp` and renamed, so it appears whole or not at all.
- **Header lines:** the decompressed file starts with `# key: value` lines, always in this order:

  ```
  # captured: 2026-11-13T01:53:16Z        one clock reading; the file name is derived from it
  # host: login007
  # cluster: <ClusterName>
  # slurm: slurm 26.05.5
  # command:                               exactly what ran, environment included, wrapped and pasteable
  #   SLURM_TIME_FORMAT=%s … scontrol --all show node
  # format: records | text | json
  # …                                      command-specific lines (times, separators, window, names, …)
  # exit: 0                                the Slurm command's exit status
  ```
- **Body:** after the header comes one of three kinds:
  - **records**: a header row of field names, then one record per object. Fields are separated by
    TAB + 0x1f, and each record ends with 0x1e + newline. These control bytes never occur in Slurm
    output.
    - **A value may contain a raw newline** (a squeue `Comment`, a sacct `SubmitLine`). Split
      records on 0x1e+newline, never on newline alone.
  - **text**: scontrol's stdout unchanged, in the default multi-line layout, **never `-o`**. That
    layout keeps free-text values (`OS=`, `Reason=`, `Comment=`) on their own lines. The parse
    rule for later readers is in `snapshot-plans/README.md`.
  - **json**: one line of JSON (`SLURM_JSON=compact`). Its `meta.plugin.data_parser` names the
    parser version.
- **Times:** epoch seconds wherever Slurm honours `SLURM_TIME_FORMAT=%s`.
- **Viewing a records file:**
  `gzip -dc FILE | sed '1,/^# exit:/d' | tr -d '\n' | tr '\036' '\n' | awk -F $'\t\037' '{print $1}'`
  The metadata is only the lines up to and including `# exit:`. A body line may itself start
  with `#` (a shell comment inside a sacct `SubmitLine`), so never strip every `#` line.
- **Exit status:** the Slurm command's own status, or one of the script's own:
  - `2`: a usage error;
  - `1`: a discovery step found nothing (`--helpFormat`/`--helpformat` listed no fields), or
    `sacctmgr assoc` found no valid cluster name;
  - `3`: the output was cut short inside a record (sacct), or a value contained the delimiter
    (sshare).
- **When a file is written:** a Slurm command that fails still produces a file, with its status
  on `# exit:` (sacct's cut-short case too, with a `# warning:` line). No file is written for a
  usage error, a failed discovery step, a missing cluster name, or sshare's ambiguity.
- **A bundle** (what `snapshot-bundle.sh` writes) is `ROOT_DIR/YYYY/MM/DD/<cluster>-<stamp>.tgz`:
  one directory `<cluster>-<stamp>/` holding the eleven snapshot files of one cycle and a
  `manifest.txt` (`# key: value` lines, then one TAB-separated line per step: step, exit,
  seconds, file). The date path and the stamp are UTC from one clock reading. The tarball is
  written as `.tmp` and renamed; the loose directory is removed only after that, and is kept
  when tar fails. The driver exits 0, 1 (a step failed; tarball written), 3 (tar failed) or
  2 (usage). A bundle directory or tarball is what downstream readers take as input.

## 5. Design rules (all scripts follow them; keep it that way)

0. **Ask Slurm at runtime; don't assume.** Field lists come from the command on every run:
   `squeue --helpFormat`, `sprio --helpformat`, `sacct --helpformat`, `sshare --helpformat`.
   - Option support that varies by release is probed at runtime, e.g. `sshare --help` for
     `--delimiter`.
   - Never paste a field list into a script.
   - Anything hardcoded because Slurm offers no way to ask is labelled "hardcoded: no runtime
     option" with its reason. Today: the scontrol object table, the sacctmgr entity table, the
     sacct `SINCE` unit table, and the free-text key list of the text parse rule.
1. **One bulk call per file**, covering every object. **No loops over jobs, arrays, partitions or
   users.** That is what made the old `capture-raw.sh` slow and partial. sprio's crash fallback (per-letter
   probes) runs only after a crash.
2. **Four stages, labelled in comments:** discover → build → run once → write. This follows
   `squeue-snapshot.sh`, the model to copy.
3. **The body kind follows the command:**
   - records when the command has a format language and a field list;
   - JSON when it only dumps whole objects and has no safe delimiter (sacctmgr; scontrol job);
   - text for the other scontrol objects.
4. **Untruncated values:** `:0` widths for squeue; no width for sprio; `--parsable2` for sacct
   and sshare.
5. **Read-only, always.** No Slurm subcommand or flag that changes state (`update`, `create`,
   `delete`, `hold`, `release`, `requeue`, `cancel`, `reconfigure`, …). Compare
   `MUTATING_TOKENS` in `../slurmview-core/src/slurmview_core/commands/catalog.py`.
6. **Validate every dynamic value before it reaches an argv:** the cluster name
   (`^[A-Za-z0-9_.-]{1,64}$`), the sacct `SINCE` (fixed forms only), the object or entity names.
   Commands are bash arrays, never strings.
7. **Shared code lives in `snapshot-lib.sh`.** It defines functions only, sets no shell options,
   and touches no variables of the caller; helpers print results rather than set globals. Every
   script writes its file through `write_snapshot`.
8. **No `timeout` or byte caps** in the scripts. The systemd unit's `TimeoutStartSec=` bounds a
   run. With a broken Slurm configuration, scontrol retries for up to 60 s, and the cluster-name
   lookup retries again, so allow more than 2 minutes.
9. **Strict mode:** `set -euo pipefail` as the first command after the header comment of every
   executed script. Never put it in the sourced `snapshot-lib.sh`. Scripts must be shellcheck-clean.
10. **Target:** bash 4.3+ on Linux login nodes (GNU coreutils, gawk or mawk). Development
    happens on macOS, so don't rely on macOS behaviour; test in Docker (§7).

## 6. Adding or changing a snapshot script

1. **Design first:** write or update the matching doc in `snapshot-plans/`. Use the doc template
   there (what it replaces, stages, argv, layout, pitfalls, verify list, what downstream would
   use it for, cadence).
2. **Copy the shape of `squeue-snapshot.sh`:**
   - the header comment (usage, stages, file layout, a viewing command, needs, exit statuses);
   - `set -euo pipefail`, then `source snapshot-lib.sh`;
   - an explicit argument-count check that exits 2. Don't use `${1:?}`, which exits 1;
   - the four stages;
   - `captured=$(snapshot_stamp)` read once, the body in a `mktemp` file removed by `trap … EXIT`,
     and the command run between `set +e` and `set -e`;
   - `write_snapshot …`, then `exit "$status"`.
3. **Record new facts with their evidence:** mark a fact `VERIFIED docker` only after checking it
   in the test cluster, and `TO VERIFY` until then.
4. **Update the docs:** `README.md` (the parts table and the script's subsection) and
   `snapshot-plans/README.md` (index, hardcoded list, verified facts, still-to-verify). Update
   `README.md` whenever a script changes its usage, its argv, its file layout or its exit
   statuses, and update the matching `snapshot-plans/` doc in the same change.

### Known traps (each one has already bitten here)

- **`cmd | grep -q` under pipefail:** grep exits early, the command dies of SIGPIPE, and the
  pipeline reports failure even on a match. Read the output into a variable first.
- **`awk '… exit'` on piped input** triggers the same SIGPIPE. `cluster_name` reads to the end
  for this reason.
- **`${2:?msg}`** exits 1, not the documented usage status 2.
- **`sprio --weights` segfaults** when the format contains `%c` (26.05.5). The jobs call is fine,
  so the sprio snapshot has no `-w` call; the weights are in the config snapshot.
- **sacct rejects short time units** (`now-1d` is an "Invalid time specification").
  `sacct-snapshot.sh` rewrites them into whole words (`now-1days`).
- **sshare has no `--delimiter`** on 26.05.5. The script translates `|`, guarded by a field count.
- **sacct has no record terminator** option. The script adds 0x1e once a record holds every field,
  counted by its separators.
- **awk `split("")` returns 0, not 1.** So `split($0, a, fs) - 1` scores −1 for an empty line, and
  a blank line inside a `SubmitLine` made its sacct record swallow the start of the next one
  (found 2026-11-13 in the orcd bundle: 12 of 38,954 records; fixed with a guard, `if (n > 1)`).
  Any count derived from `split` or `NF` must treat an empty line as contributing nothing.
- **`grep -v '^#'` on a body drops data.** Body lines can start with `#` (19 `SubmitLine` lines in
  the same bundle). Strip only the metadata: `sed '1,/^# exit:/d'`.
- **sacct does not see** jobs that were never eligible (held), or `Comment` unless
  `AccountingStoreFlags=job_comment`. squeue covers both.

## 7. Testing

**Static:** run `shellcheck *.sh` in this directory. It must be clean.

**Live: the Docker test cluster.** It runs locally:
- image `slurm-docker-cluster:26.05.5`;
- containers `slurmctld`, `slurmdbd`, `slurmrestd`, `slurm-cpu-worker-1`, `slurm-cpu-worker-2`
  and `mysql`;
- cluster `linux`, partitions `cpu` (nodes `c1`, `c2`) and `gpu` (no nodes).

Run scripts **inside** the container, so the environment matches a login node:

```bash
docker cp /path/to/script-form slurmctld:/tmp/snap
docker exec slurmctld /tmp/snap/sprio-snapshot.sh /tmp/out
docker cp slurmctld:/tmp/out ./docker-out
docker exec slurmctld rm -rf /tmp/snap /tmp/out          # clean up afterwards
```

To test the driver, run it the same way and look inside the result. The only file left under
`/tmp/out` must be `YYYY/MM/DD/linux-<stamp>.tgz`:

```bash
docker exec slurmctld /tmp/snap/snapshot-bundle.sh /tmp/out
docker exec slurmctld find /tmp/out -type f
tar -tzf docker-out/2026/11/21/linux-<stamp>.tgz
tar -xzOf docker-out/2026/11/21/linux-<stamp>.tgz linux-<stamp>/manifest.txt
```

- **One-off queries:** `docker exec [-e SLURM_TIME_FORMAT=%s] slurmctld <command>`. The container
  has no `diff`: copy files out to compare them.
- **Failure paths:** put a small stub executable first on `PATH` inside the container, e.g. a
  `sprio` that kills itself with SIGSEGV for some formats, or an `sshare` that emits a value
  containing `|`. Then run the script with `PATH=/tmp/stub:$PATH`. Remove the stubs afterwards.
- **What needs the user's permission first:**
  - read-only queries and running the scripts: no permission needed;
  - **submitting test jobs:** ask first; cancel them afterwards, and note that they stay in
    accounting history;
  - **changing state beyond short jobs:** draining nodes, creating reservations, changing
    accounting limits or QOS, editing `slurm.conf`. Always ask first.
- **Limits of the test cluster:** one release, two CPU nodes, one user (`root`), all priority
  weights 0, no usage gathering. It shows behaviour and syntax, not scale.
- **The fake-slurm shims** in `../slurmview-core/scripts/fake-slurm/` replay only argvs recorded
  exactly. They cannot run these scripts.

**Replay a real bundle.** `../example-output-bundles/sq-20261113-test002.tgz` is one bundle run
on orcd (login006, Slurm 26.05.4), with about 39,000 sacct and 16,000 squeue records. Docker
never produces the odd values a real cluster does (blank lines and `#` lines in `SubmitLine`,
very long values), so **any change to how a script processes a body** (the sacct awk pass, the
sshare `|` translation, the join of a header row) must be replayed against this bundle as well
as run in Docker. Treat it as untrusted data: stream it, don't extract it next to the scripts:

```bash
tar -xzOf ../example-output-bundles/sq-20261113-test002.tgz sq-20261113-test002/sacct-20261114T021838Z.txt.gz \
| gzip -dc | sed '1,/^# exit:/d' | tr -d '\n' | tr '\036' '\n' | awk -F $'\t\037' 'NF != 123'
```

prints the records whose field count is wrong (none, once re-split as `snapshot-plans/C11` §6
shows; 12 in the file as captured before the 2026-11-13 fix).

**Real clusters:** e.g. orcd-login, Slurm 26.05.4. These are production systems. **Do not connect
to them or run anything there yourself.** The user runs the scripts there and reports back. Items
that can only be checked there are listed under "Still to verify" in `snapshot-plans/README.md`.

### What a reviewer checks

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

The fake-slurm shims cannot replay these argvs, so run the scripts in the Docker test cluster.

## 8. Where to look for more

- `snapshot-plans/README.md`: design rules, file layout, text parse rule, helpers, cadence, test
  cluster, verified facts, open items.
- `snapshot-plans/C*.md`, `snapshot-plans/sshare-fairshare.md`: the per-command reasoning (why
  each argv, body kind and flag), with VERIFIED and TO VERIFY markers.
- `../slurmview-core/docs/slurm-commands/`: detailed, background-only notes on each Slurm
  command's output, from the downstream project. Read them; don't edit them from here.
