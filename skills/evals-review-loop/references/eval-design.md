# Writing evals that can actually fail

An eval is a **command the agent can run** plus an **observable it must produce**. Not a paragraph of intent, not a checklist item a human ticks.

## The red-first rule

An eval must be observed failing *before* the feature exists. This is the single rule that separates this process from attestation theater.

```
1. Write the eval.
2. Run it against the current (unbuilt) tree.   → must FAIL
3. Paste or log that failure in eval.md.
4. Only now let the builder write code.
5. Run it again.                                → must PASS
```

If step 2 passes, the eval is not testing your feature. Either it asserts something that was already true, or it asserts nothing. Rewrite it.

Why this is not pedantry: tests written after the code assert what the code already does. They are a description of the implementation wearing a test's clothes. Only a red observation proves the eval is coupled to the new behavior.

## Match the check to the domain

"Give the agent something it can run" looks different in every domain. Pick the cheapest observable that genuinely moves.

| Domain | Runnable check |
|---|---|
| CLI / library | command + exit code + stdout substring |
| API | request + status + a field assertion on the response body |
| Data / migration | query the DB, assert the row, assert the count |
| UI | browser automation to a screenshot, diff against the design mockup |
| Mobile | simulator run + screenshot, or an instrumented UI test |
| Perf-sensitive | a timing budget with a generous threshold, run 3× |
| Config / infra | plan/dry-run output diffed against expectation |

If you cannot name a command, the requirement is not yet specified. Go back to the requirement before writing the eval.

## Model-graded evals — last resort

Use a command when you can. When you genuinely cannot (tone, a visual judgment, "is this explanation correct"), grade with a model, and treat it as a fallible sensor:

- **Fix the model and the prompt.** A graded eval that changes graders cannot be compared across runs.
- **Force quoted evidence.** The grader must quote the text it judged. Unquoted verdicts are unreviewable.
- **Binary verdicts, one requirement per call.** "Score 1–10 on everything" produces noise.
- **Keep a hand-labelled sample.** Ten graded cases you have personally reviewed; re-check them whenever the prompt changes.
- **Prefer a structural proxy.** "Contains all five required sections" is a command (`grep`), not a judgment.

## Anti-patterns

| Anti-pattern | Why it fails |
|---|---|
| Asserting an internal call count or private method | Pins the implementation; the eval breaks on every refactor and tests nothing the user sees. |
| Copying the implementation's logic into the eval | Two copies of the same bug agree with each other. |
| Snapshot-only for a new behavior | A regenerated snapshot blesses whatever the code now does. |
| An eval that needs the network or a live third party | Flaky; gets skipped; skipped checks are not checks. |
| "It builds" as the only eval | The build was green before the feature too — it is not red-first capable. |
| Twelve evals for one requirement | Nobody reads them, so nobody notices the three that are wrong. |

Aim for **one eval per requirement**, not per function. If a requirement needs five evals, it is probably three requirements wearing a coat.

## Evals from incidents — the compounding loop

Any bug that escaped becomes a permanent eval:

1. Take the PR or commit that caused the revert or incident.
2. Reconstruct the pre-fix state (the fix-forward or revert diff gives it to you).
3. Have someone who knows that code confirm the bug and where it lived.
4. Write an eval that fails on the pre-fix state and passes after.
5. Run that set whenever the reviewer's prompt, tools, or model change — a reviewer change is a code change and needs the same red-green discipline.

This set is worth more than any hand-written suite because every entry is a real, previously-undetected escape.

## Keeping eval.md honest

`eval.md` is a working document, not a certificate. State plainly:

- which evals are currently red, and why;
- which requirements have no eval yet (an explicit gap beats a silent one);
- the exact command, so a human can re-run it in one paste.

Fill it from [the template](../templates/eval.md).
