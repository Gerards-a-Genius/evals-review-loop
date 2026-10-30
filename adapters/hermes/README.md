# Hermes adapter

Hermes is a **conductor**: it routes a coding task to Claude Code, Codex or Grok through
`hermes-dispatch`, runs it headless in an isolated worktree, and commits the result to a local
`hermes/*` branch. It does not edit files itself, so a pre-edit hook is the wrong shape.

The right shape is the one `hermes-dispatch` already uses: a **post-run verification gate**.

## What `hermes-dispatch` already does

It runs two annotate-only gates after the engine finishes:

| gate | what it does |
|---|---|
| 1 · test gate | runs the repo's own test command in the worktree |
| 2 · review gate | risk-tiered cross-engine diff review |

Both **annotate, never block** — the branch always lands, and a flag flips the run to
`needs-review` with evidence attached. That is a deliberate design choice in the dispatcher.

## What this adds

A third gate in the same shape: **gate 3 · evals gate**. It answers the one question the test gate
cannot — *did the agent do what the approved eval says, or did it just claim done?*

```
evals-gate.sh <worktree> [<runlog>]     → prints EVALS_RESULT=<value>, always exits 0
```

`EVALS_RESULT` uses the dispatcher's own test-gate vocabulary, so it slots into existing reporting:

| value | meaning |
|---|---|
| `skipped` | no eval configured for this repo |
| `not-armed` | repo has no `.evals-loop`; the loop was never adopted |
| `passed` | every check under an approved eval is PASS |
| `failed` | at least one approved check is not PASS |
| `not-approved` | an eval exists but no human has approved it |
| `malformed` | `eval.md` is not well formed |
| `timeout` | no result within `EVALS_TIMEOUT` (default 600 s) |
| `error` | the gate itself broke — reported, never silent |

Standalone mode, for CI or a pre-push hook where blocking *is* wanted:

```bash
evals-gate.sh --standalone /path/to/repo [fr-11]   # exit 0 pass, exit 2 fail
```

## Wiring it in

`hermes-dispatch` is a live user script, so this adapter **does not patch it for you**. Insert this
block immediately after the test gate (after the `TESTS_RESULT="none-found"` line, around line 468),
inside the same `if [ "$HAS_COMMITS" -gt 0 ]` scope:

```bash
# ----- verification gate 3: evals -------------------------------------------------
# Annotate-only, same contract as gates 1 and 2. A red eval does not block the
# branch; it flips the run to needs-review with the failing check IDs attached.
EVALS_RESULT="skipped"
if [ "$HAS_COMMITS" -gt 0 ] && [ "$TIMED_OUT" != "1" ]; then
  EVALS_OUT="$(bash "$HOME/Build/evals-review-loop/adapters/hermes/evals-gate.sh" "$WT" "$RUNLOG" 2>>"$RUNLOG" || true)"
  EVALS_RESULT="$(printf '%s\n' "$EVALS_OUT" | sed -n 's/^EVALS_RESULT=//p' | tail -1)"
  EVALS_RESULT="${EVALS_RESULT:-error}"
  echo "evals gate: $EVALS_RESULT" >> "$RUNLOG"
fi
```

Then include it wherever the dispatcher builds its status summary — treat `failed` / `not-approved` /
`malformed` like a non-passing test gate:

```bash
# alongside the existing status logic
case "$EVALS_RESULT" in
  failed|not-approved|malformed) STATUS="needs-review" ;;
esac
```

And echo it in the captured summary next to `TEST GATE RESULT:`:

```bash
echo "EVALS GATE RESULT: $EVALS_RESULT"
```

## What this enforces, and what it does not

**Enforces:** nothing, by design. It surfaces evidence, and the dispatcher's status carries it to a
human. A `failed` eval does not stop a branch landing — the same as a failing test gate today.

**Catches:** an engine that finished its work while an approved check is still red, and an engine
that built a feature nobody approved. Both become visible before the branch reaches review.

**Does not catch:** an engine that begins implementing before approval was given. That mutation
already happened inside the worktree. If you want that blocked, Hermes must run the engine with the
Claude Code plugin's `PreToolUse` gate active inside the dispatch (that is
`adapters/claude-code/`), not this gate.

Do not describe this adapter as blocking. It is an evidence gate on a conductor that does not block.

## Verifying it yourself

```bash
bash -n adapters/hermes/evals-gate.sh
# unarmed repo → not-armed, exit 0 in gate mode
bash adapters/hermes/evals-gate.sh /tmp/some-repo
# standalone on an unarmed repo → exit 2
bash adapters/hermes/evals-gate.sh --standalone /tmp/some-repo
```
