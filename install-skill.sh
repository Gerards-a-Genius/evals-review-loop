#!/usr/bin/env bash
# install-skill.sh — put the portable Agent Skill where every harness looks for it.
#
#   ./install-skill.sh              # → ~/.agents/skills/evals-review-loop
#   AGENTS_SKILLS_DIR=/path ./install-skill.sh
#
# The Agent Skills convention is ~/.agents/skills/<name>/ (personal) or
# .agents/skills/<name>/ (project). Claude Code, Codex CLI, Cursor, Copilot,
# Gemini CLI and others read that path. This copies the skill and the scripts it
# needs, leaving anything already there replaced — re-run it after `git pull`.
#
# Only the *skill* is installed. Enforcement (hooks) is per-host and stays opt-in:
# see adapters/.

set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/skills/evals-review-loop"
DEST_ROOT="${AGENTS_SKILLS_DIR:-$HOME/.agents/skills}"
DEST="$DEST_ROOT/evals-review-loop"

if [[ ! -f "$SRC/SKILL.md" ]]; then
  echo "error: $SRC/SKILL.md not found — run this from the cloned repo" >&2
  exit 1
fi

mkdir -p "$DEST_ROOT"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"

# --- verify it is a well-formed Agent Skill -----------------------------------
name="$(sed -n 's/^name:[[:space:]]*\([A-Za-z0-9._-]*\).*/\1/p' "$DEST/SKILL.md" | head -1)"
desc="$(sed -n 's/^description:[[:space:]]*//p' "$DEST/SKILL.md" | head -1)"
dlen=${#desc}

status=0
if [[ "$name" != "evals-review-loop" ]]; then
  echo "error: SKILL.md name '$name' does not match the directory" >&2
  status=1
fi
if (( dlen == 0 || dlen > 1024 )); then
  echo "error: description must be 1-1024 chars (got $dlen)" >&2
  status=1
fi
(( status != 0 )) && exit "$status"

# --- runtime dependencies the bundled scripts need ----------------------------
missing=()
command -v node    >/dev/null 2>&1 || missing+=("node  (hooks/core/eval-gate.mjs)")
command -v python3 >/dev/null 2>&1 || missing+=("python3  (scripts/loop.py)")
command -v git     >/dev/null 2>&1 || missing+=("git  (approval is bound to a commit)")

echo "installed evals-review-loop"
echo "  path        : $DEST"
echo "  name        : $name"
echo "  description : ${dlen} chars"
echo "  files       : $(find "$DEST" -type f | wc -l | tr -d ' ')"
if (( ${#missing[@]} > 0 )); then
  echo "  missing deps: ${missing[*]}" >&2
fi

# quick smoke: the round-cap bookkeeper must import and run
if command -v python3 >/dev/null 2>&1 && [[ -f "$DEST/scripts/loop.py" ]]; then
  if ( cd /tmp && python3 "$DEST/scripts/loop.py" status >/dev/null 2>&1 ); then
    : # expected: "no loop in progress" — exit 1 is fine, it means it ran
  fi
  if python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$DEST/scripts/loop.py" 2>/dev/null; then
    echo "  smoke       : scripts/loop.py parses"
  else
    echo "  smoke       : scripts/loop.py FAILED to parse" >&2
    status=1
  fi
fi

exit "$status"
