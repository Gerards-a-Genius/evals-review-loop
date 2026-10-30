#!/usr/bin/env python3
"""Bounded review-loop bookkeeper.

Enforces the three rules an agent will otherwise talk its way past:
  1. the round cap
  2. never re-posting a finding that was already raised
  3. stopping when the same problem survives two rounds of fixes

Exit codes are load-bearing. Wire them into a hook or wrapper so "the loop is
over budget" cannot be talked past:

  0  ok / loop is green
  1  usage or state error
  3  duplicate finding (NOT recorded)
  4  round cap exceeded   -> escalate the approach, not another patch
  5  no progress / stall  -> escalate the approach, not another patch

Usage:
  loop.py start   [--cap 5] [--risk medium] [--feature "name"] [--force]
  loop.py finding --tag auth:unchecked-index --severity important \
                  [--file src/pay.ts] [--line 42] [--round N]
  loop.py resolve --tag auth:unchecked-index
  loop.py round   --verdict pass|fail [--note "..."]
  loop.py status
  loop.py reset

State lives in ./.review-loop/state.json
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

SEVERITIES = ("important", "nit", "pre-existing")
STATE_DIR = Path(os.environ.get("REVIEW_LOOP_DIR", ".review-loop"))
STATE = STATE_DIR / "state.json"


# ---------------------------------------------------------------- state io

def load() -> dict:
    if not STATE.exists():
        die("no loop in progress; run `loop.py start` first", 1)
    try:
        return json.loads(STATE.read_text())
    except json.JSONDecodeError as exc:
        die(f"corrupt state file {STATE}: {exc}", 1)


def save(state: dict) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = STATE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2) + "\n")
    tmp.replace(STATE)


def die(msg: str, code: int) -> None:
    print(f"error: {msg}", file=sys.stderr)
    raise SystemExit(code)


def cur(state: dict) -> dict:
    return state["rounds"][-1]


def all_findings(state: dict) -> list[dict]:
    return [f for r in state["rounds"] for f in r["findings"]]


def open_findings(state: dict, severity: str | None = None) -> list[dict]:
    out = [f for f in all_findings(state) if f.get("open", True)]
    if severity is not None:
        out = [f for f in out if f["severity"] == severity]
    return out


def count(state: dict, severity: str, round_no: int | None = None) -> int:
    """Findings of a severity, optionally restricted to one round."""
    rounds = state["rounds"] if round_no is None else [
        r for r in state["rounds"] if r["n"] == round_no
    ]
    return sum(1 for r in rounds for f in r["findings"] if f["severity"] == severity)


def escalate(state: dict, reason: str, code: int) -> None:
    state["status"] = "escalated"
    state["escalation"] = reason
    state["escalation_code"] = code
    save(state)
    print(f"\nESCALATE — {reason}", file=sys.stderr)
    print(
        "\nHand the human the approach question, not another patch:\n"
        "  1. the question, in one or two lines\n"
        "  2. the two constraints in tension\n"
        "  3. what each round tried, one line each\n"
        "  4. two candidate resolutions\n",
        file=sys.stderr,
    )
    raise SystemExit(code)


# ---------------------------------------------------------------- commands

def cmd_start(a: argparse.Namespace) -> int:
    if STATE.exists() and not a.force:
        die(f"a loop is already in progress at {STATE}; use --force to replace it", 1)
    if a.cap < 1:
        die("--cap must be >= 1", 1)
    state = {
        "feature": a.feature or "(unnamed)",
        "risk": a.risk,
        "cap": a.cap,
        "round": 1,
        "status": "active",
        "escalation": None,
        "escalation_code": None,
        "no_progress_streak": 0,
        "rounds": [{"n": 1, "verdict": None, "note": None, "findings": []}],
    }
    save(state)
    print(f"loop started: {state['feature']}  risk={a.risk}  cap={a.cap}")
    print(f"state: {STATE.resolve()}")
    return 0


def cmd_finding(a: argparse.Namespace) -> int:
    state = load()
    if state["status"] != "active":
        die(f"loop is {state['status']}, not active", 1)
    if a.severity not in SEVERITIES:
        die(f"--severity must be one of {SEVERITIES}", 1)

    tag = a.tag.strip()
    if not tag:
        die("--tag must not be empty", 1)

    for prior in all_findings(state):
        if prior["tag"] == tag:
            print(
                f"duplicate — '{tag}' was already raised in round {prior['round']} "
                f"({prior['severity']}, {prior.get('file') or '?'}:{prior.get('line') or '?'}), "
                f"currently {'OPEN' if prior.get('open', True) else 'resolved'}.",
                file=sys.stderr,
            )
            print(
                "Do not re-post it. If it is still open, say so — a fail round that adds "
                "no new findings counts toward the stall rule. If it is fixed, `resolve` it.",
                file=sys.stderr,
            )
            return 3

    target = a.round or cur(state)["n"]
    rd = next((r for r in state["rounds"] if r["n"] == target), None)
    if rd is None:
        die(f"round {target} does not exist yet (current round is {cur(state)['n']})", 1)

    rd["findings"].append(
        {
            "tag": tag,
            "severity": a.severity,
            "file": a.file,
            "line": a.line,
            "round": target,
            "open": True,
        }
    )
    save(state)
    loc = f" {a.file}:{a.line}" if a.file else ""
    print(f"recorded round {target}: [{a.severity}] {tag}{loc}")
    return 0


def cmd_resolve(a: argparse.Namespace) -> int:
    state = load()
    tag = a.tag.strip()
    hits = [f for f in all_findings(state) if f["tag"] == tag and f.get("open", True)]
    if not hits:
        known = [f for f in all_findings(state) if f["tag"] == tag]
        if known:
            print(f"'{tag}' is already resolved", file=sys.stderr)
            return 0
        die(f"no finding tagged '{tag}'", 1)
    for f in hits:
        f["open"] = False
    save(state)
    print(f"resolved: {tag}  ({len(open_findings(state, 'important'))} important still open)")
    return 0


def cmd_round(a: argparse.Namespace) -> int:
    state = load()
    if state["status"] != "active":
        die(f"loop is {state['status']}, not active", 1)

    rd = cur(state)
    if rd["verdict"] is not None:
        die(f"round {rd['n']} is already closed as {rd['verdict']}", 1)

    rd["verdict"] = a.verdict
    rd["note"] = a.note
    imp_new = count(state, "important", rd["n"])
    total = len(rd["findings"])
    open_imp = len(open_findings(state, "important"))
    rd["open_important_at_close"] = open_imp

    # GREEN: evals pass and nothing Important came back this round.
    if a.verdict == "pass" and imp_new == 0:
        state["status"] = "green"
        save(state)
        print(f"\nGREEN at round {rd['n']} — evals pass, no Important findings.")
        if total:
            print(f"  {total} non-blocking finding(s) remain; file them, do not loop on them.")
        return 0

    # Evals still failing, yet every finding is old code -> the reviewer is
    # archaeology-hunting instead of reviewing the diff.
    if (
        a.verdict == "fail"
        and total
        and all(f["severity"] == "pre-existing" for f in rd["findings"])
    ):
        escalate(
            state,
            f"round {rd['n']} has failing evals but produced only Pre-existing findings — "
            "the reviewer has stopped reviewing the diff. Switch to diff-only re-review.",
            5,
        )

    # STALL. Two ways the same problem survives:
    #   (a) the round added nothing new while Important findings are still open —
    #       i.e. the still-unfixed bug, which dedupe correctly refuses to re-raise;
    #   (b) the open Important set did not shrink versus the previous round.
    prev_open = None
    for r in reversed(state["rounds"][:-1]):
        if r.get("open_important_at_close") is not None:
            prev_open = r["open_important_at_close"]
            break

    if a.verdict == "fail" and open_imp > 0 and imp_new == 0:
        state["no_progress_streak"] = state.get("no_progress_streak", 0) + 1
    elif prev_open is not None and open_imp > 0 and open_imp >= prev_open:
        state["no_progress_streak"] = state.get("no_progress_streak", 0) + 1
    else:
        state["no_progress_streak"] = 0

    if state["no_progress_streak"] >= 2:
        escalate(
            state,
            f"{state['no_progress_streak']} consecutive rounds with no net reduction in "
            f"open Important findings ({open_imp} still open) — the same problem has survived "
            "two rounds of fixes. More rounds will find more old bugs, not new ones.",
            5,
        )

    # Round cap.
    next_n = rd["n"] + 1
    if next_n > state["cap"]:
        escalate(
            state,
            f"round cap of {state['cap']} reached with {open_imp} Important finding(s) "
            "still open. The approach needs a human decision.",
            4,
        )

    state["round"] = next_n
    state["rounds"].append({"n": next_n, "verdict": None, "note": None, "findings": []})
    save(state)
    print(
        f"round {rd['n']} closed ({a.verdict}): {imp_new} new important, "
        f"{open_imp} open important.  -> round {next_n} of {state['cap']}"
    )
    if state["no_progress_streak"]:
        print("  warning: no net reduction in Important findings — one more stalls the loop.")
    return 0


def cmd_status(_a: argparse.Namespace) -> int:
    state = load()
    print(
        f"{state['feature']}   risk={state['risk']}  "
        f"round {cur(state)['n']}/{state['cap']}  status={state['status']}"
    )
    print("-" * 64)
    for rd in state["rounds"]:
        imp = sum(1 for f in rd["findings"] if f["severity"] == "important")
        nit = sum(1 for f in rd["findings"] if f["severity"] == "nit")
        pre = sum(1 for f in rd["findings"] if f["severity"] == "pre-existing")
        print(
            f"  round {rd['n']}: verdict={str(rd['verdict'] or 'open'):<5} "
            f"important={imp} nit={nit} pre-existing={pre}"
        )
        for f in rd["findings"]:
            loc = f"  {f['file']}:{f['line']}" if f.get("file") else ""
            mark = "" if f.get("open", True) else " (resolved)"
            print(f"      [{f['severity']}] {f['tag']}{loc}{mark}")

    o = open_findings(state, "important")
    print(f"\nopen important: {len(o)}" + ("" if not o else "  -> " + ", ".join(f["tag"] for f in o)))

    if state["status"] == "escalated":
        print(f"\nescalated: {state['escalation']}")
        return state.get("escalation_code", 4)
    if state["status"] == "green":
        print("\ngreen — ready for human-scale checks (first-time-user test, approvals).")
        return 0
    rounds_left = state["cap"] - cur(state)["n"] + 1
    print(f"\nopen. {rounds_left} round(s) left before the cap.")
    return 0


def cmd_reset(_a: argparse.Namespace) -> int:
    if STATE.exists():
        STATE.unlink()
        print(f"removed {STATE}")
    else:
        print("nothing to reset")
    return 0


# ---------------------------------------------------------------- cli

def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("start", help="begin a bounded review loop")
    s.add_argument(
        "--cap", type=int, default=5,
        help="max rounds (this workflow: 5; Anthropic team policy: 3 then rethink)",
    )
    s.add_argument("--risk", choices=("low", "medium", "high"), default="medium")
    s.add_argument("--feature", default=None)
    s.add_argument("--force", action="store_true", help="replace an existing loop")
    s.set_defaults(fn=cmd_start)

    f = sub.add_parser("finding", help="record a reviewer finding")
    f.add_argument("--tag", required=True,
                   help="stable slug for the finding class, e.g. auth:unchecked-index")
    f.add_argument("--severity", required=True, choices=SEVERITIES)
    f.add_argument("--file", default=None)
    f.add_argument("--line", type=int, default=None)
    f.add_argument("--round", type=int, default=None)
    f.set_defaults(fn=cmd_finding)

    v = sub.add_parser("resolve", help="mark a finding fixed")
    v.add_argument("--tag", required=True)
    v.set_defaults(fn=cmd_resolve)

    r = sub.add_parser("round", help="close the current round")
    r.add_argument("--verdict", required=True, choices=("pass", "fail"))
    r.add_argument("--note", default=None)
    r.set_defaults(fn=cmd_round)

    sub.add_parser("status", help="show loop state").set_defaults(fn=cmd_status)
    sub.add_parser("reset", help="delete loop state").set_defaults(fn=cmd_reset)

    a = p.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
