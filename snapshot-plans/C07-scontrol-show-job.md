# C07 `scontrol show job <key>` (loop) → `scontrol-snapshot.sh OUT_DIR job`

The script is defined in [C03](C03-scontrol-show-node.md#2-the-script-scontrol-snapshotsh-out_dir-object).
This doc covers the job object, the one scontrol object that stays **JSON**.

## 1. What capture-raw.sh does today

```bash
while IFS= read -r key; do
  (( count < MAX_DETAILS )) || break
  run_cmd C07 15 $(( 4 * MIB )) "$key" - scontrol "--json=${P}" show job "$key"
done < <(select_jobs PENDING key)
```

This is **one call per pending job**, capped at 50. The cost is 50 round trips to slurmctld per
capture, and every pending job past the 50th is silently missing.

## 2. Counterpart: one call, every job

**Implemented:** [`../scontrol-snapshot.sh`](../scontrol-snapshot.sh) (2026-11-12):
shellcheck-clean and run end-to-end inside the Docker `slurmctld` container with test jobs
queued (running, pending, array, multi-partition).

```
scontrol-snapshot.sh OUT_DIR job
```

This runs `scontrol --all --json show job` once and writes
`OUT_DIR/scontrol-job-<UTC stamp>.txt.gz`.

- **Bulk form:** `show job` with **no id** returns every job slurmctld still holds: all states,
  within `MinJobAge`. `--all` adds jobs in hidden partitions. It is the same job-info RPC squeue
  uses, so it costs about as much as one squeue snapshot.

## 3. Why JSON here (VERIFIED docker, job 14)

| | text `scontrol --all show job` | `--json` |
|---|---|---|
| **Free text** | `JobName=` shares line 1 with `JobId=`. `SubmitLine=sbatch … --mem=100M --wrap=sleep 30` has spaces **and `=`** inside the value. `Command=`, `WorkDir=`, `StdOut=`, `Comment=` and `AdminComment=` can hold spaces | Every value is a JSON string |
| **Keys** | About 60, and some are composite (`ReqB:S:C:T=0:0:*:*`, `NtasksPerN:B:S:C=…`, `AllocNode:Sid=…`) | 137, including **`priority_by_partition`**, **`job_resources`** (per-node allocation), `gres_detail`, `state_description`, `state_reason`, `hold`, `nice`, `flags`, `submit_line`, `memory_per_cpu/node` |
| **Size** (compact) | smaller | 5.4 KB for one pending job |

The text form is harder to parse here, and it lacks the fields that make this snapshot worth
having on top of squeue. So the job object is JSON.

`-d` is left out. On docker it changes neither the key set nor `job_resources`, for a pending
job or for a running two-node job: 137 keys, and the same 2 `nodes.allocation` entries (VERIFIED
docker).

## 4. Stages

1. **Discover:** nothing to ask. JSON dumps every field and names each one.
2. **Build:** `scontrol --all --json show job`, under `SLURM_JSON=compact` (one line).
3. **Run once:** every job slurmctld holds.
4. **Write:** `# format: json`, then the body. The envelope's `meta.plugin.data_parser` names the
   parser ([C01](C01-scontrol-json-list.md)).

## 5. What it adds over the squeue snapshot

The squeue snapshot already has 119 fields per job (VERIFIED docker `squeue --helpFormat`). Read
this file for:

- **`priority_by_partition`:** the priority for each partition a multi-partition job could run in.
  squeue shows only one.
- **`job_resources`:** per-node CPU and memory allocation of running jobs.
- **`gres_detail`:** GPU indices per node.
- **`state_description`**, alongside `state_reason`; `hold`.
- **Structured fields:** `dependency`, `nice` and the memory request mode (`memory_per_cpu` vs
  `memory_per_node`; core analysis A4).

## 6. Pitfalls

- **Value wrappers:** numbers come wrapped as `{set, infinite, number}`. Check `infinite` before
  `set`, or UNLIMITED reads as unset (core `01-parsing-primitives.md`).
- **Sentinels:** a pending job with no estimate has `start_time` = submit + 365 days and
  `end_time` in year 2163 (core's C07 doc). These are sentinels, not estimates.
- **Pending arrays:** not-yet-split tasks appear as **one** placeholder record with
  `array_task_string` (e.g. `4-11%2`). Running and finished tasks have their own records. squeue
  `--array` expands the placeholder; this file does not.
- **Size:** about 5–6.5 KB per job, so 20k jobs ≈ 120 MB raw. gzip compresses JSON well. There is
  no byte cap; the systemd `TimeoutStartSec=` bounds the run.
- **Visibility:** `PrivateData=jobs` can hide other users' jobs. Run the timer as an operator or
  admin account (TO VERIFY on orcd).

## 7. Verify

On docker:
- `docker exec -e SLURM_JSON=compact slurmctld scontrol --all --json show job | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(len(d["jobs"]), d["meta"]["plugin"]["data_parser"])'`
  shows the job count and the parser.
- Compare that count with the squeue snapshot. They match when the pending arrays are collapsed
  (VERIFIED docker: 7 JSON records against 9 squeue rows, because array `43` is one record with
  `array_task_string` `1-3`).

On orcd:
- time one run: `time scontrol --all --json show job | wc -c`;
- check `-d` against no `-d` on a running multi-node job.

## 8. What downstream uses it for

- **Priority across partitions:** `priority_by_partition`.
- **What a running job holds** (core analysis A4), and so why others pend on `Resources`:
  `job_resources`.
- **Dependency chains:** `dependency`, `state_reason`.

## 9. Cadence

Every 5 min, on the same timer as squeue, so the two can be joined by capture time.
