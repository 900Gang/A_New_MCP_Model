## What and why

<!-- What changes, and why it is needed. The diff says what; say why. -->

Closes #

**PRD reference:** <!-- e.g. FR-11, §6.6, HB2 §7 -->

---

## Security review (PRD §10.7)

Answer all four. "N/A" is a valid answer when it is true; it is not a way to
skip the question.

**1. What new data does this touch?**
<!-- Any new personal data needs an entry in docs/data-classification.md,
     covering lawful basis, who may read it, and retention. -->

**2. What new authorisation decision does it introduce?**
<!-- Which principal, which scope or role, and where the check lives.
     Deny-by-default: an undeclared route or tool must fail closed. -->

**3. What happens if the input is hostile?**
<!-- Not malformed — hostile. A replayed token, a forged webhook signature,
     a duplicate idempotency key with a different body, an id belonging to
     someone else, a 10MB menu image, a negative quantity. -->

**4. Which test proves it?**
<!-- Name the test. "It's covered" is not an answer. -->

---

## Definition of done (PRD §11.5)

- [ ] Unit tests for the logic; integration test if it touches the database
- [ ] `make check` passes locally
- [ ] New domain errors have agent-message golden entries
- [ ] New DB invariants exist as **constraints**, not only as Python
- [ ] OpenAPI document and generated frontend types regenerated and committed
- [ ] Runbook updated if operational behaviour changed
- [ ] `CHANGELOG.md` updated under `[Unreleased]`
- [ ] **No TODO and no commented-out code**

## Reviewers

- [ ] This PR touches a **(SEC)** file or a migration → **two approvals required**

<!--
If this fixes a security defect, PRD §10.1 RV.2 requires two things in the PR:
a regression test, and an answer to "what class of bug is this, and what stops
the next one?" A fix without that answer is incomplete.
-->
