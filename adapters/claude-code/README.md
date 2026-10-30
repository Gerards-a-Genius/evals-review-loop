# Claude Code adapter

The strongest of the adapters, because Claude Code is the only host here with a **pre-tool hook that
can deny a call**. Both gates are real:

| gate | hook | effect |
|---|---|---|
| **Build gate** | `PreToolUse` on `Edit\|Write\|MultiEdit\|NotebookEdit\|Bash` | product-source writes are denied until the feature's `eval.md` is approved at `HEAD` |
| **Completion gate** | `Stop` | the turn cannot end claiming a feature is done while any approved check is not `PASS`; failing check IDs are named |
| Session reminder | `SessionStart` | says whether the gate is armed, approved, or blocked |

Both are registered with `onFailure: "block"` — a hook that cannot start fails **closed**, not open.
The gate is **inert** unless the repo root contains `.evals-loop`, which a human creates.

## Install

### As a plugin (recommended)

```bash
claude plugin marketplace add Gerards-a-Genius/evals-review-loop
claude plugin install evals-review-loop@evals-review-loop
```

The plugin ships `hooks/hooks.json`, which registers the same gates for every project it is enabled
in — safe precisely because the gate does nothing until a repo is armed.

### Into one project

```bash
node adapters/claude-code/install.mjs /path/to/your/repo
```

Copies `eval-gate.mjs` and `stop-gate.sh` into `<repo>/.claude/hooks/`, then **merges** the hook
registrations into `<repo>/.claude/settings.json`. It preserves keys it did not create and is a no-op
on re-run. Inspect the diff before you commit it.

## Files

- `settings.hooks.json` — the merged hook block, for reference or manual installation.
- `install.mjs` — the installer described above.
- `CLAUDE.md-snippet.md` — verification instructions plus the `@REVIEW.md` import. **Without that
  import, `REVIEW.md` is never loaded**, which silently disables every review rule you wrote.

## Arming and approving

```bash
# arm a repo (a human does this, once)
touch .evals-loop

# approve a feature's eval at the current commit (a human does this, in their own shell)
f=specs/features/fr-11/eval.md; sha=$(git rev-parse HEAD); sed -i.bak -E \
  "s#^\| \*\*Eval status\*\* \|.*\|#| **Eval status** | Approved |#;s#^\| \*\*Approved\*\* \|.*\|#| **Approved** | $(git config user.name || echo human), $(date -u +%F) · sha:${sha} |#" "$f"
```

Move `HEAD` and the gate re-closes: the approval is bound to one commit.

## Verify it is live

Use `/hooks` in a session to confirm the two registrations, then try an edit while a feature is
unapproved — it should be refused with a message naming the eval file and the approval one-liner.
A hook that cannot run is not a gate.

## Tests

```bash
bash test/harness/run-tests.sh      # 68 assertions over this adapter's wiring and the shared core
```
