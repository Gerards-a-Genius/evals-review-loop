#!/usr/bin/env bash
# .claude/hooks/require-evals-pass.sh
#
# Gate B — the Stop hook. The agent may not end its turn claiming the feature is
# done while an approved eval still has a check that is not PASS. Exit 2 BLOCKS the
# stop and names the failing IDs; exit 0 allows the turn to end.
#
#   Invocation: no arguments. Claude Code passes the Stop event JSON on stdin; this
#   gate does not need it because it verifies the approved eval.md on disk.
#
# CONTRACT
#   Arming is explicit and human-only: a repo opts in when a HUMAN creates the
#   repo-root marker `.evals-loop`. Absent -> exit 0 (the repo has not adopted the
#   loop and this gate stays out of the way). Armed -> fail CLOSED: no eval file,
#   no approval, a stale approval, or a check that is not `Result: PASS` all block.
#
#   Approval lives INSIDE eval.md (front table), never in a side file:
#     | **Eval status** | Approved |
#     | **Approved** | <name>, <date> · sha:<git rev-parse HEAD> |
#   A bare `| **Approved** | <name> |` (no sha) is UNAPPROVED. The sha must be a
#   prefix of `git rev-parse HEAD`; approval expires when HEAD moves.
#
#   Check format parsed under `## Checks`:
#     ### U-1 <title>            (U- usage, F- failure, R- regression, Q/S/D)
#     - **Expect:** ...
#     - **Result:** PASS         <- or `FAIL: <what you actually saw>`
#   Any other Result value, and any check without one, is not PASS.
#
#   OPTIONAL .evals-commands: one command per line (blank/# ignored). When that
#   file exists the Stop gate also runs it, so recorded PASS lines cannot go stale.
#   Timeout handling is portable: `timeout` or `gtimeout` when available, else
#   `perl -e 'alarm shift; exec @ARGV'`, else unbounded with a notice. A command is
#   NEVER reported failed merely because the timeout wrapper is missing.
#
#   Runtime budget (kept below the Stop hook timeout in settings.hooks.json):
#     per command: 300s  (EVALS_PER_CMD_TIMEOUT)
#     total:      1400s  (EVALS_TOTAL_TIMEOUT)   hook timeout: 1800s
#   so the script exits deliberately with a message before Claude Code kills it.
#
# WRITE SIDE
#   The Stop hook only reads. Agents record results with Edit/Write on eval.md.
#   A human records approval in their own shell with:
#     f=<eval-file>; sha=$(git rev-parse HEAD); sed -i.bak -E \
#       "s#^\| \*\*Eval status\*\* \|.*\|#| **Eval status** | Approved |#;s#^\| \*\*Approved\*\* \|.*\|#| **Approved** | $(git config user.name || echo human), $(date -u +%F) · sha:${sha} |#" "$f"
#
# Install: cp templates/require-evals-pass.sh .claude/hooks/ && chmod +x .claude/hooks/require-evals-pass.sh

set -uo pipefail

# macOS /bin/bash is 3.2. Under `set -u` it treats an UNSET array as unbound, and
# expanding an EMPTY array errors instead of expanding to nothing. So: pre-initialise
# every array here, and always expand through the plus-guarded idiom instead of a
# bare double-quoted star-index expansion.
files=(); sections=(); problems=(); checklines=(); lines=()
CMD_FAILS=(); P_RESULTS=(); P_MISSING=()

ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# ---------------------------------------------------------------------------
# helpers (bash 3.2-safe: no ${var,,}/${var^^}, no mapfile)
# ---------------------------------------------------------------------------

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

row_cell_from_line() {
  local line="$1"
  line="${line#*|}"
  line="${line#*|}"
  line="${line%%|*}"
  trim "$line"
}

row_value_file() {
  local file="$1" label="$2" line
  [[ -f "$file" ]] || return 1
  line="$(grep -m1 -E "^[[:space:]]*\|[[:space:]]*\*\*${label}\*\*" "$file" 2>/dev/null)" || return 1
  row_cell_from_line "$line"
}

head_sha() {
  git -C "$ROOT" rev-parse HEAD 2>/dev/null
}

extract_sha() {
  local v="$1" tag
  tag="$(printf '%s' "$v" | grep -m1 -oE 'sha:[0-9a-fA-F]{7,40}' 2>/dev/null)" || true
  printf '%s' "${tag#sha:}"
}

is_approved_status() {
  case "$(trim "$1")" in
    Approved|approved|APPROVED) return 0 ;;
    *) return 1 ;;
  esac
}

feature_display() {
  local rel="${1#"$ROOT"/}" f
  case "$rel" in
    specs/features/*/eval.md)
      f="${rel#specs/features/}"
      f="${f%/eval.md}"
      case "$f" in
        [Ff][Rr]-*) f="fr-${f#??-}" ;;
      esac
      printf 'FR-%s' "${f#fr-}"
      ;;
    *) printf 'EVALS.md' ;;
  esac
}

active_feature_eval() {
  local p="$1" rel
  while [[ "$p" == "$ROOT"/* ]]; do
    if [[ "$p" == "$ROOT"/specs/features/* ]]; then
      rel="${p#"$ROOT"/specs/features/}"
      if [[ -n "$rel" && "$rel" != */* ]]; then
        printf '%s\n' "$p/eval.md"
        return 0
      fi
    fi
    p="${p%/*}"
  done
  return 1
}

resolve_eval_files() {
  local act
  if act="$(active_feature_eval "$PWD")"; then
    printf '%s\n' "$act"
    return 0
  fi
  if [[ -f "$ROOT/EVALS.md" ]]; then
    printf '%s\n' "$ROOT/EVALS.md"
    return 0
  fi
  local -a files=()
  shopt -s nullglob
  files=("$ROOT"/specs/features/*/eval.md)
  shopt -u nullglob
  if (( ${#files[@]} > 0 )); then
    printf '%s\n' ${files[@]+"${files[@]}"}
    return 0
  fi
  return 1
}

approval_hint() {
  local f="${1:-specs/features/fr-<NN>/eval.md}" hint
  hint='f=@FILE@; sha=$(git rev-parse HEAD); sed -i.bak -E "s#^\| \*\*Eval status\*\* \|.*\|#| **Eval status** | Approved |#;s#^\| \*\*Approved\*\* \|.*\|#| **Approved** | $(git config user.name || echo human), $(date -u +%F) · sha:${sha} |#" "$f"'
  printf '%s\n' "${hint//@FILE@/$f}"
}

# strip markdown emphasis around a Result value: "** FAIL: x" -> "FAIL: x"
strip_md() {
  local s
  s="$(trim "$1")"
  while [[ "$s" == \** ]]; do s="${s#\*}"; s="$(trim "$s")"; done
  while [[ "$s" == *\* ]]; do s="${s%\*}"; s="$(trim "$s")"; done
  printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# check parser — sets:
#   P_RESULTS ("ID<TAB>value"), P_MISSING ("ID")
# ---------------------------------------------------------------------------

P_RESULTS=()
P_MISSING=()

_parse_flush() {
  local cid="$1" has="$2" res="$3"
  [[ -z "$cid" ]] && return 0
  if (( has )); then
    P_RESULTS+=("$cid"$'\t'"$res")
  else
    P_MISSING+=("$cid")
  fi
  return 0
}

parse_checks_file() {
  local file="$1" line id_re res_re val cid="" has_result=0 result=""
  id_re='^###[[:space:]]+([UFRQSD]-[0-9]+)'
  res_re='Result:[[:space:]]*(.*)$'
  P_RESULTS=()
  P_MISSING=()
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $id_re ]]; then
      _parse_flush "$cid" "$has_result" "$result"
      cid="${BASH_REMATCH[1]}"
      has_result=0
      result=""
      continue
    fi
    if [[ "$line" =~ ^##[[:space:]] ]]; then
      _parse_flush "$cid" "$has_result" "$result"
      cid=""
      has_result=0
      result=""
      continue
    fi
    if [[ -n "$cid" && $has_result -eq 0 && "$line" =~ $res_re ]]; then
      val="${BASH_REMATCH[1]}"
      result="$(strip_md "$val")"
      has_result=1
    fi
  done < "$file"
  _parse_flush "$cid" "$has_result" "$result"
  return 0
}

# ---------------------------------------------------------------------------
# optional command runner (timeout-portable, bounded)
# ---------------------------------------------------------------------------

CMD_FAILS=()

run_commands() {
  local cmd_file="$ROOT/.evals-commands"
  local line cmd per_cmd total shell_bin to_bin perl_bin tmp ec i start
  local -a lines=()
  CMD_FAILS=()
  [[ -f "$cmd_file" ]] || return 0

  per_cmd="${EVALS_PER_CMD_TIMEOUT:-300}"
  case "$per_cmd" in ''|*[!0-9]*) per_cmd=300 ;; esac
  total="${EVALS_TOTAL_TIMEOUT:-1400}"
  case "$total" in ''|*[!0-9]*) total=1400 ;; esac
  shell_bin="${BASH:-/bin/bash}"
  to_bin=""
  perl_bin=""
  if command -v timeout >/dev/null 2>&1; then
    to_bin="$(command -v timeout)"
  elif command -v gtimeout >/dev/null 2>&1; then
    to_bin="$(command -v gtimeout)"
  elif command -v perl >/dev/null 2>&1; then
    perl_bin="$(command -v perl)"
  else
    printf 'evals: no timeout/gtimeout/perl on PATH — running .evals-commands without a per-command limit (the %ss total budget is still enforced; a missing wrapper is never counted as a failure).\n' "$total" >&2
  fi
  tmp="${TMPDIR:-/tmp}/evals-stop.$$"

  while IFS= read -r line || [[ -n "$line" ]]; do
    cmd="$(trim "$line")"
    [[ -z "$cmd" || "$cmd" == \#* ]] && continue
    if (( SECONDS >= total )); then
      CMD_FAILS+=("eval run exceeded the ${total}s total budget before: $cmd")
      break
    fi
    ec=0
    if [[ -n "$to_bin" ]]; then
      ( cd "$ROOT" && "$to_bin" "$per_cmd" "$shell_bin" -c "$cmd" ) >"$tmp" 2>&1 || ec=$?
    elif [[ -n "$perl_bin" ]]; then
      ( cd "$ROOT" && "$perl_bin" -e 'alarm shift; exec @ARGV' "$per_cmd" "$shell_bin" -c "$cmd" ) >"$tmp" 2>&1 || ec=$?
    else
      ( cd "$ROOT" && "$shell_bin" -c "$cmd" ) >"$tmp" 2>&1 || ec=$?
    fi
    if (( ec != 0 )); then
      if (( ec == 124 )); then
        CMD_FAILS+=("command timed out after ${per_cmd}s: $cmd")
      else
        CMD_FAILS+=("command failed (exit $ec): $cmd")
      fi
      lines=()
      while IFS= read -r line || [[ -n "$line" ]]; do
        lines+=("$line")
      done < "$tmp"
      start=${#lines[@]}
      if (( start > 8 )); then start=$((start - 8)); else start=0; fi
      i=$start
      while (( i < ${#lines[@]} )); do
        CMD_FAILS+=("    ${lines[i]}")
        i=$((i + 1))
      done
    fi
  done < "$cmd_file"

  if command -v rm >/dev/null 2>&1; then
    rm -f "$tmp" 2>/dev/null
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Stop mode
# ---------------------------------------------------------------------------

stop_main() {
  local line file display status approved sha head approved_ok entry id val
  local total_checks=0 total_files=0 needs_approval=0 any_failure=0
  local -a files=() problems=() checklines=() sections=()

  [[ -f "$ROOT/.evals-loop" ]] || exit 0

  while IFS= read -r line; do
    files+=("$line")
  done < <(resolve_eval_files)

  if (( ${#files[@]} == 0 )); then
    {
      printf 'BLOCKED — .evals-loop is present, so the evals gate is armed, but no eval file exists.\n\n'
      printf 'Expected one of:\n'
      printf '  specs/features/fr-<NN>/eval.md\n'
      printf '  EVALS.md\n\n'
      printf 'Create the eval, observe every check RED, then get it approved. Gate B will\n'
      printf 'not let the turn end until an approved eval reports every check as Result: PASS.\n'
    } >&2
    exit 2
  fi

  for file in ${files[@]+"${files[@]}"}; do
    display="$(feature_display "$file")"
    total_files=$((total_files + 1))

    if [[ ! -f "$file" ]]; then
      problems+=("$display: expected eval file ${file#"$ROOT"/} does not exist")
      any_failure=1
      continue
    fi

    status="$(row_value_file "$file" 'Eval status' || true)"
    approved="$(row_value_file "$file" 'Approved' || true)"
    sha="$(extract_sha "$approved")"
    head="$(head_sha)"
    approved_ok=0

    if ! is_approved_status "$status"; then
      problems+=("$display: Eval status is \"$(trim "$status")\", not Approved")
      any_failure=1
    elif [[ -z "$sha" ]]; then
      problems+=("$display: the Approved row has no sha:<commit>, so the approval is not valid")
      any_failure=1
    elif [[ -z "$head" ]]; then
      problems+=("$display: git HEAD is unavailable, so the approved sha cannot be checked")
      any_failure=1
    else
      case "$head" in
        "$sha"*) approved_ok=1 ;;
        *)
          problems+=("$display: approval is stale — approved at sha $sha, HEAD is $head")
          any_failure=1
          ;;
      esac
    fi

    parse_checks_file "$file"
    total_checks=$((total_checks + ${#P_RESULTS[@]} + ${#P_MISSING[@]}))

    if (( approved_ok )); then
      for id in ${P_MISSING[@]+"${P_MISSING[@]}"}; do
        checklines+=("$id has no Result: line")
        any_failure=1
      done
      for entry in ${P_RESULTS[@]+"${P_RESULTS[@]}"}; do
        id="${entry%%$'\t'*}"
        val="${entry#*$'\t'}"
        case "$val" in
          PASS) ;;
          *)
            checklines+=("$id is not PASS (Result: $val)")
            any_failure=1
            ;;
        esac
      done
      if (( ${#P_RESULTS[@]} + ${#P_MISSING[@]} == 0 )); then
        checklines+=("no checks found (expected ### U-/F-/R- checks with Result: lines)")
        any_failure=1
      fi
    fi

    if (( approved_ok == 0 )); then
      if (( ${#problems[@]} > 0 )); then
        needs_approval=1
        sections+=("$display's eval is not approved, so the feature isn't done:")
        for line in ${problems[@]+"${problems[@]}"}; do sections+=("- $line"); done
        problems=()
      fi
    elif (( ${#checklines[@]} > 0 )); then
      sections+=("$display's eval is approved but not passing, so the feature isn't done:")
      for line in ${checklines[@]+"${checklines[@]}"}; do sections+=("- $line"); done
      checklines=()
    fi
  done

  run_commands
  if (( ${#CMD_FAILS[@]} > 0 )); then
    any_failure=1
    sections+=("The eval commands in .evals-commands are failing:")
    for line in ${CMD_FAILS[@]+"${CMD_FAILS[@]}"}; do
      case "$line" in
        "    "*) sections+=("$line") ;;
        *) sections+=("- $line") ;;
      esac
    done
  fi

  if (( any_failure == 0 )); then
    printf 'evals: all checks PASS (%d checks, %d eval file(s)).\n' "$total_checks" "$total_files" >&2
    exit 0
  fi

  if (( ${#sections[@]} == 0 )); then
    sections+=("evals: the gate is armed but could not verify the eval; failing closed.")
  fi

  if (( needs_approval )); then
    sections+=("")
    sections+=("Record approval in eval.md's front table once a human says yes:")
    sections+=("  | **Eval status** | Approved |")
    sections+=("  | **Approved** | <name>, <date> · sha:<git rev-parse HEAD> |")
    sections+=("A human records it in their own shell with:")
    while IFS= read -r line; do sections+=("  $line"); done < <(approval_hint 'specs/features/fr-<NN>/eval.md')
  fi

  printf '%s\n' ${sections[@]+"${sections[@]}"} >&2
  exit 2
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------

case "${1:-}" in
  "")
    stop_main
    ;;
  *)
    printf 'usage: %s   (Stop hook; takes no arguments)\n' "$0" >&2
    exit 1
    ;;
esac
