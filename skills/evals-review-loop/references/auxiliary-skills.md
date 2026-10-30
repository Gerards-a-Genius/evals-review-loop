# The five skills that run the loop

`SKILL.md` carries the process; these carry it out. Each is a `SKILL.md` in `.claude/skills/<name>/` with frontmatter — `description` is what makes it fire, so write the triggers, not just the purpose. The prompts below are skeletons: the value is in the **outputs and guardrails**, not the wording.

```
.claude/
├── skills/
│   ├── rate-risk/SKILL.md
│   ├── write-evals/SKILL.md
│   │   └── template.md          ← gives every eval.md the same structure
│   ├── review-loop/SKILL.md
│   ├── first-time-user/SKILL.md
│   └── fix-a-bug/SKILL.md
├── agents/                      ← builder, verifier, reviewer (fresh contexts)
├── hooks/
│   └── eval-gate.mjs            ← one script, two modes: linter + Stop gate
└── settings.json
specs/features/fr-<NN>/
├── rd.md                        requirements
├── eval.md                      the checks  (output of write-evals)
├── mockup.html                  design target, when there is a UI
└── state.md                     the loop's round + failures
```

The four skill files above ship paid in AI Labs Pro; these are reconstructions from the demonstrated behaviour, not copies.

---

## 1 · `rate-risk` — one question, before you build

**Fires when:** a feature is about to be built and has no risk tier.

**The question:** *what happens to a customer if this feature breaks?*

**Output:** a `Risk:` row in `specs/features/fr-NN/eval.md` (and in `rd.md`).

See the tier table in [SKILL.md](../SKILL.md) — it is not repeated here, because two copies drift.

**Rules:**
- Ask about the **change**, never the author. Anthropic uses a classifier agent rather than self-assessment; if you let an agent pick, do not let the *builder* pick.
- Ambiguous between two tiers → take the higher.
- Any irreversible outcome is high, regardless of diff size.

**Hand-off:** pass the tier into `write-evals`. This is the part people skip: `/write-evals checkout --risk high` produces a stricter, longer eval set (the demo shows `12 checks · strict` at high, versus a short set at low) and that strictness is the tier's real cost.

---

## 2 · `write-evals` — the gate

**Fires when:** a feature folder exists with `rd.md` and no `eval.md`.

**Does:**
1. Read `specs/features/fr-NN/rd.md` and the risk tier.
2. Write `specs/features/fr-NN/eval.md` from `template.md`, using the front table and the check-ID scheme in [the template](../templates/eval.md). The evals must cover three things: **every way to use the feature, every way it can fail, and what adding it must not break.**
3. Write `specs/features/fr-NN/mockup.html` when the feature has a design — a plain static page, the design target. Render it full-width **and** at mobile width, and show the other screen states, so layout is judged before implementation tokens are spent.
4. **Lint it:** `node .claude/hooks/eval-gate.mjs lint fr-NN`. A malformed eval — a mockup linked but missing, a check with no `Result:` line — is caught here, before a human ever looks.
5. Run every check against the unbuilt tree and record the failures in the red-evidence section. Each must be red.
6. Set `Eval status: Draft → In review`, then **stop and ask**.

**The ask, and the only approval that counts:**

> "Do you approve the eval, or what should I change? Once you say yes, I'll mark it approved,
> record the perf baseline, and start building."

A human types `yes`. The agent then writes `Eval status: Approved` and `Approved | <name>, <date> · sha:<commit>` into `eval.md`, records the baseline, and builds.

**Guardrail:** the agent must never write the `Approved` row itself. If it can, the gate is decorative — that is the one write to block, and to block through the shell as well as the file tools.

**It does not implement.** It writes `eval.md` and `mockup.html` and nothing else.

---

## 3 · `review-loop` — the orchestrator

**Fires when:** a feature is approved and ready to build.

The main agent is the orchestrator; it spawns three subagents, each in a **fresh context window**, and writes `state.md` before round one.

| Agent | Does | Must not |
|---|---|---|
| **builder** | builds from `rd.md` and the eval, nothing else | write evals or tests; make a product decision above its authority — it stops and says so |
| **verifier** | runs every check against a production build; marks each `Result: PASS` / `FAIL: …` | opine on the code |
| **reviewer** | reads the diff against `REVIEW.md` to find what the evals missed | see the builder's reasoning or summary |

A round is: build → verify every eval (in a browser, for UI) → review the code. The loop stops when **all evals pass and the review finds nothing new**, or at the cap, or on a stall — see the stop conditions in [SKILL.md](../SKILL.md).

When it hits a decision it cannot make, it stops and shows a **progress report** asking the human, rather than guessing.

---

## 4 · `first-time-user` — catches what evals structurally cannot

**Fires when:** evals are green and you want to know what a real user hits.

**Does:**
1. **Preflight** — make a run folder per visit, `e2e/evidence/first-time-user/<date>-<hhmm>/`, with one subfolder per visitor (`v1/`, `v2/`), gitignored.
2. **Throwaway data** — back up `data/`, wipe it, reseed. The contract is that the user's `data/` comes back exactly as it was, whatever happens.
3. Start the app against that copy and open the live page.
4. Spawn a subagent that knows nothing about the app and instructs it to accomplish a normal task as a first-time user, narrating every confusion, dead end and ambiguous control.
5. Wait, collect, and write `report.md` — plus each visitor's own write-up in its subfolder.
6. **Restore `data/` and stop the test server.** The run is not finished until both are done.
7. Report the friction points, ranked, and propose a fix list that traces each stuck point to its code, its `rd.md` line and the exact copy the visitor could not see. Apply only what you approve.

**The guardrail is the interesting part.** The agent will otherwise read the source and stop being confused by anything — and if you block only the file tools, it reaches for `cat`/`grep`/`git log`. So block **both**: file reads on the project source, *and* shell commands that read it. Knowledge leaks through the cheapest path you forgot, so assume it will try one.

**Closing checklist** (written into the report): every screenshot the visitor cited exists; the test server is stopped; `data/` is restored.

**Output:** a ranked friction report with proposed fixes. Not a pass/fail — a human reads it.

---

## 5 · `fix-a-bug` — reproduce, confirm, then fix

**Fires when:** a feature is not behaving as intended and the cause is unknown.

**Does, in this order — do not reorder:**

1. **Reproduce.** Replay the exact steps and observe the bug. If you cannot reproduce it, stop and report that; a fix for an unreproduced bug is a guess.
2. **Hypothesize.** State the cause as a single falsifiable sentence.
3. **Confirm before fixing.** Make the specific observation that would be true only if the guess is right. If it is not true, go back to 2 — do not patch anyway.
4. **Report** the problem and its cause.
5. **Fix the cause**, at the class level: find every other place the same mistake appears.
6. **Prove it.** The reproduction now passes, and the full eval set still passes.

**Why step 3 exists:** confident guessing is the failure mode. An agent that skips it produces a plausible diff, the symptom sometimes vanishes by accident, and the real bug returns later in a different shape.

**Version history is the prerequisite.** `CLAUDE.md` must instruct: **use Git, one branch per feature (`feat/fr-11-reschedule`), commit every working version.** Then "it used to work" becomes a search — walk the saved versions, find the first bad one, read that diff — and rolling back is one action. Without this, step 1 has nothing to replay against.

**Output:** a confirmed cause, a minimal fix, and a regression check added to `eval.md` so the bug cannot come back silently.

---

## Composing them

```
rate-risk → write-evals → [human: "yes"] → review-loop (builder → verifier → reviewer)
                                                  │
                                        evals green ┘
                                                  ↓
                          first-time-user + fix-a-bug + revert path
                                                  ↓
              recurring finding → one line in REVIEW.md (human approves)
```

Each skill is small on its own. Together they mean the agent can never be the sole judge that the work is done.
