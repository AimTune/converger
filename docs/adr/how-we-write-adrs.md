---
title: How we write ADRs
sidebar_position: 2
description: When an Architecture Decision Record is required, and how to number, write, review and supersede one.
---

Converger records architecturally significant decisions as ADRs in
`docs/adr/`. They exist so that the next engineer, the next reviewer, or you in
six months can see *why* the system is the way it is, which options were
rejected, and which trade-offs were accepted on purpose.

## When an ADR is required

Write a new ADR, or supersede an existing one, in the same pull request as the
change when the change:

- alters a delivery or data-integrity guarantee (transactions, ordering,
  idempotency, retries, dead letters);
- adds, removes or replaces a dependency that shapes the architecture (a queue,
  a storage backend, an HTTP client, an auth library);
- changes a public contract: REST API shape, WebSocket protocol, adapter
  behaviour, webhook signature format, configuration that operators set;
- changes the security model (authentication, secrets handling, tenant
  isolation, network egress);
- changes how the system is built, tested, deployed or migrated;
- picks one of several reasonable designs, where the losing options would be
  proposed again later if the reasoning were not written down.

Bug fixes, refactors that keep behaviour, and features that follow an existing
decision do not need an ADR. They still need their
[documentation updates](../contributing.md#documentation-with-every-change).

## Writing one

1. Copy the [template](template.md) to `docs/adr/NNNN-short-title.md`. `NNNN`
   is the next free number (four digits, never reused). The title is
   lowercase, hyphenated and states the decision (`keyset-pagination`, not
   `pagination-discussion`).
2. Fill in every section:
   - **Context and problem statement**: the concrete failure mode or need,
     with links to the issue. Someone who has not read the issue must
     understand it.
   - **Decision drivers**: the forces that matter (correctness, operability,
     dependencies, performance, compatibility).
   - **Considered options**: at least two real options, including "do
     nothing" when it was viable, each with honest pros and cons.
   - **Decision**: the chosen option and *why* it beats the others against
     the drivers.
   - **Consequences**: what gets better, what gets worse or harder, and the
     follow-up work (link the issues).
   - **Implementation**: where it lives (modules, migrations, config keys)
     and how it is tested.
3. Add a row to the table in the [ADR index](index.md).
4. Link the ADR from the documentation pages it affects, and link those pages
   from the ADR.

## Status and lifecycle

- An ADR starts as **Proposed** in the pull request or issue that discusses
  it. A decision taken in an issue before any code exists (for example
  [ADR-0024](0024-converger-protocol-v1-as-superset-of-mekik-1.md)) is
  recorded as **Accepted** with the issue as its reference.
- It becomes **Accepted** when the pull request that implements it is merged.
  The date is the merge date.
- Accepted ADRs are not rewritten. Typos and broken links may be fixed. When
  the decision changes, write a new ADR, set the old one to **Superseded by
  ADR-NNNN** and link back from the new one.
- An ADR whose subject was removed from the code is marked **Deprecated**.

## Review

ADRs are reviewed together with the code. Reviewers check that the rejected
options are represented fairly, that the consequences include the costs, and
that the implementation section matches the diff.

## Local preview

The ADRs are part of the documentation site. Preview them with:

```bash
cd website
npm ci
npm start
```
