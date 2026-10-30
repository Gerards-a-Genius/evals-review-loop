# evals-review-loop

**Make your coding agent prove the work instead of claiming it.**

An agent writes a lot of code, calls the task done, and you find it missed half of what you asked. This is a workflow — plus the enforcement to back it — that makes the agent demonstrate the work with runnable checks before a human looks, and refuses to let it say "done" while a check is still failing.

Adapted from [how Anthropic's Claude Code team does code review](https://claude.dev/blog/solving-code-review-at-anthropic/) (merged PRs more than doubled while the share reverted fell by over 40%) as demonstrated by [AI LABS](https://youtu.be/S49gppZl8H0).

## Why

Three beliefs, each of which changes what you do:

1. **"Did a human read it?" is the wrong question.** Ask what could go wrong, and which check — automated or human — is the right one to catch it.
2. **An eval that cannot fail is theater.** Every check must be observed **red** before the feature exists, and green after.
3. **The loop must converge.** An agent author and an agent reviewer will keep each other busy forever. One real pull request went 50+ rounds overnight before a human stopped it.

## What you get

- **`skills/evals-review-loop/`** — a portable [Agent Skill](https://agentskills.io/specification): the process, the `eval.md` schema, `REVIEW.md` rules, the bounded-loop protocol, and a small Python bookkeeper that enforces the round cap and stops re-posting a finding.
- **`hooks/`** — one gate implementation with two decisions: may this change be built (`check`), and may this feature be called done (`stop`).
- **`adapters/`** — per-host wiring, each labelled with what it actually enforces.

## Install

### Claude Code — as a plugin

```bash
claude plugin marketplace add Gerards-a-Genius/evals-review-loop
claude plugin install evals-review-loop@evals-review-loop
```

The gate is **inert until you arm it**, so installing it changes nothing until you opt a repo in.

### Claude Code — into one project

```bash
node adapters/claude-code/install.mjs /path/to/your/repo
```

Merges the hooks into that project's `.claude/settings.json` without overwriting what is there.

### Any agent that reads Agent Skills

```bash
git clone https://github.com/Gerards-a-Genius/evals-review-loop.git
cd evals-review-loop && ./install-skill.sh
```

Installs to `~/.agents/skills/evals-review-loop` (override with `AGENTS_SKILLS_DIR`), verifies the
frontmatter, and checks that `node`, `python3` and `git` are present. Re-run it after `git pull`.

That directory is the shared convention read by Claude Code, Codex CLI, Cursor, Copilot, Gemini CLI and others. You get the **instructions** everywhere; enforcement needs the matching adapter.

### Other hosts

| Host | Adapter | Build gate | Completion gate |
|---|---|---|---|
| Claude Code | [`adapters/claude-code/`](adapters/claude-code/) | **Enforced** | **Enforced** |
| DeepSeek Harness | [`adapters/deepseek-harness/`](adapters/deepseek-harness/) | **Enforced** | Not enforced — injected instead |
| Codex CLI | [`adapters/codex/`](adapters/codex/) | **Enforced** (shell-write classification limited) | **Enforced** |
| Hermes | [`adapters/hermes/`](adapters/hermes/) | n/a (a conductor) | Evidence only |

Each adapter README states what it enforces, what it observes, and what is still unverified. Read it
before trusting it.

## Using it

**Arm a repo** — a human runs this, once, deliberately:

```bash
touch .evals-loop
```

**Write the eval before the code.** The `write-evals` skill produces `specs/features/fr-NN/eval.md`: a front table (RD · Mockup · Eval status · Approved · Perf baseline · New e2e paths), a `## How to verify` section with runnable commands, and checks numbered `U-` (usage), `F-` (failure), `R-` (regression). Every check must be observed **failing** first.

**Approve it** — you type `yes`; then the agent records, in the file:

```
| **Eval status** | Approved |
| **Approved** | your-name, 2026-10-30 · sha:<commit> |
```

The approval is bound to that commit. Move `HEAD` and the gate closes again.

**Then build.** The agent cannot end a turn claiming the feature is done while a check under an approved eval is not `PASS`:

```
Stop hook error: FR-11's eval is approved but not passing, so the feature isn't done:
- F-16 is not PASS (Result: FAIL: after a move to Fri Oct 30 10 AM, pressing Back shows the stale page)
```

## What is enforced, and what is only instruction

| | Portable? |
|---|---|
| The process, `eval.md` schema, `REVIEW.md`, loop protocol | **Yes** — plain files and markdown |
| `scripts/loop.py` (round cap, dedupe) | **Yes** — Python stdlib only |
| Build gate / Stop gate | Only where an adapter is installed |
| Mockup rendering, first-time-user browser test | Host-specific |

An adapter that cannot block **says so in its README** rather than reporting success it did not enforce. That is a rule of this repo, not an aspiration.

## Layout

```
.claude-plugin/     plugin.json + marketplace.json (Claude Code distribution)
skills/             the portable Agent Skill — the actual content
hooks/core/         the gate: eval-gate.mjs + stop-gate.sh + CONTRACT.md
adapters/           one directory per host, each self-contained
test/               the assertion harness for the gate
```

## Development

```bash
bash test/run-tests.sh          # the gate's assertion suite
claude plugin validate .        # marketplace + plugin manifest
```

## Provenance

The ideas are Anthropic's, as presented by AI LABS. The skill text, the `eval.md` schema reconstruction, the gate implementation and every adapter here are original work. AI LABS's own skill files are sold separately in AI Labs Pro and are not included. Where this repo reconstructs something the video demonstrates, it says so; where the video is not legible, it says that too.

MIT licensed — see [LICENSE](LICENSE).
