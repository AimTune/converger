---
title: "ADR-0026: MIT license and community health files"
sidebar_label: "0026 MIT license and community health files"
description: Converger is released under the MIT License with inbound = outbound contributions, and ships SECURITY.md, a Contributor Covenant code of conduct, issue forms and a Keep a Changelog CHANGELOG.md.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-09 |
| **Issue** | [#48](https://github.com/AimTune/converger/issues/48) |
| **Pull request** | The pull request that added `LICENSE`, `SECURITY.md` and `CODE_OF_CONDUCT.md` |
| **Related** | [ADR-0025](0025-docusaurus-site-and-docs-with-every-change.md) |

## Context and problem statement

The repository had no license file, so GitHub reported none and, legally, nobody could use, modify or contribute
to the code. The README said "This project is commercially licensed. See `LICENSE` for details (if
applicable)", which contradicted the public repository, the documentation site and the
[roadmap](../roadmap.md) goal of making Converger "adoptable by someone who has never read its source"
([#61](https://github.com/AimTune/converger/issues/61)). There was also no security policy (the
[security model](../security/overview.md#reporting-a-vulnerability) noted "There is no `SECURITY.md` yet"), no
code of conduct and no issue templates, and the feature history was split between `CHANGELOG.md` and
`VERSIONS.md`.

[#48](https://github.com/AimTune/converger/issues/48) recommended Apache-2.0 and accepted MIT. The documentation
site part of #48 was decided in [ADR-0025](0025-docusaurus-site-and-docs-with-every-change.md); this ADR covers the
rest.

## Decision drivers

- Anyone can self-host, embed and extend Converger, including commercially, with as little legal review as
  possible.
- Contributions are accepted without a CLA process the project cannot staff.
- The license is compatible with the dependencies (MIT and Apache-2.0 Hex and npm packages, for example Oban Web
  under Apache-2.0) and with code vendored from the sibling projects (mekik test fixtures, MIT).
- The GitHub community profile is complete: license, code of conduct, contributing, security policy, issue and
  pull request templates.

## Considered options

1. **MIT** - short permissive license, no patent clause.
2. **Apache-2.0** - permissive with an explicit patent grant and a NOTICE mechanism; the issue's recommendation.
3. **AGPL-3.0** (optionally dual-licensed commercially) - copyleft that also covers network use.
4. **Keep the "commercially licensed" statement** - no open source license.

### Pros and cons of the options

#### MIT

- Good, because it is the shortest and most widely understood license; adopters rarely need legal review.
- Good, because it matches the sibling project mekik, whose fixtures are vendored here, and much of the Elixir and
  JavaScript ecosystem.
- Bad, because it has no explicit patent grant or patent retaliation clause.

#### Apache-2.0

- Good, because the explicit patent grant is valued by companies adopting infrastructure software.
- Bad, because it is longer, asks modified files to carry change notices and a NOTICE file to be kept, which is
  more process for a small project and its contributors.

#### AGPL-3.0

- Good, because hosted forks have to publish their changes, and it leaves room for dual commercial licensing.
- Bad, because many companies ban AGPL dependencies outright, which works against the adoption goal.
- Bad, because dual licensing needs a CLA or copyright assignment from every contributor.

#### Keep "commercially licensed"

- Good, because it keeps every commercial option open.
- Bad, because a public repository without a license cannot be used or contributed to, which contradicts the
  project's direction.

## Decision

Chosen option: **"MIT"**, chosen by the project owner, because it gives the lowest barrier to adoption and
contribution and matches the sibling projects. The missing patent grant was accepted as a trade-off.

With the license:

- **Contributions are inbound = outbound**: a pull request is licensed under MIT. There is no CLA. Third-party code
  needs a compatible license and keeps its notice next to it.
- **`SECURITY.md`** sets private reporting: GitHub private vulnerability reporting first, email as a fallback.
  It also sets response targets (acknowledgement within 3 business days, assessment within 10, coordinated
  disclosure after 90 days by default) and states that only the latest `main` gets fixes until releases are tagged.
- **`CODE_OF_CONDUCT.md`** is the Contributor Covenant 2.1, with the maintainer's email as the enforcement contact.
- **Issue forms** (`.github/ISSUE_TEMPLATE/`): bug report, feature request and channel adapter request. Blank
  issues are disabled, and the template chooser links to private advisories and the documentation site.
- **`CHANGELOG.md`** follows Keep a Changelog. `VERSIONS.md` is folded into its last section ("Milestones before
  this changelog") and removed, so there is one history file.

ExDoc (`mix docs`) from #48's acceptance criteria is not added. ADR-0025 replaced it with the Docusaurus site,
which is built and deployed to GitHub Pages from CI.

## Consequences

### Positive

- GitHub detects the license and the community profile files. Converger can be used, forked and packaged by
  anyone.
- Security reports have a documented private channel and expectations on both sides.
- Issues arrive with the information needed to act on them (version, deployment, area, reproduction).

### Negative and trade-offs

- No patent grant. Moving to Apache-2.0 later is possible (MIT code can be relicensed under Apache-2.0 terms),
  but it should be recorded in a superseding ADR.
- Commercial dual licensing is effectively ruled out: there is no CLA, so contributed code is MIT only.
- The response targets in `SECURITY.md` are commitments a single maintainer has to keep. They are stated as
  targets, not an SLA.
- The maintainer's email address is public in `SECURITY.md` and `CODE_OF_CONDUCT.md`.

### Follow-ups

- Tag the first release, so `SECURITY.md` can name supported versions and `CHANGELOG.md` gets its first version
  section.
- SPDX headers in source files (optional in #48) are not added.

## Implementation

- [`LICENSE`](https://github.com/AimTune/converger/blob/main/LICENSE),
  [`SECURITY.md`](https://github.com/AimTune/converger/blob/main/SECURITY.md),
  [`CODE_OF_CONDUCT.md`](https://github.com/AimTune/converger/blob/main/CODE_OF_CONDUCT.md),
  [`.github/ISSUE_TEMPLATE/`](https://github.com/AimTune/converger/tree/main/.github/ISSUE_TEMPLATE)
  (`bug_report.yml`, `feature_request.yml`, `adapter_request.yml`, `config.yml`),
  [`CHANGELOG.md`](https://github.com/AimTune/converger/blob/main/CHANGELOG.md).
- README: license section, clone URL, removal of the in-process benchmark numbers (load testing is
  [#34](https://github.com/AimTune/converger/issues/34)), architecture diagram with channels, modes and routing.
- Documentation: [Contributing](../contributing.md#code-of-conduct-issues-and-license),
  [Reporting a vulnerability](../security/overview.md#reporting-a-vulnerability),
  [Upgrades](../operations/upgrades.md), [Introduction](../intro.md#license).

## Links

- [MIT License](https://opensource.org/license/mit)
- [Contributor Covenant 2.1](https://www.contributor-covenant.org/version/2/1/code_of_conduct/)
- [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/)
- [GitHub: issue forms syntax](https://docs.github.com/en/communities/using-templates-to-encourage-useful-issues-and-pull-requests/syntax-for-issue-forms)
