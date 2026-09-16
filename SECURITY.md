# Security policy

Bharat MCP takes payments, holds personal contact data, and speaks on behalf of
restaurants that signed a consent form. Each of those is a liability the pilot
cannot absorb. This document is how a problem reaches someone who can fix it,
and how fast it gets fixed.

Applies to this repository and to the deployed pilot service.

---

## Reporting a vulnerability

**Do not open a GitHub issue, and do not discuss it in a shared channel.** A
public report is an exploit notice for everyone who reads it before we patch.

| Route | Use it for |
|---|---|
| Direct message to the infra/engineering lead | Anything. Always acceptable. |
| Email to the security contact in the Founder's Office runbook | When the lead is unreachable. |
| A private GitHub security advisory on this repository | External or arms-length reporters. |

Include, as far as you have it: what you did, what happened, what you expected,
and any request/response pair, `request_id` or `trace_id`. A `request_id` alone
usually locates the whole trace across the MCP call, the service, the database
and the worker.

**If you believe data has already been accessed or money moved, say so in the
first line.** That changes the response from triage to incident, and the
incident-response runbook (`docs/runbooks/incident-response.md`) takes over.

### For anyone testing the pilot

Do not test against production restaurant or customer data, do not place real
orders you do not intend to pay for, do not run load or denial-of-service tests
against the pilot instance, and do not access an account or an order that is not
yours. Use staging. If you find something by accident, stop and report it —
continuing to explore turns an accident into an intrusion.

---

## Severity and response SLA

Severity is judged on **realised impact if exploited**, not on how clever the
bug is. When two ratings are arguable, take the higher one.

| Severity | Definition | Examples | Acknowledge | Fix or mitigate |
|---|---|---|---|---|
| **Critical** | Direct monetary loss, or unauthenticated access to personal data at scale, or full compromise | Forged PSP webhook marks an unpaid order paid · access token accepted without audience validation · SQL injection reaching customer contact · leaked signing key | 2 hours | **24 hours** |
| **High** | Authenticated privilege escalation, cross-tenant access, or duplicate charge | One person reads another's order via `get_order_status` · refresh token replay not detected · a restaurant's menu editable by an unrelated admin · idempotency bypass creating a second order | 8 hours | **72 hours** |
| **Medium** | Meaningful weakening of a control, no direct exploit path proven | Missing rate limit on an OTP endpoint · PII reaching a log sink · CSRF gap on a non-destructive route · a `(SEC)` file merged with one reviewer | 2 business days | **14 days** |
| **Low** | Hardening, defence-in-depth, informational | Missing security header on a public route · verbose error text with no internals · dependency CVE with no reachable call path | 5 business days | Next dependency-bump PR |

The clock starts when the report reaches the lead, not when it was written.

**A Medium may only remain open past its SLA as a written, time-bound accepted
risk naming who accepted it and when it expires** (PRD §G4). There is no such
allowance for Critical or High: go-live requires zero open findings at those
levels (PRD §10.8).

---

## What we commit to

1. Acknowledge within the window above, with a severity and a named owner.
2. Tell you what we found, even when the answer is "this is working as intended"
   — with the reasoning.
3. Every security defect gets **a regression test** and a written answer to
   *"what class of bug is this, and what stops the next one?"* (PRD §10.1 RV.2).
   A fix without that answer is incomplete.
4. Credit you if you want it, and keep you anonymous if you do not.

We will not pursue anyone who reports in good faith under this policy and stays
within the testing rules above.

---

## Scope

**In scope.** The MCP tool surface (`/mcp`), the OAuth 2.1 authorization server
(`/oauth/*`), payment and relay webhooks (`/webhooks/*`), the admin API
(`/api/v1/*`) and panel, the order and payment domain logic, and this
repository's supply chain.

**Out of scope.** Third-party services we integrate but do not run — Anthropic,
the PSP (Razorpay/Cashfree), the WhatsApp BSP, the managed datastores. Report
those to the vendor. Also out of scope: findings that require a compromised
developer machine or physical access, best-practice reports with no exploit path
(send them as a normal issue), and volumetric denial of service.

---

## Where the analysis lives

- **`docs/threat-model.md`** — STRIDE across ten trust boundaries, the abuse
  cases behind each requirement, and the control that answers each threat. It is
  reviewed before the module it covers is implemented, not after.
- **`docs/data-classification.md`** — what personal data is collected, the
  lawful basis, who may read it, and how long it is kept (DPDP Act 2023).
- **`docs/runbooks/incident-response.md`** — what happens in the first hour. *(planned)*
- **PRD §10** — the full Secure SDLC regime, mapped to NIST SSDF (SP 800-218)
  and OWASP ASVS 4.0 L2.

## Handling of secrets

No secret is ever committed, logged, or placed in a URL. `.env` is
local-development only; deployed environments read from a secrets manager.
gitleaks and detect-secrets run pre-commit and over full history in CI.

**If a secret is committed, rotation comes first and history rewriting second.**
Assume anything pushed is compromised from the moment it is pushed — removing it
from history does not un-leak it. Rotation procedures will live in
`docs/runbooks/key-rotation.md` *(planned)*; until it exists, rotate through the
secrets manager and record the steps taken.
