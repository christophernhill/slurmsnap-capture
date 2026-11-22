#!/usr/bin/env bash
# sacctmgr-snapshot.sh: one sacctmgr snapshot (associations or QOS), gzipped into a dated file.
#
#   scripts/sacctmgr-snapshot.sh OUT_DIR assoc   -> OUT_DIR/sacctmgr-assoc-<UTC time>.txt.gz
#   scripts/sacctmgr-snapshot.sh OUT_DIR qos     -> OUT_DIR/sacctmgr-qos-<UTC time>.txt.gz
#
# Stages, as in squeue-snapshot.sh: discover, build, run once, write. sacctmgr cannot list its
# fields (it has no --helpformat) and has no --delimiter, so the snapshot is JSON: --json dumps
# every field of every record and names each key, so no field list is hardcoded and no value
# can shift a column. assoc is scoped to this cluster (cluster=<ClusterName>), and is never run
# unscoped: a slurmdbd that serves several clusters would return all their trees. QOS are not
# per-cluster. The ENTITY table below is the one hardcoded part. Design notes:
# snapshot-plans/C12-sacctmgr-assoc.md and C13-sacctmgr-qos.md.
#
# File layout: a few "# key: value" lines ("# format: json"), then one line of JSON
# (SLURM_JSON=compact). Its meta.plugin.data_parser names the parser that wrote it. To look at one:
#
#   gzip -dc FILE | sed '1,/^# exit:/d' | python3 -m json.tool | less
#
# Needs bash 4.3+, sacctmgr, scontrol (for the cluster name), gzip, date. Read-only. Exits with
# sacctmgr's exit status, 1 when assoc finds no valid cluster name, or 2 for a usage error.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=snapshot-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/snapshot-lib.sh"   # cluster_name, snapshot_stamp, write_snapshot

usage='usage: sacctmgr-snapshot.sh OUT_DIR assoc|qos'
if (( $# != 2 )); then printf '%s\n' "$usage" >&2; exit 2; fi
out_dir="$1"
entity="$2"

# 1. Discover: nothing to ask (see the header); JSON carries every field.
# 2. Build: the argv for ENTITY. The cluster name is checked before it reaches the argv.
case "$entity" in
  assoc)
    cluster=$(cluster_name)
    if [[ ! "$cluster" =~ ^[A-Za-z0-9_.-]{1,64}$ ]]; then
      echo "sacctmgr-snapshot.sh: no valid ClusterName from scontrol show config" >&2
      exit 1
    fi
    cmd=(sacctmgr --json show assoc "cluster=$cluster") ;;
  qos)
    cmd=(sacctmgr --json show qos) ;;
  *) printf '%s\n' "$usage" >&2; exit 2 ;;
esac
mkdir -p "$out_dir"

# 3. Run sacctmgr once: every record, one line of JSON. The command is an array so the header
#    below shows exactly what ran.
export SLURM_JSON=compact
captured=$(snapshot_stamp)
body=$(mktemp); trap 'rm -f "$body"' EXIT
set +e
"${cmd[@]}" > "$body"
status=$?
set -e

# 4. Write the file: metadata, then the JSON unchanged.
write_snapshot "$out_dir" "sacctmgr-$entity" "$captured" json "$status" "$body" "" \
  "SLURM_JSON=$SLURM_JSON" "${cmd[@]}"
exit "$status"
