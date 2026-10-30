#!/usr/bin/env bash
# adapters/hermes/evals-gate.sh
#
# The evals gate for hermes-dispatch.
#
# hermes-dispatch already runs two annotate-only gates after the engine finishes
# (verification gate 1: the repo's own tests; gate 2: risk-tiered diff review).
# This is the same shape for evals — gate 3. It NEVER blocks: the branch always
# lands, and a red eval flips the run to needs-review with the evidence attached.
# That matches the dispatcher's own stated convention ("annotate, never block"),
# so this adapter cannot deadlock a Hermes run.
#
# TWO MODES
#   gate mode   (what hermes-dispatch calls)
#       evals-gate.sh <worktree> [<runlog>]
#       → always exits 0, prints a single line:  EVALS_RESULT=<value>
#       values match the dispatcher's test-gate vocabulary:
#         skipped        no eval configured for this repo
#         not-armed      repo has no .evals-loop, so the loop was never adopted
#         passed         every check under an approved eval is PASS
#         failed         at least one approved check is not PASS
#         not-approved   an eval exists but no human has approved it
#         malformed      eval.md is not well formed (lint failed)
#         timeout        the gate did not finish in time
#         error          the gate itself broke (never silently: it says so)
#
#   standalone mode   (manual use / CI)
#       evals-gate.sh --standalone <repo> [<feature-id>]
#       → exit 0 when every approved check is PASS, exit 2 otherwise. Use this
#         from CI or a pre-push hook where blocking is wanted and safe.

set -uo pipefail

MODE="gate"
if [[ "${1:-}" == "--standalone" ]]; then
  MODE="standalone"; shift
fi

if [[ "$MODE" == "gate" ]]; then
  WT="${1:-}"; RUNLOG="${2:-}"
  TIMEOUT="${EVALS_TIMEOUT:-600}"
else
  WT="${1:-}"; FEATURE="${2:-}"
  TIMEOUT="${EVALS_TIMEOUT:-600}"
fi

emit() { # emit <result> [detail]
  local result="$1" detail="${2:-}"
  if [[ "$MODE" == "standalone" ]]; then
    [[ -n "$detail" ]] && echo "$detail" >&2
    [[ "$result" == "passed" ]] && exit 0
    exit 2
  fi
  [[ -n "$detail" ]] && echo "evals gate: $detail" >&2
  echo "EVALS_RESULT=$result"
  [[ -n "${RUNLOG:-}" ]] && echo "evals gate: $result${detail:+ — $detail}" >>"$RUNLOG" 2>/dev/null
  exit 0
}

[[ -z "$WT" || ! -d "$WT" ]] && emit error "worktree not found: ${WT:-<empty>}"

# Locate the gate implementation relative to this adapter, then via the plugin.
SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CORE="$SELF_DIR/../../hooks/core/eval-gate.mjs"
[[ -f "$CORE" ]] || emit skipped "hooks/core/eval-gate.mjs not present next to this adapter"

command -v node >/dev/null 2>&1 || emit error "node not on PATH"

if [[ ! -e "$WT/.evals-loop" ]]; then
  emit not-armed "no .evals-loop in the repo root"
fi

# An eval must exist and be approved before this gate has anything to say.
if ! compgen -G "$WT/specs/features/fr-*/eval.md" >/dev/null && [[ ! -f "$WT/EVALS.md" ]]; then
  emit skipped "no specs/features/fr-*/eval.md and no EVALS.md"
fi

# Feature selection: explicit arg, else the active branch's fr-NN, else the only one.
FEATURE="${FEATURE:-}"
if [[ -z "$FEATURE" ]]; then
  BR="$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  FEATURE="$(printf '%s' "$BR" | grep -oE 'fr-[0-9]+' | head -1 || true)"
fi
if [[ -z "$FEATURE" ]]; then
  mapfile -t FOUND < <(ls -d "$WT"/specs/features/fr-* 2>/dev/null | xargs -r -n1 basename)
  [[ ${#FOUND[@]} -eq 1 ]] && FEATURE="${FOUND[0]}"
fi
[[ -z "$FEATURE" ]] && emit skipped "several features present and none inferable from the branch; pass one explicitly"

# Well-formedness first: a malformed eval is neither approved nor meaningfully red.
LINT_OUT="$(cd "$WT" && node "$CORE" lint "$FEATURE" 2>&1)"
LINT_RC=$?
[[ $LINT_RC -eq 1 ]] && emit malformed "$(printf '%s' "$LINT_OUT" | tr '\n' ' ' | cut -c1-300)"

# Completion gate. `stop` exits 0 when every approved check is PASS.
STOP_OUT="$(cd "$WT" && timeout "$TIMEOUT" node "$CORE" stop "$FEATURE" 2>&1)"
STOP_RC=$?
case "$STOP_RC" in
  0)   emit passed || true; ;;
  2)
    if printf '%s' "$STOP_OUT" | grep -qi "not approved"; then
      emit not-approved "$(printf '%s' "$STOP_OUT" | tr '\n' ' ' | cut -c1-300)"
    else
      emit failed "$(printf '%s' "$STOP_OUT" | tr '\n' ' ' | cut -c1-300)"
    fi
    ;;
  124) emit timeout "no result within ${TIMEOUT}s" ;;
  *)   emit error "gate exited $STOP_RC: $(printf '%s' "$STOP_OUT" | tr '\n' ' ' | cut -c1-200)" ;;
esac
