# `sshare` (new) → `sshare-snapshot.sh OUT_DIR`

This command is **not in capture-raw.sh**. It is added because sprio's FAIRSHARE factor (`%f`/`%F`)
says *how much* fair share contributes to a job's priority, but not *why* it differs between
users. sshare shows the cause: configured shares against decayed usage, all the way down the
account tree.

## 1. Today

Not captured. Core's tool never runs sshare (core `docs/slurm-commands/README.md`).

## 2. Counterpart

**Implemented:** [`../sshare-snapshot.sh`](../sshare-snapshot.sh) (2026-11-12): shellcheck-clean
and run end-to-end inside the Docker `slurmctld` container. Both delimiter branches were run.
The `|` translation is the real 26.05.5 path. The `--delimiter` branch used a stub `sshare`
whose `--help` offers it, and every record had 15 fields. The guard was checked with a stub that
added a value containing `|`: exit 3, and no file written.

```
sshare-snapshot.sh OUT_DIR
```

This writes `OUT_DIR/sshare-<UTC stamp>.txt.gz` (records). It is one call to slurmctld, which
holds the live usage.

## 3. Stages

1. **Discover.** `sshare --helpformat` lists the fields. VERIFIED docker 26.05.5, 15 fields, and
   VERIFIED orcd login006 (2026-11-13, the user's paste): the same 15:
   ```
   Account Cluster EffectvUsage FairShare GrpTRESMins GrpTRESRaw ID LevelFS NormShares
   NormUsage Partition RawShares RawUsage TRESRunMins User
   ```
   ```bash
   fields=$(sshare --helpformat | tr -s '[:space:]' '\n' | awk 'NF' | sort -f)
   ```
2. **Build:** `--format=` from that list (`join_fields '' '' ',' ''`), and a header row.
3. **Delimiter: probe at runtime** (rule 0). sshare has **no `--delimiter`**: `sshare --help`
   lists only `-p` and `-P` (VERIFIED docker 26.05.5; VERIFIED orcd login006 2026-11-13, from
   `sshare --usage`, which prints the same text as `--help`). So the `|` translation below is the
   path orcd takes. A later release might add `--delimiter`, hence the probe.

   **Nothing else can set the separator** (read in the schedmd source, 25.05.4, and checked in
   Docker 26.05.5):
   - **`--format` takes only field names.** Each comma-separated token is `Name[%[-]N]`, where
     `Name` is a case-insensitive prefix of a field (`src/sshare/process.c:167-190`). Anything
     else is `Invalid field requested`, exit 1 (Docker: `--format=Account,XYZ,User` and
     `--format='Account;User'`). Unlike squeue's `--Format`, there is no suffix, so no separator
     can go into the format.
   - **The `|` is fixed.** `src/common/print_fields.c` prints `|` in parsable mode unless
     `fields_delimiter` is set, and only sacct (`src/sacct/options.c`) sets it. sshare has no
     option and no environment variable for it.
   - **Widths don't help.** `%N` (right-aligned) and `%-N` (left-aligned) apply only without
     `-p`/`-P` (`print_fields.c:136-176`). That layout pads every column with spaces, one space
     between columns. It has three problems:
     - a value longer than its width is cut and its last character becomes `+` (Docker:
       `cpu=0,mem=0,en+`), which looks the same as a real value ending in `+`;
     - right-aligned padding hides the Account indentation: `root` and ` root` both print as
       `        root` under `Account%12`;
     - the widths would have to be known before the call.
   - **`-P` ignores widths** and prints every value whole, so it is the one untruncated text form.
   ```bash
   help=$(sshare --help 2>&1 || true)   # read whole: "| grep -q" stops early, and under
                                        # pipefail sshare's SIGPIPE would read as "no match"
   cmd=(sshare --all --noheader --parsable2)
   if [[ "$help" == *--delimiter* ]]; then cmd+=("--delimiter=$fs"); delim=$fs; else delim='|'; fi
   cmd+=("--format=$format")
   ```
4. **Run once:** `--all` covers every user and account. Then:
   - **if `delim` is `|`**, run an awk pass over the temp file:
     - every line must have exactly `n − 1` `|` characters. If not, a value contains `|`, which
       makes the record ambiguous;
     - on a mismatch, **write nothing**, print the offending line number to stderr, and
       **exit 3**, suggesting `sshare --json` as the fix;
     - otherwise, replace each `|` with `$fs` and append `$rs`;
     - account, user, partition and TRES strings have never been seen to contain `|`, so the
       guard should never fire. It exists so that a bad record cannot pass silently.
   - **if `--delimiter` was used**, the same awk pass runs with `delim=$fs`: it checks the field
     count, then appends `$rs` (newlines in these fields are not possible).
5. **Write.** `write_snapshot` with the separators line and, when translated,
   `# translated: sshare --parsable2 prints '|'; this script turned it into TAB+0x1f`. The body is the header row, then the records.

## 4. File layout

The `-P` output before translation, VERIFIED docker (`Account,User,RawShares,FairShare,LevelFS`):

```
root||||
 root|root|1|1.000000|1.000000
```

- **Indentation is the tree.** Leading spaces in `Account` give the depth (` root` is one level
  below `root`). Keep them; downstream computes depth = number of leading spaces, then trims.
- **Row types:** rows with an empty `User` are account rows; rows with a `User` are user
  associations under that account.

## 5. Pitfalls

- **Fair Tree vs. classic:** with Fair Tree (the default unless `PriorityFlags` has
  `NO_FAIR_TREE`), `LevelFS` and the tree's ordering decide `FairShare`. With classic fair share,
  `FairShare` comes from `NormShares` and `EffectvUsage`. Downstream needs `PriorityFlags` from
  the [config snapshot](C10-scontrol-show-config.md).
- **Decay:** `RawUsage` decays with `PriorityDecayHalfLife` and resets per
  `PriorityUsageResetPeriod`, so snapshots taken minutes apart differ. That is expected.
- **`-l` and `-m`:** not used. VERIFIED docker 26.05.5: with every field in `--format`, the
  `-a -P -n` output is byte-identical with and without `-l`, and with and without `-m`. Both only
  change the default field list: `-l` adds the normalized-usage columns and `-m` adds
  `Partition`. The `Partition` column is filled only for partition-specific associations, and
  Docker has none. TO VERIFY on orcd, if it has any: `-m` changes no rows.
- **Why not `--json`** (decided 2026-11-13). `sshare --all --json` (Docker, `data_parser/v0.0.45`)
  would avoid the `|` translation entirely, and it carries more:
  - each row's `parent` and `type` (`USER`/`ASSOCIATION`), plus `total_shares`;
  - floats at full precision, where the text rounds to 6 decimals (root's NormShares is 2.3e-10
    but prints `0.000000`).

  The records body stays anyway:
  - it follows rule 3 (sshare has a format language and a field list);
  - JSON is about 12x larger than `-P` before gzip, at a 5-minute cadence;
  - RawShares and RawUsage print as whole integers, so downstream can recompute the rounded
    ratios;
  - the tree is still recoverable: rows come in tree order, and the Account indentation gives
    the depth, so a row's parent is the nearest earlier account row one level up.

  If the `|` guard ever fires, `--json` is the fix to reach for.
- **`GrpTRESRaw` and `TRESRunMins`** are long TRES strings.
- **Visibility:** `PrivateData=usage` may limit a non-admin to their own rows (TO VERIFY on orcd
  as the timer's user).

## 6. Verify

- **On docker:**
  - `docker exec slurmctld sshare --helpformat` (VERIFIED);
  - `docker exec slurmctld sshare --help | grep -- --delimiter` (VERIFIED: absent);
  - `docker exec slurmctld sshare -a -P --noheader --format=Account,User,RawShares,FairShare,LevelFS | sed -n l`
    (VERIFIED: indentation kept, no trailing `|`);
  - the same call with every field, with and without `-l`, and with and without `-m`, compared
    with `cmp` (VERIFIED 2026-11-13: identical);
  - `docker exec slurmctld sshare -a -n --format=Account,XYZ,User` (VERIFIED: `Invalid field
    requested`, exit 1);
  - `docker exec slurmctld sshare -a --format=Account%-12,GrpTRESRaw%15 | sed -n l` (VERIFIED:
    padded, the long value cut to `cpu=0,mem=0,en+`). With `-P`, the widths are ignored.
- **On orcd:**
  - `sshare --help` has no `--delimiter`, and `--helpformat` lists the same 15 fields (VERIFIED
    orcd login006, 2026-11-13);
  - count rows: `sshare -a -P -n --format=Account | wc -l`;
  - check that no value contains `|`:
    `sshare -a -P -n --format=$(sshare --helpformat | tr -s ' \n' ',' | sed 's/,$//') | awk -F'|' '{print NF}' | sort -u`
    should print one number.

## 7. What downstream uses it for

**Why fair share differs between users:**
- For each user association, compare `NormShares` (entitlement) with `EffectvUsage` (decayed
  consumption).
- With Fair Tree, `LevelFS` at each level gives the order in which siblings rank.
- `FairShare` is the 0–1 factor that sprio's `%f` shows, so the two files cross-check each other.

## 8. Cadence

Every 5 min, the same as sprio, because usage is recomputed every `PriorityCalcPeriod`.
