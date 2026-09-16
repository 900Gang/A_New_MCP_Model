# Build log and module plan

| Field | Value |
|---|---|
| Purpose | What has been built, what was found while building it, and what must be known before the next module starts |
| Governing document | `PRD-01-core-server-admin-connector.md` — this file records execution, the PRD records intent |
| Repository | https://github.com/900Gang/A_New_MCP_Model |
| Last updated | 16 September 2026 · `main` @ `78f6faf` |

Work proceeds **one module at a time**: build, explain, verify, merge. A module
is not finished when its files exist — it is finished when its gates have been
run, its claims have been tested by trying to break them, and what was found has
been written down.

---

## Status

| # | Module | State | Commit |
|---|---|---|---|
| 1 | Repository structure (PRD §5) | **Done** | `1c2a916` |
| 2 | Tooling and machine-enforced gates (§4.2, §10, §11.6) | **Done** | `1c2a916` |
| 3 | Governance, threat model, ADRs (§10.1 PO group) | **Done** | `fb8118a`, `e4916e4`, `78f6faf` |
| **4** | **`backend/app/core/` — the framework-free primitives (§6.2)** | **Next** | — |
| 5 | `backend/app/db/` — models, migrations, constraints (§6.3, §6.4, §7) | Planned | — |
| 6 | `backend/app/schemas/` — the single source of truth (§6.5) | Planned | — |
| 7 | Domain services + admin REST (§6.6, §6.7) | Planned | — |
| 8 | Admin panel (§6.14) | Planned | — |
| 9 | MCP tools (§6.8) | Planned | — |
| 10 | Orders, idempotency, outbox, relay (§6.6, §6.11) | Planned | — |
| 11 | Payments (§6.6, §6.10) | Planned | — |
| 12 | **OAuth 2.1 AS (§6.9)** — the critical path | Planned, **blocked on D7** | — |
| 13 | CI workflows, Docker, Terraform (§5, §11.6) | Planned | — |
| 14 | Runbooks, tool manifest, intern SOP (§6.1, §12) | Planned | — |

Modules 5–14 are the PRD's §13 sequence and will be re-planned as earlier
modules land; only Module 4 is specified in detail below.

---

## Module 1 — Repository structure

**Built.** All 62 directories from PRD §5, 27 Python package markers,
`.gitkeep` in every leaf that would otherwise be empty.

**Deliberately not built.** Stub files for §6's ~120 source files. Each arrives
with real content in its own module, so the repository never looks further along
than it is, and §11.5's "no TODO, no commented-out code" is never bent.

**Found.** §5's tree omits four directories that §6, §10.5 and §11.2 require:
`.semgrep/`, `scripts/`, `docs/source/`, `frontend/e2e/`. Added, and recorded as
PRD amendment A3.

---

## Module 2 — Tooling and machine-enforced gates

The point of doing this before any feature code: every later module is checked
from its first line rather than retrofitted into compliance.

**Built.** `uv.lock` (183 packages, hash-pinned) · ruff with 24 rule families
and a banned-API policy · mypy `--strict` plus `disallow_any_explicit` ·
import-linter with 8 contracts encoding rules A1–A4 · bandit · 9 custom Semgrep
rules (§10.5) · gitleaks with 16 project secret patterns · detect-secrets ·
pip-audit · osv-scanner · 23 pre-commit hooks · a 36-target `Makefile` ·
`docker-compose` at production versions · `tests/architecture/test_layering.py`.

### What running the gates found

Nine defects, none of which were visible by reading the configuration:

| Defect | Consequence |
|---|---|
| `test_layering.py` invoked `python -m importlinter.cli`, a silent no-op returning 0 | **A test that could never fail** — import-linter separately reported a real layering violation while pytest stayed green |
| `coverage-gate` printed *"Total coverage: 100.00%"* over an application with zero lines of code | A gate reporting success over nothing. Replaced by `check_coverage.py`, which reports that state as **INACTIVE** |
| Makefile `$(UV)` embedded `--project backend`, then recipes did `cd backend` | `make lint`, `typecheck`, `test`, `sca` all resolved to `backend/backend` |
| `root_packages = app` parsed character by character | All 8 architecture contracts silently unrunnable |
| Three separate Semgrep pattern-syntax errors | Rules A4 and FR-22 unenforced |
| `pip-audit --strict` errors on our own editable package | The SCA gate could never pass |
| `minio/minio` on Docker Hub denies anonymous pulls | `make up` unusable |
| Makefile help regex excluded digits | `e2e` invisible in `make help` |
| `osv-scanner`, required by §4.2 and §10.6, wired nowhere | Half the dependency audit absent |

**Verification method.** Each gate was mutation-tested: the rule was shown to
fire against deliberately bad code **and** stay silent on correct code. All 9
Semgrep rules fire, 0 false positives. The coverage gate fails below floor and
passes above. Removing an import-linter contract fails the drift guard.

---

## Module 3 — Governance, threat model, ADRs

Sequenced **before** `app/core/` because §10.1's PO group requires the
secure-coding standard, `SECURITY.md` and the threat model merged *before the
first feature PR* — and `app/core/` is that PR, with five **(SEC)** files.

**Built.** `README.md` · `SECURITY.md` (four severities with SLAs) ·
`CONTRIBUTING.md` · `CHANGELOG.md` · `.github/CODEOWNERS` ·
`pull_request_template.md` · `dependabot.yml` · `docs/threat-model.md` (STRIDE
across ten trust boundaries, five ranked assets, four abuse-case sets, seven
residual risks) · `docs/data-classification.md` (P0–P3, DPDP Act) ·
`ADR-0001…0007`.

### What checking found

| Defect | Consequence |
|---|---|
| `CODEOWNERS` routed **15 of 31** files PRD §6 marks **(SEC)** | §10.7's two-reviewer rule would have *read* as satisfied while 16 files silently defaulted to one approval — including `core/money.py`, `api/deps.py`, `api/v1/uploads.py`, `mcp/tools/place_order.py`, `observability/sentry.py` |
| Root `scripts/` sat outside every gate | `check_codeowners.py` was committed **having never been linted**, and contained two real defects |

Both root causes were the same: **a list transcribed instead of derived.**
`scripts/check_codeowners.py` now derives the (SEC) set from the PRD and fails
`make check` unless `CODEOWNERS` routes every entry; `CONTRIBUTING.md` no longer
duplicates the list. The guard then caught a bug in itself — a loose `(SEC)`
match picked up the PRD's own amendment prose, turning `make check` red on the
commit that introduced it.

ADR-0005 is deliberately **Proposed, not Accepted**, pending decision D7.

---

## Current state

```
main @ 78f6faf     106 files · 5 commits · local == origin

make lint · typecheck · arch · codeowners · test · security · check · ci
        all PASS, verified from a fresh clone of origin/main

toolchain   uv 0.12.15 · python 3.12.14 · docker 29.8.1 · compose 5.5.1
            node 26.5.0 · pnpm 11.22.0 · gitleaks 8.30.1 · osv-scanner 2.6.0
stack       postgres 16.4 · redis 7.4 · minio · mailpit — all healthy
PRD         8 amendments (A1–A8) · 9 open deviations (D-a … D-i)
```

**What the green gates do and do not mean.** They prove the gate configuration
is valid and runnable. They say nothing about application correctness, because
there is no application code yet — 27 of the 30 Python files are empty package
markers. That changes with Module 4.

---

## Module 4 — `backend/app/core/`

### Scope

Thirteen files (PRD §6.2). Five are **(SEC)** and need two approvals.

| File | Responsibility | (SEC) |
|---|---|---|
| `config.py` | `Settings(BaseSettings)` — every environment variable, typed and validated, failing at import on a missing or malformed secret. Nested `DatabaseSettings`, `RedisSettings`, `OAuthSettings`, `PSPSettings`, `BSPSettings`, `StorageSettings`, `ObservabilitySettings`. **The only place allowed to read the environment.** | **✔** |
| `money.py` | `Paise` newtype, arithmetic helpers, `format_inr()`, `parse_rupees_to_paise()`. Floats raise `TypeError`. | **✔** |
| `security.py` | Argon2id hash/verify, constant-time compare, secure token generation, API-key digesting, CSRF issue/verify. | **✔** |
| `crypto.py` | AES-256-GCM for customer contact at rest, key-id-tagged ciphertext so keys rotate without a rewrite. | **✔** |
| `logging.py` | structlog JSON config, request/trace/tenant binding, and the **PII redaction processor**. | **✔** |
| `clock.py` | `Clock` protocol with `now_utc()`; `SystemClock` in production, `FrozenClock` in tests. Injected, never called statically. | |
| `ids.py` | UUIDv7 generation plus human-facing prefixed ids (`ord_`, `rst_`, `itm_`). | |
| `errors.py` | `BharatMCPError` with `code`, `http_status`, `agent_message`, `admin_message`, `retryable`. Directly implements FR-22. | |
| `exceptions.py` | The 13 concrete subclasses named in §6.2. | |
| `enums.py` | Every enum in the system, as `StrEnum`, in one place. | |
| `result.py` | `Result[T, E]` so an expected domain failure is a value, not an exception. | |
| `pagination.py` | Opaque signed cursors. Offset pagination is banned. | |
| `constants.py` | Bangalore coverage polygon, max items/order, max image bytes, supported MIME types, MCP protocol version. | |

### Why core comes first

It is the bottom of the dependency graph. The import-linter contract
`core-is-independent` forbids `app.core` from importing **any** other `app`
package, so it can be written and fully tested with nothing else in place. Every
later module imports it, which also means a mistake here is the most expensive
kind to correct.

### Hard constraints

1. **`app.core` imports nothing else from `app`.** Machine-enforced; `make arch`
   fails otherwise.
2. **No `Any`.** mypy runs `--strict` plus `disallow_any_explicit`.
3. **`config.py` is the only file permitted to read the environment.** `os.getenv`
   and `os.environ` are ruff-banned everywhere else, with a per-file exemption
   for `config.py` alone.
4. **Semgrep rules 4, 5, 6 and 9 aim directly at this module** — float in a money
   path, naive datetime, `==` on a secret, PII in a log call. `money.py`,
   `security.py` and `logging.py` are exactly where they fire.

### The coverage gate activates with this module

Today `make coverage-gate` reports **INACTIVE** — zero statements measured. The
moment `app/core/` contains code it becomes live at **≥90% line, ≥85% branch**,
because `COV_PKGS` includes `app/core`.

> **Note a PRD inconsistency here.** Three sections give three different scopes:
> exit criterion **E5** says `app/services` and `app/mcp`; **§11.6** says
> `app/services`, `app/mcp`, `app/oauth`; **§11.2** sets ≥95% on `app/services`
> and `app/core`. The Makefile currently gates all four packages at 90/85, which
> is stricter than §11.6 and looser than §11.2 for core. **Confirm the intended
> scope before core lands**, since it determines whether this module can merge.

### Decisions to settle

Six things the PRD specifies but does not fully determine. The first two are
genuine input gaps — neither can be invented.

| # | Decision | Why it is open |
|---|---|---|
| **1** | **UUIDv7 source.** §6.2 requires time-ordered UUIDv7 for index locality. Python 3.12's `uuid` module provides only v1/v3/v4/v5, and **no package in `uv.lock` generates v7**. Pydantic ships a `UUID7` *type*, but that only **validates** — it does not generate. | Either add a dependency (`uuid6` or `uuid-utils`, each needing the §10.6 maintenance/licence/weight note) or implement RFC 9562 §5.7 directly (~20 lines, no dependency, and testable against the spec's vectors). **Recommendation: implement it** — the algorithm is small and fully specified, and it avoids a dependency in the foundation layer. |
| **2** | **Bangalore coverage polygon.** `constants.py` requires it and `search_restaurants` (FR-8) is coverage-bounded by it. **No source document contains coordinates.** | Needs actual pilot-area coordinates from the Founder's office, or an explicit decision to start with a centre-plus-radius circle and refine later. Cannot be invented — it decides which customers get served. |
| 3 | `Paise` representation: `NewType('Paise', int)` versus a wrapper class | `NewType` is zero-cost and mypy-checked but permits raw-int mixing at runtime; a class can reject floats at construction. §6.2 says "newtype **+** arithmetic helpers", so the helpers must carry the enforcement. |
| 4 | Ciphertext envelope for `crypto.py` | Key-id-tagged format needs defining once: version byte, key id, nonce, ciphertext, tag. It becomes a storage format the moment the first row is written, so it cannot change casually. |
| 5 | `Result[T, E]` shape | No stdlib equivalent. Needs to be ergonomic enough that people actually use it instead of raising. |
| 6 | Cursor signing key and payload | `pagination.py` cursors are opaque and signed. Which key, and what goes inside — position only, never a row count (§6.2 notes offset pagination leaks counts). |

Decisions 3–6 I can make and document; **1 and 2 need your input**, though only 2
is truly blocking — `ids.py` can proceed on the recommendation above.

### Tests this module must bring

| Test | Proves |
|---|---|
| `tests/unit/test_money.py` | Named directly in PRD §3.2 rule A5. Floats rejected; rupee↔paise round-trips; the **shared golden-vector fixture** that `lib/money.ts` will later be tested against |
| `tests/unit/test_clock.py` | `FrozenClock` determinism; no naive datetime escapes |
| `tests/unit/test_ids.py` | UUIDv7 monotonicity and time-ordering; prefixed-id parsing rejects a mismatched prefix |
| `tests/unit/test_errors.py` | Every `BharatMCPError` subclass carries a non-empty `agent_message` containing no class name, SQL fragment or identifier |
| `tests/unit/test_result.py` | `Result` cannot be unwrapped unchecked |
| `tests/unit/test_pagination.py` | A tampered cursor is rejected, not silently misread |
| `tests/security/test_crypto.py` | Round-trip; wrong key fails; key-id rotation decrypts old ciphertext; nonce never reused |
| `tests/security/test_security_primitives.py` | Argon2id parameters (m=64MiB, t=3, p=4); constant-time compare; token entropy |
| `tests/security/test_pii_redaction.py` | The redaction processor scrubs phone, email, address, token and payment fields before emission |
| `tests/security/test_secure_defaults.py` | `config.py` refuses a production configuration with debug on, a wildcard CORS, or an empty secret |

### Definition of done

`make check` and `make ci` green · coverage gate **ACTIVE** and passing ·
`CHANGELOG.md` updated · new errors documented · `.env.example` written (so
`docker-compose`'s `required: false` can be removed) · no TODO, no
commented-out code.

### What blocks the merge, not the writing

**D-h — the two-reviewer rule.** Five of these thirteen files are **(SEC)**.
`@900Gang` is the only owner, and one person cannot approve twice. This needs a
second reviewer named, or an explicitly accepted risk under `SECURITY.md`'s
Medium SLA, **before this module merges**. Writing it is unaffected.

---

## Open decisions carried forward

| # | Decision | Blocks | Needed by |
|---|---|---|---|
| **D7** | Own OAuth AS (Authlib) vs hosted IdP | Module 12 only; ADR-0005 stays *Proposed* | Week 7 |
| **D-h** | Second reviewer for (SEC) files | **Merging Module 4** | Now |
| **D-f** | Is valid FSSAI a third activation precondition? | Module 5 (the CHECK constraint) | Module 5 |
| **D-i** | In-flight order when a person disconnects | Module 12 | Week 8 |
| **D-e** | FR-21 covers Claude only, so E1 cannot be literally true | Task-1 sign-off | Before close |
| **D-g** | Settlement/payout, GST invoicing, Consumer Protection disclosure | Modules 10–11 | Before real payments |
| D1, D2 | PSP (Razorpay/Cashfree), BSP (Meta/Gupshup) | Nothing — adapters + fakes absorb this | Weeks 5–6 |
| D3, D4, D5, D8, D9 | Bookings in pilot · delivery model · directory regional scope · admin MFA · retention periods | Later modules | Per PRD §15 |

Also outstanding, outside the PRD: **branch protection is still off** (§11.6
requires it), and commits are authored as `Anand N <anandanand6776@gmail.com>`.

---

## Not built yet

So the gap between this repository and the PRD is never guessed at:

**Backend** — every file in §6.2 through §6.13 except the two scripts written so
far. **Frontend** — the entire `frontend/` workspace; no `package.json` exists,
which is why those gate steps report a visible skip. **Infra** — Terraform,
`backend/Dockerfile`, nginx config, k6 scripts. **CI** — all seven workflows in
`.github/workflows/`. **Docs** — five runbooks, `mcp-tool-manifest.md`,
`onboarding-sop-interns.md`.

Every one of these is a visible skip or an explicit absence, never a silent one.
