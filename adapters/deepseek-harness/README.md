# DeepSeek Harness adapter

The harness exposes a tool-call waterfall that can **allow / deny / cancel / ask** before a tool
runs, so the build gate is genuinely enforceable here — not merely observable. The completion gate is
weaker, and this README is explicit about how.

## Verified API facts

These were read from the DSH source in this workspace (`packages/core/tools/src/index.ts`,
`packages/experimental/auto-review/src/index.ts`), not inferred:

**`tools/pre-execute`** — waterfall, "Allow, deny, cancel, or ask before dispatch."

```ts
'tools/pre-execute'(
  this: Scoped<ToolRuntime>,
  exec: ToolExecution,
  next: () => Promise<PreToolDecision>,
): Promise<PreToolDecision>
```

**`PreToolDecision`**

```ts
export type PreToolDecision =
  | { kind: 'allow' }
  | { kind: 'deny'; reason: string; info?: ToolErrorInfo }
  | { kind: 'cancel' }
  | { kind: 'ask'; reason?: string; displayReason?: { readonly en: string; … } }
```

**`ToolExecution`** exposes what the gate needs: `name` (tool name) and `arguments` ("losslessly
JSON-serializable parsed arguments"), plus `agent`, `parent`, and `signal`.

`packages/experimental/auto-review` is an in-repo precedent — a real pre-execute gate that returns
`{ kind: 'deny', … }` with a reason.

## What is here

`dsh-gate.mjs` is the **whole decision**, factored out so it can be tested without a running
profile:

```bash
echo '{"name":"write_file","arguments":{"file_path":"src/app.ts"}}' | node dsh-gate.mjs
# {"kind":"allow"}                                  (repo not armed)
# {"kind":"deny","reason":"BLOCKED — implementation writes are gated…"}
```

It maps the host's tool names onto the gate's neutral vocabulary (`write` / `edit` / `bash` / `read` /
`other`), extracts the target path or shell command from `arguments`, calls the shared core, and
returns a valid `PreToolDecision`. A misconfiguration returns **deny**, never allow.

Verified against the real core:

| case | result |
|---|---|
| repo not armed | `allow` |
| armed, eval unapproved, product write | `deny` with the reason |
| armed, unapproved, writing its own `eval.md` | `allow` |
| `read_file` | `allow` |
| malformed stdin | `deny` (fails closed) |

## The listener

`apply()` in a Cordis plugin is then small:

```js
import { spawnSync } from 'node:child_process'
import path from 'node:path'

export const name = 'evals-gate'

export function apply(ctx) {
  ctx.effect(function* () {
    ctx.on('tools/pre-execute', async (exec, next) => {
      const payload = JSON.stringify({ name: exec.name, arguments: exec.arguments })
      const r = spawnSync(process.execPath,
        [path.join(import.meta.dirname, 'dsh-gate.mjs')],
        { input: payload, encoding: 'utf8' })
      const out = (r.stdout || '').trim()
      if (!out) return { kind: 'deny', reason: 'evals gate produced no decision; failing closed' }
      return JSON.parse(out)          // { kind: 'allow' } | { kind: 'deny', reason }
    })
  })
}
```

Returning a decision instead of calling `next()` short-circuits the waterfall, which is how a deny
takes effect.

## What this enforces, and what it does not

| | status |
|---|---|
| **Build gate** — no product-source writes before approval | **Enforced** via `tools/pre-execute` returning `deny` |
| Build gate honours `.evals-loop`, approval sha bound to HEAD, its own artifacts writable | **Enforced** — same core code as every other adapter |
| **Completion gate** — cannot claim a feature done while a check fails | **Not enforced yet.** `agent/turn-stopping` is a `serial` listener returning `Promise<void>`, so it can delay or throw but cannot cleanly refuse a turn the way a Claude Code `Stop` hook can. The honest options are (a) inject the failing check IDs into the model's context every step via `agent/pre-step` (waterfall, message replacement), so "done" is stated in front of the evidence, or (b) accept that the dispatcher layer surfaces it instead. Work out which this harness supports before claiming either. |
| Writes performed through arbitrary shell commands to product source | **Not classified.** The gate denies shell writes that touch its own guardrails; it does not parse every `bash` command to infer filesystem targets. Documented in the core. |

## Not shipped here

A full `package.json` + `cordis.patch.yml` bundle for installing this as a profile plugin. Those
need the composition dialect, which is `editing-cordis-compositions` territory, and a guessed patch
is worse than none. The listener above is the part that is easy; the packaging is the part that
should be written against the current reference.

Until then, the gate is usable directly: `dsh-gate.mjs` is a complete decision function, and the
probe commands above prove it.
