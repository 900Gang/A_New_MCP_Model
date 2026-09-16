# Bharat MCP

Restaurant data and ordering, exposed to AI agents over the **Model Context
Protocol**. A person asks Claude for a dish; Claude searches, reads the menu,
checks availability and places a real order; the order reaches a restaurant that
has no point-of-sale system as a WhatsApp message, and a human there accepts or
rejects it with a one-word reply.

Bangalore pilot — 500 restaurants. Internal.

```
Claude (or any MCP client)
   │  OAuth 2.1, PKCE, audience-bound token
   ▼
Bharat MCP — one FastAPI service
   /mcp         six tools over Streamable HTTP
   /oauth/*     first-party authorization server + consent screen
   /api/v1/*    admin REST behind cookie sessions + CSRF
   /webhooks/*  PSP payments, BSP inbound relay
   │
   ├─ Postgres (system of record)  ├─ Redis (idempotency, sessions, rate limits)
   └─ R2 (menu images)             └─ arq worker (outbox dispatch, timeouts)
                                        │
                         WhatsApp relay ─┴─ UPI payment
```

## Quickstart

```bash
make doctor     # verify your toolchain matches what the PRD requires
make install    # uv sync + pnpm install, from the lockfiles
make hooks      # install the pre-commit and commit-msg hooks
make up         # Postgres 16, Redis 7, MinIO, Mailpit
make check      # everything CI runs
```

`make` with no target lists all 34 targets. There are no undocumented commands —
if CI runs it, it is a make target.

## Layout

| Path | What lives there |
|---|---|
| `backend/app/schemas/` | Pydantic models — **the single source of truth**. REST, MCP and the frontend's generated TypeScript all derive from here. |
| `backend/app/services/` | Domain logic. Framework-free: no FastAPI, no Starlette, no `mcp`. |
| `backend/app/mcp/` | The six agent-facing tools. Thin adapters, no business logic. |
| `backend/app/oauth/` | OAuth 2.1 authorization server (Path A connector). |
| `backend/app/db/` | Models and tenant-scoped repositories. |
| `backend/app/integrations/` | Every external dependency as a `Protocol` + a real adapter + a fake. |
| `frontend/` | React + TypeScript admin panel, usable by non-engineers. |
| `docs/` | The PRD, threat model, ADRs, runbooks. |

## Documents

| Document | Read it when |
|---|---|
| [`docs/PRD-01-core-server-admin-connector.md`](docs/PRD-01-core-server-admin-connector.md) | Always. It is the governing specification; §17 logs every amendment. |
| [`CLAUDE.md`](CLAUDE.md) | Before your first change. The rules, in two pages. |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Before your first pull request. |
| [`SECURITY.md`](SECURITY.md) | To report a vulnerability, or to learn the response SLA. |
| [`docs/threat-model.md`](docs/threat-model.md) | Before touching anything marked **(SEC)**. |
| [`docs/data-classification.md`](docs/data-classification.md) | Before storing, logging or exporting anything about a person. |
| [`docs/architecture/`](docs/architecture/) | To find out why a decision was made rather than what it was. |
| [`docs/source/`](docs/source/) | The five source documents this PRD derives from. |

## The rules, in brief

Money is **integer paise** everywhere. Datetimes are **timezone-aware UTC**.
Every Python invariant is **also a Postgres constraint**. External side effects
go through the **transactional outbox**, never a request handler. Authorisation
is **deny-by-default**. `place_order` is **idempotent**, and that is defended in
four layers.

The long version is [`CLAUDE.md`](CLAUDE.md); the reasoning is the PRD.

## Status

Pre-pilot. See [`CHANGELOG.md`](CHANGELOG.md) for what exists today.
