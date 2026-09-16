# ADR-0001 — Python 3.12 + FastAPI as the single runtime

**Status:** Accepted · 2026-09-16
**Context:** PRD §1.3, §4.1 · FRD §4.2, §7 · Infra plan §2

## Context

The infrastructure plan offers a choice: *"TypeScript/Node using the official MCP
SDK, or Python (FastMCP) — pick whichever your lead is faster in."* The FRD,
which is the governing functional document, instead names FastAPI/Python in its
header and in §7, and adds a constraint the infra plan does not discuss:

> Tool schemas (input/output) are defined once in Pydantic and reused for both
> the MCP layer and internal validation — no duplicate schema maintenance.
> — FRD §4.2

## Decision

**Python 3.12 with FastAPI, one process, one runtime.** Not 3.13: several
C-extension wheels in our dependency set lag a major release behind.

## Why

The FRD's shared-schema requirement is not a preference — it is the mechanism
that prevents the MCP tool contract and the REST contract from drifting apart.
Satisfying it requires the MCP layer and the REST layer to import the *same*
objects, which requires one runtime. A Node MCP server plus a Python API would
need the schema defined twice, and two definitions drift. That drift is
invisible until an agent receives a field the admin panel never sends.

Python also brings the ecosystem this system actually needs: Pydantic v2 for
validated-at-the-boundary schemas, SQLAlchemy 2.0's typed ORM, Alembic, and the
official MCP SDK's Streamable HTTP transport.

## Consequences

- One deployable, one dependency set, one test harness.
- Pydantic models become the single source of truth, and the frontend's
  TypeScript is **generated** from the OpenAPI document they produce. A backend
  schema change that breaks the frontend fails `pnpm typecheck` in CI rather
  than in production.
- Python's GIL is not a constraint here: this workload is I/O-bound and async,
  and pilot volume is low.
- We give up Node's marginally more mature MCP tooling. Acceptable — the Python
  SDK implements the same specification, including the 2025-06-18 auth revision.

## Alternatives rejected

**TypeScript/Node throughout.** Would satisfy the shared-schema rule by making
everything TypeScript, but loses Pydantic-to-OpenAPI-to-Zod generation and
SQLAlchemy's constraint modelling, and contradicts the FRD's explicit stack.

**Node MCP server + Python API.** Rejected outright: it reintroduces exactly the
duplicate schema maintenance FRD §4.2 forbids.
