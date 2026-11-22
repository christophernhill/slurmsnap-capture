# C12 `sacctmgr list assoc` → `sacctmgr-snapshot.sh OUT_DIR assoc`

This doc also defines **`sacctmgr-snapshot.sh`**, which C13 shares.

## 1. What capture-raw.sh does today

```bash
run_cmd C12 30 $(( 8 * MIB )) "$CLUSTER" - sacctmgr list assoc "Cluster=${CLUSTER}" \
  format=ID,ParentID,Cluster,Account,User,Partition,ParentName,GrpTRES,GrpTRESRunMins,GrpJobs,MaxJobs -p
```

This is bulk already, but it has two problems:
- **Eleven hardcoded fields.** `FairShare`, `QOS`, `DefaultQOS`, `MaxTRES`, `GrpTRESMins`,
  `MaxWall`, `MaxSubmit`, the priority and the rest are dropped. Core's C12 doc lists them as
  "unadopted extensions".
- **`|`-delimited text** with a trailing `|` and no escaping.

sacctmgr has **no field-list option** (no `--helpformat`) and **no `--delimiter`**, so the
squeue approach of discovering fields and choosing separators is not available.

## 2. Counterpart: JSON, every field

**Implemented:** [`../sacctmgr-snapshot.sh`](../sacctmgr-snapshot.sh) (2026-11-12):
shellcheck-clean and run end-to-end inside the Docker `slurmctld` container. The cluster-name
guard was checked with a stub `scontrol` that printed a bad name and then nothing: both gave
exit 1 before any argv was built.

```
sacctmgr-snapshot.sh OUT_DIR assoc
```

This runs `sacctmgr --json show assoc cluster=<name>` and writes
`OUT_DIR/sacctmgr-assoc-<UTC stamp>.txt.gz`.

JSON is how sacctmgr reports **every** field without a hardcoded list (rule 0): the envelope names
each key, so no column can shift.

### The script: `sacctmgr-snapshot.sh OUT_DIR ENTITY`

The ENTITY table is **hardcoded: no runtime option**. It is a design choice.

| ENTITY | argv | Scope |
|---|---|---|
| `assoc` | `sacctmgr --json show assoc cluster=<name>` | the local cluster |
| `qos` | `sacctmgr --json show qos` | all QOS (QOS are not cluster-scoped) |

```bash
#!/usr/bin/env bash
# sacctmgr-snapshot.sh: one sacctmgr JSON snapshot, gzipped into a dated file.
#   sacctmgr-snapshot.sh OUT_DIR assoc|qos
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/snapshot-lib.sh"
usage='usage: sacctmgr-snapshot.sh OUT_DIR assoc|qos'
if (( $# != 2 )); then printf '%s\n' "$usage" >&2; exit 2; fi
out_dir="$1"
entity="$2"
case "$entity" in
  assoc)
    cluster=$(cluster_name)
    # Never run unscoped: a multi-cluster slurmdbd would return every cluster's tree.
    [[ "$cluster" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] \
      || { echo "sacctmgr-snapshot.sh: no valid ClusterName from scontrol show config" >&2; exit 1; }
    cmd=(sacctmgr --json show assoc "cluster=$cluster") ;;
  qos) cmd=(sacctmgr --json show qos) ;;
  *) echo "sacctmgr-snapshot.sh: unknown entity '$entity'" >&2; exit 2 ;;
esac
mkdir -p "$out_dir"
# 1. Discover: nothing to ask. sacctmgr has no field list, so JSON (which dumps every field) is used.
# 2. Build: the argv above.  3. Run once.  4. Write.
export SLURM_JSON=compact
captured=$(snapshot_stamp)
body=$(mktemp); trap 'rm -f "$body"' EXIT
set +e; "${cmd[@]}" > "$body"; status=$?; set -e
write_snapshot "$out_dir" "sacctmgr-$entity" "$captured" json "$status" "$body" "" \
  "SLURM_JSON=$SLURM_JSON" "${cmd[@]}"
exit "$status"
```

## 3. Stages for `assoc`

1. **Discover:** nothing to ask; see above.
2. **Build:** `sacctmgr --json show assoc cluster=<ClusterName>`.
   - The `cluster=` filter **is honoured in JSON mode** (VERIFIED docker: `cluster=nosuch` gives
     `"associations": []`, exit 0).
   - A wrong name therefore gives an empty but successful snapshot. Downstream should treat zero
     associations as an error.
3. **Run once:** the whole association tree of the cluster.
4. **Write:** `# format: json`. The envelope's `meta.plugin.data_parser` is
   `data_parser/v0.0.45` on docker.

## 4. Fields (VERIFIED docker, v0.0.45 key paths)

`id`, `account`, `user`, `partition`, `cluster`, `parent_account`, **`lineage`**, `is_default`,
`shares_raw`, **`priority`**, `qos[]`, `default.qos`, `comment`, `flags[]`, plus the limits below.

The mapping to sacctmgr's text names is **expected, TO VERIFY**: set each limit on a docker test
association and diff the outputs. That changes the accounting configuration, so ask the user first.

| text name | JSON path |
|---|---|
| GrpTRES | `max.tres.total[]` |
| GrpTRESMins | `max.tres.group.minutes[]` |
| GrpTRESRunMins | `max.tres.group.active[]` |
| GrpJobs | `max.jobs.active` |
| GrpJobsAccrue | `max.jobs.accruing` |
| GrpSubmit | `max.jobs.total` |
| GrpWall | `max.per.account.wall_clock` |
| MaxJobs | `max.jobs.per.count` |
| MaxJobsAccrue | `max.jobs.per.accruing` |
| MaxSubmit | `max.jobs.per.submitted` |
| MaxWall | `max.jobs.per.wall_clock` |
| MaxTRES (per job) | `max.tres.per.job[]` |
| MaxTRESPerNode | `max.tres.per.node[]` |
| MaxTRESMins | `max.tres.minutes.per.job[]` |
| MinPrioThreshold | `min.priority_threshold` |

## 5. Pitfalls

- **Value wrappers:** numbers are `{set, infinite, number}`. Check `infinite` before `set`
  (core `01-parsing-primitives.md`). TRES limits are lists of `{type, name, id, count}`.
- **Tree structure:** the root association has no parent. User associations hang off their
  account; follow `parent_account`/`lineage`, not names.
- **Inherited limits:** a child may not repeat its parent's limits. Downstream walks the tree to
  compute effective limits.
- **Visibility:** `PrivateData=accounts,users` can hide ancestors from non-admins (TO VERIFY on
  orcd as the timer's user).
- **Shares, not usage:** `shares_raw` is the configured share. *Usage* and the fair-share factor
  come from slurmctld, so see [sshare](sshare-fairshare.md).
- **Old releases:** JSON needs `serializer/json`. On a release without it the snapshot fails
  (`# exit:` ≠ 0); no text fallback is planned.

## 6. Verify

- `docker exec -e SLURM_JSON=compact slurmctld sacctmgr --json show assoc cluster=linux | head -c 400`
  (VERIFIED: 2 associations, root and root/root).
- On orcd:
  - `sacctmgr --json show assoc cluster=$(scontrol show config | awk -F' *= *' '$1=="ClusterName"{print $2}') | wc -c`
    gives the size;
  - compare the count with `sacctmgr -n -P show assoc cluster=<name> format=ID | wc -l`.

## 7. What downstream uses it for

- **Association limits** (core analysis A4): `max.tres.total` (GrpTRES cpu/mem/gres),
  `max.tres.group.active` (GrpTRESRunMins), `max.jobs.*`. These explain the `AssocGrp*Limit` and
  `AssocMax*Limit` pending reasons.
- **The ASSOC priority factor:** `priority`, with `PriorityWeightAssoc`.
- **The fair-share tree:** `shares_raw` and `lineage`, joined with sshare usage.
- **Allowed QOS:** `qos[]` and `default.qos`, for `InvalidQOS`.

## 8. Cadence

Hourly.
