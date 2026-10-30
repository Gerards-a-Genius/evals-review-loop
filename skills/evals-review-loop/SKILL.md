---
name: evals-review-loop
description: Makes a coding agent prove its work instead of claiming it — runnable evals that must be red before they go green, a fresh-context reviewer, and a bounded fix loop with hard stop conditions. Use when an agent says a task is "done" and you need it verified, when setting up Claude Code skills/hooks/REVIEW.md or automated AI code review, when review is the bottleneck at agent volume, or when the user mentions write-evals, review loop, evals-gated development, or "it said it was finished but it wasn't".
---

# Evals Review Loop

An agent writes a lot of code, calls the task done, and you find it missed half of what you asked. The fix is not to read more code — it is to make the agent **prove** the work, then spend your own attention where a mistake actually hurts.

Adopted from Anthropic's Claude Code team (Oct 2026): merged PRs more than doubled from June to September while the **share** that had to be reverted fell by over 40%. They did not remove review. They moved most of the *reading* to machines. AI LABS then turned that into a workflow one developer can run, which is what this skill follows.

**Minimum viable version** — if you do nothing else:

1. Answer one question *before* building: **what happens to a customer if this breaks?**
2. Write the evals first and watch each one **fail**.
3. Hand the diff to a **fresh-context** reviewer and cap the fixing at 5 rounds.

## The three beliefs

1. **"Did a human read it?" is the wrong question.** Ask: *what could go wrong here, and which check — automated or human — is the right one to catch it?* That moves review from a gate at the end to something continuous, like spellcheck.
2. **An eval that cannot fail is theater.** Every eval must be observed RED before the feature exists and GREEN after. Red-then-green is the whole system; without the red observation the rest is decoration.
3. **The loop must converge.** An agent author and an agent reviewer will keep each other busy forever — one real PR went 50+ rounds overnight before a human stopped it. Every round also spends quota, and a reviewer that always finds *something* always looks productive.

## Stages

### 0 · Tier the risk — before you build

One question decides it: **what happens to a customer if this breaks?** Answer it and record `low | medium | high` before any code exists. The change sets the tier, not the author. Default to medium.

| Tier | If it breaks… | Evals | Human approvals |
|---|---|---|---|
| low | something looks wrong | smoke: does it render / return | none, once automated review is green |
| medium | the feature stops working, nothing lost | the full set, every reachable state | one |
| high | money lost, account locked out, one user sees another's data | the full set **plus** adversarial inputs; one eval per irreversible path | two |

The tier sets **both** dials: how strict the evals are — pass it into stage 1, where high risk produces more checks marked `strict` — and how many humans approve. It never relaxes the automated checks. Irreversibility is high risk however small the diff.

### 1 · Write the evals, and gate the build on them

Three authored files per feature, in `specs/features/fr-NN/`:

- `rd.md` — what the feature must do
- `eval.md` — the checks. A front table (RD · Mockup · Eval status · Approved · Perf baseline · New e2e paths), a `## How to verify` section with the runnable commands, then checks numbered by category: `### U-` for usage, `### F-` for failure, `### R-` for what this must not regress. Template: [templates/eval.md](templates/eval.md).
- `mockup.html` — when the feature has a design, a plain page rendered first as the target. The app is built until it matches, and you see the layout — plus the other screen states and the mobile width — without spending tokens on implementation.

The eval must cover three things: every way to use the feature, every way it can fail, and what adding it must not break.

Then **prove every eval RED** against the unbuilt state. An eval that already passes is not testing the feature.

Then you, the human, review `eval.md` and the mockup. On your **`yes`** the agent records `Eval status: Approved` with your name, the date and the commit in the file's front table, and only then starts building. The gate is a **Stop** hook: the agent cannot end a turn claiming the feature is done while any check under an approved eval is not `PASS`, and it names the failures (`F-16 is not PASS — no such route`). A linter over the same file catches a malformed eval during authoring — a mockup linked but missing, a check with no result line — before you ever approve it. Blueprints: [references/auxiliary-skills.md](references/auxiliary-skills.md) · wiring: [references/claude-code-wiring.md](references/claude-code-wiring.md).

### 2 · Build to green

The builder works only from `rd.md` and the evals: it does not write evals or tests, and when a product decision is above its authority it stops and says so. Its output must be **transcript, not assertion** — the command it ran and what came back. "Done" is not evidence.

### 3 · Review with fresh context

Never the agent that built it: the builder made every decision in the change and will agree with itself.

`REVIEW.md` holds the rules the reviewer checks against — what counts as a failure, how serious each kind is, what to ignore, how to report, how the app should be tested. It is **not read by default**: reference it from `CLAUDE.md` so it loads in every session and the review command sees it. Keep it under a page.

Findings return tagged **Important / Nit / Pre-existing** with a file and line. Drop style, cleanup and diagnostics before posting: with an agent author, a nit is a commit and another round. See [references/review-rules.md](references/review-rules.md).

### 4 · Run the loop, bounded

An orchestrator walks **builder → verifier → reviewer**, each in a fresh context window so they cannot simply agree with the main agent, with `state.md` tracking the round and what is still failing. The verifier runs every check against a production build — in a browser, for anything with UI. Stop on the first of:

- **Green** — every eval passes *and* the review finds nothing new.
- **Cap** — 5 rounds, then the reviewer stops listing findings and tells the builder to **rethink the approach**. (Anthropic's team policy is 3 rounds and then rethink; this workflow allows 5 because each round does more work — build, exercise every eval in a browser, then review. Pick one and write it down.)
- **Stall** — the same problem survives two rounds of fixes. Escalate the *approach question*, not another patch.

Three rules make it converge: after the first round re-review **only what the last fixes changed**; **never re-report** a finding already posted; name the **class** of problem so every instance is fixed, not one line. The reason is measured — about 59% of what kept getting flagged was code that predated the first pass. Late rounds find old bugs, not new ones.

When the loop hits a decision it cannot make, it stops and shows a progress report asking you, rather than guessing. Protocol: [references/loop-protocol.md](references/loop-protocol.md); enforce the cap and the no-repeat rule with `scripts/loop.py`.

### 5 · Check what the evals cannot see

- **First-time-user test.** A fresh agent that never saw the app built uses the *live* app like a new customer — **blocked from reading the code**, including through shell commands, on a throwaway copy of the database. It reports where someone would get stuck. This is the check evals structurally miss.
- **Fix-a-bug.** Given a symptom: reproduce it, *check whether the guess at the cause is actually right*, then report and fix. Guessing confidently is the failure mode.
- **Make it impossible to lose.** A branch per feature (`feat/fr-11-reschedule`), every working version committed, a feature flag, one documented revert action. Anthropic can undo almost anything in minutes — that is precisely what lets them read less.

### 6 · Compound the learnings at the source

The agent does not remember last session's mistake, so it repeats it on the next feature. Fix the source:

| Recurrence | Fix at |
|---|---|
| the same comment flagged twice | one line in `REVIEW.md` |
| a review **missed** a bug that surfaced later | one line in `REVIEW.md` |
| a review **flagged** something that turned out fine | one line in `REVIEW.md` — false positives matter as much |
| the same bug class in many places | a lint rule or a check |
| a broken convention | a line in `CLAUDE.md` |
| a revert or incident | a new eval that would have caught it |

Keep a **"rules learned over time"** section at the bottom of `REVIEW.md`. The loop notices the repeat in a later round, matches it to the earlier one, suggests a one-line rule, and adds it **only when you approve** — an agent that can silently rewrite its own review criteria can silently lower its own bar. Keep both files short: they load every session, and an ignored rule is worse than no rule.

## Common Rationalizations

| Rationalization | Reality |
|---|---|
| "It's done, I can see it works" | You seeing it is not evidence anyone else can check. Attach the command, its output, or a screenshot. |
| "Writing evals first is slower" | You will write them after the rework instead, and the bug they would have caught has already shipped. |
| "I'll review my own diff" | The builder made every decision in the change and will agree with itself. Fresh context or it is not a review. |
| "One more round will get it" | 59% of late-round findings were pre-existing code, and each round burns quota. More rounds surface old bugs. |
| "This nit is 30 seconds" | For an agent author a nit is a commit plus a round plus a re-review. Two nits can cost more than the bug. |
| "It's low risk, skip the checks" | Low risk changes the number of *humans* and the strictness of the evals — never whether checks run. |
| "The test suite passes" | Tests written after the code assert what the code already does. Prove them red first or they prove nothing. |
| "The hook is annoying, disable it" | The gate is the only part that survives deadline pressure. Remove it and you are back to trusting claims. |
| "Reviewer and builder agreed, so it's fine" | Two agents agreeing is one model agreeing with itself unless the contexts were isolated. |
| "The evals pass, so ship it" | Evals only cover what you thought to check. The first-time-user test covers the rest. |

## Red Flags

- Every eval passed on its first run after implementation — they were never red.
- The reviewer shares context with the builder, or was handed the builder's summary.
- Round 4+ and the findings are still all Nit or Pre-existing.
- The same finding appears in two rounds — dedupe is broken.
- No risk tier recorded for the feature, so the eval set was never calibrated.
- `REVIEW.md` exists but `CLAUDE.md` does not reference it — it is never read.
- `REVIEW.md` grew by more than about two paragraphs this session.
- A bot or agent approval counted toward a required human approval.
- `Eval status: Approved` written by the agent without you having typed yes.
- "Done" stated with no command output, eval transcript, or screenshot attached.

## Verification

- [ ] Every eval was observed RED before implementation — failing run pasted or logged in `eval.md`.
- [ ] Every eval observed GREEN against the final commit — passing run pasted or logged.
- [ ] The reviewer ran in a fresh context and received ARTIFACT + CONTRACT, not the builder's summary.
- [ ] `CLAUDE.md` references `REVIEW.md` (grep for it) — otherwise the rules never load.
- [ ] The `Approved` row in `eval.md` records your name, the date, and the commit it was approved at.
- [ ] A stop condition was hit and its reason recorded (green / cap / stall).
- [ ] The risk tier was recorded before implementation began, and the eval set reflects it.
- [ ] The first-time-user agent ran without code access, against a throwaway database, and its run folder holds a report.
- [ ] Each recurring finding has a `REVIEW.md` line or lint rule naming it, added with your approval.
- [ ] A revert path exists and is one documented action.
- [ ] `scripts/loop.py status` shows the loop inside its cap — or the escalation is recorded.

## Files

- [references/eval-design.md](references/eval-design.md) — evals that can actually fail; model grading; incident-derived eval sets.
- [references/review-rules.md](references/review-rules.md) — writing `REVIEW.md`, the finding taxonomy, noise filters.
- [references/loop-protocol.md](references/loop-protocol.md) — roles, round mechanics, cost, convergence and escalation.
- [references/auxiliary-skills.md](references/auxiliary-skills.md) — blueprints for the rate-risk, write-evals, review-loop, first-time-user and fix-a-bug skills.
- [references/claude-code-wiring.md](references/claude-code-wiring.md) — hooks, `/code-review` effort levels, CI, merge queue.
- [templates/](templates/) — `eval.md`, `REVIEW.md`, `CLAUDE.md` snippet, `settings.hooks.json`, `eval-gate.mjs` (lint + build gate), `require-evals-pass.sh` (Stop gate).
- [scripts/loop.py](scripts/loop.py) — enforces the round cap and finding dedupe.

## Sources

- Anthropic, [How the Claude Code team does code review](https://claude.dev/blog/solving-code-review-at-anthropic/) — the primary source: the numbers, the layering, noise measurement, the 59% finding, risk tiers.
- AI LABS, [Anthropic Just Released A New System For Using Claude Code](https://youtu.be/S49gppZl8H0) — the practitioner adaptation followed here: the `specs/features/fr-NN` folder and `mockup.html`, the pre-build approval and the Stop-hook gate, the 5-round cap, the first-time-user test, the fix-a-bug skill. Its four skill files ship paid in AI Labs Pro; the blueprints here are reconstructions from the demonstrated behaviour.

**Not from the video:** the literal `settings.json` hook JSON and the `CLAUDE.md → REVIEW.md` reference syntax are not legible on screen. They are constructed here and tested against Claude Code 2.1.x — see the wiring reference for exactly which parts are which.
