// Copy into the target project's CLAUDE.md, or merge into an existing one.
// The only load-bearing line is the @REVIEW.md import near the bottom.

## Verification

- Do not claim a feature is done because the code looks right. Run the check and
  show the output. A feature is done when every check in its `eval.md` is `PASS`.
- Write the eval before the implementation. Observe every check **failing** first;
  an eval that already passes is not testing the feature.
- The evals gate is armed by `.evals-loop` in the repo root. While a feature's eval
  is unapproved, product-source edits are blocked — that is intended, not a bug.

## Where the detail lives

- `REVIEW.md` — how to review a change in this codebase
- `specs/features/fr-<NN>/eval.md` — the checks for the current feature
- `specs/features/fr-<NN>/rd.md` — its requirements

## Review rules

The review rules live in `REVIEW.md` and are **not loaded by default**. The import
below is what loads them, every session. Without it, `REVIEW.md` is never loaded — a rule that is
never loaded is worse than no rule, because it looks like coverage.

@REVIEW.md
