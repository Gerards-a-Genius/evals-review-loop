# Adapters

One gate, many hosts. Every adapter calls the same implementation in
[`../hooks/core/`](../hooks/core/) and obeys [`../hooks/core/CONTRACT.md`](../hooks/core/CONTRACT.md) —
no adapter re-implements a check.

| Host | Directory | Build gate | Completion gate | Verified against |
|---|---|---|---|---|
| **Claude Code** | [`claude-code/`](claude-code/) | **Enforced** (`PreToolUse`) | **Enforced** (`Stop`) | plugin validate + 68 assertions |
| **DeepSeek Harness** | [`deepseek-harness/`](deepseek-harness/) | **Enforced** (`tools/pre-execute` → `deny`) | **Not enforced** — inject instead | `PreToolDecision` read from source; decision function tested |
| **Codex CLI** | [`codex/`](codex/) | **Not possible** — no pre-tool hook | **Enforced** (`Stop`), block convention unverified | hooks schema read from a live config |
| **Hermes** | [`hermes/`](hermes/) | n/a — a conductor, not an editor | **Evidence only** — annotate, never block | script tested; patch documented, not applied |

Read each adapter's own README before trusting it. Every one states plainly what it enforces, what it
merely observes, what it cannot see, and what remains unverified. That is a rule of this repo: an
adapter that cannot block must not report success it did not enforce.

**Why the columns differ.** "Can this host deny a tool call before it runs?" is the only question
that determines whether the build gate is enforceable. Claude Code (`PreToolUse`) and the DeepSeek
Harness (`tools/pre-execute`) can. Codex CLI cannot — it has hooks, but no pre-tool event. Hermes
never edits, so its gate belongs on the dispatch result.

## Adding a host

1. Read [`../hooks/core/CONTRACT.md`](../hooks/core/CONTRACT.md).
2. Establish — from the host's docs or source, with a citation — whether it can *block* a mutation or
   only *observe* one.
3. Write the thinnest possible translator: host event → `eval-gate.mjs check` / `stop` → the host's
   block signal (or an audit line, if it cannot block).
4. Add a README with an explicit **"What this enforces / What it does not"** and a **"Unverified"**
   section. Do not skip the second one.
5. Add the row above, and the adapter's syntax check to
   [`../.github/workflows/validate.yml`](../.github/workflows/validate.yml).
