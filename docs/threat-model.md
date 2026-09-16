# Threat model — Bharat MCP

| Field | Value |
|---|---|
| Version | 1.0 (draft for first review) |
| Date | 16 September 2026 |
| Method | STRIDE per trust boundary, per PRD §10.2 |
| Standards | NIST SSDF PW.1 · OWASP ASVS 4.0 L2 · OWASP API Security Top 10 |
| Status | **Awaiting first review.** PRD §10.1 (PW.1) requires this reviewed and signed before the corresponding module is implemented. |

---

## 0. How this document is used

This is not a document that gets written once and filed. Three rules govern it:

1. **A trust boundary is reviewed before the module that crosses it is built.**
   Threat modelling after implementation finds the bugs you already shipped.
2. **Every threat names the control that answers it and the test that proves the
   control works.** A control with no test is an intention.
3. **When a threat is accepted rather than mitigated, it is written down here
   with an owner and an expiry**, not left implicit.

If you are about to change a file marked **(SEC)** in PRD §6, read the trust
boundary it sits on first.

---

## 1. What an attacker actually wants

Threat modelling goes wrong when it starts from techniques instead of assets.
In this system there are five things worth stealing or breaking, in order:

| # | Asset | Why it is worth attacking | Worst realistic outcome |
|---|---|---|---|
| A1 | **Money in flight** | Customer → platform → restaurant, via a PSP | A forged webhook marks an unpaid order paid, and a restaurant hands over food that nobody paid for. Or a customer is charged twice. |
| A2 | **Customer contact data** | Phone numbers and order history for every pilot user | A DPDP Act 2023 breach, and the end of the pilot's licence to operate |
| A3 | **The ability to act as another person** | An access token is the only thing distinguishing one connected Claude user from another | Ordering food to someone else's address on someone else's payment method |
| A4 | **Restaurant trust** | Restaurants signed a consent form on the promise that only real orders reach them | A spoofed "order accepted" reply, or a flood of fake orders. Restaurants leave, and the pilot has no supply. |
| A5 | **Our signing keys** | Ed25519 keys that mint access tokens | Total compromise: forge any token for any user, indefinitely |

Everything below is in service of those five.

---

## 2. Trust boundaries

```
 ┌──────────────┐                    ┌──────────────────┐
 │ Claude.ai /  │───── TB-1 ────────▶│                  │
 │ Claude app   │───── TB-2 ────────▶│                  │
 │ (untrusted)  │◀──── TB-3 ─────────│                  │
 └──────────────┘                    │                  │
 ┌──────────────┐                    │   Bharat MCP     │
 │ Admin browser│───── TB-4 ────────▶│   (trusted core) │
 └──────────────┘                    │                  │
 ┌──────────────┐                    │                  │
 │ PSP          │───── TB-5 ────────▶│                  │
 │ BSP/WhatsApp │───── TB-6 ────────▶│                  │
 └──────────────┘                    │                  │
                                     │                  │──TB-7──▶ R2 object store
                                     │                  │──TB-8──▶ Postgres
                                     └──────────────────┘
 ┌──────────────┐                              ▲
 │ CI / repo    │───────── TB-9 ───────────────┘
 └──────────────┘
                     TB-10: data at rest and in logs (crosses all of the above)
```

**The core assumption:** everything outside the trusted core is hostile,
*including the AI agent*. Claude is not an attacker, but a person talking to
Claude may be, and a compromised or confused agent produces exactly the same
traffic as a malicious one. No control anywhere in this system may depend on the
agent behaving well.

---

## 3. Abuse cases

PRD §10.1 requires abuse cases written alongside acceptance criteria. These are
the ones that shaped the design.

### "What does a malicious agent do with `place_order`?"

| Abuse | Answer |
|---|---|
| Replays the same call 500 times to create 500 orders | Idempotency key is **required**. Same key → same order, replayed byte-identically. Four layers (§11.4). |
| Reuses one key with a different body, hoping to overwrite an order | Request fingerprint compared; mismatch returns `409 idempotency_key_reused` rather than silently returning someone else's order |
| Orders at a price it supplies rather than ours | Prices are never accepted from input. The cart is re-validated against live prices and **snapshotted server-side**. |
| Orders a negative or absurd quantity to invert the total | `PositiveInt` at the schema boundary; `CHECK (total_paise = subtotal_paise + tax_paise)` in Postgres |
| Orders from a paused, unconsented or out-of-coverage restaurant | `availability_service` is the single authority; `CHECK (status <> 'active' OR (consent_id IS NOT NULL AND smoke_test_passed))` |
| Floods a real restaurant with orders to burn its goodwill | Per-subject and per-client token buckets; flagged-order queue surfaces anomalies to the admin panel |
| Enumerates `ord_` ids to read other people's orders | `get_order_status` is ownership-checked against the calling principal; ids are UUIDv7-derived, not sequential |
| Passes a token it obtained for a different service | **Rejected.** Audience binding (RFC 8707) is validated on every call. No token passthrough, ever. |

### "What does a hostile person do at the consent screen?"

Registers a client whose redirect URI they control and phishes a consent grant;
intercepts an authorization code; brute-forces an OTP; replays a refresh token.
Answered in TB-2 and TB-3.

### "What does a hostile restaurant do?"

Accepts orders it cannot fulfil to keep the listing; disputes having consented
to be listed; claims non-payment. Answered by append-only `restaurant_consents`
with `REVOKE UPDATE, DELETE`, and by retaining raw signed PSP payloads as
dispute evidence.

### "What does a compromised intern account do?"

Edits prices on restaurants they were never assigned; exports the customer
table; activates a restaurant with no consent. Answered by RBAC checked
server-side on every route, the activation CHECK constraint, and an append-only
`audit_log` the account cannot rewrite.

---

## 4. Trust boundaries in detail

Each table maps **STRIDE → threat → control → the test that proves the control**.
A row with no test is not finished.

### TB-1 · AI agent → `/mcp`

The agent surface. Six tools, deliberately narrow: there is no "charge card" tool
and no "delete restaurant" tool, and there must never be. Narrowness is
structural — a tool absent from `mcp/tools/__init__.py` is not exposed.

| STRIDE | Threat | Control | Verified by |
|---|---|---|---|
| **S** | Calling as another person with a stolen or borrowed token | Ed25519 signature, `exp`, `iss`, and `jti` revocation check on **every call** | `test_oauth_conformance.py` |
| **S** | **Confused deputy** — presenting a token minted for another resource | `aud` validated against this resource (RFC 8707). **No token passthrough, ever.** | `test_token_audience_binding.py` |
| **T** | Supplying prices, totals or order status in the request | Server re-validates against live data and snapshots prices; status is never an input | `test_place_order.py` |
| **R** | Denying having placed an order | Append-only `order_status_events` with actor, reason, timestamp | `test_audit_immutability.py` |
| **I** | Enumerating restaurants, orders or other users' data | Ownership checks on `get_order_status`; cursor pagination with a capped page size; active-only results | `test_authz_matrix.py`, `test_cross_tenant.py` |
| **I** | Internals leaking through error text | `mcp/errors.py` maps every domain error to plain language plus a machine `code`. No class name, SQL fragment or stack trace reaches an agent. | `test_agent_messages.py` (golden transcripts) |
| **D** | Expensive queries or unbounded pages as a denial of service | Per-subject **and** per-client token buckets; Postgres `statement_timeout`; capped page size; single-query menu loads | `test_per_subject_ratelimit.py`, query-count test |
| **E** | Calling `place_order` with only a read scope | Deny-by-default; every tool declares a scope, and Semgrep rule 7 fails the build if one does not | `test_authz_matrix.py` |

**Residual risk.** A legitimately connected person remains able to place real
orders — that is the product. Abuse by an authenticated user is bounded by rate
limits and surfaced by the flagged-order queue, not prevented.

### TB-2 · Person → `/oauth/authorize`, consent, OTP

Where a person decides to trust us. Most consumer OAuth failures are here.

| STRIDE | Threat | Control | Verified by |
|---|---|---|---|
| **S** | Authorization-code interception | **PKCE S256 mandatory**; codes single-use, short-lived, bound to client + redirect URI + verifier + resource | `test_oauth_conformance.py` |
| **S** | OTP brute force | Attempt caps with lockout, per-phone rate limit, constant-time compare, short expiry, hashed at rest | `test_otp_bruteforce.py` |
| **T** | Open redirect via a crafted `redirect_uri` | Exact-match registered URIs. No wildcards, no prefix matching; loopback per OAuth 2.1 | `test_redirect_uri_exact_match.py` |
| **T** | CSRF on the consent POST | Signed `state` plus a session-bound CSRF token | `test_consent_csrf.py` |
| **R** | Denying having granted consent | `user_consents` records user × client × scopes × granted_at | `test_consent_recorded.py` |
| **I** | A malicious client registering a convincing name to phish scopes | Consent screen states the client name and requested scopes **verbatim**, plus who Reward360 is and a privacy-policy link (HB2 §5.2); DCR is rate-limited | Manual review of consent copy + `test_dcr_ratelimit.py` |
| **D** | OTP-request flooding to exhaust SMS budget | Per-phone and per-IP buckets; cost cap alert | `test_otp_ratelimit.py` |
| **E** | Scope escalation on a silent re-authorisation | Consent is persisted per scope set and **re-prompted on escalation**; `orders:write` is never implied by a read scope | `test_scope_escalation_reprompts.py` |

**Design note.** End users have **no password** — phone plus OTP only. That
removes credential storage, credential stuffing, password reset, and password
reuse as entire classes of risk, at the cost of depending on SMS/WhatsApp
delivery.

### TB-3 · Claude ↔ `/oauth/token`

| STRIDE | Threat | Control | Verified by |
|---|---|---|---|
| **S** | Client impersonation at the token endpoint | Client authentication; codes bound to the issuing client | `test_oauth_conformance.py` |
| **T/I** | Refresh-token theft and replay | **Rotation on every use with reuse detection: a replayed refresh token revokes the entire token family.** Hashed at rest. | `test_refresh_reuse_revokes_family.py` |
| **I** | A long-lived access token outliving consent | 15-minute access tokens; `AccessTokenRecord` by `jti` enables **immediate** server-side revocation | `test_revocation_immediate.py` |
| **R** | Disputing a disconnect | Revocation timestamped and audited | `test_audit_immutability.py` |

**Open question.** HB2's FAQ notes that disconnecting should not be assumed to
cancel an order already placed. Current intent: the order completes, but
`get_order_status` stops being callable for it. **Needs confirmation** — PRD §17
D-i.

### TB-4 · Admin browser → `/api/v1`

Interns operate this daily. It has full read access to customer contact data.

| STRIDE | Threat | Control | Verified by |
|---|---|---|---|
| **S** | Session hijack | `HttpOnly` + `Secure` + `SameSite=Lax` cookies; server-side revocable sessions with IP/UA fingerprint; 8h absolute, 1h idle | `test_session_lifecycle.py` |
| **S** | Brute-force login | Argon2id (m=64MiB, t=3, p=4), per-IP rate limit, lockout, **generic failure message** (no user enumeration) | `test_login_bruteforce.py` |
| **T** | CSRF on state-changing routes | Double-submit CSRF on every non-GET | `test_csrf_required.py` |
| **T** | Stored XSS via menu text or an uploaded SVG | Output is JSON; the only HTML is the Jinja2 consent/OTP pages with autoescape on; **SVG upload rejected outright**; strict CSP with no `unsafe-inline` | `test_secure_defaults.py`, `test_upload_rejects_svg.py` |
| **R** | Denying a price edit | Append-only `audit_log` with before/after diff, IP, UA, request id; `REVOKE UPDATE, DELETE` at the DB role | `test_audit_immutability.py` |
| **I** | An intern exporting the customer table | RBAC server-side on every route; customer contact encrypted at rest and redacted in logs; no bulk-export endpoint | `test_authz_matrix.py` |
| **E** | Intern performing a lead-only action (key rotation, admin creation) | `require_role(...)` on every route; deny-by-default | `test_authz_matrix.py` |

### TB-5 · PSP → `/webhooks/payments` — **the direct-money boundary**

The highest-consequence boundary in the system. A forged webhook here is theft.

| STRIDE | Threat | Control | Verified by |
|---|---|---|---|
| **S** | Forged "payment succeeded" | HMAC signature verified with constant-time compare **before the payload is parsed** | `test_webhook_signature_forgery.py` |
| **T** | Replaying a genuine webhook to double-credit | `UNIQUE (provider, provider_event_id)` | `test_webhook_replay.py` |
| **T** | Amount or order id tampered inside a validly signed payload | Both re-verified against our own record, **and** a server-to-server fetch must agree before marking paid | `test_payment_amount_mismatch.py` |
| **R** | A customer disputing payment | Raw signed payloads retained as dispute evidence | `test_webhook_payload_retained.py` |
| **D** | Webhook flood | Verify-then-defer: the handler returns 2xx fast and enqueues to the outbox | `test_webhook_defers_to_outbox.py` |
| — | Webhook never arrives | ≥3 retries with backoff, then an alert. **Never silently assumed paid.** | `test_webhook_retry.py` |

**Note.** No card or UPI credential ever touches Bharat MCP — PSP-hosted
collection only, per the FRD and RBI PA rules. That removes PCI scope entirely.

### TB-6 · BSP → `/webhooks/relay`

The boundary where a restaurant's decision enters the system.

| STRIDE | Threat | Control | Verified by |
|---|---|---|---|
| **S** | Spoofed sender number faking "ACCEPT" | Provider signature verification **and** the sender must match the restaurant's registered E.164 number | `test_inbound_sender_verification.py` |
| **S** | Guessing an accept link | One-time unguessable link tokens as the primary path; keywords only as fallback | `test_accept_token_unguessable.py` |
| **T** | Ambiguous reply interpreted as acceptance | Ambiguity routes to `needs_human`, never to a status change | `test_ambiguous_reply_flagging.py` |
| **R** | Restaurant denying it accepted | `relay_inbound_events` stores raw text, parsed intent and confidence | `test_inbound_parsing.py` |
| **D** | Inbound flood | Per-number rate limit; verify-then-defer | `test_relay_ratelimit.py` |

### TB-7 · Admin upload → object storage

| STRIDE | Threat | Control | Verified by |
|---|---|---|---|
| **T** | Malicious file disguised as an image | Presigned PUT with enforced content-type and size; server-side **magic-byte** validation; **re-encode via Pillow**, which strips EXIF/GPS and any embedded payload | `test_upload_validation.py` |
| **T** | Stored XSS via SVG | SVG rejected outright | `test_upload_rejects_svg.py` |
| **T** | Path traversal via filename | Random object keys; a user-supplied filename is never used as a path | `test_upload_random_key.py` |
| **I** | Enumerating menu images | Private bucket; short-TTL presigned GET; no public bucket policy | `test_bucket_not_public.py` |
| **I** | GPS coordinates leaking from a phone photo | Re-encode strips EXIF | `test_exif_stripped.py` |
| **D** | Storage exhaustion | Size cap enforced in the presign | `test_upload_size_cap.py` |

### TB-8 · Application → Postgres

| STRIDE | Threat | Control | Verified by |
|---|---|---|---|
| **T** | SQL injection | Parameterised ORM queries only; no string-built SQL. Semgrep rule 1 fails the build. | `test_injection.py`, Semgrep |
| **I** | Cross-tenant read | Mandatory tenant scope in `BaseRepository`; Semgrep rule 3; import-linter keeps raw sessions out of the service layer | `test_cross_tenant.py` |
| **I** | Mass exfiltration through a legitimate endpoint | Cursor pagination with a capped page size; no unbounded list route | `test_pagination_caps.py` |
| **E** | Runtime role performing DDL | Least-privilege role with no DDL rights; migrations run under a separate role | `test_runtime_role_cannot_ddl.py` |
| **D** | A pathological query pinning a connection | `statement_timeout`, `lock_timeout`, `idle_in_transaction_session_timeout` set at connection | `test_session_timeouts.py` |

### TB-9 · Repository / CI → production

| STRIDE | Threat | Control | Verified by |
|---|---|---|---|
| **I** | A credential committed | gitleaks (16 project patterns) + detect-secrets, pre-commit **and** over full history in CI | `make secrets` |
| **T** | Malicious or typosquatted dependency | Hash-pinned lockfiles; grouped Dependabot; `pip-audit` + `osv-scanner` + `pnpm audit` every run and nightly; a new direct dependency needs a maintenance/licence/weight note | `make sca` |
| **T** | Compromised build producing a trojaned image | Multi-stage builds from digest-pinned bases; Trivy scan; signed images; CycloneDX SBOM per release | `security-scan.yml` |
| **E** | Long-lived cloud credentials in CI | OIDC federation; no static cloud keys in CI | Workflow review |
| **T** | A gate silently weakened | Gate configs are owned in `CODEOWNERS`; weakening one is a reviewed security change | `CODEOWNERS` |

### TB-10 · Data at rest and in logs

| STRIDE | Threat | Control | Verified by |
|---|---|---|---|
| **I** | Customer phone numbers readable in a database dump | AES-256-GCM at rest, key-id tagged so keys rotate without a rewrite | `test_contact_encrypted_at_rest.py` |
| **I** | PII reaching a log sink or Sentry | structlog redaction processor; Sentry `send_default_pii=False` with a scrubbing `before_send`; Semgrep rule 9 | `test_pii_redaction.py`, `test_sentry_context.py` |
| **I** | Over-retention (DPDP Act 2023) | `token_cleanup` cron purges expired OTPs, codes, access-token records and idempotency records; retention per `data-classification.md` | `test_retention_purge.py` |
| **R** | Tampering with consent or audit records | Append-only triggers plus `REVOKE UPDATE, DELETE` on `audit_log`, `order_status_events`, `restaurant_consents` | `test_audit_immutability.py` |

---

## 5. Residual and accepted risks

Written down because an unwritten accepted risk is an unowned one.

| # | Risk | Why it is not fully mitigated | Owner | Review by |
|---|---|---|---|---|
| R1 | An authenticated user can place orders they do not intend to collect | Indistinguishable from legitimate use at this scale | Lead | Before restaurant #50 |
| R2 | A restaurant accepts an order it cannot fulfil | No live inventory sync exists; FR-15's accept/reject is the mitigation and depends on a human replying | Founder's office | Pilot review |
| R3 | Menu and price staleness — a physical restaurant changes prices without telling us | Restaurants have no login in the pilot (FRD §2.2); FR-3 gives interns an update path, not the restaurant | Founder's office | Pilot review |
| R4 | Single shared server: one outage affects all 500 restaurants | Deliberate pilot-scale tradeoff (infra plan §7). Mitigated by monitoring and a fast rollback path, not redundancy. | Lead | Post-pilot |
| R5 | SMS/WhatsApp OTP delivery is a single point of failure for end-user login | No password fallback by design — that is the point | Lead | Week 7 |
| R6 | Connector directory listing reaches users outside Bangalore | HB2 §9. Tools reject out-of-area requests with an explanation rather than an empty result. | Founder's office | Week 9 (D5) |
| R7 | **Two-reviewer rule for (SEC) files cannot be satisfied by a one-engineer team** | The documented team is one infra lead plus two non-engineering interns | Founder's office | **Before the first (SEC) module** |

R7 is a genuine conflict between PRD §10.7 and the staffing in the FRD, not an
oversight. It needs a second reviewer named, or an explicitly accepted risk.

---

## 6. Review log

| Version | Date | Boundaries reviewed | Reviewer | Outcome |
|---|---|---|---|---|
| 1.0 | 2026-09-16 | TB-1 … TB-10 drafted | — | **Awaiting first review** |

Per PRD §10.1 (PW.1), no **(SEC)** module is implemented before the boundary it
crosses is signed off here.
