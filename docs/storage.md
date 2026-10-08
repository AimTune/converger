---
sidebar_label: File storage
description: Attachment uploads, validation, the authenticated download endpoint, and the local, S3, GCS and Azure storage backends with optional CDN.
---

# File storage and attachments

Files uploaded with `POST /api/v1/converger/conversations/:id/upload` are
validated, written to a pluggable storage backend and recorded in the
`attachments` table. The activity's `contentUrl` always points at the
authenticated download endpoint:

```
GET /api/v1/converger/attachments/:id
Authorization: Bearer <converger token>
```

- The endpoint is tenant scoped. An attachment that belongs to another tenant
  returns **404**. So does an attachment from another conversation when the
  token is bound to a conversation.
- **Local storage**: the file is streamed with its sniffed `Content-Type`,
  `X-Content-Type-Options: nosniff`, a sandboxing CSP and a
  `Content-Disposition` header (`inline` for images, audio, video and PDF,
  `attachment` for everything else).
- **Cloud storage**: the endpoint answers **302** to a short-lived signed URL
  (`signed_url_ttl`, 300 s by default). If a CDN is configured, the redirect
  points at the CDN URL instead.

Nothing is served from `priv/static` any more.

## Validation

| Check | Behaviour |
| --- | --- |
| Size | `max_file_size` bytes (default 10 MB). Larger uploads get **413**. The multipart parser limit follows this value at runtime (plus 1 MB for form fields). |
| Type | Detected from magic bytes (`Converger.Uploads.MimeSniffer`). The client's declared type is ignored. |
| Allowlist | `tenants.allowed_upload_types` (text array) when set, otherwise `allowed_content_types`. Disallowed types get **415**. |

Types the sniffer recognises: `image/png`, `image/jpeg`, `image/gif`,
`image/webp`, `image/bmp`, `application/pdf`, `video/mp4`, `video/quicktime`,
`video/3gpp`, `video/webm`, `audio/mpeg`, `audio/aac`, `audio/ogg`,
`audio/mp4`, `audio/wav`, `application/zip`, and docx/xlsx/pptx. Any other
valid UTF-8 without NUL bytes is `text/plain`. Everything else is
`application/octet-stream`. SVG and HTML are therefore stored and served as
`text/plain`, so they can't run scripts.

Default allowlist: png, jpeg, gif, webp, pdf, mp4, webm, quicktime, mpeg,
ogg, mp4 audio, aac, wav, text/plain, docx, xlsx, pptx. `application/zip` and
`application/octet-stream` are not allowed by default.

Each attachment row stores `tenant_id`, `conversation_id`, `activity_id`
(nullable, set once the activity is created), `storage_key`
(`<tenant_id>/<attachment_id>`), `content_type`, `size`, `sha256` and
`filename`.

## Configuration

```elixir
config :converger, Converger.Uploads,
  storage: Converger.Uploads.LocalStorage,   # backend module
  storage_opts: [dir: "priv/uploads"],       # passed to the backend
  max_file_size: 10 * 1024 * 1024,
  allowed_content_types: nil,                # nil = built-in default list
  signed_url_ttl: 300,                       # seconds
  cdn: nil                                   # see "CDN" below
```

In releases, `config/runtime.exs` builds this from environment variables when
`UPLOAD_STORAGE` is set. It never does this in the test environment.

| Variable | Meaning |
| --- | --- |
| `UPLOAD_STORAGE` | `local`, `s3`, `minio`, `r2`, `gcs` or `azure` |
| `UPLOAD_MAX_BYTES` | max upload size in bytes (default 10485760) |
| `UPLOAD_ALLOWED_TYPES` | comma separated MIME allowlist (default: built-in list) |
| `UPLOAD_SIGNED_URL_TTL` | signed URL lifetime in seconds (default 300) |

### Local disk: `Converger.Uploads.LocalStorage`

Intended for development and single-node deployments. Files are written below
`dir`, which defaults to `priv/uploads` (git-ignored, **not** served
statically). On a release, point it at a persistent volume, because files
inside the release directory are lost on redeploy and are not shared between
nodes.

| Option | Env | Default |
| --- | --- | --- |
| `dir` | `UPLOAD_DIR` | `priv/uploads` |

### Amazon S3 / MinIO / Cloudflare R2: `Converger.Uploads.S3Storage`

Uses `Req` and a hand-written AWS Signature V4 implementation
(`Converger.Uploads.Signers.SigV4`). Supported operations: PUT, GET, DELETE,
presigned GET (with `response-content-type` / `response-content-disposition`
overrides) and presigned PUT.

| Option | Env | Notes |
| --- | --- | --- |
| `bucket` | `S3_BUCKET` | required |
| `access_key_id` | `S3_ACCESS_KEY_ID` | required |
| `secret_access_key` | `S3_SECRET_ACCESS_KEY` | required |
| `session_token` | `S3_SESSION_TOKEN` | optional (STS) |
| `region` | `S3_REGION` | default `us-east-1`; use `auto` for R2 |
| `endpoint` | `S3_ENDPOINT` | default `https://s3.<region>.amazonaws.com` |
| `path_style` | `S3_PATH_STYLE` | `false` for `s3`, `true` for `minio`/`r2` |

Examples:

- MinIO: `UPLOAD_STORAGE=minio S3_ENDPOINT=http://minio:9000 S3_BUCKET=converger`
- R2: `UPLOAD_STORAGE=r2 S3_ENDPOINT=https://<account_id>.r2.cloudflarestorage.com S3_REGION=auto`

The bucket must already exist and should be private.

### Google Cloud Storage: `Converger.Uploads.GCSStorage`

Uses the GCS **XML API with HMAC keys**. Requests are signed with
`GOOG4-HMAC-SHA256`, the SigV4-compatible scheme, with the same signer as S3.
Create a key with `gcloud storage hmac create SERVICE_ACCOUNT_EMAIL`. Signing
with a service-account RSA key (JSON key file) is **not** implemented.

| Option | Env | Notes |
| --- | --- | --- |
| `bucket` | `GCS_BUCKET` | required |
| `access_key_id` | `GCS_HMAC_ACCESS_ID` | required |
| `secret_access_key` | `GCS_HMAC_SECRET` | required |
| `endpoint` | `GCS_ENDPOINT` | default `https://storage.googleapis.com` |
| `region` | none | credential scope location, default `auto` |

### Azure Blob Storage: `Converger.Uploads.AzureBlobStorage`

PUT, GET and DELETE use **Shared Key** authorization. Signed GET URLs are
**Service SAS** tokens (`sp=r`, `sv=2020-12-06`, with `rsct`/`rscd`
overrides). Presigned uploads are SAS tokens with `sp=cw`, and the client must
send `x-ms-blob-type: BlockBlob`.

| Option | Env | Notes |
| --- | --- | --- |
| `account` | `AZURE_STORAGE_ACCOUNT` | required |
| `account_key` | `AZURE_STORAGE_KEY` | base64 account key, required |
| `container` | `AZURE_STORAGE_CONTAINER` | required, private |
| `endpoint` | `AZURE_STORAGE_ENDPOINT` | default `https://<account>.blob.core.windows.net`; Azurite: `http://127.0.0.1:10000/devstoreaccount1` |

## CDN

A CDN layer (`Converger.Uploads.CDN`) can sit in front of any backend. When
it is configured, downloads redirect to the CDN URL
`<base_url>/<path_prefix>/<storage_key>` instead of the storage URL.

```elixir
cdn: [type: :cloudfront | :google_cdn | :plain, base_url: "https://...", path_prefix: "", ...]
```

| Env | Meaning |
| --- | --- |
| `CDN_TYPE` | `cloudfront`, `google_cdn` or `plain` |
| `CDN_BASE_URL` | CDN origin, e.g. `https://d111111abcdef8.cloudfront.net` |
| `CDN_PATH_PREFIX` | optional prefix prepended to the key |

### Supported providers

| Provider | Type | Signed URLs | Notes |
| --- | --- | --- | --- |
| Amazon CloudFront | `:cloudfront` | yes, canned policy (RSA-SHA1) | `key_pair_id` / `CLOUDFRONT_KEY_PAIR_ID`, `private_key` / `CLOUDFRONT_PRIVATE_KEY` (PEM) or `CLOUDFRONT_PRIVATE_KEY_FILE`. Works with both key groups (public key ID) and legacy key pairs. Use OAC/OAI so the bucket stays private. |
| Google Cloud CDN | `:google_cdn` | yes (HMAC-SHA1) | `key_name` / `GOOGLE_CDN_KEY_NAME`, `key` / `GOOGLE_CDN_KEY` (base64url, from `gcloud compute backend-buckets add-signed-url-key`). |
| Cloudflare (R2 public bucket / custom domain, or a proxied origin) | `:plain` | no | Unsigned URLs. Only use this with content you accept as public-by-URL. Keys are unguessable UUIDs, but anyone with the link can download. |
| Azure CDN / Azure Front Door | `:plain` | via origin SAS | Set `sign_origin: true` (`CDN_SIGN_ORIGIN=true`) to append the backend's SAS query string to the CDN URL. The CDN must forward query strings to the origin and cache per query string. |
| Any other CDN | `:plain` | no | Unsigned `base_url/key` URLs. |

Not supported: CloudFront custom policies (IP or start-time conditions) and
signed cookies, Google Cloud CDN signed cookies and URL-prefix signatures,
Cloudflare signed URL tokens (Workers / WAF HMAC), and Azure Front Door token
authentication.

## Large files and presigned uploads

All cloud backends implement `presigned_put_url/3`, and
`Converger.Uploads.presigned_put_url/2` exposes it. Bytes uploaded directly to
storage skip server-side MIME sniffing, so a public HTTP flow for direct
uploads (reserve, upload, then finalize and verify) is not part of the API
yet.

## Testing

- Unit tests cover each signer against known vectors: the published AWS SigV4
  S3 examples, the documented Azure Shared Key and SAS string-to-sign layouts,
  CloudFront signature verification with a generated RSA key, and the Google
  CDN HMAC. Backends are tested with `Req.Test` stubs.
- Live tests against MinIO and Azurite are tagged `:minio` and `:azurite` and
  are excluded by default:

  ```sh
  docker run -d -p 9000:9000 -e MINIO_ROOT_USER=minioadmin -e MINIO_ROOT_PASSWORD=minioadmin bitnamilegacy/minio
  docker run -d -p 10000:10000 mcr.microsoft.com/azure-storage/azurite azurite-blob --blobHost 0.0.0.0
  mix test --only minio --only azurite
  ```

  `MINIO_ENDPOINT`, `MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY` and
  `AZURITE_ENDPOINT` override the defaults. CI runs these tests in the
  `storage-integration` job (`.github/workflows/ci.yml`).
