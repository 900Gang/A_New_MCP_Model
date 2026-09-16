# Working rules for this repository

Bharat MCP exposes restaurant data to AI agents, takes payments, and speaks on
behalf of restaurants that signed a consent form. Each of those is a liability a
pilot cannot absorb. These rules exist so that whole classes of defect are
unrepresentable rather than merely discouraged.

**The governing document is `docs/PRD-01-core-server-admin-connector.md`.** Where
this file and the PRD disagree, the PRD wins and this file is wrong — fix it.

---

## The three rules everything else follows from

1. **One schema, one truth.** Every data shape is defined exactly once, in
   Pydantic under `backend/app/schemas/`, and reused by the REST layer, the MCP
   tool layer, the CSV importer, and — via generated types — the React frontend.
   A duplicated schema definition is a defect, not a style choice.
2. **The database is the last line of defence, not the first.** Every invariant
   enforced in Python is *also* a Postgres constraint. If the application has a
   bug, the database must refuse the write rather than persist corruption.
3. **Nothing ships without a test that would have caught its absence.**

---

## Layering (rules A1–A4, enforced by `make arch`)

```
api/v1 · mcp/tools · oauth · workers     adapters — thin, no business logic
            ↓
        services/                        domain logic — framework-free
            ↓
    db/repositories/                     every method takes a tenant scope
            ↓
        db/models/

        schemas/        imported by all of the above, importing none of them
     integrations/      the only place httpx / aioboto3 may be imported
```

- MCP tools **validate → call a service → map the result**. Business logic in a
  tool is a review rejection.
- Services never import `fastapi`, `starlette`, `mcp`, `httpx` or `sqlalchemy`.
  A service you cannot unit-test without an ASGI app is wrong.
- There is no unscoped `SELECT`. Repository methods take an explicit tenant
  scope; `BaseRepository` enforces it.
- Every external dependency (BSP, PSP, storage, clock, uuid) is a `Protocol` in
  `app/integrations/` with a fake in `tests/fakes/`.

`import-linter` machine-checks all of this. It is not a convention.

## Money

Integer **paise** everywhere — Python, Postgres `BIGINT`, JSON, TypeScript.
Rupees exist only in the React layer and in rendered relay messages. `float` and
`Decimal` in a money path are banned by ruff and by semgrep. `app/core/money.py`
raises `TypeError` on a float.

## Time

All datetimes are timezone-aware UTC. `TIMESTAMPTZ` columns only; the DB type
layer rejects naive datetimes at the driver boundary. `datetime.utcnow()` and
`datetime.now()` are lint-banned — inject `Clock` and call `clock.now_utc()`.
IST is applied at render time only.

## Errors

Every raised error is a `BharatMCPError` subclass carrying `code`,
`http_status`, `agent_message`, `admin_message`, `retryable`. No bare `except`.
Every catch either handles a named domain error or re-raises.

`agent_message` is read aloud to a person by an AI agent. It names the specific
restaurant or item, suggests a next action where one exists, and contains no
identifier, class name, SQL fragment or stack trace. Expected domain failures
("item unavailable") are `Result` values, not exceptions.

## Security

- **Deny by default.** A route or tool with no explicit scope/role declaration
  fails closed. `tests/security/test_authz_matrix.py` enumerates every route ×
  every principal type and requires an expected verdict for each.
- **No token passthrough, ever.** `mcp/auth.py` rejects any token not issued for
  this resource (RFC 8707 audience binding). This is the confused-deputy defence.
- Every input is a Pydantic model with `extra='forbid'`. There is no
  `request.json()` in this codebase.
- Secrets are never committed, logged, or placed in a URL. Config is read only
  through `app.core.config.Settings`; `os.getenv` is lint-banned elsewhere.
- Compare secrets with `constant_time_compare`, never `==`.
- Verify a webhook signature **before** parsing the payload.
- Files marked **(SEC)** in PRD §6 need two reviewers.

## Side effects

A write that must cause an external side effect commits an **outbox row in the
same transaction**. Nothing dispatches to WhatsApp or a PSP from inside a
request handler. Ever.

## Idempotency

`place_order` requires an idempotency key. The guarantee is four-layered: Redis
reservation → request-fingerprint comparison → the Postgres unique constraint on
`(client_id, idempotency_key)` → replay of the stored response snapshot. A
repeated key with a *different* body is `409 idempotency_key_reused`, never a
silent return of someone else's order.

Duplicate orders and duplicate charges are the highest-severity defect class in
this system. Treat any change near this path accordingly.

## Migrations

One migration per change, with a **tested downgrade**. `make migrate-roundtrip`
must pass. A migration that drops a column, adds `NOT NULL` without a default,
or creates an index without `CONCURRENTLY` on a non-empty table is rejected by
`scripts/check_migration_safety.py` and needs an explicit override plus a second
reviewer. Every new invariant arrives as a constraint, not only as Python.

## Tests

`make test-unit` for the fast loop; integration tests run against **real**
Postgres 16 and Redis 7 via testcontainers. SQLite as a stand-in is banned — it
does not have our constraints, types or locking semantics.

No test may depend on wall-clock time, machine timezone, dict ordering, or float
arithmetic. Use the injected `Clock`, `time-machine`, and seeded fixtures. There
is no `sleep()` in the test suite.

## Definition of done

Unit tests for the logic; an integration test if it touches the database; mypy
strict, ruff and import-linter green; new domain errors have agent-message golden
entries; new DB invariants exist as constraints; the OpenAPI document and the
generated frontend types are regenerated and committed; the runbook is updated if
operational behaviour changed.

**No TODO and no commented-out code is merged.** `make check` before you push.

## Commits

Conventional commits (`feat:`, `fix:`, `sec:`, …). No direct pushes to `main`;
linear history; signed commits; reviews per `CODEOWNERS`.
