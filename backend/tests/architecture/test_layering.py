"""Architectural rules A1-A4 as an executable assertion (PRD §3.2).

`make arch` runs import-linter directly; this test exists so the same contracts
also fail the *test* suite. A layering violation should be caught by whichever
gate a contributor happens to run first.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

BACKEND_ROOT = Path(__file__).resolve().parents[2]
CONFIG = BACKEND_ROOT / ".importlinter"

# Kept in lockstep with .importlinter by test_every_contract_is_asserted below,
# so adding a contract without listing it here fails rather than passing silently.
EXPECTED_CONTRACTS = (
    "A1/A2 - adapters over services over repositories over models",
    "A2 - services import no web framework and no protocol library",
    "A4 - httpx and aioboto3 are importable only inside app.integrations",
    "A1 - MCP tools reach the database only through services",
    "A3 - sqlalchemy is importable only inside app.db",
    "core imports no other app package",
    "schemas import only app.core",
    "A4 - integrations import no domain package",
)


# The console script, not `python -m importlinter.cli` — that module exposes a
# click command object but runs nothing, so it exits 0 regardless of the graph
# and would make this test incapable of ever failing.
LINT_IMPORTS = Path(sys.executable).parent / "lint-imports"


def _run_import_linter() -> subprocess.CompletedProcess[str]:
    assert LINT_IMPORTS.exists(), f"lint-imports not installed at {LINT_IMPORTS}"
    return subprocess.run(  # noqa: S603
        [str(LINT_IMPORTS), "--config", str(CONFIG)],
        cwd=BACKEND_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )


@pytest.mark.architecture
def test_import_contracts_hold() -> None:
    """Every contract in .importlinter is KEPT."""
    result = _run_import_linter()
    assert result.returncode == 0, (
        "Architectural rules A1-A4 are broken. import-linter reported:\n\n"
        f"{result.stdout}\n{result.stderr}"
    )


@pytest.mark.architecture
def test_every_contract_is_asserted() -> None:
    """The contract list here matches .importlinter exactly.

    Guards against a contract being deleted from the config while this test file
    continues to look reassuringly green.
    """
    declared = {
        line.split("=", 1)[1].strip()
        for line in CONFIG.read_text().splitlines()
        if line.startswith("name =")
    }
    assert declared == set(EXPECTED_CONTRACTS), (
        "Contracts in .importlinter drifted from EXPECTED_CONTRACTS.\n"
        f"only in config: {sorted(declared - set(EXPECTED_CONTRACTS))}\n"
        f"only in test:   {sorted(set(EXPECTED_CONTRACTS) - declared)}"
    )
