# Changelog

Notable changes to Bharat MCP. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries are grouped by the PRD module that produced them, because that is the
unit this project is reviewed in.

## [Unreleased]

### Added — Module 3: governance, threat model and ADRs

- `SECURITY.md` — reporting routes, four severity levels with response SLAs
  (Critical 24h, High 72h, Medium 14d), scope, and the rule that a security fix
  is incomplete without a regression test and a root-cause answer.
- `CONTRIBUTING.md` — branches, conventional commits with `sec:` as a
  first-class type, the two-reviewer rule for **(SEC)** files and migrations,
  the four review questions, and the definition of done.
- `README.md` — replaces the generated stub.
- `.github/CODEOWNERS` — routes review for every **(SEC)** path, every
  migration, and the gate configurations themselves.
- `.github/pull_request_template.md` — PRD §10.7's four security questions as a
  required part of every PR.
- `.github/dependabot.yml` — grouped weekly updates, with authlib, pyjwt,
  cryptography, argon2-cffi and mcp deliberately **ungrouped** so a change to
  token or payment validation is never batch-approved.
- `docs/threat-model.md` — STRIDE across ten trust boundaries, five ranked
  assets, four abuse-case sets, and seven recorded residual risks. Every threat
  names its control **and the test that proves the control works**.
- `docs/data-classification.md` — P0–P3 levels, a full personal-data inventory
  with lawful basis and retention, and five handling rules (DPDP Act 2023).
- `docs/architecture/ADR-0001..0007` — the seven decisions PRD §5 requires.
  ADR-0005 (own OAuth AS vs hosted IdP) is **Proposed, not Accepted**, pending
  confirmation of PRD §15 decision D7.

### Changed — Module 3

- PRD deviations **D-h** and **D-i** recorded: the two-reviewer rule cannot be
  satisfied by a one-engineer team, and the behaviour of an in-flight order when
  a person disconnects is undefined in the source documents.

### Added — Module 2: tooling and quality gates

- Repository structure per PRD §5: 62 directories across `backend/`,
  `frontend/`, `infra/`, `docs/` and `.github/`.
- Backend dependency set (PRD §4.1) resolved and hash-pinned in `uv.lock`;
  183 packages, audited clean by both `pip-audit` and `osv-scanner`.
- Machine-enforced gates: ruff (24 rule families with a banned-API policy),
  mypy `--strict` plus `disallow_any_explicit`, import-linter (8 contracts
  encoding architectural rules A1–A4), bandit, nine custom Semgrep rules
  (PRD §10.5), gitleaks with 16 project-specific secret patterns,
  detect-secrets, pip-audit, osv-scanner.
- `Makefile` with 34 targets as the single entry point for developers and CI.
- 21 pre-commit hooks, including conventional-commit enforcement and a
  no-direct-commit-to-`main` guard.
- Local stack (`docker-compose.yml`) at production versions: Postgres 16.4 with
  `pgcrypto`/`citext`/`pg_trgm`/`btree_gist`, Redis 7.4 on `noeviction`, MinIO,
  Mailpit.
- `tests/architecture/test_layering.py` — rules A1–A4 as an executable
  assertion, with a drift guard so deleting a contract fails loudly.
- `scripts/doctor.sh` and `backend/scripts/check_coverage.py`.

### Fixed — Module 2

Defects found by running the gates rather than reading them:

- `test_layering.py` invoked `python -m importlinter.cli`, a silent no-op
  returning 0 — **a test that could never fail** while import-linter separately
  reported a real layering violation.
- `coverage-gate` reported *"Total coverage: 100.00%"* over an application with
  zero lines of code. Replaced with a gate that reports that state as INACTIVE.
- ruff returned different verdicts depending on the working directory it was
  invoked from; per-file-ignore globs were not anchored.
- The installed pre-commit hooks would have blocked every commit.
- `osv-scanner`, required by PRD §4.2 and §10.6, was wired nowhere.

### Changed

- PRD amended (new §17 amendment log): A1 file-count corrections, A2 the
  unenforceable "custom ruff rules" claim, A3 omitted directories, A4/A5 new
  scripts, A6 `osv-scanner` and the `pip-audit` lockfile requirement.

[Unreleased]: https://github.com/900Gang/A_New_MCP_Model
