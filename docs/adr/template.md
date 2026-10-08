---
title: ADR template
sidebar_label: Template
description: The MADR-style template for new Converger Architecture Decision Records.
---

Copy the block below to `docs/adr/NNNN-short-title.md` (see
[How we write ADRs](how-we-write-adrs.md)), replace every placeholder and
delete the guidance comments.

```markdown
---
title: "ADR-NNNN: Short statement of the decision"
sidebar_label: "NNNN Short title"
description: One sentence that summarises the decision.
---

| | |
| --- | --- |
| **Status** | Proposed / Accepted / Deprecated / Superseded by [ADR-NNNN](NNNN-title.md) |
| **Date** | YYYY-MM-DD (merge date of the implementing PR) |
| **Issue** | [#NN](https://github.com/AimTune/converger/issues/NN) |
| **Pull request** | [#NN](https://github.com/AimTune/converger/pull/NN) |
| **Related** | [ADR-NNNN](NNNN-title.md) |

## Context and problem statement

What is the problem, what is the concrete failure mode or need, and which
constraints apply? Link the issue. A reader who has not seen the issue must be
able to follow.

## Decision drivers

- Driver 1 (for example: no message may be lost if the node crashes)
- Driver 2 (for example: no new infrastructure dependency)

## Considered options

1. **Option A** - one line
2. **Option B** - one line
3. **Option C** - one line

### Pros and cons of the options

#### Option A

- Good, because ...
- Bad, because ...

#### Option B

- Good, because ...
- Bad, because ...

## Decision

Chosen option: **"Option A"**, because ... (explain how it satisfies the
drivers better than the alternatives).

## Consequences

### Positive

- ...

### Negative and trade-offs

- ...

### Follow-ups

- [#NN](https://github.com/AimTune/converger/issues/NN) ...

## Implementation

Where the decision lives in the code (modules, migrations, config keys, with
links) and how it is tested.

## Links

- Documentation pages affected by this decision
- External references
```
