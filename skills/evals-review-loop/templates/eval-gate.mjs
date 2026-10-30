#!/usr/bin/env node
// eval-gate.mjs — Gate A (PreToolUse) + the eval linter. Node stdlib only, no npm.
//
// FILES
//   eval-gate.mjs          Gate A: Edit|Write|MultiEdit|NotebookEdit|Bash, plus `lint <feature>`.
//   require-evals-pass.sh  Gate B: the Stop hook. A Stop event reaching this file is delegated
//                          to that sibling, so Gate B has exactly one implementation.
//
// CONTRACT
//   Arming is explicit and human-only: a HUMAN runs `touch .evals-loop` at the repo root.
//   Absent -> exit 0 (repo has not adopted the loop; stay out of the way).
//   Armed -> fail CLOSED (exit 2) on: no eval file, unapproved eval, stale approval,
//   unreadable hook event, or a target that cannot be resolved.
//   Approval lives INSIDE eval.md, bound to one commit:
//       | **Eval status** | Approved |
//       | **Approved** | <name>, <date> · sha:<git rev-parse HEAD> |
//   No sha, or a sha that is not a prefix of HEAD, is UNAPPROVED (it goes stale when HEAD
//   moves). A human records it in their own shell with:
//       f=specs/features/fr-11/eval.md; sha=$(git rev-parse HEAD); sed -i.bak -E \
//         "s#^\| \*\*Eval status\*\* \|.*\|#| **Eval status** | Approved |#;s#^\| \*\*Approved\*\* \|.*\|#| **Approved** | $(git config user.name || echo human), $(date -u +%F) · sha:${sha} |#" "$f"
//   Layouts: specs/features/fr-<NN>/eval.md (active = nearest feature dir from cwd, else all
//   of them) and a single root EVALS.md.
//   While unapproved the loop's own artifacts stay writable: specs/** (eval.md, rd.md,
//   mockup.html, e2e evidence), EVALS.md, rd.md, mockup.html, REVIEW.md, CLAUDE.md,
//   state.md, e2e/evidence/**. Everything else (product source) is blocked.
//   The agent may not author approval: an Edit/Write containing an `**Approved**` row is
//   allowed only when its sha is a prefix of HEAD AND the file already said
//   `Eval status = In review`. Bash writes to eval.md's Approved row, its sha, or
//   `.evals-loop` are denied.
//
// EXIT CODES  0 allow | 2 BLOCK (stderr is shown to the model) | lint: 0 well formed, 1 malformed.
//   Misconfiguration prints `BLOCKED — gate misconfigured: <reason>`; never a stack trace.
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
let ROOT = process.env.CLAUDE_PROJECT_DIR || process.cwd();
let MARKER = path.join(ROOT, '.evals-loop');
let JSON_MODE = false;
function setRoot(dir) {
  ROOT = path.resolve(String(dir));
  MARKER = path.join(ROOT, '.evals-loop');
}
const WRITE_TOOLS = ['Edit', 'Write', 'MultiEdit', 'NotebookEdit'];
const PROTECTED = ['.evals-loop', '.evals-approved', '.evals-commands'];
const HERE = path.dirname(fileURLToPath(import.meta.url));
const die = (msg, code = 2) => {
  if (JSON_MODE) process.stdout.write(JSON.stringify({ allow: false, code, reason: msg.trim() }) + '\n');
  process.stderr.write(msg.endsWith('\n') ? msg : msg + '\n');
  process.exit(code);
};
const readText = (f) => { try { return readFileSync(f, 'utf8'); } catch { return null; } };
const exists = existsSync;
const norm = (p) => p.split(path.sep).join('/'), relTo = (abs) => norm(path.relative(ROOT, abs));
const headSha = () => { try { return spawnSync('git', ['-C', ROOT, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).stdout.trim(); } catch { return ''; } };
const extractSha = (v) => { const m = /sha:([0-9a-fA-F]{7,40})/.exec(v || ''); return m ? m[1] : null; };
const isApproved = (s) => typeof s === 'string' && s.trim().toLowerCase() === 'approved';
const isInReview = (s) => typeof s === 'string' && /^in[ -]review$/i.test(s.trim());
const hasApprovedRow = (t) => String(t).split(/\r?\n/).some((l) => /^\s*\|\s*\*\*Approved\*\*/.test(l));
function rowValue(text, label) { // second cell of a markdown front-table row, or null
  const re = new RegExp('^\\s*\\|\\s*\\*\\*' + label.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\*\\*');
  for (const line of String(text).split(/\r?\n/)) {
    if (!re.test(line)) continue;
    const cell = line.split('|')[2];
    return cell === undefined ? null : cell.trim();
  }
  return null;
}
function activeFeatureEval() { // nearest specs/features/<feature> from cwd, if inside one
  const base = norm(path.join(ROOT, 'specs', 'features'));
  let p = norm(process.cwd());
  while (p === norm(ROOT) || p.startsWith(norm(ROOT) + '/')) {
    if (p.startsWith(base + '/')) {
      const rel = p.slice(base.length + 1);
      if (rel && !rel.includes('/')) return path.join(p, 'eval.md');
    }
    if (p === norm(ROOT)) break;
    p = path.dirname(p);
  }
  return null;
}
function resolveEvals() {
  const act = activeFeatureEval();
  if (act) return [act];
  if (exists(path.join(ROOT, 'EVALS.md'))) return [path.join(ROOT, 'EVALS.md')];
  const dir = path.join(ROOT, 'specs', 'features');
  if (!exists(dir)) return [];
  return readdirSync(dir, { withFileTypes: true }).filter((d) => d.isDirectory())
    .map((d) => path.join(dir, d.name, 'eval.md')).filter(exists);
}
function approvalProblem(file) { // null when approved at HEAD, else missing|status:<v>|no-sha|no-git-head|stale:<sha>
  if (!exists(file)) return 'missing';
  const text = readText(file) || '';
  const status = rowValue(text, 'Eval status');
  const sha = extractSha(rowValue(text, 'Approved'));
  const head = headSha();
  if (!isApproved(status)) return 'status:' + (status || '').trim();
  if (!sha) return 'no-sha';
  if (!head) return 'no-git-head';
  if (!head.startsWith(sha)) return 'stale:' + sha;
  return null;
}
function checkApproval() {
  const files = resolveEvals();
  if (!files.length) return { ok: false, problem: 'no-eval', display: '' };
  for (const file of files) {
    const display = relTo(file);
    if (!exists(file)) return { ok: false, problem: 'missing', display };
    const problem = approvalProblem(file);
    if (problem) return { ok: false, problem, display };
  }
  return { ok: true, display: relTo(files[0]) };
}
const isEvalFile = (rel) => /(^|\/)(eval|EVALS)\.md$/.test(rel);
const isLoopArtifact = (rel) => rel === 'EVALS.md' || rel === 'eval.md' || isEvalFile(rel) || rel.startsWith('specs/') ||
  rel.startsWith('e2e/evidence/') || ['rd.md', 'mockup.html', 'REVIEW.md', 'CLAUDE.md', 'state.md'].includes(path.basename(rel));
function segmentWrites(s) {
  return /(^|[^0-9&])>>?([^>]|$)/.test(s) ||
    /(^|[^A-Za-z0-9_])(tee|truncate|dd|rm|mv|cp|install|touch|unlink|patch)(\s|$)/.test(s) ||
    /(^|\s)(sed|perl)\s+-i/.test(s) || /git\s+(apply|checkout|restore|reset)/.test(s) ||
    /(open|writeFile|writeFileSync|createWriteStream|appendFile)\s*\(/.test(s);
}
function manipulatesGuardrails(cmd) {
  for (const seg of String(cmd).split(/[;|&\n]/)) {
    if (/\.evals-(loop|approved|commands)/.test(seg) && segmentWrites(seg)) return true;
    if (/eval\.md|EVALS\.md|approved/i.test(seg) && segmentWrites(seg)) return true;
  }
  return false;
}
const approvalHint = (file) => `f=${file}; sha=$(git rev-parse HEAD); sed -i.bak -E "s#^\\| \\*\\*Eval status\\*\\* \\|.*\\|#| **Eval status** | Approved |#;s#^\\| \\*\\*Approved\\*\\* \\|.*\\|#| **Approved** | $(git config user.name || echo human), $(date -u +%F) · sha:\${sha} |#" "$f"`;
const problemText = (p) => (
  { 'no-eval': 'no eval file exists', missing: 'the expected eval file does not exist', 'no-sha': 'the Approved row carries no sha:<commit>, so it is unapproved', 'no-git-head': 'git HEAD is unavailable — commit the repo so approval can bind to a sha' }[p] ||
  (p.startsWith('status:') ? `Eval status is "${p.slice(7)}" (needs Approved)` : p.startsWith('stale:') ? `approved at sha ${p.slice(6)}, but HEAD is ${headSha() || 'unknown'} — the approval is stale` : p));
const blockNoEval = (target) => `BLOCKED — .evals-loop is present, so the evals gate is armed, but no eval file exists.
This call would write: ${target}
Expected one of: specs/features/fr-<NN>/eval.md (standard layout) or EVALS.md (single root).
Write the eval first: writes under specs/** are never blocked. Observe every check RED,
then have a human approve it in eval.md:
  | **Eval status** | Approved |
  | **Approved** | <name>, <date> · sha:<git rev-parse HEAD> |
A human records that in their own shell with:
  ${approvalHint('specs/features/fr-<NN>/eval.md')}`;
const blockUnapproved = (target, problem, display) => `BLOCKED — implementation writes are gated until the eval is approved.
  target:  ${target}
  eval:    ${display || '<none>'}
  problem: ${problemText(problem)}
Writes to the loop's own artifacts stay open while unapproved: specs/** (eval.md, rd.md,
mockup.html, e2e evidence), EVALS.md, rd.md, mockup.html, REVIEW.md, CLAUDE.md, state.md,
e2e/evidence/**. Everything else (product source) is blocked.
Record the approval in eval.md's front table once a human says yes:
  | **Eval status** | Approved |
  | **Approved** | <name>, <date> · sha:<git rev-parse HEAD> |
A human records it in their own shell with:
  ${approvalHint(display || 'specs/features/fr-<NN>/eval.md')}
The agent may instead use Edit on eval.md, but only after a human has said yes AND the
file already says \`Eval status = In review\` — Gate A allows that one edit only when
the sha in the Approved row matches HEAD.`;
const blockApprovalWrite = (file, reason) => `BLOCKED — this edit would author the approval itself, and Gate A refuses.
  file:   ${file}
  reason: ${reason}
Approval is a human decision recorded in eval.md, bound to one commit:
  | **Eval status** | Approved |
  | **Approved** | <name>, <date> · sha:<git rev-parse HEAD> |
If a human has not said yes yet: ask them. If they have, set \`Eval status = In review\`,
then record the row with the sha of the current HEAD. A human can record it with:
  ${approvalHint(file)}`;
const blockMarker = (rel) => `BLOCKED — ${rel} is a human-only control file and is not writable by the agent.
.evals-loop arms the evals gate; .evals-approved/.evals-commands are legacy control files.
A human creates or removes them in their own shell. The agent records evidence in eval.md
itself (Edit/Write), not by editing the guardrails.`;
const blockBash = (cmd) => `BLOCKED — shell writes to the evals guardrails are denied.
  command: ${String(cmd).slice(0, 400)}
The Approved row, its sha, and \`.evals-loop\` are human-only. Shell redirection (>, >>, tee,
sed -i, patch, rm, mv, ...) against eval.md cannot be told apart from faking an approval,
so it is refused. Use Edit/Write on eval.md for red evidence and \`Result:\` lines.
A human approves in their own shell with:
  ${approvalHint('specs/features/fr-<NN>/eval.md')}`;
function checkApprovalWrite(abs, rel, content) {
  if (!hasApprovedRow(content)) return;
  const oldText = exists(abs) ? (readText(abs) || '') : '';
  const newRow = rowValue(content, 'Approved') || '';
  if (newRow.trim() === (rowValue(oldText, 'Approved') || '').trim()) return; // unchanged row
  const newSha = extractSha(newRow);
  const head = headSha();
  const oldStatus = rowValue(oldText, 'Eval status');
  let reason = null;
  if (!newRow.trim()) reason = 'the Approved row is malformed and could not be read';
  else if (!newSha) reason = 'the new Approved row carries no sha:<commit>, so it is not a valid approval';
  else if (!head) reason = 'git HEAD is unavailable, so the sha cannot be verified';
  else if (!head.startsWith(newSha)) reason = `the sha in the new Approved row (${newSha}) is not a prefix of HEAD (${head}), so the approval would be stale`;
  else if (!isInReview(oldStatus)) reason = `the file did not say \`Eval status = In review\` before this edit (was "${(oldStatus || '').trim()}"); set In review first, get the human's yes, then record approval`;
  if (reason) die(blockApprovalWrite(rel, reason));
}
function gate(event) {
  const tool = typeof event.tool_name === 'string' ? event.tool_name : '';
  const ti = event.tool_input && typeof event.tool_input === 'object' ? event.tool_input : {};
  if (tool === 'Bash') {
    const cmd = typeof ti.command === 'string' ? ti.command : '';
    if (!cmd.trim()) die('BLOCKED — a Bash tool call reached Gate A with no command; failing closed.');
    if (manipulatesGuardrails(cmd)) die(blockBash(cmd));
    return 0;
  }
  if (!tool) die('BLOCKED — gate misconfigured: the hook event has no tool_name; failing closed.');
  if (!WRITE_TOOLS.includes(tool)) return 0; // registered for write tools + Bash only
  const rawPath = ti.file_path || ti.notebook_path || ti.path;
  if (!rawPath) die(`BLOCKED — could not determine which file this ${tool} call would write; failing closed.`);
  const abs = path.resolve(ROOT, rawPath);
  const rel = relTo(abs);
  if (PROTECTED.includes(rel)) die(blockMarker(rel));
  const content = [ti.content, ti.new_string, ...(Array.isArray(ti.edits) ? ti.edits.map((e) => e && e.new_string) : [])]
    .filter((x) => typeof x === 'string').join('\n');
  if (isEvalFile(rel)) { checkApprovalWrite(abs, rel, content); return 0; }
  if (isLoopArtifact(rel)) return 0;
  const ap = checkApproval();
  if (ap.ok) return 0;
  if (ap.problem === 'no-eval' || ap.problem === 'missing') die(blockNoEval(rel));
  die(blockUnapproved(rel, ap.problem, ap.display));
}
function runStopDelegate() { // Gate B's single implementation lives in the sibling bash script
  const candidates = [path.join(HERE, 'stop-gate.sh'), path.join(HERE, 'require-evals-pass.sh')];
  const sib = candidates.find((c) => exists(c));
  if (!sib) die('BLOCKED — gate misconfigured: stop-gate.sh is missing next to eval-gate.mjs; cannot verify check results.');
  const r = spawnSync('/bin/bash', [sib], { cwd: ROOT, stdio: ['ignore', 'inherit', 'inherit'], env: { ...process.env, CLAUDE_PROJECT_DIR: ROOT } });
  return typeof r.status === 'number' ? r.status : 2;
}

// ---- lint -----------------------------------------------------------------
const stripMd = (v) => { let s = String(v).trim(); while (s.startsWith('*')) s = s.slice(1).trim(); while (s.endsWith('*')) s = s.slice(0, -1).trim(); return s; };
const normalizeFeature = (a) => 'fr-' + String(a).trim().toLowerCase().replace(/^fr-/, '');
function parseChecks(text) {
  const results = [], missing = [];
  let u = 0, f = 0, r = 0, other = 0, cur = null, val = '', has = false;
  const flush = () => {
    if (cur) {
      if (has) results.push([cur, val]); else missing.push(cur);
      if (cur.startsWith('U-')) u++; else { other++; if (cur.startsWith('F-')) f++; if (cur.startsWith('R-')) r++; }
    }
    cur = null; val = ''; has = false;
  };
  for (const line of String(text).split(/\r?\n/)) {
    const m = /^###\s+([UFRQSD]-\d+)/.exec(line);
    if (m) { flush(); cur = m[1]; continue; }
    if (/^##\s/.test(line)) { flush(); continue; }
    if (cur && !has) { const rm = /Result:\s*(.*)$/.exec(line); if (rm) { val = stripMd(rm[1]); has = true; } }
  }
  flush();
  return { results, missing, u, f, r, other };
}
function lint(arg) {
  if (!arg) { process.stderr.write('usage: eval-gate.mjs lint <feature-id>   (e.g. lint fr-11)\n'); return 1; }
  const feat = normalizeFeature(arg);
  const display = 'FR-' + feat.replace(/^fr-/, '');
  const file = path.join(ROOT, 'specs', 'features', feat, 'eval.md');
  const errors = [];
  if (!exists(file)) {
    process.stdout.write(`${display} eval is not well formed:\n- specs/features/${feat}/eval.md does not exist\n`);
    return 1;
  }
  const text = readText(file) || '';
  const required = ['RD', 'Mockup', 'Eval status', 'Approved', 'Perf baseline', 'New e2e paths'];
  for (const label of required) if (rowValue(text, label) === null) errors.push(`front table row **${label}** is missing`);
  const status = rowValue(text, 'Eval status');
  if (status !== null && !/^(draft|in[ -]review|approved)$/i.test(status.trim())) errors.push(`Eval status is "${status.trim()}"; expected Draft, In review or Approved`);
  const mock = (rowValue(text, 'Mockup') || '').trim();
  if (mock && mock !== '—' && mock !== '-') {
    const m = /\]\(([^)]*)\)/.exec(mock);
    const target = m && m[1] ? m[1].replace(/^\.\//, '') : '';
    if (target && !/^(https?:|mailto:|#)/.test(target) && !exists(path.join(path.dirname(file), target))) {
      errors.push(`Mockup is linked but specs/features/${feat}/${target} is missing`);
    }
  }
  const checks = parseChecks(text);
  if (checks.u === 0) errors.push('no ### U- usage checks found');
  if (checks.f === 0 && checks.r === 0) errors.push('no ### F- (failure) or ### R- (regression) checks found');
  for (const id of checks.missing) errors.push(`${id} has no Result: line`);
  for (const [id, val] of checks.results) if (val !== 'PASS' && !val.startsWith('FAIL:')) errors.push(`${id} Result is "${val}"; must be PASS or FAIL: <detail>`);
  if (errors.length) {
    process.stdout.write(`${display} eval is not well formed:\n${errors.map((e) => `- ${e}`).join('\n')}\n`);
    return 1;
  }
  process.stdout.write(`${display} eval is well formed. ${checks.u} U- checks, ${checks.other} F/R/Q/S/D checks.\n`);
  return 0;
}

// ---- remind + dispatch ----------------------------------------------------
function remind() {
  if (!exists(MARKER)) {
    process.stdout.write(`evals-review-loop: not adopted in this repo (no .evals-loop at ${ROOT}). Gate A (PreToolUse) and Gate B (Stop) are inactive. A HUMAN arms the loop with: touch .evals-loop\n`);
    return 0;
  }
  const ap = checkApproval();
  if (ap.ok) process.stdout.write(`evals-review-loop: armed; ${ap.display} is approved at HEAD. Implementation edits are allowed; Gate B still enforces check results.\n`);
  else if (ap.problem === 'no-eval' || ap.problem === 'missing') process.stdout.write('evals-review-loop: armed (.evals-loop) but no eval file found (specs/features/fr-<NN>/eval.md or EVALS.md). Product-source edits will be blocked until one exists and is approved.\n');
  else process.stdout.write(`evals-review-loop: armed; ${ap.display} is not validly approved (${problemText(ap.problem)}). Implementation edits are blocked. Human approval one-liner: ${approvalHint(ap.display)}\n`);
  return 0;
}
function parseArgs(argv) {
  const out = { positional: [], flags: {} };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (typeof a === 'string' && a.startsWith('--')) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (next === undefined || (typeof next === 'string' && next.startsWith('--'))) out.flags[key] = true;
      else { out.flags[key] = next; i++; }
    } else out.positional.push(a);
  }
  return out;
}
function readStdinEvent() {
  try {
    const raw = readFileSync(0, 'utf8');
    if (!raw || !raw.trim()) return null;
    return JSON.parse(raw);
  } catch { return null; }
}
// Map the host-neutral vocabulary (write/edit/bash/read/other) onto the internal event shape.
const NEUTRAL_TOOL = {
  write: 'Write', edit: 'Edit', multiedit: 'MultiEdit', notebookedit: 'NotebookEdit',
  bash: 'Bash', shell: 'Bash', read: 'Read', grep: 'Grep', glob: 'Glob',
};
function neutralEvent(flags) {
  const raw = String(flags.tool || '').toLowerCase();
  const tool = NEUTRAL_TOOL[raw] || (raw ? raw : '');
  const tool_input = {};
  if (typeof flags.path === 'string') tool_input.file_path = flags.path;
  if (typeof flags.command === 'string') tool_input.command = flags.command;
  return { tool_name: tool, tool_input };
}
function emitDecision(allow, reason) {
  if (JSON_MODE) process.stdout.write(JSON.stringify({ allow, reason: reason || undefined }) + '\n');
}
// check — the build gate, host-neutral.
function cmdCheck(argv) {
  const p = parseArgs(argv);
  if (p.flags.json) JSON_MODE = true;
  if (p.flags.root) setRoot(p.flags.root);
  let event;
  if (typeof p.flags.path === 'string' || typeof p.flags.command === 'string') {
    event = neutralEvent(p.flags);
  } else {
    event = readStdinEvent();
    if (!event) return die('BLOCKED — gate misconfigured: check needs --path/--command or a hook event on stdin. Failing closed.');
  }
  if (!exists(MARKER)) { emitDecision(true, 'not-armed'); return 0; }
  const code = gate(event);
  if (code === 0) emitDecision(true, 'allowed');
  return code;
}
// stop — the completion gate. Delegates to the single bash implementation.
function cmdStop(argv) {
  const p = parseArgs(argv);
  if (p.flags.json) JSON_MODE = true;
  if (p.flags.root) setRoot(p.flags.root);
  if (!exists(MARKER)) { emitDecision(true, 'not-armed'); return 0; }
  return runStopDelegate();
}
function main() {
  const argv = process.argv.slice(2);
  const cmd = argv[0];
  if (cmd === '--remind' || cmd === 'remind') return remind();
  if (cmd === 'lint') return lint(argv[1]);
  if (cmd === 'check') return cmdCheck(argv.slice(1));
  if (cmd === 'stop') return cmdStop(argv.slice(1));
  if (typeof cmd === 'string' && cmd && !cmd.startsWith('-')) {
    die(`BLOCKED — gate misconfigured: unknown subcommand "${cmd}". Use: lint <feature> | check --tool … | stop <feature>.`, 2);
  }
  // No subcommand: legacy hook invocation (an event arrives on stdin).
  if (!exists(MARKER)) return 0; // not adopted: stay out of the way
  const event = readStdinEvent();
  if (!event) die('BLOCKED — gate misconfigured: expected a hook event JSON on stdin (or use lint | check | stop). Failing closed.');
  if (!event || typeof event !== 'object') die('BLOCKED — gate misconfigured: the hook event JSON was not an object. Failing closed.');
  if (event.hook_event_name === 'Stop' || (Object.prototype.hasOwnProperty.call(event, 'stop_hook_active') && !event.tool_name)) return runStopDelegate();
  return gate(event);
}
try { process.exitCode = main(); }
catch (e) { die(`BLOCKED — gate misconfigured: ${e && e.message ? e.message : String(e)}`); }
