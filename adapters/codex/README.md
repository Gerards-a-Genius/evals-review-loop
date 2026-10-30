# Codex CLI adapter

Codex's hook protocol **is** the Claude Code protocol. The payloads are the same, the event names are
the same, and a `PreToolUse` hook can deny a command. So this adapter enforces **both** gates — I
verified that empirically, not by assuming it.

## Verified on codex-cli 0.162.1

The event enum is serialized inside the Codex binary:

```
PreToolUse  PermissionRequest  PostToolUse  PreCompact  PostCompact
SessionStart  SessionEnd  SubagentStart  SubagentStop  Interrupt
```

Live `codex exec` runs confirmed each of these:

| what I ran | result |
|---|---|
| `PreToolUse` hook returning `{"permissionDecision":"deny"}` | `hook: PreToolUse`, then **`hook: PreToolUse Blocked`**, log line `Command blocked by PreToolUse hook: <reason>`, and the file was **not** created |
| `Stop` hook (`eval-gate.mjs stop`) with an approved-but-failing eval | `hook: Stop`, **`hook: Stop Blocked`** — the model could not claim the feature done |
| `SessionStart` hook | `hook: SessionStart` / `Completed` |

A captured `PreToolUse` payload:

```json
{ "hook_event_name": "PreToolUse", "tool_name": "Bash",
  "tool_input": { "command": "printf 'hi' > HELLO2.txt" },
  "cwd": "…", "session_id": "…", "turn_id": "…", "permission_mode": "…",
  "model": "…", "tool_use_id": "…", "transcript_path": "…" }
```

That is **exactly** the Claude Code shape, and a shell command arrives with `tool_name: "Bash"`. The
shared core in `../../hooks/core/` reads it unchanged — this adapter needs no translator.

Project hooks live at `<repo>/.codex/hooks.json`, using the same
`{ "hooks": { "<Event>": [ { "matcher": …, "hooks": [ { "type": "command", … } ] } ] } }` schema.

## What gets installed

`node adapters/codex/install.mjs /path/to/repo` copies the gate into `.codex/hooks/` and merges three
registrations, preserving any hooks already there and no-op on re-run:

| event | runs | effect |
|---|---|---|
| `PreToolUse` | `eval-gate.mjs check` | **Build gate** — denies guardrail writes (the `Approved` row, its sha, `.evals-loop`) and gates the Write/Edit family |
| `Stop` | `eval-gate.mjs stop` | **Completion gate** — cannot end the turn claiming done while an approved check is not `PASS`; names the failing IDs |
| `UserPromptSubmit` | `eval-gate.mjs --remind` | puts the gate state in front of the model every turn |

## Two operational findings worth knowing

**1. The sandbox mode decides whether hooks run.** With `codex exec -s read-only`, `SessionStart`
fired but `Stop` and `PreToolUse` did not — hook side effects were being suppressed. Hooks ran
normally once the sandbox was relaxed. If your gate appears dead, check the sandbox mode before
debugging the gate.

**2. A blocked `Stop` causes retries.** The turn did not end at the first block: the model retried,
was blocked again, and repeated a few times before concluding "Blocked pending requirements". That is
correct behaviour — it kept working instead of claiming success — but it costs tokens. Pair the gate
with the round cap from the skill, and make the failure message tell the model what to do next (the
core's message names the eval and the fix).

## What this enforces, and what it does not

| | Codex |
|---|---|
| Cannot claim a feature done while a check fails | **Enforced**, verified |
| Cannot forge an approval or edit the gate markers | **Enforced** via `PreToolUse` |
| Gate state visible every turn | **Yes** (`UserPromptSubmit`) |
| File writes through the Write/Edit tool family | **Enforced** when Codex routes the edit through a gated tool name |
| **Arbitrary shell writes to product source** | **Not classified.** A `Bash` command that writes `src/app.ts` is not blocked, because the core inspects shell commands for guardrail tampering rather than inferring every filesystem target. This is a core limitation shared with the DeepSeek Harness adapter — and it matters more here, because Codex writes files through the shell. Treat the build gate as *guardrail protection* on Codex, not as a full write barrier. |

## Hook trust

Codex requires **persisted hook trust**, tracked by hash in `~/.codex/config.toml` under
`[hooks.state]`. A newly written `hooks.json` may not fire until Codex has trusted it. For automation,
`--dangerously-bypass-hook-trust` skips the check — that is what the verification runs above used.

## Files

- `install.mjs` — installer (idempotent, preserves existing hooks, bakes absolute paths; Codex
  documents no project-dir variable for hook commands).
- The gate itself is shared: `../../hooks/core/eval-gate.mjs` and `stop-gate.sh`.
