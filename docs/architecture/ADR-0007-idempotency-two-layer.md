# ADR-0007 — Layered idempotency for `place_order`

**Status:** Accepted · 2026-09-16
**Context:** PRD §11.4, §7.2 · FR-11 · Goal G5

## Context

> **G5 — Correctness.** No duplicate order and no duplicate charge is reachable
> by any interleaving of retries, concurrent calls, or partial failures. This is
> the single highest-severity defect class in this system.

AI agents retry. Networks drop responses after the write has landed. A person
may say "yes" twice. All three produce the same thing: two identical
`place_order` calls, and the customer must end up with one order.

A Redis `SETNX` reservation alone is not sufficient. Redis can be flushed,
restarted, evicted or briefly unavailable — and the moment it is, the only thing
standing between a retry and a duplicate charge is gone.

## Decision

**Four layers, with the database as the authority.**

| # | Layer | Role | Fails how |
|---|---|---|---|
| 1 | `SET idem:{client}:{key} <fingerprint> NX EX 86400` | Fast path — rejects the common retry in sub-millisecond time | Redis unavailable → fall through to layer 3 |
| 2 | Request-fingerprint comparison (SHA-256 of the body) | Same key, *different* body → `409 idempotency_key_reused` | — |
| 3 | **`UNIQUE (client_id, idempotency_key)` in Postgres** | **The guarantee.** Holds if Redis is gone entirely. | Constraint violation → treated as a duplicate, not an error |
| 4 | Response snapshot in `idempotency_records` | The repeat returns the **same order id**, byte-identically | — |

The order, its line items, its first status event, the idempotency record and
the outbox row all commit in **one transaction**.

## Why

Layer 3 is the decision. Everything else is optimisation or ergonomics. An
application-level check has a window between check and write; a unique
constraint does not. Making the database the authority means a bug in our code
produces a rejected write rather than a duplicate charge.

Layer 2 exists because returning "the order for this key" when the body differs
would be worse than creating a duplicate — the agent would be told an order for
*different items* succeeded. That is a data-integrity failure disguised as
idempotency.

Layer 4 exists because agents compare order ids. Returning a different id for a
retried call breaks the conversation even when no duplicate was created.

## Consequences

- Idempotency keys are **required** on `place_order`. A missing key is a 400,
  not a best-effort create.
- `idempotency_records` holds a response snapshot, which contains order data —
  so it is P2 and purged after 24 hours by `token_cleanup`.
- The same pattern, keyed on `(provider, provider_event_id)`, protects payment
  webhooks against double capture. Same defect class, same shape of answer.
- **Proof obligation, not just a design:** `test_idempotency_concurrency.py`
  fires N concurrent calls with the same key against real Postgres and asserts
  exactly one row in `orders` with all N callers receiving the same id.
  Hypothesis varies N, timing and failure injection. Testcontainers, never
  SQLite — SQLite's locking semantics would make the test meaningless.

## Alternatives rejected

**Redis only.** Fast and simple, and loses the guarantee precisely when Redis
fails — which is when retries are most likely.

**Database only.** Correct, but sends every retry through a transaction and a
constraint violation. Layer 1 keeps that off the p95 path.

**Natural-key deduplication** (restaurant + items + contact + time window).
Guesses intent. A person ordering the same coffee twice in five minutes is
placing two orders, and we must not merge them.
