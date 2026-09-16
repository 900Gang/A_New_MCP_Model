"""Enforce both coverage floors from PRD §11.6: >=90% line and >=85% branch.

Owned by one script rather than split between ``--cov-fail-under`` and a helper,
because pytest-cov and coverage.py disagree about the empty case: on a package
with no statements, ``--cov-fail-under=90`` prints

    Required test coverage of 90% reached. Total coverage: 100.00%

which is a gate reporting success over nothing. This script reports that state
explicitly as INACTIVE instead, so a green line always means code was measured.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys

INACTIVE = 0
PASS = 0
FAIL = 1
ERROR = 2


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--min-line", type=float, required=True)
    parser.add_argument("--min-branch", type=float, required=True)
    parser.add_argument("--report", type=pathlib.Path, default=pathlib.Path("coverage.json"))
    args = parser.parse_args()

    if not args.report.exists():
        print(f"error: {args.report} not found — run pytest with --cov-report=json first")
        return ERROR

    totals = json.loads(args.report.read_text())["totals"]
    statements = totals.get("num_statements", 0)
    branches = totals.get("num_branches", 0)

    if statements == 0:
        print(
            "  -- coverage gate INACTIVE: 0 statements measured in the gated packages.\n"
            "     Not a pass. It activates as soon as those packages contain code."
        )
        return INACTIVE

    line_pct = totals["percent_covered"]
    results = [("line", line_pct, args.min_line)]

    if branches == 0:
        print("  note: 0 branches in the gated packages — the branch floor is not yet meaningful")
    else:
        results.append(("branch", 100.0 * totals["covered_branches"] / branches, args.min_branch))

    failed = False
    for name, actual, floor in results:
        verdict = "PASS" if actual >= floor else "FAIL"
        failed |= actual < floor
        print(f"  {name:<7} coverage {actual:6.2f}%  floor {floor:5.2f}%  {verdict}")
    return FAIL if failed else PASS


if __name__ == "__main__":
    sys.exit(main())
