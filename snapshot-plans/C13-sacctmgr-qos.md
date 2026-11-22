# C13 `sacctmgr show qos` → `sacctmgr-snapshot.sh OUT_DIR qos`

The script is defined in [C12](C12-sacctmgr-assoc.md#the-script-sacctmgr-snapshotsh-out_dir-entity).

## 1. What capture-raw.sh does today

```bash
run_cmd C13 30 $(( 8 * MIB )) - - sacctmgr -n -P show qos \
  format=Name,Priority,GrpCPUs,GrpMem,GrpNodes,GrpJobs,GrpTRES,GrpTRESRunMins,MaxTRESPU,MaxJobsPU,LimitFactor,UsageFactor,Flags
```

This is bulk, but it has two problems:
- **Thirteen hardcoded fields**, three of them legacy (`GrpCPUs`, `GrpMem`, `GrpNodes`).
  `MaxWall`, `MaxTRESPerJob`, `MaxTRESPA`, `MaxSubmitPU`, `Preempt`, `GraceTime` and others are
  dropped.
- **`|` text.** On top of that, an unknown field name makes sacctmgr fail the whole run (exit 1,
  core's C13 doc), so a hardcoded list is also fragile across releases.

## 2. Counterpart

**Implemented:** [`../sacctmgr-snapshot.sh`](../sacctmgr-snapshot.sh) (2026-11-12):
shellcheck-clean and run end-to-end inside the Docker `slurmctld` container.

```
sacctmgr-snapshot.sh OUT_DIR qos
```

This runs `sacctmgr --json show qos` and writes `OUT_DIR/sacctmgr-qos-<UTC stamp>.txt.gz`.
As for C12, JSON is how sacctmgr reports every field without a hardcoded list.

## 3. Stages

1. **Discover:** nothing to ask (see C12).
2. **Build:** `sacctmgr --json show qos`. There is no cluster filter, because QOS are global to
   slurmdbd.
3. **Run once:** every QOS.
4. **Write:** `# format: json`.

## 4. Fields (VERIFIED docker, v0.0.45 key paths)

`id`, `name`, `description`, **`priority`**, `flags[]`, **`usage_factor`**, `usage_threshold`,
`preempt.list[]`, `preempt.mode[]`, `preempt.exempt_time`, plus the limits below.

The mapping to text names is **expected, TO VERIFY**: set limits on a docker test QOS and diff.
That changes the accounting configuration, so ask the user first.

| text name | JSON path |
|---|---|
| LimitFactor | `limits.factor` |
| GraceTime | `limits.grace_time` |
| GrpTRES | `limits.max.tres.total[]` |
| GrpTRESMins | `limits.max.tres.minutes.total[]` |
| GrpTRESRunMins | `limits.max.tres.minutes.per.qos[]` |
| GrpJobs | `limits.max.active_jobs.count` |
| GrpJobsAccrue | `limits.max.active_jobs.accruing` |
| GrpSubmit | `limits.max.jobs.count` |
| GrpWall | `limits.max.wall_clock.per.qos` |
| MaxJobsPU | `limits.max.jobs.active_jobs.per.user` |
| MaxJobsPA | `limits.max.jobs.active_jobs.per.account` |
| MaxSubmitPU | `limits.max.jobs.per.user` |
| MaxSubmitPA | `limits.max.jobs.per.account` |
| MaxTRESPU | `limits.max.tres.per.user[]` |
| MaxTRESPA | `limits.max.tres.per.account[]` |
| MaxTRES (per job) | `limits.max.tres.per.job[]` |
| MaxTRESPerNode | `limits.max.tres.per.node[]` |
| MaxTRESMins | `limits.max.tres.minutes.per.job[]` |
| MaxTRESRunMinsPU | `limits.max.tres.minutes.per.user[]` |
| MaxTRESRunMinsPA | `limits.max.tres.minutes.per.account[]` |
| MaxWall | `limits.max.wall_clock.per.job` |
| MaxJobsAccruePU/PA | `limits.max.accruing.per.user` / `.per.account` |
| MinPrioThreshold | `limits.min.priority_threshold` |
| MinTRESPerJob | `limits.min.tres.per.job[]` |

## 5. Pitfalls

- **Value wrappers and TRES lists:** as in C12.
- **No legacy columns:** the legacy `GrpCPUs`/`GrpMem`/`GrpNodes` have no separate JSON keys;
  they live inside `limits.max.tres.total[]`.
- **Flag spelling:** `flags[]` are upper-case words (`RELATIVE`, `OVER_PART_QOS`, `DENY_LIMIT`,
  …). Spelling is TO VERIFY by setting flags on a docker test QOS, which needs the user's OK.
- **Default values:** `usage_factor` is `{set:true, number:1.0}` by default.

## 6. Verify

- `docker exec -e SLURM_JSON=compact slurmctld sacctmgr --json show qos` (VERIFIED: one QOS,
  `normal`, "Normal QOS default").
- On orcd:
  - `sacctmgr --json show qos | python3 -I -c 'import json,sys; print([q["name"] for q in json.load(sys.stdin)["qos"]])'`;
  - compare with `sacctmgr -n -P show qos format=Name`.

## 7. What downstream uses it for

- **The QOS priority factor:** `priority` ÷ the maximum `priority` over all QOS, ×
  `PriorityWeightQOS`. sprio's `%q`/`%Q` show the result, and this file shows why.
- **QOS limits** (core analysis A5): `limits.max.*`, with `flags` (`RELATIVE`, `OVER_PART_QOS`)
  and `limits.factor`. These explain the `QOSGrp*Limit`, `QOSMax*PerUser` and
  `QOSMaxJobsPerUserLimit` pending reasons.
- **Fair-share charging:** `usage_factor` scales how much usage a job charges.
- **Preemption:** `preempt.list` and `preempt.mode`.

## 8. Cadence

Hourly.
