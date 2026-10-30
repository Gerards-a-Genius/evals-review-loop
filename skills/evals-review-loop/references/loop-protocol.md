# The loop protocol

The loop is the part that goes wrong quietly. Two agents, one author and one reviewer, will keep producing plausible work forever: each round finds *something*, so each round looks productive. Bound it structurally.

## Roles

| Role | Gets | Must not get |
|---|---|---|
| **Builder** | The evals and the requirements. | The reviewer's commentary history. It fixes findings as they arrive, one round at a time. |
| **Verifier** | The eval commands only. | Any opinion about the code. It runs commands and reports raw output. |
| **Reviewer** | The diff, the stated intent, `REVIEW.md`, `CLAUDE.md`. | **The builder's reasoning, summary, or plan.** Handing over the conclusion biases the review toward agreeing with it. |

Context isolation is the whole point of the separate reviewer. A reviewer that has watched the builder think has inherited the builder's blind spots; it will reliably approve the reasoning it just followed. Adding an AI reviewer at all moved substantive review comments on internal PRs from roughly 16% to 54% — the isolation is what keeps that reviewer from converging on the builder's own conclusions.

Practical isolation, cheapest first:

- a **subagent** with a fresh context, given only artifact + contract;
- a **new session** with the diff on disk;
- in a single-session harness, at minimum a **separate turn that never sees the build transcript** — and say so out loud in the record.

## Round ordering

```
round N:
  1. builder  — fix every open Important finding; fix the CLASS, not one line
  2. verifier — re-run every eval; report raw pass/fail per eval
  3. reviewer — read ONLY the diff since round N-1 (after the first two passes)
  4. record   — append findings + verdict via scripts/loop.py
```

Step 3's scope narrowing is not a shortcut, it is the fix for the actual failure mode. See below.

## Stop conditions — pick whichever fires first

**GREEN.** Stop as GREEN only when *both* hold:

- every eval passes, **and**
- zero new **Important** findings this round.

Nits and Pre-existing findings do not block. If you let them, the loop has no exit.

**CAP.** `rounds >= cap` → stop and escalate. After three rounds the reviewer is instructed to ask the author to step back and **reconsider the approach** rather than keep patching — that is Anthropic's team policy, not a study result. This workflow sets the cap at **5**, because each of its rounds does more work: it builds, exercises every eval in a browser, and reviews the code. A solo developer absorbs a longer loop for that reason, not because the review is shallower. **Choose one, write it down in `eval.md`, and do not renegotiate mid-loop.** Renegotiating the cap at round 4 is the single most common way this process fails.

**STALL.** Stop and escalate when any of:

- **the same problem survives two rounds of attempted fixes** — the plainest signal, and the one to trust most;
- two consecutive rounds with **no net reduction** in open Important findings;
- a round whose new findings are **all Pre-existing**.

All three mean the loop has stopped working. More rounds will produce more findings — that is exactly the problem.

## What a round costs

Worth stating plainly, because it is the honest objection to this whole process: **every round spends quota.** On a fixed plan, a ten-round loop on one feature can consume a day's usage. People's main complaint about the published article was that the approach only works with unlimited tokens — and it is a fair complaint.

Two consequences:

- **Cap early.** Five rounds, not fifteen. The cap exists partly to protect the budget, not just the schedule.
- **Budget the loop per feature, not per day.** If rounds are expensive, the fix is fewer, better rounds: write tighter evals up front, and let the first-time-user test catch what the loop would otherwise chase for four more rounds.

A working version of this process does *more* per round — builds, exercises every eval in a browser, then reviews — which is why a solo setup may justify 5 rounds where Anthropic's justifies 3. The trade is real: more per round costs more per round.

## When the loop cannot decide

If a round hits a decision it has no authority to make — contradictory requirements, two evals that cannot both pass without a product call, an approach that needs to change shape — **stop and show a progress report** rather than guessing. Report the round number, what is still failing, the two options, and the cost of each. Guessing at a product decision is how a loop produces a large diff nobody asked for.

## Why the loop doesn't converge (the load-bearing fact)

When Anthropic ran `git blame` on what their reviewer kept flagging, **about 59% of it was code that had been there since the reviewer's very first pass.** The reviewer was rarely finding new bugs; it was finding a few more old ones every round, from a slightly different angle.

Consequences, all of which are cheap to implement:

| Fix | Why |
|---|---|
| **Diff-only re-review** after the first couple of passes | Stops the reviewer wandering back into pre-existing code and calling it a regression. |
| **No repeats** — never re-post a finding already raised | The author has already decided about it. Re-posting is a round spent re-litigating. |
| **Flag the class of bug**, not the instance | "Unchecked array index in 6 places" produces one fix. "Line 42 is unchecked" produces one fix and five more rounds. |
| **Cap the rounds** | The default was never wrong; it was the absence of a cap that was. |
| Record **rounds-to-pass** alongside recall | Recall alone rewards a reviewer that never stops finding things. |

## Escalating

When cap or no-progress fires, do not send the human another patch. Send:

1. **The approach question** in one or two lines — not a task list.
2. **The two constraints that are in tension** (e.g. "the eval expects X but the API cannot return X without a schema change").
3. **What was tried**, one line per round, with the round number.
4. **Two candidate resolutions**, so the human picks rather than diagnoses.

That is a five-minute human decision. A fourth patch is another thirty minutes of agent time and usually a worse outcome.

## Nightly pass — optional, high value

Run the reviewer over existing code on a schedule, not just over PRs. It finds the old bugs the loop deliberately stopped chasing, at zero cost to the critical path, and gives you a backlog instead of blocking a merge.

## Bookkeeping

`scripts/loop.py` enforces the parts an agent will otherwise fudge: the round cap, and not re-posting a finding.

```bash
python3 scripts/loop.py start   --cap 5 --risk medium --feature "checkout retries"
python3 scripts/loop.py finding --tag auth:unchecked-index --severity important --file src/pay.ts --line 42
python3 scripts/loop.py round   --verdict fail
python3 scripts/loop.py status
```

Non-zero exits are load-bearing — wire them into a hook or a wrapper so "the loop is over budget" cannot be talked past: `3` duplicate finding, `4` cap exceeded, `5` no progress.
