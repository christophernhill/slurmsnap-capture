# C10 `scontrol show config` → `scontrol-snapshot.sh OUT_DIR config`

The script is defined in [C03](C03-scontrol-show-node.md#2-the-script-scontrol-snapshotsh-out_dir-object).

## 1. What capture-raw.sh does today

```bash
run_cmd C10 10 $(( 2 * MIB )) - - scontrol show config
CLUSTER="$(awk -F' *= *' '$1=="ClusterName"{print $2; exit}' "$LAST_STDOUT" || true)"
```

The command is bulk and text. capture-raw uses it only for the cluster name, which it feeds into
C12. The `PriorityWeight*` and other scheduler settings in it are captured but never read.

## 2. Counterpart

**Implemented:** [`../scontrol-snapshot.sh`](../scontrol-snapshot.sh) (2026-11-12):
shellcheck-clean and run end-to-end inside the Docker `slurmctld` container.

```
scontrol-snapshot.sh OUT_DIR config
```

This writes `OUT_DIR/scontrol-config-<UTC stamp>.txt.gz`. The cluster name for every snapshot's
`# cluster:` line comes from the shared `cluster_name` helper, which runs the same command. That
helper uses awk **without** `exit`; with `exit` it would get SIGPIPE (status 141) under pipefail.

## 3. Stages

1. **Discover:** nothing to ask. The command prints every setting.
2. **Build:** `scontrol show config`. `--all` is not meaningful here.
3. **Run once:** under `SLURM_TIME_FORMAT=%s`.
4. **Write:** `# format: text`, then the body unchanged.

`scontrol --json show config` exists on 26.05.5 (it returns `slurm_conf`; core's C10 doc §9).
It is not used here: text is version-independent and already one setting per line.

## 4. File layout

The body is unchanged, VERIFIED docker:

```
Configuration data as of 1794533299
AccountingStorageBackupHost = (null)
AccountingStorageEnforce = none
…
PriorityWeightAge       = 0
PrioritySiteFactorParameters = (null)
…
WaitTime                = 0 sec

Slurmctld(primary) at slurmctld is UP
```

This body is **one object**; the text parse rule's blank-line split does not apply. Downstream
reads it as follows:
- **Settings:** a line matching `^(\S+)\s*=\s?(.*)$` is a setting. Split at the **first** `=`.
- **Values with spaces or `=`:** values may contain spaces (`WaitTime = 0 sec`) and `=`
  (`SchedulerParameters = bf_window=…,bf_continue`).
- **Padding:** keys are padded to 23 characters; longer keys get a single space.
- **Other lines** have no `=`. They are:
  - the `Configuration data as of <epoch>` line;
  - the blank line;
  - the `Slurmctld(primary|backup) at <host> is UP|DOWN` trailer;
  - plugin section headings ending in `:`, if any. Docker 26.05.5 has none; TO VERIFY on orcd,
    where sites with cgroup or MPI plugins may print `Cgroup Support Configuration:` blocks.
    Keys after a heading belong to that section.

## 5. Pitfalls

- **Unset values** look like `(null)`, `none`, `NONE`, `N/A` or empty (`PriorityFlags = `).
- **Durations** have mixed forms: `7-00:00:00`, `00:05:00`, `300 sec`.
- **The controller must be up.** The trailer reports its state.

## 6. Verify

- `docker exec -e SLURM_TIME_FORMAT=%s slurmctld scontrol show config`: layout, the epoch first
  line, the trailer (VERIFIED).
- On orcd: `scontrol show config | grep -vE '=' ` lists every non-setting line, including section
  headings if any.

## 7. What downstream uses it for

| Settings | Explains |
|---|---|
| `PriorityType` (`priority/multifactor` VERIFIED docker), `PriorityFlags`, `PriorityParameters` | Whether sprio factors apply at all, and Fair Tree vs. classic (`NO_FAIR_TREE`) |
| `PriorityWeightAge/Assoc/FairShare/JobSize/Partition/QOS/TRES` | The weights. They are **the** weights source for the [sprio snapshot](C14-C16-sprio.md), which has no `-w` call (`sprio --weights` segfaults on `%c`, 26.05.5). `sprio -w` shows `SITE` as 1 with no setting |
| `PriorityMaxAge`, `PriorityFavorSmall`, `PriorityDecayHalfLife`, `PriorityUsageResetPeriod`, `PriorityCalcPeriod`, `FairShareDampeningFactor` | How the age, job-size and fair-share factors are computed |
| `SchedulerType`, `SchedulerParameters` (`bf_*`) | Why a job is not considered: the backfill window, depth, `bf_max_job_user`, … |
| `SelectType`, `SelectTypeParameters` | CPU/memory as consumable resources |
| `AccountingStorageEnforce` | Whether association and QOS limits are enforced (`none` means they are not) |
| `PreemptType`, `PreemptMode` | Preemption |
| `EnforcePartLimits` | Partition limits at submission |
| `MinJobAge` | How long finished jobs remain in squeue and C07 |
| `PrivateData` | What a non-admin snapshot can see |
| `ClusterName`, `SLURM_VERSION` | Identity |

## 8. Cadence

Hourly. Downstream diffs consecutive files to spot configuration changes.
