# C03 `scontrol show node` → `scontrol-snapshot.sh OUT_DIR node`

This doc also defines **`scontrol-snapshot.sh`**, the one script used by every scontrol doc
(C03, C04, C07, C08, C10).

## 1. What capture-raw.sh does today

```bash
run_cmd C03 25 $(( 64 * MIB )) - - scontrol "--json=${P}" show node
```

The command is already bulk (every node in one call). It is JSON pinned to the negotiated parser,
and it is skipped when negotiation fails. JSON adds nothing for nodes that the text form lacks: it
is the same RPC (`slurm_load_node`) printed differently, at roughly 2.5× the size. Core's C03 doc
measures 1.6–1.9 KiB per node in JSON. The docker text block for `c1` is 676 bytes.

## 2. The script: `scontrol-snapshot.sh OUT_DIR OBJECT`

Output: `OUT_DIR/scontrol-<OBJECT>-<UTC stamp>.txt.gz`. It prints the path and exits with
scontrol's status.

The OBJECT table is **hardcoded: no runtime option**. scontrol cannot list its `show` entities in
a machine-readable way, and the set is a design choice anyway.

| OBJECT | argv | Body |
|---|---|---|
| `node` | `scontrol --all show node` | text |
| `partition` | `scontrol --all show partition` | text |
| `reservation` | `scontrol --all show reservation` | text |
| `config` | `scontrol show config` | text |
| `job` | `scontrol --all --json show job` | json |

**Implemented:** [`../scontrol-snapshot.sh`](../scontrol-snapshot.sh) (2026-11-12). It is
shellcheck-clean and was run end-to-end inside the Docker `slurmctld` container for all five
objects. Its stages:

1. **Discover:** nothing to ask. `scontrol show` has no field selection and prints every field
   of every object.
2. **Build:** the argv from the table above. A wrong argument count or an unknown object prints
   the usage and exits 2.
3. **Run once:** under `SLURM_TIME_FORMAT=%s SLURM_JSON=compact`. `captured=$(snapshot_stamp)`
   is read once, and stdout goes to a `mktemp` file removed on exit.
4. **Write:** `write_snapshot "$out_dir" "scontrol-$object" "$captured" "$format" "$status" "$body" "" <env words> "${cmd[@]}"`,
   then `exit "$status"`.

Stderr goes to the journal, as in squeue-snapshot.sh. There is no `timeout`: the systemd unit's
`TimeoutStartSec=` bounds the run. With a broken Slurm configuration, scontrol retries for up to
60 s. `write_snapshot`'s `cluster_name` then retries again, so a failing run takes about 2 min
(VERIFIED docker with `SLURM_CONF=/nonexistent`: exit 1, and the file is still written with an
empty body, `# cluster:` and `# slurm:` empty, and `# exit: 1`). Set `TimeoutStartSec=` above that.

## 3. Stages for `node`

1. **Discover:** nothing (see the sketch).
2. **Build:** `scontrol --all show node`.
   - `--all` costs nothing. On docker, the node count is the same with and without it (2 and 2),
     but sites with hidden partitions may differ (TO VERIFY on orcd).
   - **`--future` is left out.** FUTURE nodes cannot run jobs.
   - **`-d`/`--details` is left out** until checked: does it add `GresUsed` index detail on GPU
     nodes? TO VERIFY on orcd, since docker has no GPUs.
3. **Run once:** every node.
4. **Write:** `# format: text`, then the body unchanged.

## 4. File layout

```
# captured: 2026-11-12T22:41:07Z
…
# command:
#   SLURM_TIME_FORMAT=%s SLURM_JSON=compact scontrol --all show node
# format: text
# exit: 0
NodeName=c1 Arch=aarch64 CoresPerSocket=16 
   CPUAlloc=0 CPUEfctv=16 CPUTot=16 CPULoad=0.31
   AvailableFeatures=cpu
   …
   OS=Linux 6.12.76-linuxkit #1 SMP Fri May 29 10:00:01 UTC 2026 
   …
   BootTime=1794038497 SlurmdStartTime=1793876717
   …

NodeName=c2 …
```

Downstream applies the [text parse rule](README.md#text-parse-rule). The free-text keys for nodes
are `OS` (VERIFIED docker: alone on its line), `Reason`, `Comment` and `Extra` (TO VERIFY: they
need a drained or commented node).

## Why not `-o`

`scontrol -o show node` puts each node on one line. It is compact, but every former line break
becomes a space. The orcd `dtn001` sample shows the problem:

```
… Version=26.05.4 OS=Linux 4.18.0-553.147.1.el8_10.x86_64 #1 SMP Fri Jul 24 18:01:18 UTC 2026  RealMemory=248000 …
```

- **Double spaces are not a boundary marker.** A double space appears only where the multi-line
  line ended in a trailing space (`CoresPerSocket=16  CPUAlloc`, `UTC 2026  RealMemory`).
  Elsewhere a line break becomes a single space: `CPULoad=0.31 AvailableFeatures=` is a line
  boundary in the docker output.
- **Free-text values can't be delimited.** `OS` is benign because its value rarely contains `=`.
  But `Reason=`, `Comment=` and `Extra=` are admin-written free text, and can contain
  `x=y` fragments, e.g. `Reason=set State=DOWN for PSU swap [root@1794…]`. On one line, a parser
  must guess where they end.
- **The multi-line form avoids both problems** and costs about 3 bytes per line (the indent),
  roughly 5% raw and almost nothing after gzip.

## 5. Pitfalls

- Values like `CPULoad=N/A`, `Gres=(null)`, `AllocTRES=` (empty), `ResumeAfterTime=None` and
  `SuspendTime=INFINITE` are words, not numbers.
- `State=IDLE+DYNAMIC_NORM`: split the flags on `+`.
- `CfgTRES=…,mem=32043M` and `AllocTRES=…,mem=42.50G` carry unit suffixes. `RealMemory`,
  `AllocMem` and `FreeMem` are plain MB.
- With `PrivateData=nodes`, non-admins may see less (TO VERIFY on orcd as the timer's user).
- Size: about 0.7–1 KB per node, so even a 10k-node cluster stays around 10 MB raw.

## 6. Verify

- `docker exec -e SLURM_TIME_FORMAT=%s slurmctld scontrol --all show node`: layout and epoch
  times (VERIFIED).
- On orcd:
  - check that `scontrol --all show node | grep -c '^NodeName='` equals `scontrol show node | grep -c '^NodeName='`;
  - check that `OS=`, `Reason=`, `Comment=` and `Extra=` lines start at the indent with nothing
    after them on the line (look at a drained node, `scontrol show node <drained>`);
  - check `-d` on a GPU node.
- On docker, drain a test node to see a `Reason=` line (`scontrol update nodename=c2 state=drain reason="a b=c"`).
  This **mutates the test cluster**, so ask the user first; resume it afterwards.

## 7. What downstream uses it for

- **`ReqNodeNotAvail` / `Resources` pending reasons:** node `State` (DOWN, DRAIN, RESERVED,
  MAINT), `Reason`, and free capacity (`CPUEfctv − CPUAlloc`, `RealMemory − AllocMem`,
  `CfgTRES` against `AllocTRES`, `Gres`).
- **Scheduling order:** node `Weight` and `Partitions` membership; `Features` for constraint matching.

## 8. Cadence

Every 5–15 min.
