#!/usr/bin/env node
// adapters/claude-code/install.mjs — install the evals gate into ONE Claude Code project.
//
//   node adapters/claude-code/install.mjs /path/to/your/repo [--force]
//
// Copies the gate into <repo>/.claude/hooks/ and MERGES the hook registrations into
// <repo>/.claude/settings.json. Existing settings are preserved: it never overwrites a
// key it did not create, and re-running is a no-op. Nothing is armed — the gate is inert
// until a human runs `touch .evals-loop` in the repo.

import { readFileSync, writeFileSync, mkdirSync, cpSync, existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CORE = path.resolve(HERE, '..', '..', 'hooks', 'core');

const args = process.argv.slice(2);
const force = args.includes('--force');
const target = args.find((a) => !a.startsWith('--'));

if (!target) {
  console.error('usage: node install.mjs <project-root> [--force]');
  process.exit(1);
}
const root = path.resolve(target);
if (!existsSync(root)) {
  console.error(`error: ${root} does not exist`);
  process.exit(1);
}

// ---------- 1. copy the gate -------------------------------------------------
const hooksDir = path.join(root, '.claude', 'hooks');
mkdirSync(hooksDir, { recursive: true });
const files = [
  ['eval-gate.mjs', path.join(CORE, 'eval-gate.mjs')],
  ['stop-gate.sh', path.join(CORE, 'stop-gate.sh')],
];
for (const [name, src] of files) {
  if (!existsSync(src)) {
    console.error(`error: missing ${src} — is this adapter inside the repo it shipped in?`);
    process.exit(1);
  }
  const dest = path.join(hooksDir, name);
  if (existsSync(dest) && !force) {
    console.log(`keep  .claude/hooks/${name} (exists; --force to replace)`);
  } else {
    cpSync(src, dest);
    console.log(`write .claude/hooks/${name}`);
  }
}

// ---------- 2. merge the hook registrations ----------------------------------
const settingsPath = path.join(root, '.claude', 'settings.json');
let settings = {};
if (existsSync(settingsPath)) {
  try {
    settings = JSON.parse(readFileSync(settingsPath, 'utf8'));
  } catch (e) {
    console.error(`error: ${settingsPath} is not valid JSON (${e.message}); refusing to touch it.`);
    process.exit(1);
  }
}

const H = 'node "$CLAUDE_PROJECT_DIR"/.claude/hooks/eval-gate.mjs';
const wanted = {
  PreToolUse: [
    {
      matcher: 'Edit|Write|MultiEdit|NotebookEdit|Bash',
      hooks: [{ type: 'command', command: `${H} check`, statusMessage: 'Checking evals gate…', timeout: 15, onFailure: 'block' }],
    },
  ],
  Stop: [
    { hooks: [{ type: 'command', command: `${H} stop`, statusMessage: 'Checking evals before finishing…', timeout: 1800, onFailure: 'block' }] },
  ],
  SessionStart: [
    { hooks: [{ type: 'command', command: `${H} --remind`, timeout: 15 }] },
  ],
};

settings.hooks = settings.hooks && typeof settings.hooks === 'object' ? settings.hooks : {};
let added = 0;
for (const [event, groups] of Object.entries(wanted)) {
  const existing = Array.isArray(settings.hooks[event]) ? settings.hooks[event] : [];
  const already = JSON.stringify(existing).includes('eval-gate.mjs');
  if (already && !force) {
    console.log(`keep  hooks.${event} (evals gate already registered)`);
  } else {
    settings.hooks[event] = already ? existing : [...existing, ...groups];
    added++;
    console.log(`write hooks.${event}`);
  }
}

if (added === 0) {
  console.log('\nnothing to change — already installed.');
} else {
  writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + '\n');
  console.log(`write .claude/settings.json`);
}

// ---------- 3. tell the human the two strings --------------------------------
console.log(`
Installed. The gate is INERT until you arm it.

  arm this repo        touch .evals-loop
  approve an eval      f=specs/features/fr-11/eval.md; sha=$(git rev-parse HEAD); \\
                       sed -i.bak -E "s#^\\| \\*\\*Eval status\\*\\* \\|.*\\|#| **Eval status** | Approved |#;s#^\\| \\*\\*Approved\\*\\* \\|.*\\|#| **Approved** | $(git config user.name || echo human), $(date -u +%F) · sha:\${sha} |#" "$f"

Verify in-session with /hooks, then try an edit while a feature is unapproved.
`);
