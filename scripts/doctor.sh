#!/usr/bin/env bash
# Verify the local toolchain matches what PRD §4 requires.
# Exits non-zero listing every unmet requirement, so `make doctor` is a gate.
set -uo pipefail

fail=0
ok()   { printf '  \033[32m✓\033[0m %-28s %s\n' "$1" "$2"; }
bad()  { printf '  \033[31m✗\033[0m %-28s %s\n' "$1" "$2"; fail=1; }

have() { command -v "$1" >/dev/null 2>&1; }

echo "Bharat MCP — toolchain check (PRD §4)"
echo

# Python 3.12 exactly: 3.13 is excluded because some C-extension wheels lag (§4.1).
if have uv; then
  ok "uv" "$(uv --version)"
  if uv python find 3.12 >/dev/null 2>&1; then
    ok "python 3.12" "$(uv python find 3.12)"
  else
    bad "python 3.12" "not installed — run: uv python install 3.12"
  fi
else
  bad "uv" "not installed — run: brew install uv"
  py=$(command -v python3 || true)
  [ -n "$py" ] && echo "      (system python is $($py --version 2>&1), which PRD §4.1 does not accept)"
fi

# Docker underpins docker-compose AND testcontainers. SQLite as a stand-in is
# banned by §4.2, so without Docker the integration suite cannot run at all.
if have docker && docker info >/dev/null 2>&1; then
  ok "docker" "$(docker --version)"
  docker compose version >/dev/null 2>&1 \
    && ok "docker compose" "$(docker compose version --short 2>/dev/null)" \
    || bad "docker compose" "v2 plugin missing"
else
  bad "docker" "not installed or daemon not running — brew install colima docker docker-compose && colima start"
fi

have node  && ok "node"  "$(node --version)"  || bad "node"  "not installed (>=20 for vite 5)"
have pnpm  && ok "pnpm"  "$(pnpm --version)"  || bad "pnpm"  "not installed — corepack enable pnpm"
have git   && ok "git"   "$(git --version | cut -d' ' -f3)" || bad "git" "not installed"
have osv-scanner && ok "osv-scanner" "$(osv-scanner --version 2>&1 | head -1 | awk '{print $3}')" || bad "osv-scanner" "not installed — brew install osv-scanner"
have gitleaks && ok "gitleaks" "$(gitleaks version 2>&1)" || bad "gitleaks" "not installed — brew install gitleaks"
have k6    && ok "k6"    "$(k6 version 2>&1 | head -1)" || printf '  \033[33m-\033[0m %-28s %s\n' "k6" "optional until load testing (E4)"

echo
if [ "$fail" -ne 0 ]; then
  echo "Toolchain incomplete. The quality gates cannot run until the items marked ✗ are installed."
  exit 1
fi
echo "Toolchain complete."
