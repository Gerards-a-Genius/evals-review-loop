#!/usr/bin/env bash
# Proof suite for the evals-review-loop enforcement layer.
# Invokes the SHIPPED template files directly:
#   templates/eval-gate.mjs            Gate A (PreToolUse) + lint
#   templates/require-evals-pass.sh    Gate B (Stop)
#   templates/settings.hooks.json      wiring
set -uo pipefail

# Repo root = three levels up from test/harness/
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
MJS="$REPO/hooks/core/eval-gate.mjs"          # Gate A (build gate) + lint
PASS_SH="$REPO/hooks/core/stop-gate.sh"       # Gate B (completion gate)
SETTINGS="$REPO/adapters/claude-code/settings.hooks.json"
CLAUDE_SNIPPET="$REPO/adapters/claude-code/CLAUDE.md-snippet.md"
SKILL="$REPO/skills/evals-review-loop"
W=/tmp/hooktests/work
OUT="$W/.out"
ERR="$W/.err"
PASSED=0
FAILED=0
FAILED_NAMES=()

rm -rf "$W"
mkdir -p "$W"

ok()  { PASSED=$((PASSED + 1)); printf 'PASS  %-66s %s\n' "$1" "${2:-}"; }
bad() { FAILED=$((FAILED + 1)); FAILED_NAMES+=("$1"); printf 'FAIL  %-66s %s\n' "$1" "${2:-}"; }
expect_code() { # name expected
  if [[ "$RC" == "$2" ]]; then ok "$1" "exit $RC"; else
    bad "$1" "expected exit $2, got $RC | stderr: $(head -c 300 "$ERR" 2>/dev/null | tr '\n' ' ')"; fi
}
expect_contains() { # name pattern [file]
  local f="${3:-$OUT}"
  if grep -qF -- "$2" "$f" 2>/dev/null; then ok "$1" "contains: $2"; else
    bad "$1" "missing from $(basename "$f"): $2 | got: $(head -c 300 "$f" 2>/dev/null | tr '\n' ' ')"; fi
}
expect_absent() { # name regex file(ERR)
  if grep -qE -- "$2" "$3" 2>/dev/null; then bad "$1" "unexpected match: $2"; else ok "$1" "absent: $2"; fi
}

# ---------- fixtures ------------------------------------------------------
new_repo() { # name -> path
  local d="$W/$1"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email test@example.com
  git -C "$d" config user.name "Test Human"
  printf 'init\n' > "$d/README.md"
  git -C "$d" add -A
  git -C "$d" commit -qm init
  printf '%s\n' "$d"
}
head_of() { git -C "$1" rev-parse HEAD; }
mk_eval() { # repo feat status approved_value with_mockup(0|1) fail_check(0|1)
  local repo="$1" feat="$2" status="$3" approved="$4" mock="${5:-0}" failchk="${6:-0}"
  local dir="$repo/specs/features/$feat"
  mkdir -p "$dir"
  {
    printf '# FR-%s eval: demo\n\n' "${feat#fr-}"
    printf '| | |\n|---|---|\n'
    printf '| **RD** | [rd.md](rd.md) |\n'
    printf '| **Mockup** | [mockup.html](mockup.html) |\n'
    printf '| **Risk** | medium |\n'
    printf '| **Eval status** | %s |\n' "$status"
    printf '| **Approved** | %s |\n' "$approved"
    printf '| **Perf baseline** | `e2e/evidence/%s/perf.json` |\n' "$feat"
    printf '| **New e2e paths** | P15 x |\n'
    printf '\n## How to verify\n\n```bash\ntrue\n```\n\n## Checks\n\n'
    printf '### U-1 usage\n- **Expect:** x\n- **Result:** PASS\n\n'
    printf '### F-1 failure\n- **Expect:** y\n- **Result:** PASS\n\n'
    printf '### R-1 regression\n- **Expect:** z\n- **Result:** PASS\n'
    [[ "$failchk" == 1 ]] && printf '\n### F-16 route missing\n- **Expect:** 200\n- **Result:** FAIL: no such route\n'
  } > "$dir/eval.md"
  [[ "$mock" == 1 ]] && printf '<html></html>\n' > "$dir/mockup.html"
  return 0
}
mk_root_evals() { # repo status approved_value fail_check(0|1)
  local repo="$1" status="$2" approved="$3" failchk="${4:-0}"
  {
    printf '# Repo eval\n\n'
    printf '| | |\n|---|---|\n'
    printf '| **RD** | rd.md |\n'
    printf '| **Mockup** | — |\n'
    printf '| **Eval status** | %s |\n' "$status"
    printf '| **Approved** | %s |\n' "$approved"
    printf '| **Perf baseline** | — |\n'
    printf '| **New e2e paths** | — |\n'
    printf '\n## Checks\n\n'
    printf '### U-1 usage\n- **Result:** PASS\n\n'
    printf '### F-1 failure\n- **Result:** PASS\n'
    [[ "$failchk" == 1 ]] && printf '\n### F-16 route missing\n- **Result:** FAIL: no such route\n'
  } > "$repo/EVALS.md"
}
json_write() { python3 -c 'import json,sys; print(json.dumps({"tool_name":"Write","tool_input":{"file_path":sys.argv[1],"content":sys.argv[2]}}))' "$1" "$2"; }
json_edit()  { python3 -c 'import json,sys; print(json.dumps({"tool_name":"Edit","tool_input":{"file_path":sys.argv[1],"old_string":"","new_string":sys.argv[2]}}))' "$1" "$2"; }
json_bash()  { python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1"; }

run_mjs_hook() { # repo json
  local repo="$1" json="$2"
  ( cd "$repo" && printf '%s' "$json" | CLAUDE_PROJECT_DIR="$repo" node "$MJS" ) >"$OUT" 2>"$ERR"
  RC=$?
}
run_mjs_raw() { # repo raw-stdin
  local repo="$1" raw="$2"
  ( cd "$repo" && printf '%s' "$raw" | CLAUDE_PROJECT_DIR="$repo" node "$MJS" ) >"$OUT" 2>"$ERR"
  RC=$?
}
run_mjs_cli() { # repo args...
  local repo="$1"; shift
  ( cd "$repo" && CLAUDE_PROJECT_DIR="$repo" node "$MJS" "$@" ) >"$OUT" 2>"$ERR"
  RC=$?
}
run_pass() { # repo
  local repo="$1"
  ( cd "$repo" && CLAUDE_PROJECT_DIR="$repo" bash "$PASS_SH" ) >"$OUT" 2>"$ERR"
  RC=$?
}
run_pass_path() { # repo path
  local repo="$1" p="$2"
  ( cd "$repo" && PATH="$p" CLAUDE_PROJECT_DIR="$repo" /bin/bash "$PASS_SH" ) >"$OUT" 2>"$ERR"
  RC=$?
}

printf '\n=== evals-review-loop enforcement tests ===\n'
printf 'gate  : %s\n' "$MJS"
printf 'stop  : %s\n' "$PASS_SH"
printf 'node  : %s\n\n' "$(node --version)"

# 1 — not armed -----------------------------------------------------------------
R=$(new_repo t01); run_mjs_hook "$R" "$(json_write src/x.ts 'x')"
expect_code "1a Gate A allows when .evals-loop absent" 0
printf 'false\n' > "$R/.evals-commands"; run_pass "$R"
expect_code "1b Gate B allows when .evals-loop absent" 0
run_mjs_cli "$R" --remind
expect_code "1c --remind exits 0 when not adopted" 0
expect_contains "1d --remind says the loop is not adopted" "not adopted"

# 2 — armed, no eval file -------------------------------------------------------
R=$(new_repo t02); : > "$R/.evals-loop"; run_mjs_hook "$R" "$(json_write src/x.ts 'x')"
expect_code "2  armed + no eval file blocks source write" 2
expect_contains "2b reason names the missing eval" "no eval file exists" "$ERR"

# 3 — armed, eval In review, writing source -------------------------------------
R=$(new_repo t03); : > "$R/.evals-loop"; mk_eval "$R" fr-11 "In review" "—"
run_mjs_hook "$R" "$(json_write src/app.ts 'x')"
expect_code "3  armed + In review blocks source write" 2
expect_contains "3b reason names the gate" "implementation writes are gated" "$ERR"

# 4 — A2: the eval file itself stays writable -----------------------------------
run_mjs_hook "$R" "$(json_write specs/features/fr-11/eval.md '- **Result:** PASS')"
expect_code "4  agent may write eval.md while In review" 0
run_mjs_hook "$R" "$(json_write specs/features/fr-11/rd.md '# reqs')"
expect_code "4b agent may write rd.md while unapproved" 0
run_mjs_hook "$R" "$(json_write REVIEW.md '# review')"
expect_code "4c agent may write REVIEW.md while unapproved" 0

# 5 — approved with correct sha, writing source ---------------------------------
R=$(new_repo t05); : > "$R/.evals-loop"; H=$(head_of "$R")
mk_eval "$R" fr-11 "Approved" "gerard, 2026-10-30 · sha:$H"
run_mjs_hook "$R" "$(json_write src/app.ts 'x')"
expect_code "5  approved at HEAD allows source write" 0

# 6 — stale sha -----------------------------------------------------------------
R=$(new_repo t06); : > "$R/.evals-loop"
mk_eval "$R" fr-11 "Approved" "gerard, 2026-10-30 · sha:deadbeefcafe"
run_mjs_hook "$R" "$(json_write src/app.ts 'x')"
expect_code "6  stale approved sha blocks" 2
expect_contains "6b reason says the approval is stale" "stale" "$ERR"

# 7 — specs layout without root EVALS.md (A1) -----------------------------------
R=$(new_repo t07); : > "$R/.evals-loop"; mk_eval "$R" fr-11 "In review" "—"
[[ ! -f "$R/EVALS.md" ]] && ok "7a fixture has no root EVALS.md" "specs layout only" || bad "7a"
run_mjs_hook "$R" "$(json_write src/app.ts 'x')"
expect_code "7b specs/features/fr-11/eval.md is found and blocks" 2

# 8 — A4: Bash cannot author the Approved row ----------------------------------
R=$(new_repo t08); : > "$R/.evals-loop"; mk_eval "$R" fr-11 "In review" "—"
run_mjs_hook "$R" "$(json_bash "printf '%s\n' '| **Approved** | claude, 2026-10-30 · sha:abc1234 |' >> specs/features/fr-11/eval.md")"
expect_code "8  Bash append of an Approved row blocks" 2
expect_contains "8b reason names shell guardrails" "shell writes to the evals guardrails" "$ERR"
run_mjs_hook "$R" "$(json_bash 'rm -f .evals-loop')"
expect_code "8c Bash removal of .evals-loop blocks" 2
run_mjs_hook "$R" "$(json_bash 'npm test')"
expect_code "8d benign Bash (running evals) is allowed" 0

# 9/10 — Gate B: green and red --------------------------------------------------
R=$(new_repo t09); : > "$R/.evals-loop"; H=$(head_of "$R")
mk_eval "$R" fr-11 "Approved" "gerard, 2026-10-30 · sha:$H"
run_pass "$R"
expect_code "9  Gate B all checks PASS allows the stop" 0
expect_contains "9b Gate B reports green" "all checks PASS" "$ERR"

R=$(new_repo t10); : > "$R/.evals-loop"; H=$(head_of "$R")
mk_eval "$R" fr-11 "Approved" "gerard, 2026-10-30 · sha:$H" 0 1
run_pass "$R"
expect_code "10 Gate B failing check blocks the stop" 2
expect_contains "10b Gate B names the failing check ID" "- F-16 is not PASS (Result: FAIL: no such route)" "$ERR"
expect_contains "10c Gate B says approved-but-not-passing" "approved but not passing" "$ERR"

# 11 — A6: no timeout/gtimeout on PATH -----------------------------------------
R=$(new_repo t11); : > "$R/.evals-loop"; H=$(head_of "$R")
mk_eval "$R" fr-11 "Approved" "gerard, 2026-10-30 · sha:$H"
printf 'true\n' > "$R/.evals-commands"
mkdir -p "$W/minbin"
for b in bash git grep; do ln -sf "$(command -v "$b")" "$W/minbin/$b"; done
run_pass_path "$R" "$W/minbin"
expect_code "11 Gate B green without timeout/gtimeout" 0
expect_contains "11b green is reported as green" "all checks PASS" "$ERR"
expect_contains "11c missing wrapper is disclosed, not failed" "no timeout/gtimeout/perl" "$ERR"
expect_absent "11d no false FAIL from the missing wrapper" "^FAIL|command failed" "$ERR"

# 12 — syntax + wiring ----------------------------------------------------------
if bash -n "$PASS_SH" 2>"$ERR"; then ok "12a bash -n require-evals-pass.sh"; else bad "12a bash -n" "$(cat "$ERR")"; fi
if node --check "$MJS" 2>"$ERR"; then ok "12b node --check eval-gate.mjs"; else bad "12b node --check" "$(cat "$ERR")"; fi
if python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$SETTINGS" 2>"$ERR"; then
  ok "12c settings.hooks.json is strict JSON"
else bad "12c settings.hooks.json is strict JSON" "$(cat "$ERR")"; fi
if python3 - "$SETTINGS" "$PASS_SH" >"$OUT" 2>"$ERR" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1])); hooks = d["hooks"]
pre = hooks["PreToolUse"][0]; stop = hooks["Stop"][0]["hooks"][0]; sess = hooks["SessionStart"][0]["hooks"][0]
assert "Bash" in pre["matcher"].split("|"), pre["matcher"]
assert pre["hooks"][0]["onFailure"] == "block"
assert "eval-gate.mjs" in pre["hooks"][0]["command"] and "node" in pre["hooks"][0]["command"]
assert stop["onFailure"] == "block"
assert "eval-gate.mjs" in stop["command"] and " stop" in stop["command"]
assert stop["timeout"] == 1800 and 2 * 300 <= stop["timeout"] and 1400 < stop["timeout"]
assert "eval-gate.mjs --remind" in sess["command"]
text = open(sys.argv[2]).read()
assert "EVALS_PER_CMD_TIMEOUT:-300" in text and "EVALS_TOTAL_TIMEOUT:-1400" in text
print("wiring-ok")
PY
then ok "12d wiring: Bash matcher, onFailure=block both, 300/1400/1800 budget"; else bad "12d wiring assertions" "$(cat "$ERR")"; fi
snippet=$(grep -c '^@REVIEW\.md$' "$CLAUDE_SNIPPET" 2>/dev/null || true)
if [[ "$snippet" == "1" ]] && grep -q "never loaded" "$CLAUDE_SNIPPET"; then ok "12e CLAUDE.md snippet imports @REVIEW.md"; else bad "12e CLAUDE.md @REVIEW.md import" "count=$snippet"; fi

# 13/14 — lint ------------------------------------------------------------------
R=$(new_repo t13); mk_eval "$R" fr-11 "In review" "—" 0
run_mjs_cli "$R" lint fr-11
expect_code "13 lint rejects a linked-but-missing mockup" 1
expect_contains "13b lint names the exact missing path" "specs/features/fr-11/mockup.html is missing"
expect_contains "13c lint header" "FR-11 eval is not well formed:" "$OUT"

R=$(new_repo t14); mk_eval "$R" fr-11 "In review" "—" 1
run_mjs_cli "$R" lint fr-11
expect_code "14 lint accepts a well-formed eval" 0
expect_contains "14b lint prints counts" "FR-11 eval is well formed. 1 U- checks, 2 F/R/Q/S/D checks." "$OUT"
run_mjs_cli "$R" lint 11
expect_code "14c lint accepts a bare feature number" 0

# 15 — malformed stdin fails CLOSED, no stack trace ------------------------------
R=$(new_repo t15); : > "$R/.evals-loop"
run_mjs_raw "$R" 'this is not json'
expect_code "15 malformed stdin fails closed" 2
expect_contains "15b plain misconfiguration message" "gate misconfigured" "$ERR"
expect_absent "15c no JS stack trace" "^[[:space:]]+at " "$ERR"
run_mjs_raw "$R" ''
expect_code "15d empty stdin fails closed" 2
expect_absent "15e empty stdin has no stack trace" "^[[:space:]]+at " "$ERR"

# 16 — agent-authored approval is conditional -----------------------------------
R=$(new_repo t16); : > "$R/.evals-loop"; H=$(head_of "$R"); mk_eval "$R" fr-11 "In review" "—"
run_mjs_hook "$R" "$(json_edit specs/features/fr-11/eval.md "| **Approved** | gerard, 2026-10-30 · sha:$H |")"
expect_code "16 approval edit allowed: In review + sha == HEAD" 0
R=$(new_repo t16b); : > "$R/.evals-loop"; H=$(head_of "$R"); mk_eval "$R" fr-11 "Draft" "—"
run_mjs_hook "$R" "$(json_edit specs/features/fr-11/eval.md "| **Approved** | claude, 2026-10-30 · sha:$H |")"
expect_code "16b approval edit blocked when not In review" 2
expect_contains "16c reason names In review" "did not say" "$ERR"
R=$(new_repo t16d); : > "$R/.evals-loop"; mk_eval "$R" fr-11 "In review" "—"
run_mjs_hook "$R" "$(json_edit specs/features/fr-11/eval.md "| **Approved** | claude, 2026-10-30 · sha:deadbeefcafe |")"
expect_code "16d approval edit blocked with a stale sha" 2
expect_contains "16e reason names the sha mismatch" "not a prefix of HEAD" "$ERR"
run_mjs_hook "$R" "$(json_write .evals-loop '')"
expect_code "16f agent cannot write the arming marker" 2

# 17/18 — Gate B fail-closed extras --------------------------------------------
R=$(new_repo t17); : > "$R/.evals-loop"; run_pass "$R"
expect_code "17 Gate B armed + no eval file blocks" 2
expect_contains "17b reason says no eval file" "no eval file exists" "$ERR"
R=$(new_repo t17b); : > "$R/.evals-loop"; mk_eval "$R" fr-11 "In review" "—"; run_pass "$R"
expect_code "17c Gate B unapproved eval blocks" 2
expect_contains "17d reason names approval" "not approved" "$ERR"
R=$(new_repo t17c); : > "$R/.evals-loop"; mk_eval "$R" fr-11 "Approved" "gerard · sha:deadbeefcafe"; run_pass "$R"
expect_code "17e Gate B stale approval blocks" 2
expect_contains "17f reason says stale" "stale" "$ERR"
R=$(new_repo t17d); : > "$R/.evals-loop"; H=$(head_of "$R")
mk_eval "$R" fr-11 "Approved" "gerard · sha:$H"; printf 'false\n' > "$R/.evals-commands"; run_pass "$R"
expect_code "17g Gate B failing .evals-commands blocks" 2
expect_contains "17h failed command is named" "command failed" "$ERR"

# 19 — Stop event routed through eval-gate.mjs delegates to Gate B --------------
R=$(new_repo t19); : > "$R/.evals-loop"; H=$(head_of "$R")
mk_eval "$R" fr-11 "Approved" "gerard · sha:$H"
run_mjs_raw "$R" '{"hook_event_name":"Stop","stop_hook_active":false}'
expect_code "19 Stop event through eval-gate.mjs delegates to Gate B" 0
mk_eval "$R" fr-11 "Approved" "gerard · sha:$H" 0 1
run_mjs_raw "$R" '{"hook_event_name":"Stop","stop_hook_active":false}'
expect_code "19b delegated Stop blocks on failing check" 2
expect_contains "19c delegated Stop names F-16" "F-16 is not PASS" "$ERR"

# 20 — single root EVALS.md layout ---------------------------------------------
R=$(new_repo t20); : > "$R/.evals-loop"
mk_root_evals "$R" "In review" "—" 0
run_mjs_hook "$R" "$(json_write src/app.ts 'x')"
expect_code "20 root EVALS.md unapproved blocks source write" 2
R=$(new_repo t20b); : > "$R/.evals-loop"; H=$(head_of "$R")
mk_root_evals "$R" "Approved" "gerard · sha:$H" 0
run_mjs_hook "$R" "$(json_write src/app.ts 'x')"
expect_code "20b root EVALS.md approved at HEAD allows" 0
run_pass "$R"
expect_code "20c Gate B reads root EVALS.md and passes" 0

# 21 — lint: a check with no Result line ---------------------------------------
R=$(new_repo t21); mk_eval "$R" fr-11 "Draft" "—" 1
printf '\n### F-9 no result recorded\n- **Expect:** x\n' >> "$R/specs/features/fr-11/eval.md"
run_mjs_cli "$R" lint fr-11
expect_code "21 lint rejects a check without a Result line" 1
expect_contains "21b lint names the check" "- F-9 has no Result: line" "$OUT"

# 22 — a non-gated tool passes through -----------------------------------------
R=$(new_repo t22); : > "$R/.evals-loop"; mk_eval "$R" fr-11 "In review" "—"
run_mjs_hook "$R" '{"tool_name":"Read","tool_input":{"file_path":"src/app.ts"}}'
expect_code "22 non-gated tool is not blocked" 0

# ---------- summary ------------------------------------------------------------
printf '\n=== summary ===\n'
printf 'passed: %d\nfailed: %d\n' "$PASSED" "$FAILED"
if (( FAILED > 0 )); then
  printf 'failing cases:\n'
  printf '  - %s\n' "${FAILED_NAMES[@]}"
  exit 1
fi
printf 'ALL TESTS PASSED\n'
