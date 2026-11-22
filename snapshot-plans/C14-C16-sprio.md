# C14, C15, C16 `sprio` → `sprio-snapshot.sh OUT_DIR`

One script with **one sprio call** covers C14 and C15. The C16 weights come from the
[config snapshot](C10-scontrol-show-config.md); §3 explains why.

## 1. What capture-raw.sh does today

```bash
run_cmd C16 15 $(( 4 * MIB )) - - sprio -w                       # weights, once
while IFS= read -r jid; do                                        # per PENDING job, ≤ 50
  run_cmd C14 15 $(( 4 * MIB )) "$jid" - sprio -j "$jid"          # weighted factors
  run_cmd C15 15 $(( 4 * MIB )) "$jid" - sprio -n -j "$jid"       # normalized factors
done < <(select_jobs PENDING id)
```

That is **up to 101 calls**, and they have three problems:
- **Whitespace-aligned tables.** In the `-w` row the `NICE` cell is blank and TRES prints
  `(null)`, so token positions break.
- **The column set changes:** only factors with a non-zero weight get a column, `SITE` is always
  present, and `-n` drops `SITE`.
- **Partial coverage:** only the first 50 pending jobs are seen.

## 2. Counterpart

**Implemented:** [`../sprio-snapshot.sh`](../sprio-snapshot.sh) (2026-11-12): shellcheck-clean
and run end-to-end inside the Docker `slurmctld` container with six eligible pending jobs
(including a multi-partition job and a nice job). The crash fallback was checked with a stub
`sprio` that segfaults on `%c`: it blanked `%c`, all 25 columns stayed aligned, and the script
exited 0.

```
sprio-snapshot.sh OUT_DIR
```

This writes `OUT_DIR/sprio-<UTC stamp>.txt.gz` (records), prints the path, and exits with sprio's
status.

## 3. Stages

1. **Discover.** `sprio --helpformat` lists every format letter. VERIFIED docker 26.05.5, 25
   letters:
   ```
   %a %A %b %B %c %f %F %i %j %J %n %N %o %p %P %r %S %q %Q %s %u %y %Y %t %T
   ```
   ```bash
   letters=$(sprio --helpformat | tr -s '[:space:]' '\n' | awk '/^%[A-Za-z]$/' | LC_ALL=C sort -f)
   ```
   - The case-insensitive sort keeps `%A`/`%a` adjacent, as squeue-snapshot.sh sorts its fields.
   - The list is never hardcoded: a release that adds letters (`%s` SLUID is new) gets them
     automatically.
2. **Build.** `-o` (`--format=`) takes every letter **with no width**: sprio's
   `%[[.]size]type[suffix]` uses "whatever is needed" when no size is given. The separators go in
   as suffixes:
   ```bash
   format=$(printf '%s\n' "$letters" | join_fields '' '' "$fs" "$rs")   # %A\t\x1f%a\t\x1f…%y\x1e
   header=$format                                                       # the specifiers are the column names
   ```
   - **Lowercase letters are normalized factors and uppercase are weighted.** One row carries
     both, so **one call replaces C14 and C15**.
   - Explicit letters also fix the column set, whatever the weights are.
3. **Run once:** `cmd=(sprio --format="$format")`. This covers every pending job, with sprio's own
   header line kept.
   - **sprio's titles become a `# names:` line, not column names.** The first output line is
     sprio's header in the same separators (VERIFIED docker), and its titles are ambiguous
     (VERIFIED: `AGE AGE ASSOC ASSOC CLUSTER FAIRSHARE FAIRSHARE JOBID …`). The script pairs each
     specifier with its title, e.g. `# names: %A=AGE %a=AGE %B=ASSOC … %c=CLUSTER …`, and drops
     the line from the body.
   - **No `-w` call: weights come from the config snapshot.**
     - VERIFIED docker 26.05.5: `sprio --weights --format=%c` crashes with **SIGSEGV (exit 139)**.
       The other 24 letters work with `--weights`.
     - A weights call would need a hardcoded exclusion or a crash fallback on every run.
     - The weights are controller configuration: `PriorityWeightAge/Assoc/FairShare/JobSize/Partition/QOS/TRES`,
       which the config snapshot already captures hourly.
     - TO VERIFY on orcd that they match `sprio -w`. sprio -w shows `SITE` as `1` even without a
       `PriorityWeightSite` setting (core C14 doc), so downstream treats the site weight as 1.
4. **Crash fallback** (rule 0: discover, don't hardcode).
   - **Not needed on docker:** `%c` is safe in the jobs call with no rows and **with rows**: it
     prints `(null)`, and every letter alone exits 0 (VERIFIED docker, 6 pending jobs). The
     fallback stays as protection for other releases, at no cost when nothing crashes.
   - **The fallback:** if sprio is killed by a signal (`status > 128`), the script works out the
     bad letters instead of excluding a hardcoded list:
     1. get one job id: `sprio --noheader --format=%i | head -n1`;
     2. probe each letter alone, `sprio --noheader --jobs=<id> --format=%X`. That is 25 cheap
        one-job calls, on the failure path only;
     3. rebuild the format with every letter whose probe died by a signal left as an **empty
        cell**, keeping its separator so columns still match the header;
     4. re-run once, add `# blanked: %c (empty columns: sprio was killed by signal 11 with them)`, print a warning to stderr,
        and exit with the re-run's status.
5. **Write.** `write_snapshot` with:
   - the extra lines `# separators: …`, `# records: one row per eligible pending job per partition`,
     `# names: …` and `# blanked: …` (only if used);
   - the body: the header row, then the job records.

## 4. File layout

```
# captured: …
# command:
#   sprio \
#     --format=$'%A\t\x1f%a\t\x1f%B\t\x1f%b\t\x1f%c\t\x1f%F\t\x1f%f\t\x1f%i\t\x1f%J\t\x1f%j\t\x1f'\
#     $'%N\t\x1f%n\t\x1f%o\t\x1f%P\t\x1f%p\t\x1f%Q\t\x1f%q\t\x1f%r\t\x1f%S\t\x1f%s\t\x1f%T\t\x1f'\
#     $'%t\t\x1f%u\t\x1f%Y\t\x1f%y\x1e'
# format: records
# separators: TAB+0x1f between fields, 0x1e then newline after each record
# records: one row per eligible pending job per partition
# names: %A=AGE %a=AGE %B=ASSOC %b=ASSOC %c=CLUSTER %F=FAIRSHARE … %Y=PRIORITY %y=PRIORITY
# exit: 0
%A␉␟%a␉␟%B…%y␞
16␉␟0␉␟0.0000000…␞
```

The `# command:` wrapping above is illustrative. `show_command` chooses the actual line breaks.

**Specifier meanings**, for downstream reference (core `C14-sprio.md` §4.3; titles VERIFIED
docker). The script does not use this table:

| | normalized | weighted | | |
|---|---|---|---|---|
| age | `%a` | `%A` | job id | `%i` |
| association | `%b` | `%B` | partition **name** | `%r` |
| fair-share | `%f` | `%F` | user / account / QOS name | `%u` / `%o` / `%n` |
| job size | `%j` | `%J` | nice | `%N` |
| partition factor | `%p` | `%P` | site | `%S` |
| QOS | `%q` | `%Q` | cluster | `%c` |
| TRES | `%t` | `%T` | SLUID | `%s` |
| **priority** | `%y` | `%Y` | | |

Downstream must match specifiers **case-sensitively**. squeue's field names are matched
case-insensitively; sprio's must not be.

## 5. Pitfalls

- **Missing rows are expected:**
  - **No row** means the job is not eligible: held, dependency, BeginTime, reservation-bound,
    array-throttled, or running. The reason is in the squeue snapshot.
  - With no eligible pending job at all, the body is the header row only (VERIFIED docker: job
    14 is held).
- **Multi-partition jobs** have one row per partition. The key is (`%i`, `%r`).
- **Arithmetic:** `%Y` ≈ the sum of the weighted factors − nice, with a floor of 1. `%N` is signed
  (core Q36).
- **Policy:**
  - Needs `PriorityType=priority/multifactor` (VERIFIED docker).
  - `PrivateData=jobs` may limit a non-admin to their own jobs (TO VERIFY on orcd as the timer's
    user).

## 6. Verify

- **On docker:**
  - `docker exec slurmctld sprio --helpformat` (VERIFIED, 25 letters).
  - `docker exec slurmctld sprio -o $'%i\t\x1f%r\t\x1f%Y\x1e' | od -c`: the suffixes appear in the
    header (VERIFIED).
  - `for l in …; do docker exec slurmctld sprio --noheader --weights --format=%$l; done`
    (VERIFIED: only `%c` exits 139).
- **`%c` with rows: VERIFIED docker.** With both nodes filled
  (`sbatch -N2 --exclusive --wrap='sleep 900'`) and six jobs pending,
  `sprio --noheader --format='%i %c'` printed `(null)` per row and exited 0, and so did every
  letter alone. The multi-partition job gave two rows (`cpu`, `gpu`) and the nice job `%N` = 50.
- **Cells are unpadded: VERIFIED docker** (e.g. `0`, `0.0000000`, `normal`, `cpu`).
- **Long names in full: TO VERIFY on orcd.** Docker has only the user `root`. Run
  `sprio --noheader --format='%i %u %o %r %Y' | awk 'length($2) > 8' | head`.
- **Weights:** on orcd, compare `sprio -w` with `scontrol show config | grep ^PriorityWeight`.
- **Coverage:** on orcd, check that `sprio --noheader --format='%i %r' | wc -l` matches the
  eligible pending job × partition pairs in squeue.

## 7. What downstream uses it for

**The core question: why does job X rank above job Y?**
- For every pending job, each factor's normalized value × weight (weights from config) = its
  contribution, also shown directly as the weighted letter. Join to the squeue snapshot on `%i`
  to rank competitors by `PriorityLong`.
- **Context files:** fair-share contributions come with [sshare](sshare-fairshare.md) context,
  and QOS contributions with [QOS](C13-sacctmgr-qos.md) context.

## 8. Cadence

Every 5 min. The age and fair-share factors move every `PriorityCalcPeriod` (5 min by default).
