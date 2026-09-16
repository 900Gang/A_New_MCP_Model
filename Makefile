# PRD §6.1 — the single dev entry point. Everything a developer or CI runs is a
# make target; there are no undocumented commands.
.DEFAULT_GOAL := help
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

BACKEND  := backend
FRONTEND := frontend
# UV runs inside $(BACKEND); UV_ROOT runs from the repository root.
UV       := uv run
UV_ROOT  := uv run --project $(BACKEND)
COMPOSE  := docker compose

# Packages held to the §11.6 coverage gate.
COV_PKGS := --cov=app/services --cov=app/mcp --cov=app/oauth --cov=app/core

# Run a frontend command, or announce a visible skip if the workspace is absent.
define frontend
	@if [ -f $(FRONTEND)/package.json ]; then \
	  cd $(FRONTEND) && $(1); \
	else \
	  printf '  \033[33m--\033[0m frontend not scaffolded yet, skipped: %s\n' "$(1)"; \
	fi
endef

# Run a backend script, or announce a visible skip if it has not been written
# yet. The skip disappears on its own the moment the module lands.
define bscript
	@if [ -f $(BACKEND)/scripts/$(1) ]; then \
	  cd $(BACKEND) && $(UV) python scripts/$(1) $(2); \
	else \
	  printf '  \033[33m--\033[0m not written yet, skipped: scripts/%s\n' "$(1)"; \
	fi
endef

.PHONY: help
help:  ## Show this help
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

# ── Environment ───────────────────────────────────────────────────────────────
.PHONY: install
install:  ## Install backend + frontend dependencies from the lockfiles
	cd $(BACKEND) && uv sync --all-groups --frozen
	$(call frontend,pnpm install --frozen-lockfile)

.PHONY: hooks
hooks:  ## Install git pre-commit and commit-msg hooks
	$(UV_ROOT) pre-commit install --install-hooks
	$(UV_ROOT) pre-commit install --hook-type commit-msg

.PHONY: doctor
doctor:  ## Verify the local toolchain matches what the PRD requires
	@bash scripts/doctor.sh

# ── Local stack ───────────────────────────────────────────────────────────────
.PHONY: up
up:  ## Start Postgres, Redis, MinIO and Mailpit
	$(COMPOSE) up -d postgres redis minio mailpit
	@echo "waiting for health..." && $(COMPOSE) ps

.PHONY: down
down:  ## Stop the local stack (volumes preserved)
	$(COMPOSE) down

.PHONY: nuke
nuke:  ## Stop the local stack and DESTROY its volumes
	$(COMPOSE) down -v

.PHONY: dev
dev: up migrate  ## Run the API and the arq worker against the local stack
	$(COMPOSE) up api worker

.PHONY: logs
logs:  ## Tail local stack logs
	$(COMPOSE) logs -f --tail=100

# ── Database ──────────────────────────────────────────────────────────────────
.PHONY: migrate
migrate:  ## Apply all migrations
	cd $(BACKEND) && $(UV) alembic upgrade head

.PHONY: migration
migration:  ## Autogenerate a migration: make migration m="add bookings"
	cd $(BACKEND) && $(UV) alembic revision --autogenerate -m "$(m)"

.PHONY: migrate-roundtrip
migrate-roundtrip:  ## CI gate: upgrade head, downgrade -1, upgrade head again
	@if [ -f $(BACKEND)/alembic.ini ]; then \
	  cd $(BACKEND) && $(UV) alembic upgrade head && $(UV) alembic downgrade -1 && $(UV) alembic upgrade head; \
	else printf '  \033[33m--\033[0m alembic.ini not present yet, skipped\n'; fi

.PHONY: seed
seed:  ## Load the deterministic development dataset
	$(call bscript,seed_dev_data.py,)

# ── Quality gates (§11.6) ─────────────────────────────────────────────────────
.PHONY: lint
lint:  ## ruff lint + format check (backend) and eslint (frontend)
	cd $(BACKEND) && $(UV) ruff check --config ruff.toml .
	cd $(BACKEND) && $(UV) ruff format --check --config ruff.toml .
	# Repository-root scripts are Python too — they get the same gates.
	$(UV_ROOT) ruff check --config $(BACKEND)/ruff.toml scripts/
	$(UV_ROOT) ruff format --check --config $(BACKEND)/ruff.toml scripts/
	$(call frontend,pnpm lint)

.PHONY: format
format:  ## Apply ruff and prettier formatting
	cd $(BACKEND) && $(UV) ruff check --fix --config ruff.toml .
	cd $(BACKEND) && $(UV) ruff format --config ruff.toml .
	$(UV_ROOT) ruff check --fix --config $(BACKEND)/ruff.toml scripts/
	$(UV_ROOT) ruff format --config $(BACKEND)/ruff.toml scripts/
	$(call frontend,pnpm format)

.PHONY: typecheck
typecheck:  ## mypy --strict (backend) and tsc --noEmit (frontend)
	cd $(BACKEND) && $(UV) mypy --config-file mypy.ini
	$(UV_ROOT) mypy --config-file $(BACKEND)/mypy.ini scripts/
	$(call frontend,pnpm typecheck)

.PHONY: arch
arch:  ## import-linter — architectural rules A1-A4
	cd $(BACKEND) && $(UV) lint-imports --config .importlinter

.PHONY: codeowners
codeowners:  ## Verify CODEOWNERS routes every (SEC) file in PRD §6
	python3 scripts/check_codeowners.py

# ── Tests (§11.2) ─────────────────────────────────────────────────────────────
.PHONY: test
test:  ## Full backend suite with coverage
	cd $(BACKEND) && $(UV) pytest $(COV_PKGS) --cov-report=term-missing --cov-report=xml

.PHONY: test-unit
test-unit:  ## Fast loop: unit tests only, no containers
	cd $(BACKEND) && $(UV) pytest tests/unit -m unit

.PHONY: test-integration
test-integration:  ## Real Postgres 16 + Redis 7 via testcontainers
	cd $(BACKEND) && $(UV) pytest tests/integration -m integration

.PHONY: test-security
test-security:  ## Authz matrix, OAuth conformance, secure defaults, PII redaction
	cd $(BACKEND) && $(UV) pytest tests/security -m security

.PHONY: test-contract
test-contract:  ## MCP tool schemas, OpenAPI snapshot, adapter contracts
	cd $(BACKEND) && $(UV) pytest tests/contract -m contract

.PHONY: coverage-gate
coverage-gate:  ## Enforce >=90% line / >=85% branch on services, mcp, oauth
	cd $(BACKEND) && $(UV) pytest $(COV_PKGS) --cov-report=json:coverage.json
	cd $(BACKEND) && $(UV) python scripts/check_coverage.py --min-line 90 --min-branch 85

.PHONY: test-frontend
test-frontend:  ## vitest with coverage
	$(call frontend,pnpm test:coverage)

.PHONY: e2e
e2e:  ## Playwright journeys + axe accessibility against the local stack
	$(call frontend,pnpm e2e)

# ── Security (§10, §11.6) ─────────────────────────────────────────────────────
.PHONY: security
security: sast sca secrets  ## Run every security gate

.PHONY: sast
sast:  ## bandit + semgrep (OWASP ruleset + the nine custom rules)
	cd $(BACKEND) && $(UV) bandit -c bandit.yaml -r app -ll
	$(UV_ROOT) semgrep --config .semgrep/bharat-mcp.yml --config p/owasp-top-ten --error backend/app

.PHONY: sca
sca:  ## Dependency CVE audit on the lockfiles
	# Audit the LOCKFILE, not the live venv: §10.6 pins by hash, and pip-audit
	# cannot inspect our own editable package.
	cd $(BACKEND) && uv export --all-groups --no-emit-project --no-hashes \
	  --format requirements-txt -o .audit-requirements.txt -q
	cd $(BACKEND) && $(UV) pip-audit --strict -r .audit-requirements.txt
	cd $(BACKEND) && rm -f .audit-requirements.txt
	# osv-scanner cross-checks the OSV database; pip-audit alone reads PyPI advisories.
	osv-scanner scan source --lockfile $(BACKEND)/uv.lock
	$(call frontend,pnpm audit --audit-level=moderate)

.PHONY: secrets
secrets:  ## gitleaks over the full history
	gitleaks detect --config .gitleaks.toml --redact --log-opts="--all"

.PHONY: fuzz
fuzz:  ## schemathesis adversarial requests against a running app
	cd $(BACKEND) && $(UV) schemathesis run http://localhost:8000/openapi.json --checks all

# ── Contracts between backend and frontend ────────────────────────────────────
.PHONY: openapi
openapi:  ## Regenerate the OpenAPI document and the frontend's TypeScript types
	$(call bscript,generate_openapi.py,)
	$(call frontend,pnpm generate:types)

.PHONY: openapi-check
openapi-check:  ## CI gate: fail if the committed OpenAPI doc or types are stale
	$(call bscript,generate_openapi.py,--check)
	$(call frontend,pnpm generate:types && git diff --exit-code src/api/schema.d.ts)

# ── Aggregates ────────────────────────────────────────────────────────────────
.PHONY: check
check: lint typecheck arch codeowners test security openapi-check  ## Everything CI runs, locally

.PHONY: ci
ci: check coverage-gate migrate-roundtrip  ## The full blocking gate set (§11.6)

.PHONY: load
load:  ## k6 load run for exit criterion E4
	k6 run infra/k6/mcp-read-load.js
	k6 run infra/k6/place-order-load.js
