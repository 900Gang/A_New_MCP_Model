# Data classification and retention

| Field | Value |
|---|---|
| Version | 1.0 (draft for first review) |
| Date | 16 September 2026 |
| Governs | Digital Personal Data Protection Act 2023 (India) · PRD §10.3 · TB-10 |
| Status | **Awaiting review with legal.** The consent-screen disclosure and the published privacy policy must be reviewed together so they cannot contradict each other (HB2 §8). |

---

## 0. Why this document exists

Under the DPDP Act, personal data needs a stated purpose, a lawful basis, a
retention limit and an accountable owner. "We collect what we need" is not a
lawful basis. This document is the record of what we collect, why, who may read
it, and when it is destroyed.

**Practical rule for engineers:** if you are adding a column, a log field, a
Sentry tag or an export that contains anything about a person, it needs a row in
§2 before it merges. `CONTRIBUTING.md` makes that a review question.

---

## 1. Classification levels

| Level | Meaning | Handling |
|---|---|---|
| **P0 — Public** | Safe to show anyone | Restaurant name, address, cuisine, published menu and prices, opening hours |
| **P1 — Internal** | Operational data, no personal identifier | Order totals, order states, relay delivery latency, aggregate dashboard counts |
| **P2 — Personal** | Identifies a person, directly or with little effort | Customer phone, delivery address, order history tied to a person, end-user `sub`, admin email |
| **P3 — Secret** | Compromise causes immediate loss | Signing keys, PSP keys, BSP tokens, session tokens, refresh tokens, OTP values, admin password hashes |

**P2 is encrypted at rest and redacted from every log.** P3 never touches the
database in plaintext, never appears in a log, and never appears in a URL.

---

## 2. Inventory

### Customer / end user

| Data | Level | Purpose | Lawful basis | Who may read it | Retention |
|---|---|---|---|---|---|
| Phone number (E.164) | **P2** | Identify the connected person; deliver order confirmations | Consent at the OAuth consent screen | Order-handling services; admin panel order detail | **12 months** after the last order, then purged |
| Display name | P2 | Address the person in relay messages | Consent | Same | 12 months |
| `sub` (internal id) | P2 | Link consent, tokens and orders | Contract performance | Services only | Until account deletion |
| Order contents, totals, state | P2 when linked to a person | Fulfil and support the order | Contract performance | Services; admin panel | 12 months |
| Delivery address | P2 | Fulfilment, when delivery is enabled | Contract performance | Order services; relay rendering | 12 months |
| OTP challenge | **P3** | Verify phone ownership | Consent | Nothing outside `oauth/userauth.py` | Hashed; purged on use or expiry (minutes) |
| Access / refresh tokens | **P3** | Maintain the connection | Consent | Nothing | Access 15 min; refresh 30 days; both hashed at rest |

**Encryption.** Phone, display name and address are stored with AES-256-GCM via
`core/crypto.py`, key-id tagged so keys rotate without rewriting rows.

### Restaurant and owner

| Data | Level | Purpose | Lawful basis | Retention |
|---|---|---|---|---|
| Name, address, geo, cuisine, hours, menu, prices | **P0** | The product | Contract | Life of the listing |
| Owner phone / WhatsApp (E.164) | **P2** | Order relay — the pilot depends on it | Contract | Life of listing + 12 months |
| FSSAI number and expiry | P2 | Legal precondition for listing (non-technical §1.3) | Legal obligation | Life of listing + statutory period |
| GSTIN | P2 | Invoicing where registered | Legal obligation | Life of listing + statutory period |
| Consent record (actor, method, evidence URI, text version, timestamp) | P2 | Prove the restaurant agreed to be listed | Legal obligation | **Permanent** — append-only. A consent dispute rests on this record. |

### Admin (interns and lead)

| Data | Level | Purpose | Retention |
|---|---|---|---|
| Email (citext), role | P2 | Authentication and RBAC | Life of account |
| Argon2id password hash, TOTP secret | **P3** | Authentication | Life of account |
| Sessions (IP, UA fingerprint) | P2 | Session revocation and abuse detection | 8 hours absolute |
| `audit_log` entries (actor, action, before/after, IP, UA) | P2 | Auditability (FRD) | **Permanent** — append-only |

### Operational

| Data | Level | Notes | Retention |
|---|---|---|---|
| Raw PSP webhook payloads | P2 | Retained deliberately as dispute evidence | 12 months |
| Raw relay inbound payloads | P2 | Contain a restaurant phone number | **90 days** |
| Structured application logs | P1 after redaction | The redaction processor runs before emission | 30 days |
| Sentry events | P1 | `send_default_pii=False` plus a scrubbing `before_send` | Per Sentry plan |
| Traces and metrics | P1 | Ids only, never contact data | 30 days |
| `idempotency_records` | P2 — response snapshots contain order data | Purged by `token_cleanup` | 24 hours |

---

## 3. Rules that follow

1. **Never log a P2 or P3 field.** Log an id. The structlog redaction processor
   is a backstop, not a licence — Semgrep rule 9 fails the build on a logging
   call with an unredacted PII field name.
2. **Never put a secret or a phone number in a URL.** URLs land in access logs,
   proxies and browser history.
3. **Never widen a read path without asking who gains access.** "The admin panel
   already shows it" is not a reason to add an export.
4. **Retention is enforced by a job, not by intention.** `token_cleanup` purges
   expired OTPs, codes, access-token records and idempotency records. Anything
   with a retention period in §2 needs a purge path and a test.
5. **Deletion honours the append-only tables.** A person's contact data is
   erasable; `audit_log`, `order_status_events` and `restaurant_consents` are
   not. Erasure replaces personal fields with a tombstone and keeps the
   transition record, which is what auditability requires and what the DPDP
   Act's legal-obligation basis permits.

---

## 4. Open items

| # | Item | Needed by | Owner |
|---|---|---|---|
| 1 | Confirm the 12-month order / 90-day relay retention periods with legal (PRD D9) | Week 8 | Legal + lead |
| 2 | Publish a privacy policy consistent with the consent-screen disclosure (HB2 §8) | Before real customer orders | Founder's office |
| 3 | Decide what customer data each AI platform expects to pass through, and what we may retain versus must pass through only (non-technical §3.2) | Week 9 | Founder's office |
| 4 | Name a grievance-redressal contact for the Consumer Protection (E-Commerce) Rules 2020, and decide how it reaches a customer who only ever sees Claude's interface | Before go-live | Founder's office |
| 5 | Confirm whether a Data Protection Officer is required at pilot scale | Week 8 | Legal |

Item 4 is a real design question, not paperwork: on the connector path the tool
output is the **only** channel to the customer, so seller identity and grievance
contact would have to travel in the tool response for the agent to be able to
state them.
