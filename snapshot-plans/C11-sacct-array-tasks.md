# C11 `sacct --jobs=<array>` (loop) → `sacct-snapshot.sh OUT_DIR [SINCE]`

## 1. What capture-raw.sh does today

```bash
while IFS= read -r aid; do                                  # per distinct array job id, ≤ 50
  run_cmd C11 20 $(( 8 * MIB )) "$aid" - sacct "--jobs=${aid}" --array --allocations --allusers \
    --local --noheader --parsable2 --format=JobID,State,ExitCode,ElapsedRaw,NodeList
done < <(… awk '$3 != "N/A" …' )
```

This is **one slurmdbd query per array**, with problems on every axis:
- **Fields:** five hardcoded.
- **Separator:** `|`, which a value can contain.
- **Rows:** `--allocations` drops step rows.
- **Coverage:** arrays past the 50th are missing.

## 2. Counterpart: one query for a time window

**Implemented:** [`../sacct-snapshot.sh`](../sacct-snapshot.sh) (2026-11-12): shellcheck-clean
and run end-to-end inside the Docker `slurmctld` container with test jobs queued: every record
had 123 fields, pending array tasks were expanded (`43_1`–`43_3`) and the step row `40.batch`
was kept. A stub `sacct` that cut its last record short gave exit 3 and a `# warning:` line.

**Fixed 2026-11-13: a blank line inside a value ended its record late.** The downstream reader
found it in the orcd bundle `sq-20261113-test002` (login006, Slurm 26.05.4): the sacct file had
38,943 terminators and 12 records with the wrong field count, because the awk pass counted
separators as `split($0, parts, fs) - 1`, and `split("")` returns 0, so an empty physical line
scored −1. Re-splitting the same physical lines with the guarded count (step 4 below) gives
38,954 records of exactly 123 fields, under gawk and BSD awk alike. VERIFIED docker 26.05.5
with jobs 46 and 47 (`--comment` holding one and two blank lines, and a line starting with `#`):
the fixed script wrote 4 records of 123 fields for 4 sacct rows, and the old awk on the same raw
output wrote 2 records, both wrong. Files written before the fix need the downstream re-split.

```
sacct-snapshot.sh OUT_DIR [SINCE]
```

This writes `OUT_DIR/sacct-<UTC stamp>.txt.gz` (records).

**Bulk equivalent:** instead of asking per array, ask once for **every job and step active in a
window**:
- array tasks are rows whose `JobID` contains `_` (e.g. `13_4`);
- the same file also holds everything [seff](C17-seff.md) needs.

`SINCE` defaults to `now-2hours`. Accepted forms, each matched whole before it reaches the argv:

| Form | Example | Passed to sacct as |
|---|---|---|
| `now-N<unit>`: unit `s`, `m`, `h`, `d` or `w` in any case, or the word (`sec`, `min`, `hour`, `day`, `week`, with or without a trailing `s`); `m` means minutes; no unit means seconds | `now-1d`, `now-24H`, `now-90m`, `now-2w`, `now-3600` | `now-1days`, `now-24hours`, `now-90minutes`, `now-2weeks`, `now-3600seconds` |
| a date or date-time | `2026-11-10`, `2026-11-10T08:00[:00]`, `11/10`, `11/10/26` | unchanged |
| a keyword | `today`, `midnight` (any case) | lower-cased |

**Why rewrite:** sacct itself rejects the short units. VERIFIED docker 26.05.5:
- `sacct -S now-1d`, `now-24h`, `now-90min`, `now-2w` and `now-30s` all fail with
  `Invalid time specification` (exit 1);
- `now-1day`, `now-1days`, `now-24hours`, `now-90minutes`, `now-1weeks` and `now-3600` are
  accepted.

The script therefore takes the short forms people type and passes sacct the whole words.
- **Recording:** when it rewrites, `# window:` records both values, e.g.
  `# window: now-1days .. now (SINCE given as now-1d)`.
- **Rejection:** anything else (`now-1x`, `now+1d`, `yesterday`, `now-1d;id`) exits 2 before
  sacct runs.

The unit table is **hardcoded: no runtime option**. sacct cannot list the time forms it accepts.

## 3. Stages

1. **Discover.** `sacct --helpformat` lists the fields: 123 on docker 26.05.5 (VERIFIED). This is
   the same treatment as squeue:
   ```bash
   fields=$(sacct --helpformat | tr -s '[:space:]' '\n' | awk 'NF' | sort -f)
   n=$(printf '%s\n' "$fields" | wc -l)
   ```
2. **Build:**
   ```bash
   format=$(printf '%s\n' "$fields" | join_fields '' '' ',' '')        # JobID,JobIDRaw,…
   header=$(printf '%s\n' "$fields" | join_fields '' '' "$fs" "$rs")
   ```
   No widths are needed: `--parsable2` never truncates.
3. **Run once:**
   ```bash
   export SLURM_TIME_FORMAT=%s
   cmd=(sacct --allusers --array --local --noconvert --noheader --parsable2
        "--delimiter=$fs" "--starttime=$since" --endtime=now "--format=$format")
   ```
   | Flag | Why |
   |---|---|
   | `--delimiter=$'\t\x1f'` | The two-byte delimiter is honoured (VERIFIED docker, `od -c`) |
   | `--array` | Pending array tasks get one row each (core C11, 26.05.5) |
   | **no `--allocations`** | Keeps the step rows (`123.batch`, `123.extern`, `123.0`) that carry the CPU and memory usage |
   | `--noconvert` | No unit rescaling. Values keep their original suffix: `ReqMem=32043M` (VERIFIED docker) |
   | `--local` | Only this cluster's jobs, as C11 does |
   | `--allusers` | Every user (subject to `PrivateData`) |
   | `--starttime` / `--endtime` | Bound the slurmdbd query |
4. **Record terminator.** sacct ends records with a bare newline and has no option for a
   terminator. A value with a newline, such as `SubmitLine` or `Comment`, would split a record.
   - Write sacct's stdout to a temp file first, then run a streaming awk pass. It joins physical
     lines until a logical record holds `n − 1` separators, then emits it plus `\x1e`:
     ```awk
     { buf = (have ? buf "\n" : "") $0; have = 1
       k = split($0, parts, fs); if (k > 1) seen += k - 1 }
     seen >= n - 1 { printf "%s%s\n", buf, rs; buf = ""; have = 0; seen = 0 }
     END { if (have) { printf "%s%s\n", buf, rs; exit 3 } }
     ```
     `fs` contains no regex metacharacters, so `split` matches it literally.
   - **The guard matters.** `split("", parts, fs)` returns 0, not 1, so `split(...) - 1` scores
     −1 for an empty physical line, and a blank line inside a `SubmitLine` made the record
     demand one separator too many and swallow the start of the next record (see §2, fixed
     2026-11-13). An empty line, or any line without a separator, must add nothing.
   - **Limit:** counting separators cannot see a newline inside the *last* field of the sorted
     list (`WorkDir` on 26.05.5): its first line already completes the record, and the rest
     would open the next one. sacct has no terminator option, so this cannot be closed here;
     a path with a newline in it is the only way to hit it.
   - A trailing partial record still gets written, but awk exits 3. The script then exits non-zero.
   - The body is then identical in shape to squeue's.
5. **Write.** `write_snapshot` with the extra lines `# times:`, `# window: <SINCE> .. now` and the separators
   line. The body is the header row, then the records.

## 4. File layout

```
# captured: …
# command:
#   SLURM_TIME_FORMAT=%s sacct --allusers --array --local --noconvert --noheader --parsable2 \
#     --delimiter=$'\t\x1f' --starttime=now-2hours --endtime=now --format=Account,AdminComment,…
# format: records
# times: epoch seconds (SLURM_TIME_FORMAT=%s)
# separators: TAB+0x1f between fields, 0x1e then newline after each record
# window: now-2hours .. now
# exit: 0
Account␉␟AdminComment␉␟…␞
root␉␟␉␟…␞
```

## 5. Pitfalls

- **No ArrayJobID or ArrayTaskID fields.** sacct 26.05.5 lists neither (VERIFIED docker
  `--helpformat`). Array membership comes from `JobID` (`<array>_<task>`); `JobIDRaw` is the
  task's own numeric id.
- **Load:** the window decides how much slurmdbd works. On docker, all 123 fields average 513
  bytes per row. A busy cluster with 2 h of jobs and steps is tens of MB raw; gzip compresses it
  well. TO VERIFY on orcd: `time` one run with `now-2hours`.
- **Window semantics:** without `--state`, `-S`/`-E` select jobs that were pending or running at
  any time in the window, whenever they were submitted. VERIFIED docker: with `now-1minutes`,
  jobs pending for 5 minutes and a running job all appear. A **held** job that was never
  eligible (job 14) does not appear in sacct at all, even with `now-30days`. squeue has it.
- **Requeued jobs:** only the latest run appears, unless `--duplicates`, which is not used.
- **Accounting lag:** a job that ended seconds ago may lack its final usage. The next window
  overlaps and fixes it.
- **Overlapping windows:** downstream deduplicates by `JobID` (which includes the step suffix),
  keeping the newest snapshot.
- **Visibility:** `PrivateData=jobs` may limit a non-admin to their own jobs (TO VERIFY on orcd).
- **Units:** `TotalCPU` is a duration `[D-]HH:MM:SS[.mmm]` and `ElapsedRaw` is seconds.
  TRES strings carry units.
- **`Comment` is empty unless `AccountingStoreFlags` includes `job_comment`.** On docker it is
  `(null)`, so a job's `--comment` is not stored. `SubmitLine` is stored, and holds the
  `--comment=` text, newline included.
- **`SubmitLine` can hold anything a submit script holds:** blank lines (VERIFIED on the orcd
  bundle: 36 empty physical lines, 12 records affected before the 2026-11-13 fix) and lines
  that start with `#` (19 in the same file). So a body line starting with `#` is data, not
  metadata: strip only the lines up to and including `# exit:`, never every `#` line.

## 6. Verify

- `docker exec slurmctld sacct --helpformat` (VERIFIED, 123 fields).
- `docker exec slurmctld sacct --allusers --noheader --parsable2 --delimiter=$'\t\x1f' --starttime=now-30days --format=JobID,JobName,State -X | od -c | head`
  (VERIFIED: the two-byte delimiter appears).
- Embedded newline (VERIFIED docker): `sbatch -J "sv name with spaces" --comment=$'line1\nline2 x=y' --wrap=true`
  put a newline into `SubmitLine`. The body had 11 physical lines for 10 records (header
  included), and that record kept all 123 fields.
- Blank line inside a value (VERIFIED docker 2026-11-13, jobs 46 and 47):
  `sbatch -J sv-blank -p cpu --comment=$'line1\n\nline3' --wrap=true` and
  `--comment=$'# a comment line\n\n\nend'`. Run the script with `now-1hours`, then check that every
  record has 123 fields and that the two `SubmitLine` values keep their blank lines:
  ```bash
  gzip -dc FILE | sed '1,/^# exit:/d' | tr -d '\n' | tr '\036' '\n' | awk -F $'\t\037' 'NF != 123'
  ```
  must print nothing.
- Replay the orcd bundle offline, without connecting to orcd (expect `38954 0`):
  ```bash
  tar -xzOf ../../example-output-bundles/sq-20261113-test002.tgz sq-20261113-test002/sacct-20261114T021838Z.txt.gz \
  | gzip -dc | sed '1,/^# exit:/d' | tail -n +2 | tr -d '\036' \
  | awk -v fs=$'\t\x1f' -v rs=$'\x1e' -v want=122 '<the awk program from sacct-snapshot.sh>' \
  | tr -d '\n' | tr '\036' '\n' | awk -F $'\t\037' '{n++} NF != 123 {bad++} END {print n, bad + 0}'
  ```
  `tail -n +2` drops the old header row and `tr -d '\036'` the old terminators, leaving sacct's
  physical lines as it printed them.
- On orcd: time one run, and count the rows against `sacct … -X | wc -l`.

## 7. What downstream uses it for

- **Array progress** (C11's purpose): the state of every task of every array in the window.
- **Efficiency** ([C17](C17-seff.md)): CPU and memory use per job from the step rows.
- **Recent history:** jobs that left squeue (`MinJobAge`) before the next squeue snapshot.

## 8. Cadence

Hourly, with `SINCE=now-2hours`.
