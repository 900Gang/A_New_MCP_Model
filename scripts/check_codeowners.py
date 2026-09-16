"""Verify .github/CODEOWNERS routes every file PRD §6 marks **(SEC)**.

PRD §10.7 requires two approvals for any (SEC) file. CODEOWNERS is what routes
those reviewers, so a (SEC) file absent from CODEOWNERS silently drops to the
one-approval default — the rule appears to hold while not holding.

The (SEC) set is derived from the PRD rather than duplicated here, so marking a
new file (SEC) automatically makes this check demand a CODEOWNERS entry.
"""

from __future__ import annotations

import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
PRD = REPO / "docs" / "PRD-01-core-server-admin-connector.md"
CODEOWNERS = REPO / ".github" / "CODEOWNERS"

# §6's tables name files relative to their own section. Longest prefix wins.
SECTION_ROOTS: tuple[tuple[str, str], ...] = (
    ("db/models/", "backend/app/"),
    ("db/repositories/", "backend/app/"),
    ("api/", "backend/app/"),
    ("mcp/", "backend/app/"),
    ("oauth/", "backend/app/"),
    ("integrations/", "backend/app/"),
    ("workers/", "backend/app/"),
    ("observability/", "backend/app/"),
    ("schemas/", "backend/app/"),
    ("docs/", ""),
)
# Bare filenames, by the section that lists them.
BARE: dict[str, str] = {
    "config.py": "backend/app/core/",
    "logging.py": "backend/app/core/",
    "money.py": "backend/app/core/",
    "security.py": "backend/app/core/",
    "crypto.py": "backend/app/core/",
    "errors.py": "backend/app/core/",
    "exceptions.py": "backend/app/core/",
    "oauth.py": "backend/app/schemas/",   # §6.5 schemas/oauth.py
    "audit_repo.py": "backend/app/db/repositories/",
    "oauth_repo.py": "backend/app/db/repositories/",
    "order_service.py": "backend/app/services/",
    "payment_service.py": "backend/app/services/",
    "audit_service.py": "backend/app/services/",
    ".gitleaks.toml": "",
    "SECURITY.md": "",
}


def sec_files() -> list[str]:
    """Every path the PRD marks (SEC), resolved to a repository path."""
    out: set[str] = set()
    for line in PRD.read_text().splitlines():
        # Only the bold marker counts. Prose mentioning "(SEC)" in backticks
        # — including this document's own amendment log — is not a marking.
        if not line.startswith("|") or "**(SEC)**" not in line:
            continue
        match = re.match(r"\|\s*`([^`]+)`\s*\|", line)
        if not match:
            continue
        label = match.group(1)
        for prefix, root in SECTION_ROOTS:
            if label.startswith(prefix):
                out.add(root + label)
                break
        else:
            if label in BARE:
                out.add(BARE[label] + label)
            else:
                # An unmapped bare filename means BARE/SECTION_ROOTS needs
                # extending — report it rather than guessing a path.
                out.add(f"<unmapped:{label}>")
    return sorted(out)


def owned_patterns() -> list[str]:
    patterns = []
    for line in CODEOWNERS.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        pattern = line.split()[0].lstrip("/")
        if pattern != "*":
            patterns.append(pattern)
    return patterns


def covered(path: str, patterns: list[str]) -> bool:
    return any(p == path or (p.endswith("/") and path.startswith(p)) for p in patterns)


def main() -> int:
    patterns = owned_patterns()
    files = sec_files()
    missing = [f for f in files if not covered(f, patterns)]

    print(f"(SEC) files in PRD §6: {len(files)}   routed by CODEOWNERS: {len(files) - len(missing)}")
    if missing:
        print("\nNOT routed — these would fall back to the one-approval default:")
        for f in missing:
            print(f"  {f}")
        if any(f.startswith("<unmapped:") for f in missing):
            print(
                "\nAn <unmapped:...> entry means this script cannot resolve that label to a\n"
                "repository path — extend BARE or SECTION_ROOTS in this file."
            )
        print("\nAdd each to .github/CODEOWNERS, or remove its (SEC) marking from the PRD.")
        return 1
    print("every (SEC) file is routed for review.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
