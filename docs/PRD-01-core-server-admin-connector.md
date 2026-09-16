# PRD-01 — Bharat MCP: Core MCP Server, Admin Panel & Claude Connector (OAuth) Layer

| Field | Value |
|---|---|
| Document | Product & Engineering Requirements — Task 1 |
| Version | 1.0 |
| Date | 16 September 2026 |
| Owner | Infra/Engineering Lead |
| Sponsor | Reward360 Founder's Office |
| Classification | **Internal — discreet** |
| Source documents | `bharat-mcp-frd.pdf` (FRD v1.0), `bharat-mcp-infra-plan.pdf`, `bharat-mcp-non-technical-requirements.pdf`, `bharat_mcp_handbook.pdf` (HB1), `bharat_mcp_connector_handbook.pdf` (HB2 / Path A) |
| Explicitly NOT in this task | `bharat_mcp_whatsapp_chatbot_handbook.pdf` (HB3 / Path B — WhatsApp customer-facing chatbot) |

---

## 0. How to read this document

This PRD is written to be executed directly. It specifies **every directory, every file, every library, and every table** the Task-1 build needs, plus the security and quality regime the build must follow. A file listed here is a file that gets created; a file not listed here should not appear in the repository without an amendment to this document.

Three rules govern everything below:

1. **One schema, one truth.** Every data shape is defined exactly once, in Pydantic, and reused by the REST layer, the MCP tool layer, the database mapping tests, and (via generated types) the React frontend. Duplicated schema definitions are a defect, not a style choice.
2. **The database is the last line of defence, not the first.** Every invariant enforced in Python is *also* enforced as a Postgres constraint. If application code has a bug, the database must refuse the write rather than persist corruption.
3. **Nothing ships without a test that would have caught its absence.** See §11.

---

## 1. Scope

### 1.1 In scope for Task 1

| Area | FRD IDs | Summary |
|---|---|---|
| Restaurant & menu management | FR-1 … FR-7 | Full CRUD, consent recording, automated smoke test, status lifecycle, CSV bulk import |
| MCP tool surface | FR-8 … FR-13 | All six tools over Streamable HTTP, per MCP specification |
| Order relay & fulfilment | FR-14 … FR-17 | Outbound relay dispatch, inbound accept/reject parsing, status propagation, timeout flagging |
| Payments | FR-18 … FR-20 | UPI intent generation, webhook receipt with retry, COD path |
| AI platform integration | FR-21 … FR-23 | Per-platform credentials, agent-readable errors, zero-downtime key rotation |
| Monitoring & admin visibility | FR-24 … FR-26 | Sentry, uptime alerting, 24h rolling dashboard |
| Admin panel | §3.1, §5 Usability | React + TypeScript SPA usable by non-engineer interns |
| **Connector / OAuth layer (Path A)** | HB2 §7 | OAuth 2.1 authorization server, consent screen, token lifecycle, per-person rate limiting, revocation, tool manifest |

### 1.2 Out of scope for Task 1

WhatsApp customer-facing chatbot (Path B, HB3) · POS integrations · multi-city rollout · restaurant-facing native app · menu OCR · R360 loyalty integration · multi-language menus · third-party delivery-logistics API integration · ChatGPT and Gemini connector submissions (the *server* supports them; the per-platform registration work is a later task).

### 1.3 Deliberate deviations from the source documents, and why

| Deviation | Rationale |
|---|---|
| Infra plan offers "TypeScript/Node *or* Python (FastMCP)". **This PRD fixes Python 3.12 + FastAPI.** | The FRD (the governing functional document) specifies FastAPI/Python explicitly, and §4.2 requires the MCP layer to be mounted as an ASGI sub-app sharing Pydantic schemas with the REST layer. That shared-schema requirement is only satisfiable in one runtime. |
| WhatsApp BSP and PSP (Razorpay vs Cashfree) are **still undecided** per the source docs, but are Must-have FRD requirements. | Both are built behind a **provider-adapter interface** with a fully functional in-repo fake. The entire order → relay → accept → payment loop is buildable, testable and demoable *before* either commercial contract is signed. Swapping in the real provider is a single adapter class plus configuration, with no change to domain logic. This removes the longest external dependency from the critical path. |
| `book_table` (FR-13, "Should", flagged open) is **built**, but ships **disabled by default** behind a per-restaurant flag. | Building it now costs ~2 days; retrofitting a `bookings` aggregate later costs far more. Shipping it off by default means the pilot decision can be made at any time without a code change. |
| Delivery model (pickup / restaurant fleet / 3P logistics) is **undecided**. | `orders.fulfilment_type` is modelled as an enum from day one with `PICKUP` and `DINE_IN` implemented, `OWN_DELIVERY` and `THIRD_PARTY_DELIVERY` present in the enum and rejected at the service boundary until enabled. The data model does not need rework when the decision lands. |
| HB3 §8.1 shows model id `claude-sonnet-4-6`. | **That model id does not exist.** Current Claude models are `claude-opus-5`, `claude-sonnet-5`, `claude-fable-5-1`, `claude-haiku-4-5-20251001`. Task 1 does not call an LLM API at all, so this affects nothing here — recorded so it is not copied into Path B later. |

---

## 2. Goals & success criteria

### 2.1 Product goals

- **G1** — An AI agent authenticated via the connector path can complete search → menu → availability → order → status against real pilot data, with no Reward360 app in between.
- **G2** — An intern with no engineering background can onboard a restaurant end-to-end (record, menu, consent, smoke test, go-live) after a single walkthrough, with zero engineering intervention.
- **G3** — A restaurant with no POS receives an order on WhatsApp within 30 seconds and can accept or reject it with a one-word reply.

### 2.2 Engineering goals (the stated aim of this task)

- **G4 — Security.** The system passes a full Secure SDLC regime (§10) with no open High or Critical finding at go-live, and no Medium finding without a documented, time-bound accepted risk.
- **G5 — Correctness.** No duplicate order and no duplicate charge is reachable by any interleaving of retries, concurrent calls, or partial failures. This is the single highest-severity defect class in this system and is treated as such throughout (§11.4).
- **G6 — Determinism.** No test is flaky. No behaviour depends on wall-clock time, machine timezone, dict ordering, or float arithmetic.

### 2.3 Task-1 exit criteria

| # | Criterion | How verified |
|---|---|---|
| E1 | All 26 FRD requirements implemented, each traceable to a named test | Traceability matrix, §14 |
| E2 | All six MCP tools callable from Claude with a real OAuth-connected account | Live transcript, recorded |
| E3 | OAuth 2.1 flow passes PKCE, resource-indicator, rotation and revocation conformance tests | `tests/security/test_oauth_conformance.py` |
| E4 | p95 ≤ 1.5 s for `search_restaurants` / `get_menu`, ≤ 3 s for `place_order` under 20 rps | k6 load report |
| E5 | CI gate green: mypy strict, ruff, bandit, semgrep, pip-audit, gitleaks, ≥90% line / ≥85% branch coverage on `app/services` and `app/mcp` | CI run |
| E6 | Zero Critical/High from SAST, SCA and the manual threat-model review | Security sign-off, §10.8 |
| E7 | 50 restaurants onboarded by an intern on staging without engineering help | Ops dry run |

---

## 3. Architecture

### 3.1 Component view

```
                         ┌───────────────────────────────┐
   Claude.ai / Claude app│  Connector Directory listing   │
   (end user)            └───────────────┬───────────────┘
        │                                │ discovery
        │ OAuth 2.1 (PKCE, RFC 8707)     │
        ▼                                ▼
┌────────────────────────────────────────────────────────────────────┐
│                   Bharat MCP — single FastAPI service              │
│                                                                    │
│  /oauth/*        Authorization Server  (authorize, token, consent, │
│                  register, revoke, jwks, .well-known metadata)     │
│  /mcp            MCP Streamable HTTP sub-app  → 6 tools            │
│  /api/v1/*       Admin REST API (cookie session + CSRF)            │
│  /webhooks/*     PSP payment webhooks, BSP inbound relay webhooks  │
│  /healthz /readyz /metrics                                         │
│                                                                    │
│  ── shared Pydantic schema layer (single source of truth) ──       │
│  ── domain services (orders, menu, onboarding, payments) ──        │
│  ── repository layer (tenant-scoped, async SQLAlchemy) ──          │
└───────┬─────────────────┬──────────────────┬───────────────────────┘
        │                 │                  │
   ┌────▼────┐      ┌─────▼─────┐     ┌──────▼──────┐
   │Postgres │      │   Redis   │     │  R2 (S3)    │
   │ system  │      │ idem keys │     │ menu images │
   │of record│      │ sessions  │     └─────────────┘
   └─────────┘      │ ratelimit │
        │           └───────────┘
        │ transactional outbox
   ┌────▼──────────────────────┐
   │  arq worker (async jobs)  │
   │ relay dispatch · timeouts │
   │ webhook retry · smoke test│
   └────┬─────────────┬────────┘
        │             │
   ┌────▼────┐   ┌────▼─────┐
   │ WhatsApp│   │ Razorpay/│
   │ BSP     │   │ Cashfree │
   │ adapter │   │ adapter  │
   └─────────┘   └──────────┘

   React + TypeScript admin SPA  ──HTTPS──▶  /api/v1/*
```

### 3.2 Non-negotiable architectural rules

| # | Rule | Enforcement |
|---|---|---|
| A1 | The MCP layer contains **no business logic**. Tools are thin adapters: validate → call a domain service → map result/error to agent-readable output. | Code review + `tests/architecture/test_layering.py` (import-graph assertion) |
| A2 | Domain services **never** import FastAPI, Starlette, or `mcp`. They are framework-free and unit-testable with no ASGI app. | Import-linter contract in CI |
| A3 | Every repository method takes an explicit tenant scope. There is **no** unscoped `SELECT * FROM menu_items`. | Repository base class enforces it; lint rule forbids raw session use outside `db/repositories/` |
| A4 | All external I/O (BSP, PSP, storage, clock, uuid) goes through a `Protocol` defined in `app/integrations/` with a fake implementation in `tests/fakes/`. | Import-linter; no `httpx` import outside `app/integrations/` |
| A5 | Money is **integer paise** everywhere — Python, Postgres, JSON, and TypeScript. Floats for money are a CI failure. | Custom ruff rule + `tests/unit/test_money.py` |
| A6 | All datetimes are timezone-aware UTC. Display-local conversion happens only in the React layer and in relay message rendering. | `TIMESTAMPTZ` columns only; ruff-banned `datetime.utcnow()` |
| A7 | Writes that must cause an external side effect are committed with an **outbox row in the same transaction**. Nothing dispatches to WhatsApp or a PSP from inside a request handler. | `tests/integration/test_outbox.py` |

---

## 4. Technology stack

Versions are **minimum floors**; exact versions are pinned with hashes in `uv.lock` / `pnpm-lock.yaml` at first install and updated only via a reviewed dependency-bump PR (§10.6).

### 4.1 Backend

| Concern | Library | Version floor | Why this one |
|---|---|---|---|
| Runtime | CPython | 3.12.x | Per-interpreter GIL improvements, `asyncio` maturity, full `typing` support used by the strict-mypy regime. Not 3.13 — some C-extension wheels in this set lag. |
| Package/lockfile manager | `uv` | 0.4 | Deterministic, hash-pinned resolution; 10–100× faster CI installs than pip. |
| Web framework | `fastapi` | 0.115 | FRD-mandated. Native Pydantic v2, ASGI sub-app mounting (required by FRD §4.2), automatic OpenAPI for frontend codegen. |
| ASGI server | `uvicorn[standard]` | 0.32 | uvloop + httptools. Run under `gunicorn` `UvicornWorker` in production for worker supervision. |
| Process manager | `gunicorn` | 23.0 | Pre-fork supervision, graceful reload for zero-downtime key rotation (FR-23). |
| Validation / schemas | `pydantic` | 2.9 | The single-source-of-truth layer. v2's Rust core keeps validation off the p95 budget. |
| Settings | `pydantic-settings` | 2.5 | Typed, validated config from env; fails fast at boot on a missing or malformed secret. |
| ORM | `sqlalchemy[asyncio]` | 2.0.35 | 2.0 typed ORM, `Mapped[]` annotations mypy can actually check. |
| DB driver | `asyncpg` | 0.30 | Fastest async Postgres driver; native prepared statements. |
| Migrations | `alembic` | 1.13 | Autogenerate + hand-reviewed; every migration has a tested downgrade. |
| Cache / idempotency / rate limit | `redis` (redis-py, asyncio) | 5.1 | `aioredis` is merged into redis-py and is no longer separately maintained — the infra plan's "redis-py/aioredis" is satisfied by redis-py alone. |
| MCP protocol | `mcp` (official Python SDK) | 1.9 | Reference implementation of Streamable HTTP transport and the 2025-06-18 auth revision. Do **not** hand-roll the protocol. |
| Background jobs | `arq` | 0.26 | Async-native, Redis-backed, ~1k LOC. Celery's prefork model fights an async codebase and adds a broker we do not otherwise need. |
| OAuth 2.1 AS | `authlib` | 1.3 | Framework-agnostic `authlib.oauth2.rfc6749` grant machinery; we supply a thin Starlette adapter. Hand-rolling an authorization server is the single worst security decision available here. |
| JWT sign/verify | `pyjwt[crypto]` | 2.9 | EdDSA (Ed25519) access tokens; `cryptography` backend. |
| Password/secret hashing | `argon2-cffi` | 23.1 | Argon2id for admin passwords. (`passlib` is effectively unmaintained — do not use it.) |
| Token hashing | `hashlib` (stdlib) | — | SHA-256 for refresh-token and API-key lookup digests; these are high-entropy secrets, so a slow KDF is unnecessary and harmful to p95. |
| HTTP client | `httpx` | 0.27 | Async, timeouts mandatory, connection pooling; only importable inside `app/integrations/`. |
| Retry/backoff | `tenacity` | 9.0 | Declarative retry policy for PSP/BSP calls with jitter. |
| Structured logging | `structlog` | 24.4 | JSON logs with bound request/trace/tenant context; PII redaction processor. |
| Error tracking | `sentry-sdk[fastapi]` | 2.17 | FR-24. Configured with `send_default_pii=False` and a scrubbing `before_send`. |
| Metrics | `prometheus-client` | 0.21 | `/metrics` for uptime/latency SLO tracking (FR-25). |
| Tracing | `opentelemetry-sdk` + FastAPI/SQLAlchemy/Redis instrumentation | 1.27 | One trace id spans MCP call → service → DB → outbox → worker → BSP. Essential for the three-layer debugging problem. |
| Phone validation | `phonenumbers` | 8.13 | E.164 normalisation for restaurant and customer numbers. Prevents an entire class of relay-delivery failure. |
| Object storage | `aioboto3` | 13.2 | S3-compatible → Cloudflare R2. Presigned PUT for direct browser upload (images never transit the API). |
| Image validation | `Pillow` | 11.0 | Server-side magic-byte + dimension validation of uploaded menu images; re-encode to strip EXIF/GPS. |
| CSV import | stdlib `csv` + `pydantic` | — | FR-7. No pandas — an 80 MB dependency for row validation is unjustified. |
| Timezone | stdlib `zoneinfo` | — | `Asia/Kolkata` for restaurant hours. No `pytz`. |

### 4.2 Backend — development & quality

| Concern | Tool | Purpose |
|---|---|---|
| Lint + format | `ruff` ≥0.7 | Lint, import sort, format. Replaces black/isort/flake8/pyupgrade. Banned-API config rejects `datetime.utcnow`, `os.getenv` outside `config.py`, `Decimal` in money paths, and `passlib`/`pytz`/`pandas`; `BLE`/`E722` reject bare `except`; `DTZ` rejects naive datetimes. **`float` in a money path is not expressible in ruff (no plugin system) — it is Semgrep rule 4 in §10.5.** |
| Types | `mypy` ≥1.13, `--strict` | Zero `Any` in `app/`. `disallow_untyped_defs`, `warn_return_any`, `no_implicit_optional` all on. |
| Architecture rules | `import-linter` ≥2.1 | Machine-enforces A1–A4 in §3.2. |
| Security SAST | `bandit` ≥1.7, `semgrep` ≥1.95 | Python security lint + custom rules (§10.5). |
| Dependency audit | `pip-audit` ≥2.7, `osv-scanner` ≥2.6 | CVE scan on the lockfile every CI run and nightly. Both run in `make sca`: `pip-audit` against the **exported lockfile** (it cannot audit the project's own editable package), `osv-scanner` against `uv.lock` directly. |
| Secret scanning | `gitleaks` ≥8.21 + `detect-secrets` | Pre-commit and CI; blocks a committed key before it reaches history. |
| Test runner | `pytest` ≥8.3, `pytest-asyncio` ≥0.24 | `asyncio_mode=strict`. |
| Coverage | `pytest-cov` / `coverage[toml]` ≥7.6 | Branch coverage, per-package thresholds. |
| Real-dependency tests | `testcontainers[postgres,redis]` ≥4.8 | Integration tests run against real Postgres 16 and Redis 7. SQLite-as-a-stand-in is banned — it does not have our constraints, types, or locking semantics. |
| Property-based tests | `hypothesis` ≥6.115 | Idempotency, money arithmetic, state-machine transitions. |
| API fuzzing | `schemathesis` ≥3.38 | Generates adversarial requests from the OpenAPI schema; catches 500s the example-based tests miss. |
| Fixtures | `polyfactory` ≥2.18 | Typed factories derived from the Pydantic models — no drift between factory and schema. |
| Time control | `time-machine` ≥2.16 | Deterministic tests for hours, timeouts, token expiry. |
| HTTP mocking | `respx` ≥0.21 | Pins the httpx layer in adapter tests (the fakes cover everything above it). |
| Load testing | `k6` | E4 p95 verification. |
| Pre-commit | `pre-commit` ≥4.0 | Runs ruff, mypy, gitleaks, and the migration-safety check locally. |

### 4.3 Frontend

| Concern | Library | Version floor | Why |
|---|---|---|---|
| Language | TypeScript | 5.6 | `strict: true` plus `noUncheckedIndexedAccess`, `exactOptionalPropertyTypes`. |
| Framework | React | 18.3 | FRD-mandated. |
| Build | `vite` | 5.4 | Fast HMR, first-class TS, simple CSP-compatible output. |
| Package manager | `pnpm` | 9.x | Strict node_modules layout prevents phantom dependencies; lockfile integrity. |
| Routing | `react-router-dom` | 6.27 | Nested layouts for the restaurant-detail workspace. |
| Server state | `@tanstack/react-query` | 5.59 | Cache, retry, optimistic updates, request dedup. The admin panel is ~90% server state — Redux would be overhead. |
| Client state | `zustand` | 5.0 | Small, for UI-only state (drawer open, table filters). |
| Forms | `react-hook-form` | 7.53 | Uncontrolled inputs — matters for the 60-item menu editor's render cost. |
| Validation | `zod` | 3.23 | Client-side mirror of backend rules, **generated** (not hand-written) from OpenAPI. |
| API client | `openapi-typescript` + `openapi-fetch` | 7.4 / 0.13 | **Types are generated from the live FastAPI OpenAPI document.** A backend schema change that breaks the frontend fails `pnpm typecheck` in CI rather than in production. This is the mechanism that makes "one schema, one truth" real across the language boundary. |
| Styling | `tailwindcss` | 3.4 | Utility CSS; no runtime cost, no CSS-in-JS `unsafe-inline` CSP problem. |
| Components | `@radix-ui/react-*` primitives + local `shadcn/ui`-style wrappers | latest | Accessible, unstyled primitives. Vendored into `components/ui/` so there is no opaque component dependency. |
| Tables | `@tanstack/react-table` | 8.20 | Headless — order list, restaurant list, flagged-order queue. |
| Icons | `lucide-react` | 0.45 | Tree-shakeable. |
| Dates | `date-fns` + `date-fns-tz` | 4.1 | IST rendering of UTC timestamps. |
| Toasts | `sonner` | 1.5 | Non-blocking feedback for intern workflows. |
| Unit/component tests | `vitest` 2.1 + `@testing-library/react` 16 | | Fast, Vite-native. |
| API mocking | `msw` | 2.6 | Handlers generated against the same OpenAPI types. |
| E2E | `@playwright/test` | 1.48 | The FR-1→FR-5 onboarding journey as an executable test. |
| a11y | `@axe-core/playwright` | 4.10 | Intern usability is an FRD non-functional requirement; keyboard/contrast failures are real defects. |
| Lint | `eslint` 9 (flat config) + `typescript-eslint` 8 + `eslint-plugin-security` | | |

### 4.4 Infrastructure & data stores

| Concern | Choice | Notes |
|---|---|---|
| Database | **PostgreSQL 16** (managed: Neon / Supabase / RDS) | Requires `pgcrypto` (gen_random_uuid), `citext` (case-insensitive email), `pg_trgm` (restaurant name fuzzy search for FR-8). |
| Cache / queue | **Redis 7** (managed: Upstash) | Idempotency reservations, admin sessions, rate-limit counters, arq job queue. **Never** the system of record. |
| Object storage | **Cloudflare R2** (S3 API) | Menu images. Private bucket; presigned GET with short TTL; no public bucket policy. |
| Container | Docker, multi-stage, distroless/`python:3.12-slim` final, non-root UID 10001, read-only root filesystem | |
| Orchestration (pilot) | Single small ECS Fargate service or a monitored VPS behind a TLS-terminating load balancer | Per infra plan §7 — deliberately not over-built |
| IaC | Terraform ≥1.9 from day one | Infra plan §7 requires redeployability if the provider changes post-pilot |
| CI/CD | GitHub Actions | Gates in §11.6 |
| Secrets | AWS Secrets Manager / Doppler — **never** `.env` in any deployed environment | §10.4 |

---

## 5. Repository layout

Monorepo, single Git repository, three top-level workspaces.

```
bharat-mcp/
├── README.md
├── CLAUDE.md                          # agent/contributor working rules for this repo
├── SECURITY.md                        # vulnerability disclosure + internal reporting path
├── CONTRIBUTING.md                    # branch, review, commit, migration rules
├── CHANGELOG.md
├── .gitignore  .gitattributes  .editorconfig
├── .pre-commit-config.yaml
├── .gitleaks.toml
├── docker-compose.yml                 # local dev: api, worker, postgres, redis, minio, mailpit
├── Makefile                           # single entry point for every dev command
├── .semgrep/bharat-mcp.yml            # §10.5 custom rules (tree previously omitted)
├── scripts/doctor.sh                  # toolchain check against §4 (amendment A5)
├── docs/
│   ├── PRD-01-core-server-admin-connector.md   # this document
│   ├── source/                        # the five source PDFs this PRD derives from
│   ├── architecture/
│   │   ├── ADR-0001-python-fastapi-runtime.md
│   │   ├── ADR-0002-single-service-mcp-mount.md
│   │   ├── ADR-0003-integer-paise-money.md
│   │   ├── ADR-0004-transactional-outbox.md
│   │   ├── ADR-0005-oauth-as-in-house-vs-idp.md
│   │   ├── ADR-0006-arq-over-celery.md
│   │   └── ADR-0007-idempotency-two-layer.md
│   ├── threat-model.md                # STRIDE per trust boundary — §10.2
│   ├── data-classification.md         # what is PII, retention, who may read it
│   ├── runbooks/
│   │   ├── incident-response.md
│   │   ├── key-rotation.md            # FR-23
│   │   ├── relay-failure.md
│   │   ├── payment-reconciliation.md
│   │   └── restore-from-backup.md
│   ├── onboarding-sop-interns.md      # the single walkthrough G2 refers to
│   └── mcp-tool-manifest.md           # HB2 §7 written tool manifest
│
├── backend/
│   ├── pyproject.toml   uv.lock   .python-version
│   ├── alembic.ini
│   ├── Dockerfile   .dockerignore
│   ├── mypy.ini  ruff.toml  .importlinter  bandit.yaml
│   ├── app/
│   │   ├── __init__.py
│   │   ├── main.py
│   │   ├── asgi.py
│   │   ├── lifespan.py
│   │   ├── core/
│   │   │   ├── config.py      errors.py      exceptions.py
│   │   │   ├── logging.py     security.py    crypto.py
│   │   │   ├── money.py       clock.py       ids.py
│   │   │   ├── pagination.py  constants.py   enums.py
│   │   │   └── result.py
│   │   ├── db/
│   │   │   ├── session.py     base.py        types.py
│   │   │   ├── models/        (16 files — §6.3)
│   │   │   └── repositories/  (11 files — §6.4)
│   │   ├── schemas/           (12 files — §6.5)  ← single source of truth
│   │   ├── services/          (14 files — §6.6)
│   │   ├── api/
│   │   │   ├── deps.py        errors.py      middleware.py
│   │   │   └── v1/            (12 routers — §6.7)
│   │   ├── mcp/
│   │   │   ├── server.py      auth.py        context.py
│   │   │   ├── errors.py      manifest.py
│   │   │   └── tools/         (7 files — §6.8)
│   │   ├── oauth/             (11 files — §6.9)
│   │   ├── integrations/
│   │   │   ├── whatsapp/      payments/      storage/
│   │   ├── workers/           (8 files — §6.11)
│   │   ├── observability/     (4 files)
│   │   ├── templates/         # server-rendered consent & OTP pages (Jinja2)
│   │   └── static/
│   ├── alembic/
│   │   ├── env.py  script.py.mako
│   │   └── versions/
│   ├── scripts/
│   │   ├── seed_dev_data.py   generate_openapi.py
│   │   ├── rotate_platform_key.py  check_migration_safety.py
│   │   └── smoke_test_restaurant.py
│   └── tests/
│       ├── conftest.py
│       ├── fakes/            unit/          integration/
│       ├── contract/         security/      architecture/
│       ├── e2e/              load/
│       └── fixtures/
│
├── frontend/
│   ├── package.json  pnpm-lock.yaml  tsconfig.json  vite.config.ts
│   ├── tailwind.config.ts  postcss.config.js  eslint.config.js
│   ├── playwright.config.ts  vitest.config.ts  Dockerfile  nginx.conf
│   ├── index.html
│   ├── e2e/                           # Playwright specs (§11.2; tree previously omitted)
│   ├── public/
│   └── src/
│       ├── main.tsx  App.tsx  router.tsx  index.css  vite-env.d.ts
│       ├── api/          components/     features/
│       ├── hooks/        lib/            types/
│       └── test/
│
├── infra/
│   ├── terraform/
│   │   ├── main.tf  variables.tf  outputs.tf  versions.tf
│   │   └── modules/{network,database,redis,compute,storage,secrets,monitoring}/
│   ├── docker/
│   │   ├── postgres-init.sql
│   │   └── nginx/security-headers.conf
│   └── k6/
│       ├── mcp-read-load.js
│       └── place-order-load.js
│
└── .github/
    ├── CODEOWNERS
    ├── pull_request_template.md
    ├── dependabot.yml
    └── workflows/
        ├── ci-backend.yml      ci-frontend.yml
        ├── security-scan.yml   e2e.yml
        ├── deploy-staging.yml  deploy-production.yml
        └── nightly-audit.yml
```

---

## 6. File manifest

Every file that Task 1 creates, with its responsibility. Anything marked **(SEC)** is security-critical and requires two-reviewer sign-off per §10.7.

### 6.1 Root & tooling

| File | Responsibility |
|---|---|
| `Makefile` | Single dev entry point: `make dev up down test lint typecheck migrate seed openapi security e2e`. Everything a developer or CI runs is a make target — no undocumented commands. |
| `docker-compose.yml` | Local stack: api, arq worker, Postgres 16, Redis 7, MinIO (R2 stand-in), Mailpit. Matches production versions exactly. |
| `CLAUDE.md` | Repo conventions for any agent/contributor: layering rules, money rule, test-before-merge rule, migration rule. |
| `.pre-commit-config.yaml` | ruff (lint+format), mypy, gitleaks, alembic-safety, `pnpm typecheck` on frontend changes, conventional-commit check. |
| `.gitleaks.toml` | Secret patterns incl. Razorpay `rzp_*`, Cashfree, Meta/WhatsApp tokens, `sk-ant-*`, JWT private keys. **(SEC)** |
| `SECURITY.md` | Internal reporting path, severity definitions, SLA per severity, disclosure policy. **(SEC)** |
| `docs/threat-model.md` | STRIDE analysis per trust boundary; the living document §10.2 is executed against. **(SEC)** |
| `docs/mcp-tool-manifest.md` | HB2 §7's required written tool manifest: exact name, purpose, inputs, outputs, error modes, and data touched for each of the six tools. Feeds the directory listing submission and the consent screen copy. |

### 6.2 Backend — `app/core/`

| File | Responsibility |
|---|---|
| `config.py` | `Settings(BaseSettings)` — every environment variable, typed and validated. Fails at import if a required secret is absent or malformed. Distinct nested models: `DatabaseSettings`, `RedisSettings`, `OAuthSettings`, `PSPSettings`, `BSPSettings`, `StorageSettings`, `ObservabilitySettings`. No `os.getenv` anywhere else in the codebase. **(SEC)** |
| `enums.py` | Every enum in the system, in one place: `RestaurantStatus`, `OrderStatus`, `PaymentMode`, `PaymentStatus`, `FulfilmentType`, `RelayChannel`, `RelayStatus`, `BookingStatus`, `AdminRole`, `OAuthScope`, `AuditAction`, `OutboxStatus`. Declared as `StrEnum` so DB value, JSON value and Python value are one string. |
| `money.py` | `Paise` newtype + arithmetic helpers, `format_inr()`, `parse_rupees_to_paise()`. Guarantees G5's price correctness. Floats raise `TypeError`. **(SEC)** |
| `clock.py` | `Clock` protocol with `now_utc()`; `SystemClock` in prod, `FrozenClock` in tests. Injected, never called statically. Underwrites G6. |
| `ids.py` | UUIDv7 generation (time-ordered — index locality), plus human-facing prefixed ids (`ord_`, `rst_`, `itm_`). Prefixes make a mis-passed id a 400 instead of a silent cross-entity lookup. |
| `errors.py` | Error taxonomy root: `BharatMCPError` with `code`, `http_status`, `agent_message`, `admin_message`, `retryable`. Every raised error is one of these — never a bare `Exception`. Directly implements FR-22. |
| `exceptions.py` | Concrete subclasses: `RestaurantNotFound`, `RestaurantNotActive`, `ItemUnavailable`, `OutsideOperatingHours`, `DuplicateIdempotencyKey`, `PaymentDeclined`, `RelayDispatchFailed`, `ConsentMissing`, `SmokeTestFailed`, `RateLimited`, `TokenRevoked`, `InsufficientScope`, `OutOfCoverageArea`. |
| `security.py` | Argon2id hash/verify, constant-time comparison, secure random token generation, API-key digesting, CSRF token issue/verify. **(SEC)** |
| `crypto.py` | Application-layer encryption for customer contact at rest (AES-256-GCM via `cryptography`), key-id-tagged ciphertext so keys can rotate without a rewrite. **(SEC)** |
| `logging.py` | structlog config: JSON renderer, request-id/trace-id/tenant-id binding, and a **PII redaction processor** that scrubs phone, email, address, token and payment fields before anything is emitted. **(SEC)** |
| `pagination.py` | Cursor pagination (opaque, signed cursors). Offset pagination is banned — it breaks under concurrent inserts and leaks row counts. |
| `result.py` | `Result[T, E]` for expected domain failures, so "item unavailable" is a value, not an exception. Exceptions are reserved for genuinely exceptional states. |
| `constants.py` | Non-configurable constants: Bangalore coverage polygon, max items/order, max menu image bytes, supported MIME types, MCP protocol version. |

### 6.3 Backend — `app/db/` (session, base, models)

| File | Responsibility |
|---|---|
| `db/session.py` | Async engine + `async_sessionmaker`. Pool sizing, `statement_timeout`, `lock_timeout`, `idle_in_transaction_session_timeout` set at connection. Provides `get_session` dependency and a `transaction()` context manager. A connection is never checked out across an `await` on external I/O. |
| `db/base.py` | `Base(DeclarativeBase)`, naming convention for constraints/indexes (so Alembic autogenerate is stable), `TimestampMixin` (`created_at`, `updated_at` TIMESTAMPTZ), `SoftDeleteMixin`. |
| `db/types.py` | Reusable column types: `PaiseType` (BIGINT ↔ `Paise`), `E164Type`, `EncryptedStr` (transparent AES-GCM), `UTCDateTime` (rejects naive datetimes at the driver boundary). |
| `db/models/admin.py` | `AdminUser` (email citext unique, argon2 hash, role, `is_active`, `mfa_secret`, failed-attempt counter, lockout), `AdminSession` (server-side session record, IP + UA fingerprint, revocable). **(SEC)** |
| `db/models/restaurant.py` | `Restaurant` (name, address, `geo_lat/lng`, phone E164, WhatsApp E164, cuisine tags, status, timezone, `accepts_bookings`, `relay_timeout_seconds`, FSSAI number + expiry, GSTIN, `onboarded_at`, `activated_at`), `RestaurantHours` (weekday, open/close, overnight-safe), `RestaurantConsent` (FR-4: actor, method, evidence URI, consented_at, text version — immutable, append-only). |
| `db/models/menu.py` | `MenuCategory` (restaurant_id, name, sort_order), `MenuItem` (category_id, name, description, `price_paise`, `is_veg`, `image_key`, `is_available`, allergen tags, sort_order). |
| `db/models/availability.py` | `AvailabilityOverride` (restaurant_id, nullable menu_item_id, `effective_from/to` TIMESTAMPTZ, reason, created_by). Restaurant-wide when item id is null. Serves FR-3. |
| `db/models/order.py` | `Order` (public `ord_` id, restaurant_id, source platform, end_user_id, `fulfilment_type`, status, `subtotal_paise`/`tax_paise`/`total_paise`, payment_mode, payment_status, encrypted customer contact, `idempotency_key`, `relay_deadline_at`, `flagged_at`, timestamps per state), `OrderItem` (**price-snapshotted**: `menu_item_id`, `name_snapshot`, `unit_price_paise_snapshot`, qty, line total — FRD §6 requirement that historical orders survive a menu price change), `OrderStatusEvent` (append-only transition log with actor, reason, timestamp — FRD Auditability). |
| `db/models/booking.py` | `Booking` (restaurant_id, party_size, slot start/end, status, contact). FR-13, gated by `Restaurant.accepts_bookings`. |
| `db/models/payment.py` | `Payment` (order_id, PSP name, PSP order/payment ids, `amount_paise`, status, UPI intent URI, `expires_at`), `PaymentWebhookEvent` (raw signed payload, signature, verification result, dedupe key, processed_at, attempt count). Raw payloads retained for dispute evidence. **(SEC)** |
| `db/models/relay.py` | `RelayMessage` (order_id, channel, provider message id, template, rendered body, status, attempts, `delivered_at`), `RelayInboundEvent` (from number, raw text, parsed intent, confidence, `matched_order_id`, `needs_human` — FR-15's ambiguous-reply path). |
| `db/models/outbox.py` | `OutboxEvent` (aggregate type/id, event type, payload JSONB, status, attempts, `next_attempt_at`, `locked_by`, `locked_until`, `last_error`). The A7 reliability primitive. |
| `db/models/idempotency.py` | `IdempotencyRecord` (platform/client id, key, `request_fingerprint` SHA-256, `response_snapshot` JSONB, order_id, status, `expires_at`). **Unique constraint `(client_id, idempotency_key)`** — the authoritative duplicate-order guard. **(SEC)** |
| `db/models/oauth.py` | `OAuthClient` (DCR-registered: client_id, hashed secret if confidential, redirect URIs, grant types, scopes, `is_public`, software statement), `AuthorizationCode` (hashed code, PKCE challenge+method, redirect_uri, scope, resource, `expires_at`, `consumed_at`), `RefreshToken` (hashed, family_id for reuse detection, rotation counter, revoked_at), `AccessTokenRecord` (jti, subject, client, scope, `expires_at`, revoked_at — enables instant revocation), `UserConsent` (end_user × client × scopes × granted_at × revoked_at). **(SEC)** |
| `db/models/end_user.py` | `EndUser` (the connected consumer: `sub`, encrypted phone E164, display name, created_at, `disconnected_at`), `OtpChallenge` (hashed OTP, purpose, attempts, expires_at, consumed_at). **(SEC)** |
| `db/models/platform.py` | `PlatformCredential` (platform name, key digest, label, scopes, `active_from`/`active_until`, rotated_from_id). Two overlapping active rows is what makes FR-23 zero-downtime rotation possible. **(SEC)** |
| `db/models/audit.py` | `AuditLog` (actor type+id, action, entity type+id, before/after JSONB diff, IP, UA, request_id, at). Append-only; `REVOKE UPDATE, DELETE` granted at the DB role level. FRD Auditability. **(SEC)** |
| `db/models/onboarding.py` | `SmokeTestRun` (restaurant_id, started/finished, per-check results JSONB, passed, failure summary). FR-5's blocking gate. |
| `db/models/import_job.py` | `CsvImportJob` + `CsvImportRow` (row number, raw payload, status, per-row error list). FR-7 requires errors reported **per row, not per file** — that is only possible with a per-row record. |

### 6.4 Backend — `app/db/repositories/`

Every repository extends `BaseRepository`, which requires an explicit tenant scope and forbids raw session access (rule A3).

| File | Responsibility |
|---|---|
| `base.py` | Generic typed CRUD, cursor pagination, `for_update()` row locking, mandatory tenant filter. |
| `restaurant_repo.py` | Lookup by id/slug, `search()` using `pg_trgm` similarity + geo distance + active-status filter (FR-8), duplicate detection on phone and name+address (FR-1). |
| `menu_repo.py` | Full menu tree for a restaurant in **one** query (`selectinload`) — the N+1 here is the single biggest threat to the FR-9 1.5 s p95. |
| `availability_repo.py` | Effective availability for items at an instant, combining `is_available` and active overrides. |
| `order_repo.py` | Create with line items in one transaction, status transition with optimistic-lock version check, list by restaurant, flagged-order queue. |
| `booking_repo.py` | Slot conflict detection, booking CRUD. |
| `payment_repo.py` | Payment + webhook event persistence, dedupe lookup by provider event id. |
| `relay_repo.py` | Relay message/inbound event persistence, open-order lookup by restaurant WhatsApp number (for reply matching). |
| `outbox_repo.py` | Claim-with-lock batch fetch (`SELECT … FOR UPDATE SKIP LOCKED`), mark done/failed, backoff scheduling. |
| `oauth_repo.py` | Client, code, token, consent persistence. All lookups by **digest**, never by the plaintext secret. **(SEC)** |
| `audit_repo.py` | Append-only writer. Exposes no update or delete method at all. **(SEC)** |

### 6.5 Backend — `app/schemas/` — the single source of truth

These Pydantic models are imported by the REST routers, the MCP tools, the CSV importer, and are the origin of the frontend's generated TypeScript types. A shape defined here is defined nowhere else.

| File | Responsibility |
|---|---|
| `common.py` | `PaiseAmount`, `E164Phone`, `GeoPoint`, `CursorPage[T]`, `ErrorResponse`, `HealthResponse`. |
| `restaurant.py` | `RestaurantCreate/Update/Read/Summary`, `RestaurantHoursIn/Out`, `ConsentRecord`. Field validators: E.164 phones, coordinates inside the Bangalore pilot polygon, FSSAI format, GSTIN checksum. |
| `menu.py` | `MenuCategoryCreate/Update/Read`, `MenuItemCreate/Update/Read`, `MenuTree`. `price_paise: PositiveInt` enforces FR-2's "numeric > 0" in the type itself. |
| `availability.py` | `AvailabilityOverrideCreate/Read`, `ItemAvailability`. |
| `order.py` | `OrderLineIn`, `OrderCreate`, `OrderRead`, `OrderStatusRead`, `OrderStatusTransition`, `CustomerContact`. |
| `booking.py` | `BookingCreate/Read`. |
| `payment.py` | `PaymentIntentRead`, `PaymentWebhookPayload` (per-PSP discriminated union). |
| `admin.py` | `AdminLogin`, `AdminRead`, `SessionRead`, `DashboardSummary` (FR-26's 24 h rolling window). |
| `oauth.py` | `AuthorizeRequest`, `TokenRequest` (discriminated on `grant_type`), `TokenResponse`, `ClientRegistrationRequest/Response`, `IntrospectionResponse`, `AuthorizationServerMetadata` (RFC 8414), `ProtectedResourceMetadata` (RFC 9728). **(SEC)** |
| `mcp_tools.py` | Input/output model **per tool**: `SearchRestaurantsInput/Output`, `GetMenuInput/Output`, `CheckAvailabilityInput/Output`, `PlaceOrderInput/Output`, `GetOrderStatusInput/Output`, `BookTableInput/Output`. These generate the MCP tool JSON Schemas directly — FRD §4.2's "defined once, reused" requirement is literally this file. |
| `csv_import.py` | `RestaurantCsvRow`, `MenuItemCsvRow` with per-field validators, so FR-7's per-row error reporting is a by-product of validation rather than bespoke code. |
| `events.py` | Outbox event payload models, one per event type, discriminated union. Prevents an untyped JSONB blob from becoming an unversioned contract. |

### 6.6 Backend — `app/services/` (framework-free domain logic)

| File | Responsibility |
|---|---|
| `restaurant_service.py` | Create/update with duplicate detection (FR-1), status transitions, coverage-area validation. |
| `menu_service.py` | Category/item CRUD, ordering, price change → audit entry, image key association (FR-2). |
| `availability_service.py` | The one authority on "is this orderable right now": item flag ∧ no active override ∧ restaurant active ∧ within hours in restaurant-local time, DST- and midnight-crossing-safe. Backs FR-3, FR-9, FR-10. |
| `onboarding_service.py` | Consent recording (FR-4), smoke-test orchestration (FR-5), pending → active gate. **`activate()` raises unless consent exists AND the most recent smoke test passed** — the FRD's two hard preconditions, enforced in one place plus a DB CHECK. |
| `smoke_test_service.py` | Runs `get_menu` and a test-mode `place_order` against a real candidate restaurant with `test_mode=True`, persists per-check results. Test orders never dispatch a relay and never create a payment. |
| `order_service.py` | The core aggregate. Validates the cart against live prices, snapshots prices, computes totals in paise, reserves idempotency, creates order + items + status event + outbox row **in a single transaction**, applies the state machine. The most heavily tested file in the repository. **(SEC)** |
| `order_state_machine.py` | Explicit `ALLOWED_TRANSITIONS: dict[OrderStatus, frozenset[OrderStatus]]`. An illegal transition raises. Exhaustively property-tested (§11.4). |
| `booking_service.py` | Slot validation, conflict check, `accepts_bookings` gate (FR-13). |
| `payment_service.py` | UPI intent creation via the PSP adapter, expiry window, webhook verification and application, refund initiation stub, reconciliation query (FR-18/19/20). **(SEC)** |
| `relay_service.py` | Renders the restaurant-facing message, dispatches via the BSP adapter, parses inbound replies (keyword + fuzzy + one-time link token), applies accept/reject, routes ambiguity to `needs_human` (FR-14/15/16). |
| `timeout_service.py` | Scans for orders past `relay_deadline_at`, flags them for intern follow-up, emits an agent-visible `timed_out` signal (FR-17). |
| `dashboard_service.py` | 24 h rolling aggregates for FR-26, computed with indexed time-bucketed queries — never a full table scan. |
| `csv_import_service.py` | Streaming row-by-row parse, validate, per-row error capture, atomic commit per row with job-level summary (FR-7). |
| `audit_service.py` | Uniform `record(actor, action, entity, before, after)` used by every mutating service. **(SEC)** |

### 6.7 Backend — `app/api/` (admin REST layer)

| File | Responsibility |
|---|---|
| `api/deps.py` | Dependencies: `get_current_admin` (session cookie → DB-backed session → user), `require_role(...)`, `get_db`, `get_request_id`, `verify_csrf`. **(SEC)** |
| `api/errors.py` | Maps `BharatMCPError` → RFC 9457 `application/problem+json`. Catch-all handler returns a correlation id and **never** a stack trace or an ORM message. **(SEC)** |
| `api/middleware.py` | Request id, structured access log, security headers, body size cap, timing, trace context propagation. **(SEC)** |
| `api/v1/router.py` | Assembles all v1 routers under `/api/v1`. |
| `api/v1/auth.py` | Admin login (rate-limited, argon2, generic failure message, lockout), logout, session listing/revocation, password change, TOTP enrolment/verify. **(SEC)** |
| `api/v1/restaurants.py` | FR-1, FR-6: CRUD, list with filters, detail with status + last 50 orders. |
| `api/v1/menu.py` | FR-2: category and item CRUD, reordering, availability toggle (FR-3). |
| `api/v1/availability.py` | FR-3: override create/expire. |
| `api/v1/orders.py` | Order list, detail, manual status override (audited), flagged-order queue (FR-17). |
| `api/v1/onboarding.py` | FR-4, FR-5: record consent, trigger smoke test, poll result, activate. |
| `api/v1/uploads.py` | Presigned R2 PUT issuance with content-type and size constraints; post-upload server-side validation and EXIF-stripping re-encode. **(SEC)** |
| `api/v1/imports.py` | FR-7: CSV template download, upload, job status with per-row errors. |
| `api/v1/dashboard.py` | FR-26 summary. |
| `api/v1/platform_keys.py` | FR-23: issue, list, rotate, revoke per-platform credentials. Plaintext shown exactly once, at creation. **(SEC)** |
| `api/v1/webhooks.py` | PSP payment webhooks and BSP inbound-message webhooks. Signature verified **before** parsing; replay-protected by provider event id; always returns 2xx quickly and defers work to the outbox. **(SEC)** |

### 6.8 Backend — `app/mcp/` (the AI-agent surface)

| File | Responsibility |
|---|---|
| `mcp/server.py` | Constructs the MCP server (official SDK), registers the six tools, exposes the Streamable HTTP ASGI app mounted at `/mcp` in `main.py`. FRD §4.2. |
| `mcp/auth.py` | Bearer-token verification for every tool call: signature, expiry, `aud` (**resource indicator, RFC 8707**) binding, jti revocation check, scope check. **Rejects any token not issued for this resource — no token passthrough, ever** (an explicit MCP security requirement and the defence against confused-deputy attacks). **(SEC)** |
| `mcp/context.py` | Per-call context: authenticated `EndUser` or platform principal, scopes, request id, trace id, rate-limit bucket. |
| `mcp/errors.py` | Translates domain exceptions into **agent-readable** results — FR-22 is implemented here and nowhere else. "Paneer Butter Masala is sold out at Spice Route right now." is the output; an exception class name or stack trace never reaches an agent. Includes a machine `code` so agents can branch. |
| `mcp/manifest.py` | Programmatic tool manifest (names, descriptions, schemas) served for the directory listing and kept in lockstep with `docs/mcp-tool-manifest.md` by a test. |
| `mcp/tools/search_restaurants.py` | FR-8. Location + cuisine + free-text, active-only, coverage-bounded, cursor-paged. Out-of-area queries return a graceful, explanatory message rather than an empty list (HB2 §9's regional-scope risk). |
| `mcp/tools/get_menu.py` | FR-9. Full structured tree; **unavailable items are flagged, never omitted** — the FRD is explicit and a test asserts it. |
| `mcp/tools/check_availability.py` | FR-10. Delegates entirely to `availability_service`. |
| `mcp/tools/place_order.py` | FR-11. Requires an idempotency key; enforces scope `orders:write`; returns the identical order on a repeated key. **(SEC)** |
| `mcp/tools/get_order_status.py` | FR-12. Returns state + timestamp history; ownership-checked against the calling principal. |
| `mcp/tools/book_table.py` | FR-13. Refuses politely when the restaurant has not opted in. |
| `mcp/tools/__init__.py` | Registry; a tool absent here is not exposed. Deliberately narrow surface (HB1 §5: there is no "charge card" or "delete restaurant" tool, and there must never be). |

### 6.9 Backend — `app/oauth/` (Path A connector layer) **(all SEC)**

Standards implemented: **OAuth 2.1** (draft-consolidated), **RFC 7636 PKCE S256 (mandatory)**, **RFC 8414** AS metadata, **RFC 9728** protected-resource metadata, **RFC 7591** dynamic client registration, **RFC 8707** resource indicators, **RFC 7009** revocation, **RFC 9700** best current practice.

| File | Responsibility |
|---|---|
| `oauth/metadata.py` | `/.well-known/oauth-authorization-server` and `/.well-known/oauth-protected-resource`. These are how Claude discovers how to authenticate — the first thing the connector touches. |
| `oauth/registration.py` | RFC 7591 dynamic client registration, rate-limited, redirect-URI validated (exact match; no wildcards; loopback rules per OAuth 2.1). |
| `oauth/authorize.py` | `GET /oauth/authorize` — validates client, redirect URI, scopes, `resource`, PKCE challenge; starts the end-user login; renders consent. Rejects `response_type=token` (implicit flow is removed in 2.1). |
| `oauth/consent.py` | Renders and records the consent screen (HB2 §5.2): exactly what data is shared, what actions are authorised, who Reward360 is, and a link to the privacy policy. Consent is persisted per user × client × scope set, and re-prompted on scope escalation. |
| `oauth/token.py` | `POST /oauth/token` — `authorization_code` (with PKCE verifier) and `refresh_token` grants. Codes are single-use, short-lived, and bound to client + redirect URI + PKCE + resource. Refresh tokens **rotate on every use with reuse detection**: a replayed refresh token revokes the entire token family. |
| `oauth/revocation.py` | RFC 7009 `/oauth/revoke`, plus the user-initiated disconnect path. Revocation is **immediate and server-side** — HB2 §7 requires that a disconnected token stops working at Bharat MCP, not merely inside Claude's memory. |
| `oauth/jwks.py` | `/oauth/jwks.json`. Ed25519 signing keys with `kid`, overlapping publication window so rotation never breaks an in-flight token (also satisfies FR-23 for this path). |
| `oauth/tokens.py` | Issue/verify access tokens: `iss`, `sub`, `aud` = this resource, `scope`, `jti`, `exp` (15 min), `iat`, `client_id`. Refresh: 30 days, opaque, hashed at rest. |
| `oauth/userauth.py` | End-user identity for the pilot: **phone number + WhatsApp/SMS OTP** — no consumer passwords are created, stored, or transmitted, which removes the entire credential-storage risk class for end users. Rate-limited, attempt-capped, constant-time verified. |
| `oauth/scopes.py` | Scope definitions and human-readable descriptions surfaced verbatim on the consent screen: `restaurants:read`, `orders:write`, `orders:read`, `bookings:write`. Least privilege; `orders:write` is never implied by a read scope. |
| `oauth/ratelimit.py` | Per-subject and per-client token-bucket limits (HB2 §7's "per-person rate limiting"), so one compromised token cannot exhaust the shared pilot server. |

### 6.10 Backend — `app/integrations/` (external adapters)

Each package exports a `Protocol`, a real adapter, and a fake. Nothing above this layer knows which vendor is configured (deviation §1.3).

| File | Responsibility |
|---|---|
| `integrations/whatsapp/base.py` | `RelayProvider` protocol: `send_template`, `send_text`, `verify_webhook`, `parse_inbound`. |
| `integrations/whatsapp/meta_cloud.py` | Meta WhatsApp Cloud API adapter. |
| `integrations/whatsapp/gupshup.py` | BSP adapter (Gupshup/Twilio-shaped). |
| `integrations/whatsapp/sms_fallback.py` | SMS fallback for FR-14. |
| `integrations/whatsapp/fake.py` | In-memory provider; records sends, lets tests inject inbound replies. Makes the full relay loop testable with no vendor contract. |
| `integrations/payments/base.py` | `PaymentProvider` protocol: `create_upi_intent`, `verify_webhook_signature`, `fetch_payment`, `refund`. |
| `integrations/payments/razorpay.py` / `cashfree.py` | The two candidate PSPs. Signature verification is constant-time. **(SEC)** |
| `integrations/payments/fake.py` | Deterministic fake supporting success, failure, delay and duplicate-webhook scenarios. |
| `integrations/storage/base.py` | `ObjectStorage` protocol: presigned put/get, delete, head. |
| `integrations/storage/r2.py` | Cloudflare R2 via aioboto3. |
| `integrations/storage/fake.py` | Local/in-memory storage for tests and offline dev. |

### 6.11 Backend — `app/workers/` (arq)

| File | Responsibility |
|---|---|
| `workers/main.py` | arq `WorkerSettings`: queues, concurrency, timeouts, retry policy, cron registration, health reporting. |
| `workers/outbox_dispatcher.py` | Polls `outbox_events` with `FOR UPDATE SKIP LOCKED`, dispatches, applies exponential backoff with jitter, moves exhausted events to a dead-letter state **with an alert**. The FR-14 30-second guarantee is this loop's SLO. |
| `workers/relay_dispatch.py` | Renders and sends the restaurant message; records `RelayMessage`. |
| `workers/relay_timeout.py` | Cron (every 60 s): flags orders past `relay_deadline_at` (FR-17) and notifies the admin queue. |
| `workers/payment_webhook_retry.py` | FR-20's ≥3 retries with alerting on final failure; idempotent application. |
| `workers/smoke_test_runner.py` | Async execution of FR-5 so the admin UI is never blocked on it. |
| `workers/csv_import_runner.py` | Async CSV processing with progress reporting (FR-7). |
| `workers/token_cleanup.py` | Cron: purges expired auth codes, access-token records, OTP challenges, and idempotency records past TTL. Keeps the hot tables small and bounds PII retention. |

### 6.12 Backend — `app/observability/` and entry points

| File | Responsibility |
|---|---|
| `observability/sentry.py` | FR-24. Init with `send_default_pii=False`, a `before_send` scrubber, release tagging, and restaurant/order context tags so an error is actionable rather than a bare stack trace. **(SEC)** |
| `observability/metrics.py` | Prometheus collectors: per-tool latency histograms, order-state counters, relay delivery latency, outbox depth and age, OAuth grant outcomes, 4xx/5xx by route. |
| `observability/tracing.py` | OpenTelemetry wiring across FastAPI, SQLAlchemy, Redis, httpx and arq. |
| `observability/health.py` | `/healthz` (liveness, no dependencies) and `/readyz` (DB, Redis, storage, migration-version check). FR-25's monitor targets `/readyz` on the MCP host. |
| `app/main.py` | Builds the FastAPI app, installs middleware in the correct order, mounts `/api/v1`, `/oauth`, `/webhooks`, and the MCP ASGI sub-app at `/mcp`. |
| `app/lifespan.py` | Startup/shutdown: engine and Redis pools, JWKS load, config assertion, graceful drain. Startup **fails loudly** on a bad config rather than degrading. |
| `app/asgi.py` | Production entry (`gunicorn app.asgi:application`). |

### 6.13 Backend — `scripts/` and `alembic/`

| File | Responsibility |
|---|---|
| `alembic/env.py` | Async-aware migration env; imports `Base.metadata` for autogenerate. |
| `alembic/versions/*.py` | One migration per change. **Every migration has a tested downgrade.** Destructive operations require an explicit override comment and second reviewer. |
| `scripts/check_migration_safety.py` | Pre-commit + CI: rejects a migration that drops a column, adds a NOT NULL without a default, or creates an index without `CONCURRENTLY` on a non-empty table. Prevents the "migration locked production" class of incident. |
| `scripts/generate_openapi.py` | Dumps the OpenAPI document; CI diffs it against the committed copy and regenerates frontend types. Backend/frontend drift becomes a failing build. |
| `scripts/seed_dev_data.py` | Deterministic seed: 20 restaurants, menus, an admin user, an OAuth client. Same data every run. |
| `scripts/rotate_platform_key.py` | Operator command implementing FR-23's overlap-window rotation. |
| `scripts/smoke_test_restaurant.py` | CLI wrapper on FR-5 for ops use. |
| `scripts/check_coverage.py` | **Amendment A4.** Enforces both §11.6 floors (≥90% line, ≥85% branch) in one place. `--cov-fail-under` cannot express two floors, and reports *"Total coverage: 100.00%"* over a package with no statements — a gate succeeding over nothing. This script reports that state as INACTIVE instead, so a green line always means code was measured. |
| `../scripts/check_codeowners.py` | **Amendment A7.** Derives the `(SEC)` set from §6 and fails `make check` unless `.github/CODEOWNERS` routes every entry. Written because the first CODEOWNERS drafted by hand covered only 15 of the 31 `(SEC)` files — §10.7's two-reviewer rule would have appeared to hold while silently defaulting 16 files to one approval. |
| `../scripts/doctor.sh` | **Amendment A5.** Repository-root script verifying the local toolchain matches §4 (uv, Python 3.12, Docker, Compose, node, pnpm, gitleaks, osv-scanner). Exits non-zero, so `make doctor` is a gate rather than advice. |

### 6.14 Frontend — `frontend/src/`

| File / directory | Responsibility |
|---|---|
| `main.tsx` | React root, QueryClient, router, error boundary, Sentry init. |
| `router.tsx` | Route table with an auth guard; unauthenticated users land on `/login`. |
| `api/client.ts` | `openapi-fetch` client: credentials `include`, CSRF header injection, 401 → session-expired redirect, typed error surface. |
| `api/schema.d.ts` | **Generated** from the backend OpenAPI document. Never hand-edited; a stale copy fails CI. |
| `api/queries/*.ts` | One file per resource (`restaurants`, `menu`, `orders`, `onboarding`, `dashboard`, `imports`, `platformKeys`) — typed hooks, query keys, invalidation rules. |
| `components/ui/*` | Vendored Radix-based primitives: Button, Input, Select, Dialog, Sheet, Table, Badge, Toast, Tabs, Card, Form. |
| `components/layout/*` | AppShell, Sidebar, TopBar, PageHeader, breadcrumbs. |
| `components/common/*` | `DataTable`, `EmptyState`, `ErrorState`, `ConfirmDialog`, `MoneyInput` (rupees in the UI, **paise on the wire**), `PhoneInput` (E.164), `StatusBadge`, `TimeAgo` (IST). |
| `features/auth/*` | `LoginPage`, `useSession`, TOTP challenge. |
| `features/restaurants/*` | `RestaurantListPage`, `RestaurantDetailPage`, `RestaurantForm`, `HoursEditor`, `DuplicateWarning`, `StatusControl`. FR-1, FR-6. |
| `features/menu/*` | `MenuEditor`, `CategoryList`, `ItemForm`, `ItemAvailabilityToggle`, `ImageUploader` (presigned PUT), drag-reorder. FR-2, FR-3. |
| `features/onboarding/*` | `OnboardingChecklist`, `ConsentForm`, `SmokeTestPanel`, `GoLiveButton`. The interns' primary screen; the Go-Live control is **disabled with an explicit reason** until consent and a passing smoke test both exist (FR-4, FR-5). |
| `features/orders/*` | `OrderListPage`, `OrderDetailPage`, `FlaggedOrdersQueue` (FR-17), `StatusTimeline`, `ManualStatusOverride`. |
| `features/imports/*` | `CsvImportPage`, `TemplateDownload`, `RowErrorTable` (FR-7's per-row errors). |
| `features/dashboard/*` | `DashboardPage` with the FR-26 24 h tiles: onboarded, placed, fulfilled, failed/flagged. |
| `features/settings/*` | `PlatformKeysPage` (FR-23), `AdminUsersPage`, `AuditLogPage`. |
| `hooks/*` | `useDebounce`, `usePagination`, `useConfirm`, `usePermissions`. |
| `lib/money.ts` | Rupee ↔ paise conversion, INR formatting. Mirrors `core/money.py`; a shared golden-vector fixture tests both sides against the same table. |
| `lib/datetime.ts` | UTC → IST rendering. |
| `lib/validation.ts` | Zod schemas derived from the generated types. |
| `lib/permissions.ts` | Role → allowed-action map, mirroring the server. The server remains authoritative; this only hides controls. |
| `test/*` | Vitest setup, MSW handlers, render helpers. |
| `e2e/*.spec.ts` | Playwright: `onboarding-happy-path`, `menu-editing`, `order-flagging`, `csv-import`, `auth-guard`, `a11y`. |
| `nginx.conf` | Static serving with the CSP and security headers in §10.3. |

---

## 7. Data model

### 7.1 Entity relationships

```
admin_users ─┬─ admin_sessions
             └─ audit_log (actor)

restaurants ─┬─ restaurant_hours
             ├─ restaurant_consents        (append-only)
             ├─ menu_categories ── menu_items
             ├─ availability_overrides
             ├─ smoke_test_runs
             ├─ orders ─┬─ order_items      (price-snapshotted)
             │          ├─ order_status_events (append-only)
             │          ├─ payments ── payment_webhook_events
             │          └─ relay_messages ── relay_inbound_events
             └─ bookings

end_users ─┬─ otp_challenges
           ├─ user_consents ── oauth_clients
           ├─ refresh_tokens (family) / access_token_records / authorization_codes
           └─ orders

outbox_events        (polymorphic, drives all external side effects)
idempotency_records  (unique on client_id + key)
platform_credentials (overlapping validity windows → FR-23)
csv_import_jobs ── csv_import_rows
```

### 7.2 Constraints that exist because application code can be wrong

| Constraint | Prevents |
|---|---|
| `UNIQUE (client_id, idempotency_key)` on `idempotency_records` | Duplicate orders under concurrent retries — the G5 defect class. Application-level Redis reservation is the fast path; **this** is the guarantee. |
| `CHECK (price_paise > 0)` on `menu_items`; same on order line snapshots | FR-2's numeric-positive rule surviving any code path, including CSV import. |
| `CHECK (total_paise = subtotal_paise + tax_paise)` on `orders` | Arithmetic drift between computed and stored totals. |
| `CHECK (status <> 'active' OR (consent_id IS NOT NULL AND smoke_test_passed))` on `restaurants` | FR-4 and FR-5's go-live gate, at the storage layer. A restaurant cannot be active without consent and a passing smoke test even if a service is bypassed. |
| `UNIQUE (restaurant_id, lower(name))` on `menu_categories` | Duplicate categories from double-submits. |
| Partial `UNIQUE (phone) WHERE deleted_at IS NULL` on `restaurants` | FR-1's duplicate detection. |
| `UNIQUE (provider, provider_event_id)` on `payment_webhook_events` | Double-processing a redelivered PSP webhook — the duplicate-charge class. |
| `EXCLUDE USING gist` on `bookings` (restaurant, time range) where active | Double-booked table slots. |
| `FOREIGN KEY … ON DELETE RESTRICT` throughout | Silent orphaning of order history. |
| Append-only trigger + `REVOKE UPDATE, DELETE` on `audit_log`, `order_status_events`, `restaurant_consents` | Tampering with the exact records the FRD requires for auditability and that a restaurant consent dispute would rest on. |
| `TIMESTAMPTZ` on every time column, no `TIMESTAMP` | Timezone-ambiguity bugs in hours, timeouts and expiry. |
| `BIGINT` paise, no `FLOAT`/`REAL`/`DOUBLE` anywhere | Money rounding errors. |

### 7.3 Order state machine (FR-12, HB1 §6)

| From | Allowed to | Trigger |
|---|---|---|
| `PLACED` | `ACCEPTED`, `REJECTED`, `CANCELLED` | Restaurant reply, customer cancel, or timeout auto-cancel |
| `ACCEPTED` | `FULFILLED`, `CANCELLED` | Completion, or post-acceptance cancellation |
| `REJECTED` | `CANCELLED` | Refund path (HB1 Fig 3's "rejected → cancellation + refund") |
| `FULFILLED` | — | Terminal |
| `CANCELLED` | — | Terminal |

Every transition writes an `order_status_event` with actor, reason and timestamp. Any transition not in this table raises `IllegalStateTransition` and is never persisted.

---

## 8. Interface specification

### 8.1 Admin REST (`/api/v1`, cookie session + CSRF)

```
POST   /auth/login            POST /auth/logout         GET  /auth/me
POST   /auth/totp/enroll      POST /auth/totp/verify
GET    /restaurants           POST /restaurants
GET    /restaurants/{id}      PATCH /restaurants/{id}   DELETE /restaurants/{id}
GET    /restaurants/{id}/orders                         GET /restaurants/{id}/hours
PUT    /restaurants/{id}/hours
POST   /restaurants/{id}/consent          POST /restaurants/{id}/smoke-test
GET    /restaurants/{id}/smoke-test/{run_id}            POST /restaurants/{id}/activate
POST   /restaurants/{id}/pause
GET/POST /restaurants/{id}/categories     PATCH/DELETE /categories/{id}
GET/POST /categories/{id}/items           PATCH/DELETE /items/{id}
POST   /items/{id}/availability           POST /restaurants/{id}/availability-override
POST   /uploads/presign
GET    /orders  GET /orders/flagged  GET /orders/{id}  POST /orders/{id}/status
GET    /dashboard/summary
POST   /imports/restaurants  POST /imports/menu-items  GET /imports/{job_id}
GET    /imports/template/{kind}.csv
GET/POST /platform-keys      POST /platform-keys/{id}/rotate  DELETE /platform-keys/{id}
GET    /audit-log
POST   /webhooks/payments/{provider}      POST /webhooks/relay/{provider}
```

### 8.2 MCP tools (`/mcp`, Streamable HTTP, Bearer token)

| Tool | Scope | Input | Output | Key guarantees |
|---|---|---|---|---|
| `search_restaurants` | `restaurants:read` | `location?`, `cuisine?`, `query?`, `cursor?` | Active restaurants with id, name, cuisine, area, open-now, booking flag | p95 < 1.5 s; active only; out-of-coverage handled with an explanation |
| `get_menu` | `restaurants:read` | `restaurant_id` | Categories → items with `price_paise`, `is_veg`, `is_available` | Reflects admin edits within 60 s; **unavailable items flagged, not omitted** |
| `check_availability` | `restaurants:read` | `restaurant_id`, `item_ids[]`, `at?` | Per-item availability, restaurant open/closed, reason | Rejects outside operating hours |
| `place_order` | `orders:write` | `restaurant_id`, `items[]`, `customer_contact`, `payment_mode`, `fulfilment_type`, **`idempotency_key`** | `order_id`, status, totals, UPI intent if prepaid | Idempotent; same key → same order, never a second one; p95 < 3 s including relay enqueue |
| `get_order_status` | `orders:read` | `order_id` | State + timestamped history + ETA | Ownership-checked; reflects restaurant reply within 60 s |
| `book_table` | `bookings:write` | `restaurant_id`, `party_size`, `time` | Booking id + status | Only for opted-in restaurants |

Every tool returns, on failure, `{ code, message, retryable }` where `message` is plain language a person could read aloud (FR-22). **No tool returns a stack trace, an SQL error, or an internal identifier.**

### 8.3 OAuth endpoints (Path A)

```
GET  /.well-known/oauth-authorization-server     GET /.well-known/oauth-protected-resource
POST /oauth/register        GET  /oauth/authorize      POST /oauth/consent
POST /oauth/token           POST /oauth/revoke         GET  /oauth/jwks.json
POST /oauth/otp/request     POST /oauth/otp/verify
GET  /account/connections   POST /account/connections/{client_id}/disconnect
```

### 8.4 Connector-path sequence (HB2 §5, implemented)

1. Claude discovers `/.well-known/oauth-protected-resource` from a 401 `WWW-Authenticate` challenge on `/mcp`.
2. Claude fetches AS metadata, dynamically registers (RFC 7591), and redirects the person to `/oauth/authorize` with PKCE `S256` and a `resource` parameter.
3. The person verifies their phone by OTP (no password is ever created) and sees **Bharat MCP's own consent screen**, stating what is shared and what is authorised.
4. On approval: authorization code → `/oauth/token` with the PKCE verifier → access token (15 min, audience-bound) + rotating refresh token (30 days).
5. Every subsequent tool call carries that access token; `mcp/auth.py` validates issuer, audience, scope, expiry and revocation on each call.
6. Disconnect from `/account/connections` or Claude's own settings revokes the token family server-side, immediately.

---

## 9. Non-functional requirements

| Category | Requirement | How it is met | How it is proven |
|---|---|---|---|
| Performance | p95 < 1.5 s reads, < 3 s `place_order` | Single-query menu loads, covering indexes, Redis caching of menu trees with 60 s TTL (matching the FRD's "within 1 minute" freshness rule exactly), relay dispatch deferred to the outbox | k6 at 20 rps, `infra/k6/` |
| Availability | 99% during 11:00–23:00 IST | Managed Postgres/Redis, graceful degradation (reads survive a relay-provider outage), `/readyz`-driven load-balancer health, fast rollback path | Uptime monitor report over the pilot |
| Scalability | 500 → 2,000+ restaurants with **no schema or protocol redesign** | Multi-tenant row model, cursor pagination everywhere, no per-tenant tables, stateless app processes, Redis-backed sessions | Load test seeded with 2,000 restaurants and 50k menu items |
| Security | See §10 in full | | §10.8 sign-off |
| Data integrity | Idempotent `place_order`, no duplicate orders | Two-layer idempotency (§11.4) + DB unique constraint | Property-based concurrency test |
| Auditability | Consent, state transitions and menu/price edits timestamped and attributable | Append-only `audit_log`, `order_status_events`, `restaurant_consents` with DB-level write protection | `tests/integration/test_audit_immutability.py` |
| Usability | Intern-operable after one walkthrough; no DB or code access for any onboarding task | Guided onboarding checklist, blocking controls that explain *why* they are blocked, per-row import errors, plain-language validation messages | Ops dry run (E7) + Playwright journey test |
| Accessibility | Keyboard-navigable, WCAG 2.1 AA contrast | Radix primitives, focus management, axe in CI | `@axe-core/playwright` |

---

## 10. Security & Secure SDLC

This section is the part of the PRD that is not negotiable under schedule pressure. The system takes payments, holds personal contact data, and speaks on behalf of restaurants that have signed a consent form — each of those is a liability the pilot cannot absorb.

The regime below maps to **NIST SSDF (SP 800-218)** practice groups and **OWASP ASVS 4.0 Level 2**, with **OWASP Top 10** and **OWASP API Security Top 10** as review checklists.

### 10.1 Secure SDLC — the process, phase by phase

| SSDF group | Phase | What happens in this project | Artefact / gate |
|---|---|---|---|
| **PO** — Prepare the Organization | Before code | Secure-coding standard written into `CLAUDE.md` and `CONTRIBUTING.md`; roles and reviewers set in `CODEOWNERS`; `SECURITY.md` defines severities and response SLAs; every contributor reads the threat model | Documents merged before the first feature PR |
| **PO/PW** | Requirements | Every FRD requirement is assessed for a security impact; abuse cases are written alongside acceptance criteria ("what does a malicious agent do with `place_order`?") | Abuse-case list in `docs/threat-model.md` |
| **PW.1** | Design | **STRIDE threat model per trust boundary** (§10.2), reviewed and signed before implementation of the corresponding module. Security-relevant design choices captured as ADRs | Threat model + ADR-0005, ADR-0007 |
| **PW.4** | Reuse | Only well-maintained, widely-audited libraries (§4). No hand-rolled crypto, no hand-rolled OAuth server, no hand-rolled MCP protocol | Dependency review in PR |
| **PW.5/PW.6** | Implementation | Secure defaults, deny-by-default authorisation, parameterised queries only, mandatory typing, banned-function lint rules | ruff + semgrep in pre-commit and CI |
| **PW.7** | Code review | Two reviewers for any file marked **(SEC)**; a security checklist is embedded in the PR template | `pull_request_template.md` |
| **PW.8** | Testing | SAST, SCA, secret scanning, DAST, fuzzing, dependency audit — all in CI, all blocking (§11.6) | `security-scan.yml` |
| **PW.9** | Configuration | Secure-by-default config; production settings validated at boot; no debug mode, no permissive CORS, no default credentials | `tests/security/test_secure_defaults.py` |
| **RV.1** | Vulnerability response | Nightly dependency audit; `SECURITY.md` intake; severity-based SLA (Critical 24 h, High 72 h, Medium 14 d) | `nightly-audit.yml` |
| **RV.2/RV.3** | Root cause | Every security defect gets a regression test **and** an answer to "what class of bug is this, and what prevents the next one?" | Post-incident note in the PR |
| — | Pre-go-live | Manual security review pass + an external or peer penetration test focused on the OAuth flow, the MCP surface, and the payment webhooks | Sign-off, §10.8 |

### 10.2 Threat model — trust boundaries and controls

| # | Trust boundary | Principal threats (STRIDE) | Controls |
|---|---|---|---|
| TB-1 | AI agent → `/mcp` | Spoofing a user; token replay; **confused deputy / token passthrough**; scope escalation; enumeration of restaurants or orders; DoS via expensive queries | Audience-bound (RFC 8707) tokens validated per call; scope checks per tool; ownership checks on `get_order_status`; per-subject and per-client rate limits; cursor pagination with capped page size; query timeouts |
| TB-2 | Person → OAuth authorize/consent | Authorization-code interception; CSRF on consent; open redirect; phishing a consent screen; OTP brute force; session fixation | Mandatory PKCE S256; exact-match redirect URIs; single-use short-lived codes bound to client+redirect+PKCE+resource; signed `state`; OTP attempt caps with lockout and constant-time compare; consent screen states the client name and requested scopes verbatim |
| TB-3 | Claude ↔ token endpoint | Refresh-token theft and replay; client impersonation | Rotation with **reuse detection that revokes the whole family**; hashed-at-rest tokens; short access-token TTL; immediate server-side revocation |
| TB-4 | Admin browser → `/api/v1` | Session hijack; CSRF; privilege escalation; XSS; brute-force login | `HttpOnly`+`Secure`+`SameSite=Lax` cookies with server-side revocable sessions; double-submit CSRF on all state-changing verbs; RBAC checked server-side on every route; strict CSP with no `unsafe-inline`; Argon2id + lockout + generic error messages; optional TOTP for the lead role |
| TB-5 | PSP → `/webhooks/payments` | Forged payment confirmation (**direct monetary loss**); replay; race with the order flow | HMAC signature verified with constant-time compare **before parsing**; provider event id uniqueness; amount and order id re-verified against our own record; fetch-and-confirm against the PSP API before marking paid |
| TB-6 | BSP → `/webhooks/relay` | Forged "restaurant accepted" reply; spoofed sender number | Provider signature verification; sender number must match the restaurant's registered E.164 number; one-time unguessable accept/reject link tokens as the primary path, keywords as fallback |
| TB-7 | Admin upload → object storage | Malicious file upload; stored XSS via SVG; path traversal; storage exhaustion | Presigned PUT with enforced content-type and size; server-side magic-byte validation; re-encode via Pillow (strips EXIF/GPS and any embedded payload); SVG rejected outright; random object keys, never user-supplied filenames; private bucket with short-TTL presigned GET |
| TB-8 | Application → Postgres | SQL injection; cross-tenant data access; mass data exfiltration | Parameterised ORM queries only, no string-built SQL; mandatory tenant scoping in the repository base class; least-privilege DB role (no DDL at runtime); statement timeouts |
| TB-9 | Repository / CI → production | Leaked credentials in code or logs; malicious dependency; compromised build | Secret scanning pre-commit and in CI; hash-pinned lockfiles; least-privilege deploy credentials via OIDC (no long-lived cloud keys in CI); signed container images; branch protection with required reviews |
| TB-10 | Data at rest / in logs | PII exposure (DPDP Act); over-retention | Customer contact encrypted at rest (AES-256-GCM, key-id tagged); structlog redaction processor; Sentry PII disabled and scrubbed; retention job purges expired OTPs, codes and idempotency records |

### 10.3 Applied security controls

**Transport & headers.** HTTPS only; HSTS with `includeSubDomains` and preload; TLS 1.2+. Response headers on every route: `Content-Security-Policy` (`default-src 'self'`, no `unsafe-inline`, no `unsafe-eval`, nonce-based for the consent page), `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY` plus `frame-ancestors 'none'`, `Referrer-Policy: strict-origin-when-cross-origin`, `Permissions-Policy` with everything denied, `Cache-Control: no-store` on all authenticated responses.

**Authentication & authorisation.**
- Admin: Argon2id (m=64 MiB, t=3, p=4), server-side sessions in Redis with a Postgres record, 8-hour absolute and 1-hour idle timeout, rotation on privilege change, listable and revocable by the user.
- End user (connector path): phone + OTP only. **No consumer password is ever created or stored.**
- AI platform (server-to-server, for the future ChatGPT/Gemini path): API key with a stored SHA-256 digest, prefix-identifiable for scanning, scoped and rotatable with an overlap window (FR-23).
- Authorisation is **deny-by-default**: a route or tool without an explicit scope/role declaration fails closed, asserted by `tests/security/test_authz_matrix.py`, which enumerates every route × every principal type and requires an expected allow/deny for each.

**Input handling.** Every input is a Pydantic model — there is no `request.json()` anywhere. Strict types, length caps, pattern constraints, `extra='forbid'` so unexpected fields are rejected rather than ignored. Body size capped by middleware. All output is JSON; the only HTML rendered is the consent and OTP pages, via Jinja2 with autoescaping on and a nonce-based CSP.

**Rate limiting.** Redis token bucket, atomic via Lua, applied per admin IP on `/auth/login`, per client and per subject on `/oauth/token` and `/mcp`, per phone number on OTP requests, and globally per platform credential. Limits are configuration, not code.

**Secrets.** No secret is ever committed, logged, or placed in a URL. `.env` is local-development only and gitignored; deployed environments read from a secrets manager. Every secret has a documented rotation procedure in `docs/runbooks/key-rotation.md`. Signing keys are Ed25519 with overlapping `kid` publication so rotation is invisible to in-flight requests.

**Payments.** No card or UPI credential ever touches Bharat MCP — PSP-hosted collection only, per the FRD and RBI PA rules. Webhook signatures are verified before the payload is parsed. A payment is marked successful only after both a valid signature **and** a server-to-server confirmation fetch agree on order id and amount.

**Privacy (DPDP Act 2023).** `docs/data-classification.md` records what is collected, why, the lawful basis, who may read it, and how long it is kept. Customer contact is encrypted at rest and redacted from logs. The consent screen's disclosure text and the published privacy policy are reviewed together so they cannot contradict each other (HB2 §8).

### 10.4 Secure defaults asserted by tests

`tests/security/test_secure_defaults.py` fails the build if any of these is true in a production configuration: debug mode on · CORS allowing `*` or credentials with a wildcard · a default or empty secret · HTTP allowed · a cookie missing `Secure`/`HttpOnly`/`SameSite` · a security header absent · Sentry PII enabled · an unauthenticated route not on the explicit public allowlist (`/healthz`, `/readyz`, the two `.well-known` documents, and the OAuth endpoints that must be public).

### 10.5 Custom Semgrep rules (`.semgrep/bharat-mcp.yml`)

Raw SQL string interpolation · `httpx` used outside `app/integrations/` · a repository query without a tenant filter · `float` in a money path · `datetime.utcnow()` or naive datetime construction · `==` comparison on a secret or token (must be constant-time) · a new MCP tool that does not declare a scope · an exception handler that returns `str(exc)` to a client · a logging call with an unredacted PII field name.

### 10.6 Supply chain

Hash-pinned `uv.lock` and `pnpm-lock.yaml`; Dependabot grouped weekly updates; `pip-audit` + `osv-scanner` + `pnpm audit` on every CI run and nightly; a new direct dependency requires a note in the PR covering maintenance status, licence and transitive weight; multi-stage Docker builds from digest-pinned bases; images scanned with Trivy; an SBOM (CycloneDX) generated per release and stored with the build.

### 10.7 Code review rules

Two approvals for any file marked **(SEC)** in §6 — the OAuth package, `mcp/auth.py`, `order_service.py`, `payment_service.py`, webhook handlers, `core/security.py`, `core/crypto.py`, and every migration. The PR template requires the author to answer explicitly: what new data this touches, what new authorisation decision it introduces, what happens if the input is hostile, and which test proves it.

### 10.8 Pre-go-live security sign-off

Go-live requires, in writing: threat model reviewed and current · zero open Critical or High findings from SAST/SCA/DAST · the `test_authz_matrix` and `test_oauth_conformance` suites green · a penetration test of the OAuth flow, MCP surface and payment webhooks with all High findings remediated · secrets rotated off all development values · backup restore rehearsed successfully · incident-response runbook walked through with the on-call person.

---

## 11. Quality engineering — how this ships without bugs

"No bugs" is not achievable by intent; it is achievable by making whole classes of bug *unrepresentable*, and by making the remaining ones fail loudly in CI rather than quietly in production. This section is the plan for doing that.

### 11.1 Bug classes eliminated by design

| Bug class | Why it cannot occur here |
|---|---|
| Money rounding / float drift | Integer paise end to end, enforced by type, lint rule and DB column type. Rupees exist only in the UI layer and in rendered messages. |
| Backend/frontend schema drift | Frontend types are **generated** from the backend's OpenAPI document; a mismatch fails `pnpm typecheck` in CI. |
| MCP/REST schema divergence | Both layers import the same Pydantic models. There is no second definition to drift from. |
| Timezone bugs | `TIMESTAMPTZ` only; naive datetimes rejected at the DB type boundary; `datetime.utcnow()` banned by lint; IST applied only at render time. |
| Duplicate orders / duplicate charges | Two-layer idempotency (§11.4) plus a DB unique constraint plus provider-event-id uniqueness on webhooks. |
| Illegal order states | A single explicit transition table; every other transition raises. |
| N+1 queries on the p95 path | `selectinload` menu loading, plus a test that asserts the query count for `get_menu` is ≤ 2. |
| Cross-tenant data leaks | Mandatory tenant scope in the repository base class, lint-enforced, plus an explicit cross-tenant access test suite. |
| Lost external side effects | Transactional outbox — the order and the intent to notify commit atomically. |
| Silent failure | No bare `except`. Every catch either handles a named domain error or re-raises. Dead-lettered outbox events raise an alert. |
| Flaky tests from time or randomness | Injected `Clock` and id generator; `time-machine` for temporal tests; seeded fixtures; no `sleep()` in tests. |

### 11.2 Test pyramid

| Layer | Location | Scope | Target |
|---|---|---|---|
| Unit | `tests/unit/` | Pure domain logic with fakes — money, state machine, availability windows, price snapshotting, relay reply parsing, scope checks | ≥95% on `app/services`, `app/core` |
| Integration | `tests/integration/` | Real Postgres 16 + Redis 7 via testcontainers — repositories, migrations, constraints, outbox, transactions | Every constraint in §7.2 has a test that proves it rejects the bad write |
| Contract | `tests/contract/` | MCP tool schemas, OpenAPI snapshot, PSP/BSP adapter contracts against recorded fixtures | Schema change without a version bump fails |
| Security | `tests/security/` | Authz matrix, OAuth conformance, secure defaults, injection, rate limits, PII redaction, webhook forgery | All blocking |
| Architecture | `tests/architecture/` | Import-graph rules A1–A4 | Blocking |
| E2E | `frontend/e2e/` + `tests/e2e/` | Full journeys: onboard → smoke test → go live → agent search → order → relay reply → status; and the complete OAuth connect flow | Runs on every PR |
| Load | `infra/k6/` | E4 p95 verification at 20 rps with 2,000 seeded restaurants | Nightly + pre-release |

### 11.3 Agent-facing behaviour tests (FR-22)

`tests/contract/test_agent_messages.py` holds **golden transcripts** for every failure mode named in the FRD and HB1 §7: item sold out, restaurant closed, restaurant paused, outside coverage area, payment failed, relay timed out, invalid token, insufficient scope, rate limited. Each asserts that the message is plain language, names the specific restaurant or item, suggests a next action where one exists, and contains no identifier, class name, or stack fragment. A change to any of these messages requires updating the golden file deliberately — which is exactly the review moment that catches a leak of internals into an agent-visible string.

### 11.4 The duplicate-order guarantee (G5), in detail

This is the highest-severity defect class in the system, so it gets defence in depth:

1. **Redis reservation** — `SET idem:{client}:{key} <fingerprint> NX EX 86400`. Fast path; rejects the common retry in sub-millisecond time.
2. **Fingerprint comparison** — the request body is hashed. A repeated key with a *different* body returns `409 idempotency_key_reused`, rather than silently returning someone else's order.
3. **Postgres unique constraint** on `(client_id, idempotency_key)` — the authority. If Redis is flushed, evicted, or unavailable, the constraint still holds.
4. **Response snapshot** — the original response is stored and replayed byte-identically on a repeat, so the agent sees the same order id, not a new one.
5. **Concurrency proof** — `tests/integration/test_idempotency_concurrency.py` fires N concurrent `place_order` calls with the same key against real Postgres and asserts exactly one row in `orders`, with all N callers receiving the same order id. Hypothesis varies N, timing and failure injection.

The same pattern, keyed on provider event id, protects payment webhooks against a double capture.

### 11.5 Definition of Done (per pull request)

A change is done when: it has unit tests for its logic and an integration test if it touches the database · mypy strict, ruff, and import-linter pass · new domain errors have agent-message golden entries · any new DB invariant exists as a constraint, not only as Python · security-relevant changes have a threat-model note · the OpenAPI document and generated frontend types are regenerated and committed · the runbook is updated if operational behaviour changed · **no TODO or commented-out code is merged**.

### 11.6 CI gates (all blocking — a red gate cannot be merged past)

| Workflow | Gates |
|---|---|
| `ci-backend.yml` | ruff · ruff-format · mypy --strict · import-linter · pytest unit+integration+contract+security+architecture on real Postgres/Redis · coverage ≥90% line / ≥85% branch on `app/services`, `app/mcp`, `app/oauth` · alembic upgrade-then-downgrade round trip · migration safety check · OpenAPI drift check |
| `ci-frontend.yml` | eslint · tsc --noEmit · vitest with coverage · generated-types freshness check · production build · bundle-size budget |
| `security-scan.yml` | bandit · semgrep (OWASP ruleset + custom) · pip-audit · osv-scanner · pnpm audit · gitleaks full history · Trivy image scan · schemathesis fuzz against the running app |
| `e2e.yml` | Playwright journeys against a docker-compose stack · axe accessibility · OAuth connect flow end to end |
| `nightly-audit.yml` | Fresh CVE scan of the deployed lockfile · k6 load run · restore-from-backup rehearsal against staging |

Branch protection: no direct pushes to `main`; linear history; required reviews per `CODEOWNERS`; all gates green; signed commits.

---

## 12. Observability & operations

| Concern | Implementation |
|---|---|
| Errors (FR-24) | Sentry with restaurant id, order id, tool name and request id as tags — an error is triaged without opening a database |
| Uptime (FR-25) | External monitor on `/readyz` at the MCP host, 1-minute interval, alert to the lead via email/Slack/SMS within 5 minutes; a separate synthetic check performs a real `search_restaurants` tool call, because an MCP endpoint that returns 200 while returning garbage to agents is still an outage |
| Metrics | Per-tool latency histograms, order-state counters, relay delivery latency, outbox depth and oldest-event age, OAuth grant success/failure, 4xx/5xx by route |
| Tracing | One trace id spans MCP call → service → DB → outbox → worker → BSP, which is what makes a three-layer failure diagnosable in minutes rather than hours |
| Logs | Structured JSON, PII-redacted, correlated by request id, shipped to a hosted sink with a defined retention period |
| Alerts | MCP endpoint down · outbox oldest-event age > 60 s (FR-14 at risk) · payment webhook final-retry failure (FR-20) · flagged-order queue above threshold (FR-17) · authentication failure spike · error rate above baseline |
| Runbooks | `docs/runbooks/` — incident response, key rotation, relay failure, payment reconciliation, restore from backup. Each is rehearsed once before go-live, not written and filed |
| Backups | Managed Postgres PITR; **restore rehearsed and timed** — an unrehearsed backup is not a backup |

---

## 13. Delivery plan

Sequenced so the riskiest external dependency (directory listing approval, per HB2 §4 and the Non-Technical Requirements' gating analysis) starts on day one and runs in parallel with the build rather than after it.

| Week | Engineering | Parallel, non-engineering |
|---|---|---|
| **0** | Repo, CI skeleton, all quality gates green on an empty app, docker-compose, ADRs, threat model v1 | Connector directory submission enquiry opened with Anthropic; PSP KYC started |
| **1** | Core: config, logging, errors, money, clock, DB models, migrations, repositories, constraints | FSSAI/consent document templates drafted |
| **2** | Domain services + admin REST: restaurants, menu, availability, consent, smoke test. Admin auth | Intern SOP drafted against the emerging UI |
| **3** | Admin panel: shell, auth, restaurant CRUD, menu editor, image upload, onboarding checklist | First 10 restaurants sourced |
| **4** | MCP server mounted; all six tools with static auth; agent error taxonomy + golden transcripts | — |
| **5** | Orders: state machine, idempotency, outbox, relay adapters + fake, timeout flagging | BSP decision |
| **6** | Payments: UPI intent, webhook verification and retry, COD path, reconciliation view | PSP contract signed |
| **7** | **OAuth 2.1 AS**: metadata, DCR, authorize, PKCE, consent screen, token, JWKS | Consent-screen copy reviewed against the privacy policy |
| **8** | OAuth: refresh rotation with reuse detection, revocation, per-subject rate limiting, `/account/connections` | Privacy policy + T&Cs drafted |
| **9** | End-to-end connector test against Claude; tool manifest; directory submission | Directory listing submitted |
| **10** | Dashboard, CSV import, audit log viewer, platform key rotation | Intern training |
| **11** | Hardening: pen test, load test, chaos (kill Redis, kill BSP, delay PSP), runbook rehearsals | Legal review pass |
| **12** | Fixes, security sign-off, staging soak, go-live | Ops dry run (E7) |

Critical path: OAuth (weeks 7–8) → connector submission (week 9) → external approval. Budget slack here; it is the one item outside the team's control.

---

## 14. Requirements traceability

Every FRD requirement maps to code and to a named test. This table is maintained as the build proceeds and is the artefact for exit criterion E1.

| FRD ID | Implemented in | Verified by |
|---|---|---|
| FR-1 | `restaurant_service.create`, `api/v1/restaurants.py`, `RestaurantForm` | `test_restaurant_create.py`, `test_duplicate_detection.py`, Playwright `onboarding-happy-path` |
| FR-2 | `menu_service`, `api/v1/menu.py`, `MenuEditor` | `test_menu_crud.py`, `test_price_positive_constraint.py` |
| FR-3 | `availability_service`, `api/v1/availability.py` | `test_availability_override.py`, `test_menu_cache_freshness.py` (asserts ≤60 s) |
| FR-4 | `onboarding_service.record_consent`, `RestaurantConsent` | `test_consent_required_for_activation.py`, `test_audit_immutability.py` |
| FR-5 | `smoke_test_service`, `workers/smoke_test_runner.py` | `test_smoke_test_blocks_activation.py` |
| FR-6 | `api/v1/restaurants.py` detail, `RestaurantDetailPage` | `test_restaurant_detail.py`, Playwright |
| FR-7 | `csv_import_service`, `CsvImportRow`, `RowErrorTable` | `test_csv_per_row_errors.py` |
| FR-8 | `mcp/tools/search_restaurants.py`, `restaurant_repo.search` | `test_search_tool.py`, k6 p95 |
| FR-9 | `mcp/tools/get_menu.py`, `menu_repo` | `test_get_menu_tool.py` (asserts unavailable items present and flagged), query-count test |
| FR-10 | `mcp/tools/check_availability.py`, `availability_service` | `test_check_availability.py`, `test_operating_hours_edge_cases.py` |
| FR-11 | `mcp/tools/place_order.py`, `order_service` | `test_place_order.py`, `test_idempotency_concurrency.py` |
| FR-12 | `mcp/tools/get_order_status.py`, `order_status_events` | `test_order_status.py`, `test_state_machine.py` |
| FR-13 | `mcp/tools/book_table.py`, `booking_service` | `test_book_table.py`, `test_booking_slot_exclusion.py` |
| FR-14 | `relay_service`, `outbox_dispatcher` | `test_relay_dispatch.py` (asserts ≤30 s), `test_outbox.py` |
| FR-15 | `relay_service.parse_inbound`, `webhooks/relay` | `test_inbound_parsing.py`, `test_ambiguous_reply_flagging.py` |
| FR-16 | `order_service.transition`, status propagation | `test_status_propagation.py` (asserts ≤60 s) |
| FR-17 | `timeout_service`, `workers/relay_timeout.py`, `FlaggedOrdersQueue` | `test_relay_timeout.py` |
| FR-18 | `payment_service.create_intent`, PSP adapter | `test_upi_intent.py`, `test_payment_expiry.py` |
| FR-19 | `payment_service` COD path | `test_cod_flow.py` |
| FR-20 | `workers/payment_webhook_retry.py` | `test_webhook_retry.py`, `test_webhook_signature_forgery.py` |
| FR-21 | `mcp/server.py`, `oauth/*`, `platform_credentials` | `test_oauth_conformance.py`, live Claude transcript |
| FR-22 | `mcp/errors.py` | `test_agent_messages.py` (golden transcripts) |
| FR-23 | `platform_credentials` overlap, `rotate_platform_key.py`, JWKS `kid` overlap | `test_key_rotation_no_downtime.py` |
| FR-24 | `observability/sentry.py` | `test_sentry_context.py`, `test_pii_redaction.py` |
| FR-25 | `observability/health.py` + external monitor + synthetic tool call | Monitor configuration review |
| FR-26 | `dashboard_service`, `DashboardPage` | `test_dashboard_summary.py` |
| HB2 §7 (connector) | `app/oauth/*`, `mcp/auth.py`, `docs/mcp-tool-manifest.md` | `test_oauth_conformance.py`, `test_revocation_immediate.py`, `test_per_subject_ratelimit.py`, E2E connect flow |

---

## 15. Open decisions

These do not block the start of the build — each has a documented default that lets work proceed — but each needs an answer by the week shown.

| # | Decision | Default assumed by this PRD | Needed by | Owner |
|---|---|---|---|---|
| D1 | Razorpay vs Cashfree | Adapter interface + fake; either can be dropped in | Week 6 | Founder's office |
| D2 | WhatsApp: direct Meta vs BSP (Gupshup/Twilio) | Adapter interface + fake | Week 5 | Founder's office + lead |
| D3 | `book_table` in pilot scope? | Built, **disabled by default** per restaurant | Week 10 | Founder's office |
| D4 | Delivery model (pickup / own fleet / 3P) | `PICKUP` and `DINE_IN` enabled; delivery enum values present but rejected | Before restaurant #50 | Founder's office |
| D5 | Does the connector directory listing support regional or invite-only scoping? (HB2 §8) | Assume **no**; tools reject out-of-area requests with a clear explanation | Week 9 | Founder's office + lead |
| D6 | Is the OAuth consent screen also the moment a Reward360 account is created? (HB2 FAQ) | Yes — phone + OTP creates an `EndUser` on first consent | Week 7 | Product |
| D7 | Own OAuth AS vs a hosted IdP (Auth0/Clerk/WorkOS) | **Own AS with Authlib**, per ADR-0005 — MCP's resource-indicator and DCR requirements are easier to satisfy directly than to bend a hosted IdP into | Week 7 | Lead |
| D8 | Admin MFA mandatory or lead-only? | Lead role mandatory, interns optional | Week 2 | Lead |
| D9 | Customer-data retention period (DPDP) | 12 months for order records, 90 days for raw relay payloads | Week 8 | Legal + lead |

---

## 16. References

- Functional Requirements Document v1.0 — `bharat-mcp-frd.pdf`
- Infrastructure Plan — `bharat-mcp-infra-plan.pdf`
- Non-Technical Requirements v1.0 — `bharat-mcp-non-technical-requirements.pdf`
- Technical Handbook: How an AI Agent Orders Food — `bharat_mcp_handbook.pdf`
- Connector Handbook (Path A) — `bharat_mcp_connector_handbook.pdf`
- MCP specification, including the authorization revision — `modelcontextprotocol.io` / `docs.claude.com`
- OAuth 2.1 draft · RFC 7636 (PKCE) · RFC 7591 (DCR) · RFC 8414 (AS metadata) · RFC 8707 (resource indicators) · RFC 9728 (protected resource metadata) · RFC 9700 (OAuth BCP)
- NIST SP 800-218 (SSDF) · OWASP ASVS 4.0 L2 · OWASP Top 10 · OWASP API Security Top 10
- DPDP Act 2023 · Consumer Protection (E-Commerce) Rules 2020 · RBI Payment Aggregator guidelines

---

---

## 17. Amendment log

Changes made to this document after v1.0, each with the evidence that prompted
it. The PRD is executable specification: when the build proves a clause wrong,
the clause is corrected here rather than silently ignored in code.

| # | Date | Section | Amendment | Why |
|---|---|---|---|---|
| A1 | 2026-09-16 | §5 | File counts corrected: `models/` 15→**16**, `services/` 12→**14**, `api/v1/` 10→**12** routers, `oauth/` 10→**11**. | §5's tree and §6's itemised manifest disagreed. §0 makes §6 authoritative ("a file not listed here should not appear"), so §5 was the error. `repositories/` (11), `schemas/` (12), `mcp/tools/` (7) and `workers/` (8) were already correct. |
| A2 | 2026-09-16 | §4.2 | The "custom ruff rules" claim replaced with what each tool can actually enforce. | **Ruff has no plugin system — custom rules do not exist.** `datetime.utcnow`, `os.getenv`, `Decimal` and the banned libraries are enforceable via banned-API config; bare `except` via `BLE`/`E722`; naive datetimes via `DTZ`. **`float` in a money path is not expressible in ruff at all** and is Semgrep rule 4. Rule A5 was therefore unenforced as originally specified. |
| A3 | 2026-09-16 | §5 | Added to the tree: `.semgrep/bharat-mcp.yml`, `scripts/doctor.sh`, `docs/source/`, `frontend/e2e/`. | §10.5 specifies `.semgrep/bharat-mcp.yml` and §11.2 specifies `frontend/e2e/`, but neither appeared in the tree. `docs/source/` holds the five source PDFs. `backend/tests/e2e/` was already present. |
| A4 | 2026-09-16 | §6.13 | Added `scripts/check_coverage.py`. | §11.6 sets **two** floors (≥90% line, ≥85% branch); `coverage.py`'s `fail_under` expresses one blended number. Worse, on a package with no statements `--cov-fail-under=90` prints *"Total coverage: 100.00%"* — a gate reporting success over nothing. Verified against the empty Week-0 app. |
| A5 | 2026-09-16 | §6.13 | Added `scripts/doctor.sh` at the repository root. | §4 states a toolchain but nothing verified it. The first run found Python 3.9.6 where §4.1 requires 3.12, and no uv, Docker or gitleaks — i.e. the entire integration tier (§4.2 bans SQLite as a stand-in) was unrunnable. |
| A7 | 2026-09-16 | §6.13 | Added `scripts/check_codeowners.py`, wired into `make check`. | A hand-written `CODEOWNERS` routed 15 of 31 `(SEC)` files. The remaining 16 — including `core/money.py`, `api/deps.py`, `api/v1/uploads.py`, `mcp/tools/place_order.py` and `observability/sentry.py` — would have fallen back to the one-approval default, so §10.7 would have read as satisfied while not being satisfied. The `(SEC)` set is now derived from §6 rather than transcribed. |
| A6 | 2026-09-16 | §4.2 | `osv-scanner` pinned ≥2.6 and its wiring recorded. | §4.2 and §10.6 both require it; it appeared nowhere in the repository. Also recorded that `pip-audit` must run against the **exported lockfile** — it errors on the project's own editable package, so the SCA gate as originally specified could never pass. |

### Deviations recorded, not yet amended

Carried deliberately; each needs a decision before the section it touches is built.

| # | Section | Deviation | Status |
|---|---|---|---|
| D-a | §5 | Repository root is `barath_MCP/`, not a nested `bharat-mcp/`. | Accepted — avoids redundant nesting. |
| D-b | §10.1 (PO) | `SECURITY.md`, `CONTRIBUTING.md`, `README.md`, `CHANGELOG.md`, `docs/threat-model.md` and `docs/mcp-tool-manifest.md` are **not yet written**, but §10.1 requires them merged *before the first feature PR* — and `app/core/` is that PR, with four **(SEC)** files. | **Open.** Governance docs and threat model v1 should precede `app/core/`. |
| D-c | §11.6 | Gates that depend on later modules (frontend workspace, `generate_openapi.py`, `check_migration_safety.py`, `alembic.ini`) **skip visibly** rather than failing. | Accepted — the skip is printed, never silent, and disappears when the module lands. Without it `make check` stays red for weeks and stops being read. |
| D-d | §6.1 | `docker-compose.yml` sources MinIO from **quay.io**, not Docker Hub. | Forced — `minio/minio` on Docker Hub denies anonymous pulls. |
| D-e | §1.2 / FR-21 | FRD §8 and FR-21 require end-to-end demos on Claude, ChatGPT **and** Gemini; Task 1 scopes only Claude. Exit criterion **E1 ("all 26 FRD requirements implemented") cannot be literally true** at Task-1 close. | **Open** — needs explicit acceptance that FR-21 is partially met. |
| D-f | §7.2 / §6.6 | Non-technical requirements §1.3 makes a valid FSSAI licence a go-live precondition, but the activation CHECK constraint covers only consent and smoke test. | **Open** — proposed as a third precondition. |
| D-g | — | Restaurant settlement/payout, GST invoicing, and the Consumer Protection (E-Commerce) Rules 2020 disclosure surface are unmodelled. On Path A the tool output is the only channel to the customer. | **Open** — see the questions raised at kickoff. |
| D-h | §10.7 | **The two-reviewer rule for (SEC) files cannot be satisfied by the documented team** — one infra lead plus two non-engineering interns. `CODEOWNERS` currently names a single owner, and one owner cannot approve twice. | **Open** — needs a second reviewer named, or an accepted risk under SECURITY.md's Medium SLA, **before the first (SEC) module merges**. Tracked as R7 in the threat model. |
| D-i | HB2 FAQ | What happens to an **in-flight order when the person disconnects**. HB2 states revocation should not be assumed to cancel a placed order, but never says what should happen. | **Open.** Proposed: the order completes, the relay and payment proceed, and `get_order_status` stops being callable for it. Recorded in threat model TB-3. |

---

**End of PRD-01.** No code is written against this document until §15's D7 is confirmed and the threat model (§10.2) has had its first review.
