# C01 `scontrol --json=list`: no counterpart script

## 1. What capture-raw.sh does today

```bash
run_cmd C01 10 "$MIB" - - scontrol --json=list
P="$( { grep -oE 'v0\.0\.4[345]' "$LAST_STDOUT" || true; } | sort -u | sort -r | head -n1)"
```

capture-raw.sh asks which `data_parser` versions this Slurm offers and keeps the newest of
v0.0.43–v0.0.45, the only ones core's parsers read. Every later `--json` command is pinned to it
(`--json=$P`), and the JSON commands are skipped when none matches.

The step exists only because **core's parsers** accept a fixed set of versions. It captures no
cluster state.

## 2. Counterpart: none

The snapshot design does not need negotiation:

- **The text bodies don't use data_parser at all.** That covers `scontrol show node`,
  `partition`, `reservation` and `config`
  ([README rule 3](README.md#design-rules)).
- **The JSON bodies record their parser themselves.** That covers `scontrol show job` and
  sacctmgr assoc/qos. They run with plain `--json`, the cluster's default parser, and the envelope
  says which one was used:

  ```json
  "meta":{"plugin":{"data_parser":"data_parser\/v0.0.45", …},
          "slurm":{"release":"26.05.5","cluster":"linux"}}
  ```

  This is VERIFIED docker for scontrol and sacctmgr, and matches core's live-docker fixture.
  Downstream reads `meta.plugin.data_parser` and dispatches on it, so nothing is hardcoded
  ([rule 0](README.md#design-rules)).

The JSON snapshots therefore carry no `# data_parser:` metadata line, because the body already
has that information.

## 3. Optional extension (not planned)

A downstream parser might one day need a fixed version, for example core's v0.0.43–45 set on a
release whose default is newer. In that case add one environment variable to the JSON scripts:

- `SNAPSHOT_JSON_PARSER=v0.0.4x` turns `--json` into `--json=$SNAPSHOT_JSON_PARSER`;
- validate it at **runtime** against `scontrol --json=list` (or `sacctmgr --json=list`), never
  against a hardcoded list:
  - the output is free text, one `data_parser/v0.0.4x` per line on stdout, with the heading on
    stderr (core `docs/slurm-commands/C01-scontrol-json-list.md`);
  - use `grep -qx "data_parser/$SNAPSHOT_JSON_PARSER"`, with `|| true` handling under pipefail;
- record the pin as `# json-parser: v0.0.4x (pinned)`.

## 4. Pitfalls this removes

- **Unsupported parser versions:** 24.x and earlier lack v0.0.43, so capture-raw skips every JSON
  command there. A snapshot uses whatever the default parser is.
- **Text commands no longer depend on JSON support:** the text commands keep working even without
  the `serializer/json` plugin (some OpenHPC builds lack it). Only the three JSON snapshots fail,
  each with its own `# exit:`.

## 5. Verify

- `docker exec slurmctld scontrol --json=list`, then on orcd-login. This confirms the default
  parser is listed. Informational only, because nothing depends on it.
- `docker exec -e SLURM_JSON=compact slurmctld sacctmgr --json show qos | grep -o '"data_parser":"[^"]*"'`
  shows that sacctmgr's envelope names the parser (VERIFIED docker: `data_parser\/v0.0.45`).
