# C04 `scontrol show partition` → `scontrol-snapshot.sh OUT_DIR partition`

The script is defined in [C03](C03-scontrol-show-node.md#2-the-script-scontrol-snapshotsh-out_dir-object).
This doc covers what differs for partitions.

## 1. What capture-raw.sh does today

```bash
run_cmd C04 15 $(( 8 * MIB )) - - scontrol "--json=${P}" show partition
```

The command is bulk, but JSON pinned to the negotiated parser, and skipped without one. It has no
`--all`, so hidden partitions may be missing (UNVERIFIED in core's C04 doc). The text form carries
the same partition data.

## 2. Counterpart

**Implemented:** [`../scontrol-snapshot.sh`](../scontrol-snapshot.sh) (2026-11-12):
shellcheck-clean and run end-to-end inside the Docker `slurmctld` container.

```
scontrol-snapshot.sh OUT_DIR partition
```

This writes `OUT_DIR/scontrol-partition-<UTC stamp>.txt.gz`.

## 3. Stages

1. **Discover:** nothing to ask. `show partition` prints every field.
2. **Build:** `scontrol --all show partition`. `--all` includes `Hidden=YES` partitions and
   partitions the caller cannot use. **These matter:** a pending job may name one.
3. **Run once:** every partition, under `SLURM_TIME_FORMAT=%s`.
4. **Write:** `# format: text`, then the body unchanged.

## 4. File layout

The body is unchanged, VERIFIED docker:

```
PartitionName=cpu
   AllowGroups=ALL AllowAccounts=ALL AllowQos=ALL
   AllocNodes=ALL Default=YES QoS=N/A
   DefaultTime=NONE DisableRootJobs=NO Exclusive=NO GraceTime=0 Hidden=NO
   MaxNodes=UNLIMITED MaxTime=UNLIMITED MinNodes=0 LLN=NO MaxCPUsPerNode=UNLIMITED MaxCPUsPerSocket=UNLIMITED
   NodeSets=cpu_nodes
   Nodes=c[1-2]
   PriorityJobFactor=1 PriorityTier=1 RootOnly=NO ReqResv=NO OverSubscribe=NO
   OverTimeLimit=NONE PreemptMode=OFF
   State=UP TotalCPUs=32 TotalNodes=2 SelectTypeParameters=NONE
   JobDefaults=(null)
   DefMemPerNode=UNLIMITED MaxMemPerNode=UNLIMITED
   TRES=cpu=32,mem=64086M,node=2,billing=32
```

- **Free-text keys:** none seen on docker. TO VERIFY on orcd: no partition value contains a space.
- **Optional lines:** some lines appear only when set, e.g. `TRESBillingWeights=`,
  `DenyAccounts=`, `DenyQos=` and `Alternate=`. A missing key means unset.

## 5. Pitfalls

- **Value forms:**
  - `MaxTime=UNLIMITED`, `DefaultTime=NONE` and `Nodes=(null)` are words.
  - Times are `[D-]HH:MM:SS` durations; `SLURM_TIME_FORMAT` does not affect durations.
  - `Nodes=c[1-2]` is a hostlist expression, so downstream must expand it.
- **`QoS=N/A`** means the partition has no partition QOS.
- **Lookup:** partition names are case-sensitive.

## 6. Verify

- `docker exec slurmctld scontrol --all show partition`: layout (VERIFIED).
- On orcd:
  - count partitions: `scontrol --all show partition | grep -c '^PartitionName='` against
    `scontrol show partition | grep -c '^PartitionName='`. A difference means hidden partitions
    exist, and confirms `--all` matters;
  - check for any value with a space: `scontrol --all show partition | grep -E '=[^ ]* [^ =]+( |$)'`
    as a rough screen.

## 7. What downstream uses it for

| Fields | Explains |
|---|---|
| `PriorityJobFactor` | The partition factor in sprio: job factor ÷ the maximum over partitions, × `PriorityWeightPartition` |
| `PriorityTier` | Tiers are scheduled before priority, so a lower-priority job in a higher tier runs first |
| `QoS` (partition QOS) | Partition-QOS limits (core analysis A5) |
| `AllowAccounts/Groups/Qos`, `Deny*` | `AccountNotAllowed`/`QOSNotAllowed` pending reasons |
| `MaxTime`, `MaxNodes`, `MaxCPUsPerNode`, `MaxMemPer*` | `PartitionTimeLimit`/`PartitionNodeLimit` pending reasons |
| `State` | A `DOWN`/`INACTIVE` partition means jobs pend with `PartitionDown`/`PartitionInactive` |
| `PreemptMode`, `OverSubscribe`, `TRES` | Partition capacity and behaviour |

## 8. Cadence

Hourly. Configuration changes rarely.
