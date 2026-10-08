# Security: client IPs, proxies and admin access

## Client IP behind a reverse proxy

Converger uses the client IP (`conn.remote_ip`) for two things:

- the admin IP whitelist (`ConvergerWeb.Plugs.AdminAuth`), and
- per-IP rate limiting (`ConvergerWeb.Plugs.RateLimit`).

Behind a load balancer or ingress, the TCP peer is the proxy, not the client.
`ConvergerWeb.Plugs.TrustedProxies` runs first in the endpoint and rewrites
`conn.remote_ip` from `X-Forwarded-For`, but **only** when the request arrives
from a proxy you have explicitly trusted:

1. If the TCP peer is not in `TRUSTED_PROXIES`, forwarding headers are ignored.
   Clients that connect directly cannot spoof their address.
2. Otherwise the `X-Forwarded-For` chain is read right to left. Trusted hops
   are skipped and the first untrusted address becomes the client IP. Anything
   the client put further left is never used.
3. An unparsable entry stops the walk; the last trusted hop is used instead.

Private and loopback addresses get no special treatment. If they are not in
`TRUSTED_PROXIES`, they are treated as clients, so admins on a VPN range can
be whitelisted.

The original peer address is kept in `conn.private[:peer_remote_ip]`.

Make sure your proxy **appends** to (or overwrites) `X-Forwarded-For`
instead of passing the client's value through untouched. Most load balancers
(AWS ALB/ELB, GCP LB, nginx with `$proxy_add_x_forwarded_for`, Traefik,
ingress-nginx) append by default.

## Configuration

Both variables are read at runtime (`config/runtime.exs`), so a release does
not need to be rebuilt to change them. Entries are comma-separated and may be
single IPs or CIDR ranges, IPv4 or IPv6.

| Variable | Default | Example |
| --- | --- | --- |
| `TRUSTED_PROXIES` | empty (headers ignored) | `10.0.0.0/8,fd00::/8` |
| `ADMIN_IP_WHITELIST` | `127.0.0.1,::1` | `10.8.0.0/16,203.0.113.7` |

Keep `TRUSTED_PROXIES` as narrow as you can: only the subnets your load
balancer or ingress controller actually connects from. Trusting a range that
untrusted clients can also reach lets those clients pick their own IP.

Invalid entries are logged as warnings and ignored.

## Admin protection in cloud deployments

An IP whitelist works when admins come from a known, stable network. In cloud
deployments that is often not true, and you should add one of these, or use
one instead:

- **VPN-only or private ingress.** Expose `/admin` only through an internal
  load balancer or a private network reached over VPN, Tailscale or
  WireGuard, and whitelist that range. The public ingress should not route
  `/admin` at all.
- **SSO / OIDC at the edge.** Put an identity-aware proxy in front of
  `/admin`, such as oauth2-proxy, Pomerium, Cloudflare Access, Google IAP or
  AWS ALB OIDC authentication. Users have to sign in with your identity
  provider before a request reaches Converger. Add the proxy's addresses to
  `TRUSTED_PROXIES`.
- **mTLS.** Require client certificates for the admin hostname at the ingress
  (for example ingress-nginx `auth-tls-*` annotations or Envoy). Only devices
  with an issued certificate can reach the admin UI.

All of these sit in front of the existing admin login and do not replace it.

## Oban dashboard

The Oban Web dashboard is mounted at `/admin/oban` and goes through the same
pipelines as the rest of `/admin` (IP whitelist and admin session).
`ConvergerWeb.ObanResolver` then maps admin roles to dashboard access:
`super_admin` and `admin` can retry, cancel and delete jobs and pause queues,
and `viewer` gets read-only access.

## HTTPS and forwarded headers

`X-Forwarded-Proto` follows the same rule as `X-Forwarded-For`: it is honoured
only when the TCP peer is in `TRUSTED_PROXIES`. `ConvergerWeb.Plugs.ForceSSL`
uses it to decide whether a request arrived over HTTPS, redirects everything
else to `https://PHX_HOST` and sets HSTS. A client connecting directly cannot
skip the redirect or fake an HTTPS request by sending the header itself. See
[docs/deployment.md](deployment.md#tls-hsts-and-websocket-origins) for the
`FORCE_SSL`, `HSTS_*` and `CHECK_ORIGIN` settings.

## Rotating leaked secrets

Some secrets used to be committed to this repository. They are still in the
git history, which is **not** rewritten, so treat them as public:

| Secret | Where it was | Since |
| --- | --- | --- |
| `SECRET_KEY_BASE` (`hJk3F8xZ...`) | `docker-compose.yml` | commit `8de0819` (2026-02-27) |
| Demo `CLOAK_KEY` (`Y29udmVyZ2Vy...`) | `docker-compose.yml` in PR #79 | proposed only |
| Grafana admin password `admin` | `docker-compose.yml` | initial commit |
| Admin login `admin@converger.local` / `admin123456` | `priv/repo/seeds.exs` | commit `5098e43` |

The release refuses to boot when `SECRET_KEY_BASE` or `CLOAK_KEY` equals one
of the published values (checked by SHA-256 fingerprint in
`config/runtime.exs`). If any deployment ever used them, rotate:

1. **`SECRET_KEY_BASE`**: generate a new one (`mix phx.gen.secret`), put it in
   your secret store and restart all replicas at the same time. Every session
   cookie and every token signed with the old key (admin/portal sessions,
   conversation and channel JWTs issued by Converger) becomes invalid: users
   log in again and clients request new tokens. Anyone who knew the old key
   could forge sessions and tokens, so also review the audit log
   (`/admin/audit_logs`) for unexpected admin activity.
2. **`CLOAK_KEY`** (if the demo key was used): generate a new key, set it as
   `CLOAK_KEY`, move the old key into `CLOAK_RETIRED_KEYS`, deploy, run
   `bin/converger eval "Converger.Release.reencrypt_secrets()"`, then remove the
   retired key. Because the old key was public, also rotate the channel
   secrets themselves (they could have been decrypted from a database copy).
3. **Grafana**: set a strong `GF_SECURITY_ADMIN_PASSWORD`. It only applies to a
   fresh Grafana data directory; on an existing one, change the password in
   Grafana (or `grafana cli admin reset-admin-password`).
4. **Seeded admin**: if an `admin@converger.local` / `admin123456` account
   exists, change its password at `/admin/password` or delete the account and
   create named admin users. New installations no longer get a fixed password
   (see [Initial admin account](deployment.md#initial-admin-account)).

Never commit real secrets: keep them in `.env` (gitignored) for compose and in
your platform's secret store for production.
