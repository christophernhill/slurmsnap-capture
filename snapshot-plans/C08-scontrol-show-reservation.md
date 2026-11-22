# C08 `scontrol show reservation` → `scontrol-snapshot.sh OUT_DIR reservation`

This command is **not in capture-raw.sh**. Core's catalog has C08/C09 as per-name lookups, but
capture-raw never runs them. It is added because reservations explain the pending reasons that
nothing else in the capture explains.

The script is defined in [C03](C03-scontrol-show-node.md#2-the-script-scontrol-snapshotsh-out_dir-object).

## 1. Today

Not captured. Core's C08 (JSON) and C09 (text fallback) take one reservation name each.

## 2. Counterpart: every reservation in one call

**Implemented:** [`../scontrol-snapshot.sh`](../scontrol-snapshot.sh) (2026-11-12):
shellcheck-clean and run end-to-end inside the Docker `slurmctld` container. Only the empty case
could be checked, because creating a reservation was not approved.

```
scontrol-snapshot.sh OUT_DIR reservation
```

This runs `scontrol --all show reservation` (no name) and writes
`OUT_DIR/scontrol-reservation-<UTC stamp>.txt.gz`.

**Text, not JSON.** Text has `State=ACTIVE|INACTIVE`, which the JSON form lacks in every parser
version (core's C08 doc). Text also needs no data_parser.

## 3. Stages

1. **Discover:** nothing to ask.
2. **Build:** `scontrol --all show reservation`, under `SLURM_TIME_FORMAT=%s` so
   `StartTime`/`EndTime` are epoch seconds. In text these otherwise follow the client's `TZ`.
3. **Run once.**
4. **Write:** `# format: text`, then the body unchanged.

## 4. File layout

The first line of a reservation is `ReservationName=… StartTime=… EndTime=… Duration=…`, followed
by lines indented by 3 spaces (core's 02-version-compat.md, 26.05.5):

```
ReservationName=demo-calibration StartTime=1794… EndTime=1794… Duration=00:30:00
   Nodes=c2 NodeCnt=1 CoreCnt=16 Features=(null) PartitionName=(null) Flags=IGNORE_JOBS,SPEC_NODES
   TRES=cpu=16
   Users=root,ood Groups=(null) Accounts=(null) Licenses=(null) State=INACTIVE BurstBuffer=(null)
   MaxStartDelay=(null)
```

- **No reservations** gives `No reservations in the system` on stdout with exit 0 (VERIFIED
  docker). Downstream treats that body as zero objects.
- **Free-text key:** `Comment`, if the release prints it. TO VERIFY its placement: it should be
  alone on its line.

## 5. Pitfalls

- **Overnight changes:** `State` is the controller's view at capture time. A reservation that
  starts between snapshots is caught by comparing `StartTime` with `# captured`.
- **Hostlists:** `Nodes=` is a hostlist expression.
- **Duration:** `Duration` is `[D-]HH:MM:SS`.
- **Visibility:** `PrivateData=reservations` hides reservations from non-members (TO VERIFY on
  orcd as the timer's user).

## 6. Verify

- `docker exec slurmctld scontrol --all show reservation`: the empty case (VERIFIED).
- To see a real record on docker, create one:
  `scontrol create reservation starttime=now duration=10 nodes=c2 users=root flags=maint`.
  This **mutates the test cluster**, so ask the user first, and delete it afterwards. Then check
  the layout, the epoch times, and whether `Comment=` is alone on its line.
- On orcd: `scontrol --all show reservation | head -40`.

## 7. What downstream uses it for

- **Pending reasons:** `Reservation`, `ReqNodeNotAvail, Reserved for maintenance`, `ResvDeleted`.
- **Node availability:** the nodes inside an ACTIVE `MAINT` reservation, and which jobs may use a
  reservation (`Users=`, `Accounts=`). A job's own reservation is in the squeue `Reservation`
  field and C07's `resv_name`.

## 8. Cadence

Every 15–60 min.
