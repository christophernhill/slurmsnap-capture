# C17 `seff <key>` (loop): no counterpart script

## 1. What capture-raw.sh does today

```bash
while IFS= read -r key; do                                  # per COMPLETED job, ≤ 50
  run_cmd C17 15 $(( 512 * 1024 )) "$key" - seff "$key"
done < <(select_jobs COMPLETED key)
```

seff is a contrib Perl script (`/usr/bin/seff`, in the `slurm-contribs` package). It takes **one
job per call** and runs one accounting lookup for each. It has no multi-job form. It exits 1, 2
or 3 for jobs it cannot report on, and prints human-formatted text (`CPU Efficiency: 12.34% of
01:00:00 core-walltime`).

capture-raw therefore makes up to 50 slurmdbd round trips and sees only completed jobs that are
still in squeue.

## 2. Counterpart: none, because it is derived from the sacct snapshot

seff's numbers are arithmetic on accounting fields that the
[sacct snapshot](C11-sacct-array-tasks.md) already holds for **every** job in its window,
including the step rows. Efficiency is therefore a **downstream reduction**, not a capture.

### seff's formula (read from `/usr/bin/seff` on docker 26.05.5)

| seff value | Perl (26.05.5) | sacct snapshot field(s) |
|---|---|---|
| cores `ncpus` | `alloc_cpus`, else the `cpu=` count in `tres_alloc_str`; 0 → 1 | `AllocCPUS` (job row), else `AllocTRES` `cpu=` |
| nodes `nnodes` | `alloc_nodes`, else the `node=` count in `tres_alloc_str`; 0 → 1 | `NNodes`, else `AllocTRES` `node=` |
| wall time | `elapsed` | `ElapsedRaw` (job row) |
| CPU used `cput` | **sum over steps** of `tot_cpu_sec` + `tot_cpu_usec` | the sum of `TotalCPU` over the job's step rows |
| memory used `mem` | **max over steps** of the `mem` in `tres_usage_in_tot` ("the sum of memory peaks of all tasks"), ÷ 1024 | the max over step rows of `TRESUsageInTot` `mem=` |
| memory allocated | the `mem` in `tres_alloc_str` | `AllocTRES` `mem=` (job row) |
| **CPU efficiency** | `cput / (walltime × ncpus) × 100` | |
| **Memory efficiency** | `mem / allocmem × 100` | |

**The formula changes between releases.** Older seff took memory from `MaxRSS`/`tres_usage_in_max`
and printed `(estimated maximum)` (core Q10). Before trusting the table, read the installed script
on each cluster (`less "$(command -v seff)"`, around the `foreach … steps` loop), and record which
variant applies.

## 3. What the reduction needs from the sacct snapshot

- **Step rows.** The snapshot runs **without** `--allocations` for this reason.
- **Units:**
  - `--noconvert`, so `mem=` values keep their original unit suffix and are not rescaled;
  - `TotalCPU` is `[D-]HH:MM:SS[.mmm]`, so convert it to seconds;
  - the `TRESUsageInTot` byte or unit form is TO VERIFY on a job with real usage (docker reports
    no usage: `MaxRSS` is empty).
- **States:** seff reports only finished jobs. Filter on `State`, and use `ExitCode` for its
  `State: COMPLETED (exit code 0)` line.

## 4. Pitfalls

- **No gathered usage:** with `JobAcctGatherType` unset, usage fields are empty or zero, and so
  are seff's numbers.
- **Accounting lag:** a job that just ended may lack final usage until the next sacct window.
- **Reused job ids:** these are ambiguous without `--duplicates` (core C17 doc). The snapshot's
  key is `JobID` within one window.

## 5. Verify

- **On docker:**
  - `docker exec slurmctld sed -n '60,200p' /usr/bin/seff` gives the formula (read 2026-11-12;
    the table above).
  - A cross-check is **not possible on docker**: `JobAcctGatherType = (null)` (VERIFIED), so no
    job has usage, `MaxRSS` and `TRESUsageInTot` are empty, and seff would print zeros.
- **On orcd:**
  - read the installed seff's step loop;
  - pick 3 completed jobs and compare `seff <id>` with the reduction over the sacct snapshot.
