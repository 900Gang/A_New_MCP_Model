# ADR-0003 — Money is integer paise, end to end

**Status:** Accepted · 2026-09-16
**Context:** PRD §3.2 rule A5, §7.2, §11.1 · Goal G5

## Context

Money crosses four representations in this system: Python, Postgres, JSON on the
wire, and TypeScript in the browser. Every boundary is an opportunity for a
rounding error, and rounding errors in an ordering system mean a customer is
charged the wrong amount.

`float` is the obvious trap — `0.1 + 0.2 != 0.3` — but `Decimal` has a subtler
one: it is correct in Python and becomes a float the moment it is serialised to
JSON, unless every serialiser is configured not to.

## Decision

**Integer paise everywhere.** `price_paise: int`, Postgres `BIGINT`, a JSON
integer, a TypeScript `number` holding paise. Rupees exist in exactly two
places: the React presentation layer, and the text of a rendered relay message.

`float` and `Decimal` in a money path are **build failures**, not review
comments:

| Enforcement | Mechanism |
|---|---|
| `Decimal` banned in money paths | ruff banned-API (`TID251`) |
| `float` in a money path | Semgrep rule 4 (§10.5) — *not expressible in ruff; see PRD §17 A2* |
| Runtime | `core/money.py` raises `TypeError` on a float |
| Storage | `BIGINT` columns; no `FLOAT`/`REAL`/`DOUBLE` anywhere |
| Arithmetic | `CHECK (total_paise = subtotal_paise + tax_paise)` |
| Cross-language | A shared golden-vector fixture tests `core/money.py` and `lib/money.ts` against the same table |

## Why

This makes the bug class unrepresentable rather than merely discouraged. An
integer that survives serialisation unchanged cannot drift, and the smallest
Indian currency unit is the paisa, so no sub-unit is lost.

The golden-vector fixture matters as much as the type: two implementations of
rupee↔paise conversion that are each individually correct can still disagree at
a boundary. Testing both against one table is what stops that.

## Consequences

- Every display needs an explicit conversion. Deliberate: conversion becomes a
  visible act, not an implicit cast.
- Percentage-based taxes require a stated rounding rule at the point of
  calculation — the rule lives in `core/money.py`, once.
- `BIGINT` is oversized for a food order. Irrelevant, and it removes any ceiling
  question permanently.

## Alternatives rejected

**`Decimal` in Python with `NUMERIC` in Postgres.** Correct within Python, but
JSON has no decimal type — it becomes a float at the wire boundary, or a string
every consumer must remember to parse. Integers are correct in every
representation without special handling.
