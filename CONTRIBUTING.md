# Contributing

`CLAUDE.md` is the two-page version of the engineering rules; read it first.
This document covers process: branches, reviews, commits, migrations, and what
"done" means.

The governing specification is `docs/PRD-01-core-server-admin-connector.md`.
Where this document and the PRD disagree, the PRD wins and this document is
wrong — fix it and note the correction in PRD §17.

---

## Before your first change

```bash
make doctor     # toolchain check; exits non-zero and tells you what is missing
make install
make hooks      # do not skip: the hooks are the same gates CI runs
make up
```

Read `docs/threat-model.md` before touching anything marked **(SEC)** in PRD §6.

---

## Branches and commits

No direct commits to `main` — a pre-commit hook enforces it locally and branch
protection enforces it on GitHub. Branch from `main`:

```
feat/place-order-idempotency      fix/relay-timeout-off-by-one
sec/oauth-refresh-rotation        chore/bump-sqlalchemy
docs/threat-model-tb7             test/booking-slot-exclusion
```

Commits are [Conventional Commits](https://www.conventionalcommits.org/), and
`sec:` is a first-class type here — security work should be findable in `git log`
without reading diffs.

```
feat(orders): reserve idempotency key before creating the order

Redis reservation is the fast path; the unique constraint on
(client_id, idempotency_key) remains the authority. A repeated key with a
different request fingerprint now returns 409 idempotency_key_reused rather
than silently replaying an unrelated order.

Closes #42
```

Explain **why**, not what — the diff already says what. History is linear:
rebase onto `main`, never merge `main` into your branch.

---

## Reviews

| What you changed | Approvals |
|---|---|
| Anything marked **(SEC)** in PRD §6 | **Two** |
| Any Alembic migration | **Two** |
| Everything else | One |

`.github/CODEOWNERS` routes these automatically.

The **(SEC)** set is **whatever PRD §6 marks `(SEC)`** — currently 31 files:
the whole OAuth package, `mcp/auth.py` and `place_order.py`, the order and
payment services, the admin edge (`deps`, `errors`, `middleware`, `auth`,
`uploads`, `platform_keys`, `webhooks`), the crypto/secrets/config/logging/money
primitives, the models and repositories holding credentials or personal data,
`observability/sentry.py`, and every migration.

Do not copy that list anywhere. `scripts/check_codeowners.py` derives it from the
PRD and fails `make check` if `CODEOWNERS` does not route every entry — so
marking a file `(SEC)` in the PRD is sufficient, and duplicating the list is how
it goes stale.

Two reviewers is not ceremony: these are the files where a mistake costs money,
leaks personal data, or lets one person act as another.

### Reviewing

Four questions, and the PR template makes the author answer them first:

1. **What new data does this touch?** New personal data needs an entry in
   `docs/data-classification.md`.
2. **What new authorisation decision does it introduce?** It must fail closed,
   and `tests/security/test_authz_matrix.py` must cover it.
3. **What happens if the input is hostile?** Not malformed — hostile.
4. **Which test proves it?** Name the test. "It's covered" is not an answer.

Approve when you understand the change, not when it looks plausible. If you
cannot tell whether it is correct, say so — that is useful information, and a
blocked review is cheaper than a duplicate charge.

---

## Migrations

One migration per change, with a **tested downgrade**. `make migrate-roundtrip`
runs upgrade → downgrade → upgrade and must pass.

`scripts/check_migration_safety.py` rejects a migration that drops a column,
adds `NOT NULL` without a default, or creates an index without `CONCURRENTLY` on
a non-empty table. Overriding it needs an explicit comment saying why, plus the
second reviewer you already needed.

**Every new invariant arrives as a constraint, not only as Python.** If the
service enforces it, the database enforces it too. That is rule 2 of the three
the whole PRD rests on: the database is the last line of defence, not the first.

---

## Tests

| Command | Scope |
|---|---|
| `make test-unit` | Pure domain logic, fakes only. The fast loop. |
| `make test-integration` | Real Postgres 16 + Redis 7 via testcontainers. |
| `make test-security` | Authz matrix, OAuth conformance, secure defaults, PII redaction. |
| `make test` | Everything, with coverage. |

SQLite as a stand-in for Postgres is banned — it does not have our constraints,
types or locking semantics, so a green SQLite test proves nothing about
production.

No test may depend on wall-clock time, machine timezone, dict ordering, or float
arithmetic. Use the injected `Clock`, `time-machine`, and seeded fixtures. There
is no `sleep()` in the suite.

A test that cannot fail is worse than no test, because it produces confidence
instead of information. When you add an assertion, break the code once and check
that it actually goes red.

---

## Definition of done

- [ ] Unit tests for the logic; an integration test if it touches the database
- [ ] `make check` passes
- [ ] New domain errors have agent-message golden entries (`tests/contract/`)
- [ ] New DB invariants exist as **constraints**, not only as Python
- [ ] Security-relevant changes carry a threat-model note
- [ ] OpenAPI document and generated frontend types regenerated and committed
- [ ] Runbook updated if operational behaviour changed
- [ ] **No TODO, no commented-out code**
- [ ] `CHANGELOG.md` updated under `[Unreleased]`

---

## Adding a dependency

A new direct dependency needs a note in the PR covering **maintenance status,
licence, and transitive weight**. Lockfiles are hash-pinned; regenerate with
`uv lock` or `pnpm install`, and commit the lockfile in the same PR.

Prefer the standard library. Prefer a well-audited library over your own crypto,
your own OAuth server, or your own MCP protocol implementation — all three are
explicitly out of bounds (PRD §10.1 PW.4).

---

## Reporting a vulnerability

Not here. `SECURITY.md`.
