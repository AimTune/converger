---
title: "ADR-0011: Custom TrustedProxies plug for client IP resolution and a CIDR admin whitelist"
sidebar_label: "0011 Trusted proxies"
description: The client IP is resolved from X-Forwarded-For only across configured trusted hops, by a small in-house plug instead of the remote_ip library, and the admin whitelist accepts CIDR ranges.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-08 |
| **Issue** | [#11](https://github.com/AimTune/converger/issues/11) |
| **Pull request** | [#75](https://github.com/AimTune/converger/pull/75) |
| **Related** | [ADR-0010](0010-runtime-cors-and-opentelemetry-configuration.md), [ADR-0013](0013-cluster-wide-rate-limiting-with-hammer-and-pubsub.md), [ADR-0014](0014-webhook-ssrf-guard-and-outbound-signing.md), [ADR-0022](0022-deployment-hardening.md) |

Several parts of Converger make decisions based on the client IP address: the admin IP whitelist, per-IP rate limits and the failed-login lockout. In almost every real deployment the app runs behind a load balancer or an ingress controller, so the TCP peer is the proxy, not the client. This ADR records how the real client address is derived and why a custom plug was written instead of using the `remote_ip` Hex package suggested in the issue.

## Context and problem statement

`ConvergerWeb.Plugs.AdminAuth` compared `conn.remote_ip` with `admin_ip_whitelist`. Behind a proxy, `remote_ip` is the proxy's address, which left operators with two bad choices:

- the whitelist never matched and admins were locked out, or
- the operator added the proxy IP to the whitelist, which let **everyone** through the proxy into the admin interface.

`ConvergerWeb.Plugs.RateLimit` used the same `remote_ip`, so every per-IP limit collapsed into a single bucket shared by all clients behind the proxy. The whitelist also accepted only exact addresses, so a VPN range such as `10.8.0.0/16` could not be expressed.

A naive `X-Forwarded-For` parser would be worse than nothing: the header is client-controlled, so taking its left-most entry lets any client claim any address, including a whitelisted admin IP.

## Decision drivers

- Never trust forwarding headers from a peer that is not a configured proxy.
- Pick the correct client in multi-hop chains (CDN, then load balancer, then ingress) where a spoofed entry may sit to the left.
- Work with private address space on both sides: admins on a VPN at `10.8.x.x` behind a load balancer at `10.0.x.x` is a typical setup.
- IPv4, IPv6, CIDR, ports and IPv4-mapped IPv6 must all be handled.
- Runtime configuration (`TRUSTED_PROXIES`), consistent with [ADR-0010](0010-runtime-cors-and-opentelemetry-configuration.md).
- No new dependency if the code is small.

## Considered options

1. **Custom `TrustedProxies` plug with strict trusted-hop resolution** plus a shared `IpMatcher` for CIDR matching.
2. **The `remote_ip` Hex package** with a configured proxy list, as proposed in the issue.
3. **`Plug.RewriteOn` / proxy-specific headers** (for example `X-Real-IP` or the left-most `X-Forwarded-For`).
4. **Move admin protection out of the app entirely** (VPN-only ingress, OIDC/SSO at the edge, mTLS) and drop the IP whitelist.

### Pros and cons of the options

**Option 1: custom plug**

- Good: checks the TCP peer first; a client that talks to the app directly cannot spoof its address.
- Good: walks the chain right to left and stops at the first untrusted hop, which is the only address a trusted proxy actually observed.
- Good: treats private ranges like any other address; only listed proxies are skipped.
- Good: about 100 lines with no new dependency; `IpMatcher` is reused by the admin whitelist and later by the webhook SSRF guard ([ADR-0014](0014-webhook-ssrf-guard-and-outbound-signing.md)).
- Bad: security-sensitive parsing code that the project has to own and test.

**Option 2: `remote_ip`**

- Good: maintained library, widely used.
- Bad: it never checks the TCP peer. It rewrites `remote_ip` from the headers no matter who sent them, so it is spoofable unless a separate trusted-peer check is added anyway.
- Bad: it always treats private and loopback ranges (`10/8`, `172.16/12`, `192.168/16`, `fc00::/7`) as proxies. In the VPN-behind-LB setup above it discards the admin's real `10.8.x.x` address and falls back to the load balancer IP, which breaks the CIDR whitelist this issue asks for. A non-trusted private hop could also let a spoofed address to its left be picked as the client.

**Option 3: single trusted header**

- Good: trivial.
- Bad: the left-most `X-Forwarded-For` entry is attacker-controlled; `X-Real-IP` semantics differ per proxy and the header is not set by every load balancer.

**Option 4: edge-only admin protection**

- Good: stronger than IP checks for cloud deployments.
- Bad: not available in every environment (bare metal, docker compose); rate limits and login lockout still need a correct client IP.
- Kept as **documented guidance** in [`docs/security.md`](../security.md), in addition to the whitelist rather than instead of it.

## Decision

Chosen option: **"Custom `TrustedProxies` plug with strict trusted-hop resolution"**, because the `remote_ip` package cannot express "trust the header only from these peers" and its built-in private-range skipping breaks the VPN case that motivated the CIDR whitelist. The custom plug is small enough to review in full.

The algorithm in `ConvergerWeb.Plugs.TrustedProxies`:

1. Read the trusted list from `Application.get_env(:converger, :trusted_proxies)` on every call (parsed once per distinct value and memoized in `:persistent_term`).
2. If the list is empty or the TCP peer is not in it, leave `conn.remote_ip` untouched and ignore every forwarding header.
3. Otherwise collect all `X-Forwarded-For` headers in order, split on commas, and walk the entries **right to left**. Trusted entries are skipped; the first untrusted entry is the client.
4. If an entry cannot be parsed, stop and use the last trusted hop, so garbage injected by the client is never trusted.
5. If every entry is trusted, the left-most one is used.
6. Entries may carry ports and brackets (`1.2.3.4:5678`, `[::1]:5678`).
7. Keep the original peer in `conn.private[:peer_remote_ip]`.

The plug runs first in the endpoint, ahead of `Plug.RequestId`, the router, `AdminAuth` and `RateLimit`. `AdminAuth` and `RateLimit` keep reading `conn.remote_ip` and need no proxy awareness.

`ConvergerWeb.IpMatcher` parses single addresses (treated as `/32` or `/128`) and CIDR ranges for IPv4 and IPv6, matches IPv4-mapped IPv6 (`::ffff:a.b.c.d`) as IPv4, and logs and skips invalid entries once.

## Consequences

### Positive

- Admins can be whitelisted by their real address or range (`10.8.0.0/16`, `fd00::/8`) behind any number of trusted proxies.
- A direct client cannot spoof its address; a spoofed left-most entry behind a trusted proxy is ignored.
- Per-IP rate limits and the login lockout ([ADR-0013](0013-cluster-wide-rate-limiting-with-hammer-and-pubsub.md)) see distinct clients again. The rate-limit key uses `:inet.ntoa/1`, so IPv6 addresses are formatted correctly.
- `conn.private[:peer_remote_ip]` doubles as the "came through a trusted proxy" marker. `ConvergerWeb.Plugs.ForceSSL` uses it to honor `X-Forwarded-Proto` only from those peers ([ADR-0022](0022-deployment-hardening.md)).
- With `TRUSTED_PROXIES` unset (the default) the plug is a no-op, so single-node and local setups are unaffected.

### Negative and trade-offs

- Operators must list every proxy hop. A missing hop makes that proxy's address look like the client (fails closed for the whitelist, but merges rate-limit buckets).
- Listing too broad a range (for example `0.0.0.0/0`) would let any peer set `X-Forwarded-For` and make the whitelist spoofable. Nothing in the code prevents such a configuration.
- Only `X-Forwarded-For` is supported; the RFC 7239 `Forwarded` header is ignored.
- WebSocket and LiveView sockets read `peer_data` from `connect_info`, which this plug does not rewrite. No socket code uses the client IP today.
- The project owns the parsing code rather than a shared library.

### Follow-ups

- [#52](https://github.com/AimTune/converger/issues/52): auth hardening (admin 2FA, session expiry) as stronger admin protection than the IP whitelist.
- [#29](https://github.com/AimTune/converger/issues/29): multi-node deployment and Kubernetes manifests. Those run behind an ingress, so they must set `TRUSTED_PROXIES` to the ingress range.
- Socket-level client IP resolution (rewriting `peer_data` for WebSocket and LiveView connections) is not tracked by an issue yet. It becomes necessary as soon as socket code uses the client address.

## Implementation

- Plug: [`lib/converger_web/plugs/trusted_proxies.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/plugs/trusted_proxies.ex), plugged at the top of [`lib/converger_web/endpoint.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/endpoint.ex).
- Matcher: [`lib/converger_web/ip_matcher.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/ip_matcher.ex) (`parse_list/1`, `parse_list_cached/1`, `member?/2`, `parse_address/1`).
- Whitelist: [`lib/converger_web/plugs/admin_auth.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/plugs/admin_auth.ex).
- Rate-limit key: [`lib/converger_web/plugs/rate_limit.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/plugs/rate_limit.ex).
- Config: `trusted_proxies: []` and `admin_ip_whitelist: ["127.0.0.1", "::1"]` in [`config/config.exs`](https://github.com/AimTune/converger/blob/main/config/config.exs); `TRUSTED_PROXIES` and `ADMIN_IP_WHITELIST` (entries trimmed) in [`config/runtime.exs`](https://github.com/AimTune/converger/blob/main/config/runtime.exs).

| Variable | Default | Example |
| --- | --- | --- |
| `TRUSTED_PROXIES` | empty (forwarding headers ignored) | `10.0.0.0/8,fd00::/8` |
| `ADMIN_IP_WHITELIST` | `127.0.0.1,::1` | `10.8.0.0/16,203.0.113.7` |

Example: with `TRUSTED_PROXIES=10.0.0.0/8`, a request from peer `10.0.0.5` carrying `X-Forwarded-For: 6.6.6.6, 198.51.100.7, 10.0.0.9` resolves to `198.51.100.7`. `10.0.0.9` is skipped as trusted, and `6.6.6.6` is never reached because `198.51.100.7` is the first untrusted hop.

Tests: [`test/converger_web/plugs/trusted_proxies_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger_web/plugs/trusted_proxies_test.exs) covers trusted versus untrusted peers, no proxies configured, chained hops with a spoofed left-most entry, a private non-proxy hop, garbage entries, all hops trusted, a missing header, multiple headers, ports and IPv6, integration with `AdminAuth`, and an end-to-end request to `/admin/login` (allowed through a trusted proxy, 403 through an untrusted peer). [`test/converger_web/plugs/admin_auth_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger_web/plugs/admin_auth_test.exs) covers IPv4 and IPv6 CIDR, mixed entries, IPv4-mapped IPv6 and invalid entries.

## Links

- Issue [#11](https://github.com/AimTune/converger/issues/11), pull request [#75](https://github.com/AimTune/converger/pull/75)
- [Security: client IPs, proxies and admin access](../security.md)
- [Deployment and environment variables](../deployment.md)
