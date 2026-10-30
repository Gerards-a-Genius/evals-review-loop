# REVIEW.md — <repo or area>

<!-- This file is NOT loaded by default. Link it from CLAUDE.md (e.g. an @REVIEW.md import)
     so it loads in every session and the review command actually follows it.
     Keep it under a page — it is a recurring token cost, not a one-time write. -->

Reviewer: read this before the diff.

## What counts as a real failure here

- **<area>**: failure is <the specific wrong outcome>.
- **<area>**: failure is <the specific wrong outcome>.

<!-- Examples that work:
  docs    → failure is that it lies.
  config  → failure is that it misroutes.
  api     → failure is a silently dropped or coerced field.
  billing → failure is a double charge, or a missed one.
  auth    → failure is one user reaching another user's data.
-->

## How serious is each kind of problem

| Kind | Severity |
|---|---|
| wrong output for valid input | Important |
| data loss or corruption | Important — blocks, always |
| cross-user data exposure | Important — blocks, always |
| a path that cannot be undone | Important — blocks, always |
| degraded but recoverable behavior | Nit unless it is on a hot path |
| naming, structure, taste | Nit, capped, often not worth posting |

## How to test this app

- <the command that proves it works>
- <the command that proves the UI renders>
- <how to reach the other screen states>
- <the mobile viewport to check>

## Never report

- Style and formatting — the formatter owns it.
- Cleanup and refactor suggestions.
- Diagnostics the linter already prints.
- Anything outside the diff, unless it is Important **and** tagged Pre-existing.

## Skip these paths

- `generated/**`
- `vendor/**`
- `*.lock`, `*.snap`

## Evidence rules

- Every finding needs a file and a line. No guesses inferred from a symbol name.
- Keep nits to **<N>** per review. Beyond that, stop and say so instead of padding.
- Tag every finding **Important**, **Nit**, or **Pre-existing**. Pre-existing means the diff did not introduce it.

## Summary format

First line is a count: `2 important, 1 nit`. If there is nothing to fix, the first line is `No blocking findings.` — plainly, without an apology paragraph.

## Escalation

If round > 3, or the same problem survives two rounds of fixes, stop reviewing the diff and ask the author to reconsider the approach. Do not post another patch-level finding.

---

## Rules learned over time

<!-- Append here, one line each, and only after a human approves. Two sources:
       - a review MISSED a bug that surfaced later      → the rule that would have caught it
       - a review FLAGGED something that turned out OK   → the rule that stops the false positive
     Keep every line short enough to act on. Promote a rule to a lint check when it repeats. -->

- <rule>
- <rule>
