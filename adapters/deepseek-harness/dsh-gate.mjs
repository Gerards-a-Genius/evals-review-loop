#!/usr/bin/env node
// adapters/deepseek-harness/dsh-gate.mjs
//
// The evals gate, expressed as a decision function for the DeepSeek Harness.
//
// DSH's `tools/pre-execute` is a waterfall that can allow / deny / cancel / ask
// before a tool runs. This script is the whole decision: hand it the tool call,
// get back a `PreToolDecision` on stdout. A Cordis listener is then ~8 lines
// (see README.md) — this file is where the logic lives so it can be tested
// without a live profile.
//
// INPUT  (stdin, JSON)   { "name": "<tool>", "arguments": { … } }
//                        or the raw ToolExecutionInput subset DSH provides.
// OUTPUT (stdout, JSON)  { "kind": "allow" }
//                        { "kind": "deny", "reason": "<why>" }
//
// Exit status is always 0 — the decision is in the JSON, matching DSH's
// waterfall contract. A misconfiguration returns deny, never allow.

import { spawnSync } from 'node:child_process';
import { readFileSync, existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CORE = path.resolve(HERE, '..', '..', 'hooks', 'core', 'eval-gate.mjs');

const ALLOW = { kind: 'allow' };
const deny = (reason) => ({ kind: 'deny', reason });
const emit = (d) => { process.stdout.write(JSON.stringify(d) + '\n'); process.exit(0); };

// DSH tool names → the gate's neutral vocabulary.
// Write-ish tools must be listed here; an unknown tool is passed through as
// `other` and the core decides (it ignores anything it does not gate).
function neutral(toolName) {
  const n = String(toolName || '').toLowerCase();
  if (/(^|_)(write|create)_file$/.test(n) || n === 'write' || n === 'write_file') return 'write';
  if (/(^|_)(edit|patch|replace|apply)_(file|text|patch)?$/.test(n) || n === 'edit' || n === 'str_replace') return 'edit';
  if (n === 'bash' || n === 'shell' || n === 'run_command' || n === 'terminal' || n === 'exec') return 'bash';
  if (n === 'read' || n === 'read_file' || n === 'grep' || n === 'glob') return 'read';
  return 'other';
}

// Pull a path or a command out of whatever argument shape the tool uses.
function target(args) {
  if (!args || typeof args !== 'object') return {};
  const pick = (...keys) => {
    for (const k of keys) if (typeof args[k] === 'string' && args[k]) return args[k];
    return undefined;
  };
  return {
    path: pick('file_path', 'filePath', 'path', 'filename', 'notebook_path', 'target_file'),
    command: pick('command', 'cmd', 'script', 'shell_command'),
  };
}

let event;
try {
  const raw = readFileSync(0, 'utf8');
  event = raw && raw.trim() ? JSON.parse(raw) : null;
} catch {
  emit(deny('evals gate misconfigured: could not parse the tool call JSON. Failing closed.'));
}
if (!event || typeof event !== 'object') {
  emit(deny('evals gate misconfigured: no tool call received. Failing closed.'));
}

const toolName = event.name || event.tool || event.tool_name;
const args = event.arguments || event.args || event.tool_input || {};
const tool = neutral(toolName);
const { path: filePath, command } = target(args);

// Nothing to gate, and nothing the core would gate: allow immediately.
if (tool === 'read' || (tool === 'other' && !filePath && !command)) emit(ALLOW);

if (!existsSync(CORE)) {
  emit(deny(`evals gate misconfigured: ${CORE} is missing. Failing closed.`));
}

const argv = [CORE, 'check', '--tool', tool];
if (tool === 'bash' && command) argv.push('--command', command);
else if (filePath) argv.push('--path', filePath);

const r = spawnSync(process.execPath, argv, {
  encoding: 'utf8',
  cwd: process.env.CLAUDE_PROJECT_DIR || process.cwd(),
  timeout: 15000,
  env: process.env,
});

if (r.error) emit(deny(`evals gate misconfigured: could not run the core gate (${r.error.message}). Failing closed.`));
if (r.status === 0) emit(ALLOW);

// 2 (and anything unexpected) is a block. Surface the core's reason verbatim —
// it is written for a human and names the file and the fix.
const reason = (r.stderr || r.stdout || '').trim() || `evals gate denied this call (exit ${r.status}).`;
emit(deny(reason));
