# ADR-0002 — Mount the MCP server as an ASGI sub-app, not a separate service

**Status:** Accepted · 2026-09-16
**Context:** PRD §3.1, §6.12 · FRD §4.2

## Context

The MCP tool surface, the admin REST API, the OAuth authorization server and the
provider webhooks could each be their own deployable. At 500 restaurants with
low order volume, they do not need to be.

## Decision

**One FastAPI application.** `/mcp` is the official MCP SDK's Streamable HTTP
ASGI app mounted as a sub-application; `/api/v1`, `/oauth` and `/webhooks` are
routers on the same app. One `arq` worker process shares the codebase.

## Why

Separating them would buy independent scaling we do not need and cost us the
thing we do need: shared Pydantic schemas and shared domain services in the same
process. FRD §4.2 requires the MCP layer to reuse the REST layer's schemas;
mounting satisfies that with no serialisation boundary.

It also keeps authentication coherent. `/mcp` validates bearer tokens minted by
`/oauth` in the same process, with the same key material and the same revocation
table — so a revoked token stops working immediately, which HB2 §7 requires.

## Consequences

- **A single point of failure for all 500 restaurants** (infra plan §12, and
  residual risk R4 in the threat model). The mitigation is monitoring and a fast
  rollback path, not redundancy — a deliberate pilot-scale tradeoff.
- Middleware ordering matters: security headers, body-size caps and request-id
  binding apply to `/mcp` as well as `/api/v1`, and must be verified for both.
- Architectural discipline has to do the work that process boundaries would
  otherwise do. Hence rules A1–A4, machine-enforced by import-linter: the MCP
  layer holds no business logic and cannot import `app.db` at all.
- Scaling past a few thousand restaurants means horizontal replicas of the whole
  app first. Splitting services remains possible later precisely because the
  layering is enforced now.

## Alternatives rejected

**Separate MCP microservice.** Would need either a duplicated schema definition
or an internal API between them — one is forbidden by FRD §4.2, the other adds a
network hop to the p95 budget for no pilot-scale benefit.
