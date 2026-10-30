# REVIEW.md and the reviewer's finding taxonomy

`CLAUDE.md` tells the reviewer what the project *is*. `REVIEW.md` tells it **what matters in this part of the code**. Two different jobs; do not merge them.

**It is not read by default.** A file that exists is not a file that loads. If you want a review command or agent to follow these rules, put `REVIEW.md` in the project root and **link or import it from `CLAUDE.md`** (`@REVIEW.md`). Then it loads with `CLAUDE.md` in every new session. Keeping the rules in a separate file rather than pasting them into `CLAUDE.md` is the right call — it loads the same way and stays readable.

Test it: open a fresh session and ask what review rules it has. If it cannot answer, the file never loaded.

`REVIEW.md` is written by the code owner and read on every review, so length is the enemy. The good ones are under a page. A file that grows into documentation stops being read, and an ignored rule is worse than no rule — it looks like coverage.

## The four content moves

1. **Name what failure looks like here.** Not "be careful with config" but "config failure means it misroutes." For docs: "failure is that it lies." For an API: "failure is a silently dropped field." This single line does more work than a page of guidelines, because it gives the reviewer a concrete thing to look for.
2. **Say how serious each kind of problem is.** A short table mapping problem type to severity — data loss and cross-user exposure block unconditionally; degraded-but-recoverable is a nit unless it is on a hot path. Without this the reviewer grades everything the same and you drown in equal-weight findings.
3. **Cap the nits, and list paths to skip.** A number for nits (they are how a review becomes an infinite loop with an agent author), and explicit skips for generated code, vendored code, lockfiles, fixtures.
4. **Say how the app should be tested.** The commands that prove it works, the ones that prove the UI renders, how to reach the other screen states, the mobile viewport. The reviewer uses these; otherwise it reviews by reading only.

Plus: require a summary that **starts with a count** and says plainly when there is nothing to fix. Padding a clean review with reassurance wastes the reader's attention and trains them to skim.

## Finding taxonomy

Every posted finding gets exactly one tag:

| Tag | Meaning | Effect |
|---|---|---|
| **Important** | Would cause wrong behavior, data loss, a security issue, or a broken contract. | Blocks merge. Must be fixed or explicitly declined with a reason. |
| **Nit** | True but cosmetic or a preference. | Capped per review. Never blocks alone. |
| **Pre-existing** | Real bug, but the diff did not introduce it. | Does not block; does not read as the author's fault. Can be filed as a follow-up. |

**Pre-existing is not a downgrade of severity — it is an attribution.** Without it, a reviewer surface-scanning a file reports old bugs as if the author caused them, the author spends rounds defending unrelated code, and the review loses credibility. The tag costs one word and saves whole rounds.

## Noise filters — drop before posting

Filter out, then tune the filters against real PRs before trusting them:

- **Style and formatting** — the formatter already owns this. A reviewer comment on it is pure duplication.
- **Cleanup and "consider extracting" suggestions** — additions to scope, not defects.
- **Diagnostics and lint-adjacent remarks** — the linter said it first, for free.
- **Anything about untouched code** unless it is Important *and* pre-existing.

Filtering is not laziness. **Noise costs more when the author is an agent.** A human dismisses a nit in two seconds; an agent dutifully fixes it, which is a commit, which is a round, which is another review. Three nits can add more wall-clock time than the one real bug the review found.

## Measure the noise, don't estimate it

It is trivial to catch more bugs by flagging more non-bugs, so recall alone is not a signal. Two measurements keep the reviewer honest:

1. **Sort every comment by what the author did with it:** fixed / said it was wrong / said the behavior was intentional / decided it didn't matter. The last three are the noise sample.
2. **Run the reviewer on PRs known to be clean** and count findings that would have led someone to make a harmful change.

Then the priority order, written down where the reviewer can see it: **catch real bugs first, cut review rounds second.** Optimising rounds first produces a reviewer that says nothing.

## What the reviewer actually reads

- The **diff**, against the **whole repo** — a change that is locally correct can still break a caller.
- The **stated intent** — the PR body or the original request. Ask: does this change solve its problem, fit the system, or break something else?
- On a **bug fix**, is the root cause the thing that was fixed? A fix at the symptom is a finding.

## The "Rules learned over time" section

Keep a section with that heading at the **bottom** of `REVIEW.md`. It is the file's memory, and it is the only part that makes the reviewer better rather than just busier.

**Why it exists:** the agent does not remember last session's mistake, so it makes the same one on the next feature and you fix it again from scratch. Writing the rule down is what converts one correction into permanent behavior.

**Two sources, and both matter:**

| What happened | The rule to add |
|---|---|
| a review **missed** a bug that surfaced later | what the reviewer should have looked for |
| a review **flagged** something that turned out to be fine | what it should stop flagging |

The second one is the one teams skip, and it is half the value. A reviewer that only accumulates "look harder" rules becomes noisier every week; one that also accumulates false-positive rules stays usable.

**How a rule gets added:**

1. The loop notices the same problem recurring across rounds or features (matching the new finding to the earlier one is exactly what a state file buys you).
2. It **suggests** a one-line rule — not a paragraph, not a rewrite.
3. It adds the rule **only when you approve**.

Approval is not bureaucracy. An agent that can silently write its own review criteria can also silently write itself an easier bar. You want the human in the loop precisely at the point where the standard moves.

When a learned rule starts repeating, promote it out of prose: a lint rule or a check is cheaper, always on, and cannot be forgotten in a context window.

## When to escalate REVIEW.md to CLAUDE.md

| The rule is about | Goes in |
|---|---|
| stack, conventions, goals and non-goals, "don't do X here" | `CLAUDE.md` |
| how a review of *this area* should behave, what its failure mode is | `REVIEW.md` |
| a bug class that keeps appearing | a lint rule — cheaper and always on |
| a check that must never be skipped | a hook or CI, not prose |
