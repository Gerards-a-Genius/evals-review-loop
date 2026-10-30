# CLAUDE.md — <project>

<!-- Keep this SHORT. It loads on every turn and every review.
     Detail goes in linked docs; this file is the table of contents + the rules that must never be broken. -->

## What this is

<one or two sentences: what the project does and who uses it>

## Stack

- <language / framework / runtime>
- <test runner and the exact command>
- <build command>
- <formatter and linter>

## Conventions

- <the three or four that actually matter>
- <naming, file layout, error handling — only if an agent would plausibly get it wrong>

## Goals / non-goals

- Goal: <...>
- Not a goal: <...> <!-- non-goals prevent scope creep better than goals do -->

## Rules that are not negotiable

- Verify before claiming done: run the check and show the output. The checks live in `specs/features/fr-<NN>/eval.md`.
- Do not edit generated files.
- The review rules are loaded by the `@REVIEW.md` import below. Without that line the review rules are never loaded — a `REVIEW.md` that merely exists on disk is never read.
- The evals loop is armed by a human with `touch .evals-loop`; agents never create or remove it.

## Imports

<!-- `@path` is a real import, not a mention. THIS line is what loads the review rules. -->
@REVIEW.md

## Where the detail lives

- `REVIEW.md` — how to review this codebase (loaded above by `@REVIEW.md`)
- `specs/features/fr-<NN>/eval.md` — the current feature's eval table
- `specs/features/fr-<NN>/rd.md` — its requirements
- `docs/` — architecture and decisions
