# ADR-0004 — Transactional outbox for every external side effect

**Status:** Accepted · 2026-09-16
**Context:** PRD §3.2 rule A7, §6.11 · FR-14

## Context

Placing an order must do two things: write the order to Postgres, and send a
WhatsApp message to the restaurant within 30 seconds (FR-14). These are
different systems, and there is no transaction spanning both.

Doing it naively — commit the order, then call the BSP from the request handler
— fails in two directions. If the BSP call fails after the commit, the order
exists and the restaurant never hears about it, so the customer waits for food
nobody is cooking. If the BSP call succeeds but the response is lost and the
handler retries, the restaurant gets the same order twice.

Calling the BSP *before* committing is worse: a message goes out for an order
that may never exist.

## Decision

**The order row and an `outbox_events` row commit in the same transaction.**
Nothing dispatches to WhatsApp or a PSP from inside a request handler — ever.

An `arq` worker polls `outbox_events` with `SELECT … FOR UPDATE SKIP LOCKED`,
dispatches, applies exponential backoff with jitter on failure, and moves
exhausted events to a dead-letter state **with an alert**.

## Why

It reduces a distributed-transaction problem to a local one. The database is the
single source of truth for both the fact and the intent to notify, so they
cannot disagree. A crash at any instant leaves the system in a recoverable
state: either neither row exists, or both do and the worker will retry.

`SKIP LOCKED` lets multiple workers share the queue without coordination.
Dead-lettering with an alert is the part people skip, and it is why "the order
vanished" is not a failure mode here.

## Consequences

- Delivery is **at-least-once**, so every consumer must be idempotent. The BSP
  adapter carries a provider-side idempotency key.
- The FR-14 30-second guarantee becomes this loop's SLO, monitored as
  **outbox oldest-event age**. An alert fires above 60 seconds — before the
  requirement is breached, not after.
- Outbox payloads are typed Pydantic models in `schemas/events.py`, a
  discriminated union. An untyped JSONB blob would become an unversioned
  contract the first time a payload shape changed.
- One more moving part, and a worker that must be running. Accepted: the
  alternative is silent order loss.

## Alternatives rejected

**Dispatch from the request handler.** Simplest, and wrong in both directions
described above.

**Redis as the queue of record.** Redis is not the system of record here —
§4.4 is explicit. An eviction or restart would lose orders.

**Two-phase commit.** No BSP or PSP supports it.
