# Adapter contract

One implementation, many hosts. An adapter is a **thin translator** and nothing else:

```
host event ──► adapter ──► hooks/core/eval-gate.mjs ──► exit code ──► host's block signal
```

Adapters own *plumbing only*: reading their host's event shape, mapping it to the CLI below, and
converting the exit code into whatever that host calls "block". They must never re-implement a
check. If two adapters disagree about whether a build is allowed, the bug is in an adapter.

## CLI

```
node eval-gate.mjs lint <feature-id> [--root DIR]
```
Well-formedness only, used while authoring.
- **exit 0** — well formed; stdout prints check counts, e.g. `FR-11 eval is well formed. 11 U- checks, 20 F/R/Q/S/D checks.`
- **exit 1** — malformed; stderr lists human-readable reasons, one per line, e.g.
  `- Mockup is linked but specs/features/fr-11/mockup.html is missing`

```
node eval-gate.mjs check --tool <name> [--path FILE] [--command SHELL] [--root DIR] [--json]
```
The build gate: may this mutation proceed?
- **exit 0** — allow.
- **exit 2** — deny; reason on stderr.
- `--path` / `--command` may be omitted when the host event is supplied on stdin.

```
node eval-gate.mjs stop <feature-id> [--root DIR] [--json]
```
The completion gate: may the agent claim this feature is done?
- **exit 0** — every check under the approved eval is `PASS`.
- **exit 2** — not done; stderr names the failing check IDs.

## stdin event (all optional)

```json
{
  "tool": "write",
  "path": "src/app.ts",
  "command": "npm run build"
}
```

`tool` is the adapter's *neutral* name for what is being attempted: `write`, `edit`, `bash`, `read`,
or `other`. The core decides which of these it gates; an adapter must pass `read` through unchanged
so read-blocks can be added later without touching adapters.

## Exit codes (stable across every host)

| code | meaning |
|---|---|
| 0 | ok / allow / done |
| 1 | usage error, or `lint` found the eval malformed |
| 2 | blocked — gate deny, or completion refused |
| 3+ | reserved; treat as a block, never as an allow |

## Arming

The gates are inert unless the repo root contains `.evals-loop`, which a **human** creates. This is
the one safety property that must survive every adapter: an adapter must not create, delete, or
bypass that marker, and must not treat "not armed" as anything other than allow. Approval lives in
`eval.md`'s front table (`Eval status` / `Approved` with a sha bound to `HEAD`).

## When a host cannot block

Some hosts can only observe. In that case the adapter:

1. runs the gate anyway,
2. prints the failure to stderr in the host's visible log,
3. appends the result to its own audit file, and
4. **documents the gap in its README** — it must never report success it did not enforce.

An honestly-labelled observing adapter is useful. A silently-passing one is worse than no adapter.
