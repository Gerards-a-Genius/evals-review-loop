#!/usr/bin/env node
// adapters/codex/install.mjs — install the evals gate into one Codex CLI project.
//
//   node adapters/codex/install.mjs /path/to/your/repo [--force]
//
// Codex CLI reads project hooks from <repo>/.codex/hooks.json, using the SAME
// schema as Claude Code: { hooks: { <Event>: [ { matcher?, hooks: [ {type, command, …} ] } ] } }.
//
// What Codex gets, and why it is less than Claude Code:
//   Stop              → the completion gate. Real enforcement of "cannot claim done".
//   UserPromptSubmit  → injects the gate state as context, so the model states "done"
//                       in front of the evidence. Soft: it informs, it does not block.
//   PreToolUse        → does NOT exist in Codex. There is no way for a hook to deny a
//                       write, so the build gate cannot be enforced here. Codex's own
//                       sandbox/approval layer is what stops writes.
//
// The gate is inert until a human runs `touch .evals-loop` in the repo.

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

// 1. copy the gate next to the hooks, inside the repo
const hooksDir = path.join(root, '.codex', 'hooks');
mkdirSync(hooksDir, { recursive: true });
for (const name of ['eval-gate.mjs', 'stop-gate.sh']) {
  const src = path.join(CORE, name);
  if (!existsSync(src)) {
    console.error(`error: missing ${src} — is this adapter inside the repo it shipped in?`);
    process.exit(1);
  }
  const dest = path.join(hooksDir, name);
  if (existsSync(dest) && !force) {
    console.log(`keep  .codex/hooks/${name} (exists; --force to replace)`);
  } else {
    cpSync(src, dest);
    console.log(`write .codex/hooks/${name}`);
  }
}

// 2. merge hook registrations. Absolute paths: Codex does not document a
//    project-dir variable for hook commands, so bake the path in.
const gate = path.join(hooksDir, 'eval-gate.mjs').replace(/\\/g, '/');
const wanted = {
  Stop: [
    {
      hooks: [
        {
          type: 'command',
          command: `node '${gate}' stop`,
          timeout: 1800,
          statusMessage: 'Checking evals before finishing…',
        },
      ],
    },
  ],
  UserPromptSubmit: [
    {
      hooks: [
        {
          type: 'command',
          command: `node '${gate}' --remind`,
          timeout: 15,
          additionalContextLimit: 1200,
          statusMessage: 'Checking evals gate…',
        },
      ],
    },
  ],
};

const hooksPath = path.join(root, '.codex', 'hooks.json');
let doc = {};
if (existsSync(hooksPath)) {
  try {
    doc = JSON.parse(readFileSync(hooksPath, 'utf8'));
  } catch (e) {
    console.error(`error: ${hooksPath} is not valid JSON (${e.message}); refusing to touch it.`);
    process.exit(1);
  }
}
doc.hooks = doc.hooks && typeof doc.hooks === 'object' ? doc.hooks : {};

let changed = 0;
for (const [event, groups] of Object.entries(wanted)) {
  const existing = Array.isArray(doc.hooks[event]) ? doc.hooks[event] : [];
  if (JSON.stringify(existing).includes('eval-gate.mjs') && !force) {
    console.log(`keep  hooks.${event} (already registered)`);
    continue;
  }
  doc.hooks[event] = existing.concat(groups);
  changed++;
  console.log(`write hooks.${event}`);
}

if (changed === 0) {
  console.log('\nnothing to change — already installed.');
} else {
  writeFileSync(hooksPath, JSON.stringify(doc, null, 2) + '\n');
  console.log('write .codex/hooks.json');
}

console.log(`
Installed. The gate is INERT until you arm it.

  arm this repo   touch .evals-loop

Codex loads hooks.json only after it trusts the file. If the hooks do not fire,
run Codex once interactively and approve its hook-trust prompt — or, for
automation only, pass --dangerously-bypass-hook-trust.

Stop enforces "cannot claim done". There is no PreToolUse in Codex, so the
build gate cannot block a write here — see README.md.
`);
