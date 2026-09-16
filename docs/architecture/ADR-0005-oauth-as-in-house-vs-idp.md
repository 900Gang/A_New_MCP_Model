# ADR-0005 — Run our own OAuth 2.1 authorization server (Authlib)

**Status:** **Proposed — pending confirmation of PRD §15 decision D7**
**Context:** PRD §6.9, §15 D7 · HB2 §7

> This ADR records the PRD's assumed default so work can proceed. It is not
> Accepted until D7 is confirmed by the lead. `app/oauth/` is not implemented
> before that point.

## Context

The Path A connector requires per-person authentication: Claude must prove
*which* person a tool call is for, so an order confirmation reaches the right
phone. HB2 §7 permits either option — *"either built in-house or delegated to an
existing identity provider Reward360 already trusts."*

MCP's authorization revision imposes requirements a general-purpose IdP is not
built around:

| Requirement | Standard | Why a hosted IdP struggles |
|---|---|---|
| Dynamic client registration | RFC 7591 | Claude registers itself; many IdPs expect clients created by an admin |
| Resource indicators | RFC 8707 | The `aud` claim must bind to *this* resource — the confused-deputy defence |
| Protected-resource metadata | RFC 9728 | Served from our domain, pointing at the AS |
| Immediate server-side revocation | HB2 §7 | A disconnect must stop working *at Bharat MCP*, not just in Claude's memory |
| Phone + OTP only, no password | Product | Many IdPs assume a password or a social provider |

## Decision (proposed)

**Own authorization server built on Authlib's `rfc6749` grant machinery**, with
a thin Starlette adapter — OAuth 2.1, PKCE S256 mandatory, RFC 7591 DCR, RFC
8414 and RFC 9728 metadata, RFC 8707 resource indicators, RFC 7009 revocation,
following RFC 9700 BCP.

**Authlib provides the grant state machine. We never hand-roll protocol or
crypto** — PRD §10.1 PW.4 is explicit, and a hand-rolled authorization server is
the single worst security decision available here.

## Why

The requirements above are the *whole* of what we need, and each is directly
expressible with Authlib. Bending a hosted IdP into DCR plus resource indicators
plus password-less phone login is more work than implementing the subset, and
leaves us dependent on a vendor's roadmap for a specification that is still
moving.

End-user identity is phone + OTP only: **no consumer password is ever created,
stored, or transmitted.** That removes credential storage, credential stuffing,
password reset and password reuse as entire risk classes — the largest security
argument for a hosted IdP disappears with it.

## Consequences

- **`app/oauth/` is the highest-risk code in the repository.** Eleven files, all
  **(SEC)**, all two-reviewer, plus `test_oauth_conformance.py` and an external
  penetration test focused here before go-live (§10.8).
- We own token lifecycle correctness: rotation with reuse detection that revokes
  the whole family, single-use codes bound to client + redirect + verifier +
  resource, Ed25519 keys with overlapping `kid` publication.
- Weeks 7–8 are the critical path, and the directory submission depends on them.
- Full control over the consent screen — which HB2 §5.2 requires to state the
  client name, the exact scopes, who Reward360 is, and a privacy-policy link.

## Alternatives

**Auth0 / Clerk / WorkOS.** Less code we own, mature security posture, MFA for
free. But DCR and resource-indicator support vary, password-less phone-only
login is not always a first-class flow, and "immediate revocation at Bharat MCP"
becomes a synchronisation problem across two systems.

**Reuse an existing Reward360 IdP.** Depends on what exists; not evaluated. If
one does exist with the properties above, it likely wins — which is exactly what
D7 must settle.
