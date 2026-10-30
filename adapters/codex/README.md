# Codex CLI adapter

Codex CLI **does** have hooks, and they use the **same schema as Claude Code**. What it does not
have is a pre-tool hook, so this adapter enforces the completion gate and only *informs* on the build
gate. That distinction is the whole README.

## Verified on this machine — codex-cli 0.162.1

Read from `~/.codex/config.toml` (its `[hooks.state]` trust table) and a live project
`.codex/hooks.json`:

- Project hooks live at **`<repo>/.codex/hooks.json`**.
- The schema is identical to Claude Code's:

  ```json
  { "hooks": { "Stop": [ { "matcher": "…", "hooks": [ { "type": "command",
      "command": "…", "timeout": 10, "statusMessage": "…",
      "additionalContextLimit": 3500 } ] } ] } }
  ```

- Events observed in real configs on this machine: **`SessionStart`**, **`UserPromptSubmit`**,
  **`Stop`**. `additionalContextLimit` is a Codex addition — it caps how much text an
  `additionalContextLimit`-bearing hook can inject.
- Codex **requires persisted hook trust**; the `--dangerously-bypass-hook-trust` flag exists to skip
  it for automation. A freshly installed `hooks.json` may not fire until Codex has trusted it.

## What gets installed

`node adapters/codex/install.mjs /path/to/repo` copies the gate into `.codex/hooks/` and merges:

| event | what it runs | effect |
|---|---|---|
| `Stop` | `eval-gate.mjs stop` | **Enforcement**: the turn cannot end cleanly while an approved check is not `PASS`, and the failing check IDs are named. |
| `UserPromptSubmit` | `eval-gate.mjs --remind` | **Informs**: puts the current gate state in front of the model every turn, so "done" is stated in front of the evidence. |

Existing hooks in `hooks.json` are preserved; re-running is a no-op.

## What this enforces, and what it does not

| | Codex |
|---|---|
| Cannot claim a feature done while a check fails | **Enforced** via `Stop` |
| Gate state visible every turn | **Yes**, via `UserPromptSubmit` context |
| Cannot write product source before approval | **No.** Codex has no pre-tool hook. The build gate would need Codex's sandbox/approval layer; a hook cannot deny a write here. |
| `.evals-loop` arming, sha-bound approval, own-artifacts-writable | **Yes** — same core code as every adapter |

The consequence is concrete: in Codex an agent can start implementing before you approve the eval.
What it cannot do is finish and call it done. If you need the stronger property, run the work through
Claude Code (which has `PreToolUse`) or through Hermes with the build gate active inside the dispatch.

## Unverified — verify before trusting

- **That exit code 2 blocks a `Stop` in Codex.** The schema matches Claude Code and Codex's hook
  vocabulary is the same, but this adapter has not been run against a live Codex session. Verify:

  ```bash
  cd /tmp/your-repo && touch .evals-loop        # arm
  codex exec 'say done'                          # should be refused while an eval is red
  ```

  If Codex uses a different block convention (a JSON field rather than an exit code), the `Stop`
  command in `hooks.json` is the one line to change — the core's exit codes stay as they are.
- **That a project-level `.codex/hooks.json` is picked up without also configuring user-level
  hooks.** Try `codex doctor` first; it reports config and runtime health.

Do not describe this adapter as blocking writes. It blocks a false claim of completion.

## Files

- `install.mjs` — the installer (idempotent, preserves existing hooks, bakes absolute paths because
  Codex does not document a project-dir variable for hook commands).
- The gate itself lives in `../../hooks/core/` and is shared with every other adapter.
