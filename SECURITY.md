# Security policy

## Supported versions

Converger has not tagged a release yet. Security fixes land on `main`; deploy from the latest `main` commit to get
them. Once releases are tagged, the latest minor release will receive security fixes as well.

| Version | Supported |
| --- | --- |
| `main` | Yes |
| Anything older than the latest `main` | No, upgrade first |

## Reporting a vulnerability

**Do not open a public issue, discussion or pull request for a security problem.**

Report it privately, in order of preference:

1. **GitHub private vulnerability reporting**: the repository's **Security** tab, **Report a vulnerability**
   ([github.com/AimTune/converger/security/advisories/new](https://github.com/AimTune/converger/security/advisories/new)).
2. **Email**: [hamzaagareng@gmail.com](mailto:hamzaagareng@gmail.com) with the subject `[converger security]`, if
   you cannot use GitHub.

Please include:

- the affected commit or version and how Converger was deployed (docker compose, release, Kubernetes);
- the component (REST API, WebSocket, channel adapter, inbound webhook, admin panel, tenant portal, ...);
- reproduction steps or a proof of concept, and the impact you observed (for example cross-tenant data access,
  authentication bypass, SSRF, secret disclosure);
- whether the issue is already public anywhere.

## What happens next

- We acknowledge the report within **3 business days**.
- We confirm or reject it and share a first assessment (severity, affected versions) within **10 business days**.
- We agree a disclosure date with you. The default is 90 days after the report, or earlier once a fix is on `main`.
- The fix is published with a GitHub security advisory (and a CVE when it applies). Reporters are credited unless
  they prefer not to be.

This is a volunteer-maintained project: these are targets, not a contractual SLA.

## Scope

In scope: the code in this repository (the Phoenix application, channel adapters, the `converger_js` client, the
Docker image and the deployment files).

Out of scope: vulnerabilities in third-party services (WhatsApp, Infobip, ...) and in dependencies that are not
exploitable through Converger (report those upstream), findings that need a compromised host or a malicious
operator, and missing hardening without a concrete impact.

Safe harbor: good-faith research that respects this policy, avoids privacy violations and service disruption, and
only uses accounts and tenants you own will not be pursued.

## Security model

How Converger authenticates, isolates tenants, stores secrets and hardens the HTTP edge is documented in the
[Security model](https://converger.aimtune.dev/security/overview).
