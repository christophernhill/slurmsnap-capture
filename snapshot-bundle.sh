#!/usr/bin/env bash
# snapshot-bundle.sh: one snapshot cycle, every snapshot script once, packed into one tarball.
#
#   scripts/snapshot-bundle.sh ROOT_DIR [SINCE]   -> ROOT_DIR/YYYY/MM/DD/<cluster>-<UTC time>.tgz
#
# This is the unattended form of command-list: it runs the eleven snapshot calls that make one
# bundle, in that order, into a directory of its own, then tars and gzips the directory. It is
# meant to be the ExecStart of a systemd oneshot service fired by a timer: systemd/system/ for a
# root-installed service account, systemd/user/ for an ordinary account's `systemctl --user`.
#
# Stages: discover (the UTC stamp, read once, and the cluster name), build (the bundle name and
# the day directory from that stamp), run once (each snapshot script, one after another; a step
# that fails does not stop the cycle, since the other files are still worth having and each file
# carries its own "# exit:"), write (tar the directory into <name>.tgz.tmp, rename, remove the
# directory). The step list is hardcoded: no runtime option, because which snapshots make a
# bundle is a design decision (snapshot-plans/README.md, "Cadence"), not something Slurm can list.
#
# Layout: ROOT_DIR/2026/11/21/eofe7-20261121T141500Z.tgz. Year, month and day are UTC, like
# the stamps in the file names, so the hierarchy and the files never disagree across midnight,
# and `ls` sorts it in time order. The tarball holds one directory, <name>/, with the eleven
# <source>-<stamp>.txt.gz files and a manifest.txt (the "# key: value" lines below, then one
# TAB-separated line per step: step, exit status, seconds, file). Downstream readers that take
# a bundle directory or tarball read it as it is; they skip manifest.txt by name. To look at one
# (NAME is the tarball's base name without .tgz):
#
#   tar -tzf NAME.tgz
#   tar -xzOf NAME.tgz NAME/manifest.txt
#
# When tar fails the directory stays in place, with no tarball next to it, so nothing is lost.
#
# Needs bash 4.3+, the *-snapshot.sh scripts and snapshot-lib.sh next to this file, the Slurm
# client commands they need, GNU tar, gzip, date, hostname. Read-only towards Slurm. Exits 0
# when every step and the tar succeeded, 1 when the tarball was written but a step failed, 3
# when the tarball could not be written, or 2 for a usage error.
# Under systemd: a oneshot service running this with ROOT_DIR, and a timer with
# OnCalendar=*:0/15. systemd never starts a oneshot that is still running, so cycles cannot
# overlap; the unit's TimeoutStartSec= bounds a cycle (see systemd/system/slurm-snapshot.service).
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=snapshot-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/snapshot-lib.sh"   # cluster_name, snapshot_stamp, show_command

usage='usage: snapshot-bundle.sh ROOT_DIR [SINCE=now-2hours]'
if (( $# < 1 || $# > 2 )); then printf '%s\n' "$usage" >&2; exit 2; fi
root_dir="$1"
since="${2:-now-2hours}"
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# 1. Discover: one clock reading for the whole cycle, and the cluster name. The name is checked
#    before it becomes part of a path (same regex as sacctmgr-snapshot.sh); without a valid one
#    the bundle is called snap-<stamp>.
started=$(snapshot_stamp)
cluster=$(cluster_name)
if [[ ! "$cluster" =~ ^[A-Za-z0-9_.-]{1,64}$ ]]; then cluster=snap; fi

# 2. Build: the bundle name and the day directory, both from the one stamp.
name="$cluster-${started//[-:]/}"
day_dir="$root_dir/${started:0:4}/${started:5:2}/${started:8:2}"
bundle_dir="$day_dir/$name"
manifest="$bundle_dir/manifest.txt"
tgz="$day_dir/$name.tgz"
mkdir -p "$bundle_dir"
trap 'rm -f "$tgz.tmp"' EXIT

{
  printf '# bundle: %s\n' "$name"
  printf '# started: %s\n' "$started"
  printf '# host: %s\n' "$(hostname -s)"
  printf '# cluster: %s\n' "$(cluster_name)"
  show_command "$(basename "$0")" "$@"
  printf '# steps: 11\n'
  printf '# columns: step\texit\tseconds\tfile\n'
} > "$manifest"

# 3. Run once: each snapshot script in command-list order. run_step LABEL WORD... runs WORD...
#    between set +e and set -e, and appends one manifest line: LABEL, the exit status, the
#    seconds it took, and the base name of the file it printed (or "-" when it printed none).
#    stderr passes through, so the journal shows what a failing step said.
failed=0
run_step() {
  local label="$1" path status file="-" t0=$SECONDS
  shift
  set +e
  path=$("$@")
  status=$?
  set -e
  if (( status != 0 )); then failed=$(( failed + 1 )); fi
  if [[ -n "$path" ]]; then file=$(basename "$path"); fi
  printf '%s\t%s\t%s\t%s\n' "$label" "$status" "$(( SECONDS - t0 ))" "$file" >> "$manifest"
}

run_step 'squeue-snapshot.sh'                "$here/squeue-snapshot.sh"   "$bundle_dir"
run_step 'scontrol-snapshot.sh job'          "$here/scontrol-snapshot.sh" "$bundle_dir" job
run_step 'sprio-snapshot.sh'                 "$here/sprio-snapshot.sh"    "$bundle_dir"
run_step 'sshare-snapshot.sh'                "$here/sshare-snapshot.sh"   "$bundle_dir"
run_step 'scontrol-snapshot.sh node'         "$here/scontrol-snapshot.sh" "$bundle_dir" node
run_step 'scontrol-snapshot.sh partition'    "$here/scontrol-snapshot.sh" "$bundle_dir" partition
run_step 'scontrol-snapshot.sh reservation'  "$here/scontrol-snapshot.sh" "$bundle_dir" reservation
run_step 'scontrol-snapshot.sh config'       "$here/scontrol-snapshot.sh" "$bundle_dir" config
run_step 'sacctmgr-snapshot.sh assoc'        "$here/sacctmgr-snapshot.sh" "$bundle_dir" assoc
run_step 'sacctmgr-snapshot.sh qos'          "$here/sacctmgr-snapshot.sh" "$bundle_dir" qos
run_step "sacct-snapshot.sh $since"          "$here/sacct-snapshot.sh"    "$bundle_dir" "$since"

status=0
if (( failed > 0 )); then status=1; fi
{
  printf '# finished: %s\n' "$(snapshot_stamp)"
  printf '# failed: %s\n' "$failed"
  printf '# exit: %s\n' "$status"
} >> "$manifest"

# 4. Write: tar the directory (members are <name>/<file>, as in the example bundle), gzip it
#    to .tmp and rename, so the tarball appears whole or not at all. Only then remove the
#    directory. If tar or gzip fails the directory stays and the exit status is 3.
set +e
tar -C "$day_dir" -cf - "$name" | gzip > "$tgz.tmp"
tar_status=$?
set -e
if (( tar_status != 0 )); then
  rm -f "$tgz.tmp"
  echo "snapshot-bundle.sh: could not write $tgz (status $tar_status); $bundle_dir kept" >&2
  exit 3
fi
mv "$tgz.tmp" "$tgz"
rm -rf "$bundle_dir"
printf '%s\n' "$tgz"
exit "$status"
