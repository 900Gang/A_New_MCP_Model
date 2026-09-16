# ADR-0006 — `arq` for background jobs, not Celery

**Status:** Accepted · 2026-09-16
**Context:** PRD §4.1, §6.11

## Context

Four things must happen outside a request: outbox dispatch to WhatsApp and the
PSP, the FR-17 relay-timeout sweep, payment-webhook retries, and the FR-5 smoke
test (which the admin UI must not block on). All four are I/O-bound, and all
four live in an async codebase that already runs Redis.

## Decision

**`arq`** — async-native, Redis-backed, roughly a thousand lines of code.

## Why

Celery's prefork model fights an async codebase. Running async domain services
inside prefork workers means either an event loop per process or `asgiref`-style
bridging, and both add failure modes that are hard to reason about under
retries. `arq` runs the same `async def` service functions the request path
runs, with the same session and Redis pools.

It also adds no infrastructure: Redis is already present for idempotency
reservations, admin sessions and rate limiting. Celery would add a broker we do
not otherwise need — and if that broker were Redis anyway, we would have taken
on Celery's complexity for none of its benefit.

At pilot volume, Celery's advantages — routing, chords, huge ecosystem — are
things we would not use. `arq`'s codebase is small enough to read end to end
when something goes wrong at 11pm, which at this team size is a real feature.

## Consequences

- Cron-style jobs (`relay_timeout` every 60s, `token_cleanup`) use arq's cron
  registration.
- Smaller ecosystem: no Flower. Observability comes from our own Prometheus
  metrics — outbox depth, oldest-event age, job latency — which we need anyway
  because the FR-14 SLO is measured there.
- Retry policy is ours to define: exponential backoff with jitter, a bounded
  attempt count, then dead-letter **with an alert**.
- The worker shares the codebase and therefore the layering rules. It sits in
  the adapter layer, alongside `api`, `mcp` and `oauth`.

## Alternatives rejected

**Celery.** Mature and well-understood, but prefork against an async codebase,
plus a broker we do not need.

**FastAPI `BackgroundTasks`.** In-process: the work dies with the request and
the process. Unacceptable for anything that must reach a restaurant.

**`APScheduler`.** Solves scheduling, not durable queuing with retries and
dead-lettering. We need both.
