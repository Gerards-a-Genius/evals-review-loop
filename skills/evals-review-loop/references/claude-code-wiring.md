# Wiring it into Claude Code

Everything here is scaffolding around the process. The process works without it; the wiring is what makes the gates survive deadline pressure.

> **What is and is not from the video.** The video demonstrates a Node hook at `.claude/hooks/eval-gate.mjs`, a Stop hook that refuses "done", the `specs/features/fr-NN/{rd.md,eval.md,mockup.html}` layout, and REVIEW.md being referenced from CLAUDE.md. It **never shows** the literal `settings.json` hook block, the matcher values, or the CLAUDE.md→REVIEW.md link syntax — that segment is an animated diagram. The config in [templates/](../templates/) is constructed here and tested against Claude Code 2.1.x. Treat it as working scaffolding, not as a transcript.

## The files

| File | Holds |
|---|---|
| `CLAUDE.md` | what the project is: stack, conventions, goals, non-goals. Loads every session — keep it short. |
| `REVIEW.md` | what matters in *this* code area, written by the owner. Under a page. See [review-rules.md](review-rules.md). |
| `specs/features/fr-NN/rd.md` | the requirements for one feature |
| `specs/features/fr-NN/eval.md` | the checks, the approval, red/green evidence. See [eval.md template](../templates/eval.md). |
| `specs/features/fr-NN/mockup.html` | the design target, when there is a UI |
| `specs/features/fr-NN/state.md` | the loop's current round and what is still failing |
| `.evals-loop` | repo-root marker a **human** creates to arm the gates |
| `.claude/settings.json` | hooks that enforce the gates |
| `.claude/hooks/eval-gate.mjs` | one script, two modes: linter and Stop gate |
| `.claude/skills/<name>/SKILL.md` | `rate-risk`, `write-evals`, `review-loop`, `first-time-user`, `fix-a-bug` |

## REVIEW.md is not loaded unless you reference it

The easiest thing to get wrong, and it silently disables every review rule you wrote:

- A file is not read because it exists. `REVIEW.md` is only consulted if something loads it.
- So **reference it from `CLAUDE.md`**. Then it loads with `CLAUDE.md` in every session, and the review command picks it up too.
- Keeping the rules in a separate file rather than pasting them into `CLAUDE.md` is correct — it loads the same way and stays readable. The video's exact link syntax is not legible; whatever import/reference form your Claude Code version supports, the requirement is that a fresh session has the rules loaded.
- Verify it: start a fresh session and ask the agent what review rules it has. If it cannot say, it never loaded.

Both files load every session, so they are a recurring token cost. When either passes about a page, move detail into a linked doc and leave the trigger.

## The gate, in two modes

The video's hook is a **well-formedness linter** and a **Stop gate** at the same time. The linter runs during authoring; the Stop registration is the blocker.

**Mode 1 — lint, during authoring.** The skill calls it before asking for approval, so a malformed eval never reaches a human:

```bash
node .claude/hooks/eval-gate.mjs lint fr-11
# FR-11 eval is not well formed:
# - Mockup is linked but specs/features/fr-11/mockup.html is missing
# exit 1

node .claude/hooks/eval-gate.mjs lint fr-11
# FR-11 eval is well formed. 11 U- checks, 20 F/R/Q/S/D checks.
# exit 0
```

**Mode 2 — Stop, blocking.** Registered on the `Stop` event it exits **2** instead of 1, which blocks and feeds the reason back to the model:

```
Stop hook error: FR-11's eval is approved but not passing, so the feature isn't done:
- F-16 is not PASS (Result: FAIL: after a move to Fri, Oct 30 10 AM, pressing Back shows the stale page)
```

That error is the whole point: the agent physically cannot end its turn claiming the feature is done while an approved check is not `PASS`, and the message names the failing IDs so the next round starts with the specific gap rather than a vague "fix the tests".

Two scripts share the work: `eval-gate.mjs` owns the linter and the build gate, and `require-evals-pass.sh` owns the Stop gate (the `.mjs` delegates a `Stop` event to it, so either entry point behaves the same). Registrations: [settings.hooks.json](../templates/settings.hooks.json).

**Optional third gate — block the build entirely.** A `PreToolUse` hook on the write tools that refuses product-source edits while the eval is unapproved. Stricter than the video, which relies on the skill's instruction plus the Stop gate. Worth it if you have watched an agent start implementing before you approved anything.

Hook semantics worth knowing:

- **Exit 2 blocks**, and stderr is shown to the model as the reason. Exit 0 with no output means "no decision" — the call proceeds. (Note the asymmetry: the same script exits **1** when run as a linter, because that is a normal command result, and **2** when it must block.)
- `onFailure` defaults to `continue`, meaning a hook that cannot start — a missing or non-executable script — is reported and **the action goes ahead**. Set `onFailure: "block"` on any gate; that is the difference between a gate and a decoration.
- Hooks fire **inside subagents**, so a builder subagent cannot route around the gate.
- Skills and subagents can carry their **own** frontmatter hooks, which is how a skill arms its own gate.
- A hook that cannot run is not a gate. Verify with `/hooks` in-session, then deliberately try to trip it.

Blocking code-reading for the first-time-user test is the same mechanism inverted: deny `Read`/`Grep`/`Glob` on the project source **and** deny shell commands that read it. Block only the file tools and the agent reaches for `cat`.

## Approvals, exactly

- **The human types yes; the agent writes it down.** Approval is `Eval status: Approved` plus `Approved | <name>, <date> · sha:<commit>` in `eval.md`. If the agent can author that row alone, the gate is decorative — block that one write, through the shell as well as the file tools.
- **Bind the approval to a commit.** The sha in the row must match `HEAD`; when `HEAD` moves the approval goes stale and the gate closes again. Without that, one approval opens the gate for the life of the repo.
- The **change sets the tier**, not the author. Anthropic runs a classifier rather than self-assessment; a second classifier asks whether this change needs another person even when the tier says no.
- Some paths always need a person regardless of tier: auth, billing, CI workflow files, installers, release tooling. `CODEOWNERS` plus branch protection is the cheap version.
- **A bot's approval never fills a human slot.** Automated review can clear a low-risk change; it cannot substitute for a required human.
- **Whoever prompted the change owns it**, including when an agent wrote every line.
- Lighter approval paths are for **trusted authors only**.

## Depth control and the review product

| Need | Use |
|---|---|
| pre-PR self-review, free, local | `/code-review` |
| depth on that command | its **Effort** setting: `low`, `medium`, `high`, `max`. Low reports only what it is most sure about; higher effort checks more of the app. |
| security pass | `/security-review`, or the open-source security-review GitHub Action |
| independent reviewer with real isolation | a fresh-context subagent handed only the diff + `REVIEW.md` |
| hosted, multi-file, verified findings | **Code Review for Claude Code** — Team/Enterprise plans only; admins set each repo **Quick**, **Standard**, or **Deep** |

Pick per repo by cost of a miss: Deep where one missed bug costs more than the extra review time; Quick where the change surface is dull. The hosted reviewer also closes most of the noise problem for you — findings are multi-agent verified and voted on before posting, and style/cleanup/diagnostics findings are dropped. Build that filtering yourself if you run a homegrown reviewer: several agents hunt, then a separate group votes, and a finding only posts if enough agree.

## CI and the PR template

Blocking checks, all of them: lint, type check, tests on every platform you ship, and a build. A typical PR should run dozens of checks before a human sees it.

```md
## Testing
<the command you ran and what it returned — not "tested locally">

## Risk
<low | medium | high> — <why this tier>

## How to revert
<the one command or the flag to flip>
```

An agent can fill these in; the person who requested the change signs off on them.

## Merge and rollback

- **Merge queue** re-runs checks against `main` with the change applied, so two individually-green PRs cannot combine into a broken `main`.
- **Flags**, not deploys, for turning things off.
- **Internal-first**, then staged channels — a fast channel, a stable channel that trails it.
- **One-step rollback**, documented in the PR body. Reversibility is what earns the right to lower the review bar; that trade only holds if rollback actually works.

## Measure the right thing

Track **human approvals per PR** (median and p95), human comments, and time a PR waits on a person. Guardrail: **revert rate and incident rate**. If reversions rise, you did not save human time, you only moved it to the fixing side. "Median approvals dropped" on its own is not a win.
