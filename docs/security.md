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
