---
title: "ADR-0007: Attachment storage on S3, GCS and Azure with hand-written Req signing"
sidebar_label: "0007 Attachment storage"
description: Attachments go to a pluggable storage backend (local, S3-compatible, GCS, Azure) signed by small in-house signers over Req, are recorded in an attachments table, and are served only through an authenticated, tenant-scoped endpoint.
---

| | |
| --- | --- |
| **Status** | Accepted |
| **Date** | 2026-10-08 |
| **Issue** | [#7](https://github.com/AimTune/converger/issues/7) |
| **Pull request** | [#80](https://github.com/AimTune/converger/pull/80) |
| **Related** | [ADR-0004](0004-single-canonical-activity-serializer.md), [ADR-0005](0005-separate-client-and-system-changesets.md), [ADR-0013](0013-cluster-wide-rate-limiting-with-hammer-and-pubsub.md), [ADR-0021](0021-ci-quality-gates-and-lf-line-endings.md) |

Clients upload files into a conversation with `POST /api/v1/converger/conversations/:conversation_id/upload`. This ADR records where those files are stored, how Converger talks to cloud object stores, how downloads are authorized, and how file types are validated. The operator reference is [File storage](../storage.md).

## Context and problem statement

`Converger.Uploads.LocalStorage` wrote files to `priv/static/uploads/<tenant>/...` and returned `/uploads/...` URLs. The concrete failures:

- `ConvergerWeb.static_paths/0` is `~w(assets fonts images favicon.ico robots.txt)`, so `Plug.Static` never served `uploads`. **Every `contentUrl` returned by the upload endpoint was a 404.**
- Files lived inside the release directory, so they were lost on redeploy, not shared between nodes and not backed up. A multi-node deployment could not work at all.
- Had the files been served statically, download URLs would have had no tenant authorization: anyone with the path could fetch them.
- The content type came from the client and was never checked, so a client could store HTML or SVG labelled as an image.
- The size limit was hardcoded to 10 MB, while the multipart parser actually capped requests at 8 MB.

## Decision drivers

- Uploaded files must be retrievable, from any node, after redeploys.
- Downloads must be authenticated and tenant scoped.
- Support the object stores operators actually use: AWS S3 and S3-compatible stores (MinIO, Cloudflare R2), Google Cloud Storage and Azure Blob Storage, plus an optional CDN in front.
- Keep the dependency footprint small; the project standard HTTP client is `Req`.
- Every backend must be testable offline (stubbed HTTP) and against emulators in CI.
- Stored bytes must never be executable in a browser context.

## Considered options

For the storage clients:

1. **Hand-written request signing over `Req`** - implement AWS SigV4 (with a GOOG4 flavor for GCS HMAC keys), Azure Shared Key and Service SAS, and CloudFront and Google CDN URL signing in small modules; all backends use `Req`.
2. **Provider SDKs and community clients** - `ex_aws` + `ex_aws_s3` for S3 and MinIO, `goth` + a Google API client for GCS, an Azure blob library.
3. **S3 API only** - support S3-compatible stores and tell GCS and Azure users to use their S3 interoperability layers or a gateway.

For serving downloads:

- **A.** Authenticated endpoint that streams local files and redirects (302) to short-lived signed URLs for cloud backends.
- **B.** Public or long-lived signed URLs returned directly in the activity.
- **C.** Always proxy bytes through Converger.

### Pros and cons of the options

#### Option 1: Hand-written signing over Req

- Good: no new runtime dependencies; `Req` is already used for webhooks and providers, and `Req.Test` stubs work the same for every backend.
- Good: Converger needs a small surface (PUT, GET, DELETE, signed GET, presigned PUT), which is a few hundred lines per provider.
- Good: all backends share one behaviour and receive their configuration as an argument, so there is no global client state.
- Bad: Converger owns security-critical signing code. It must be verified against published test vectors and live emulators, and provider changes (new SAS versions) are on us.
- Bad: features outside the small surface (GCS service-account RSA signing, multipart uploads, CloudFront custom policies) are not available until written.

#### Option 2: SDKs and community clients

- Good: broad feature coverage maintained by others.
- Bad: three or more dependency trees with their own HTTP clients and JSON/XML parsers (for example `ex_aws` defaults to `hackney` and needs `sweet_xml`), against the project rule of using `Req`.
- Bad: uneven maintenance and test seams across providers; stubbing differs per library.

#### Option 3: S3 API only

- Good: one signer.
- Bad: Azure Blob Storage has no native S3 API, and GCS interoperability still needs HMAC keys and its own signing flavor, so "S3 only" either excludes Azure or pushes a gateway onto operators.

**Serving: A (authenticated endpoint plus redirect)** keeps authorization in Converger and lets the provider or CDN carry the bytes. **B** leaks access to anyone who sees a message. **C** makes Converger a file proxy for every download, which costs bandwidth and memory on the hub.

## Decision

Chosen options: **"Hand-written request signing over Req"** (option 1) and **"authenticated endpoint plus redirect"** (A).

Why hand-written signing: the needed API surface is small and stable, `Req` is the project's HTTP client, and owning the signers gives one uniform, testable implementation across four providers and two CDNs without pulling in several SDK dependency trees. The risk of owning crypto code is handled with test vectors (the AWS published S3 SigV4 examples and the `get-vanilla` case, the documented Azure Shared Key and SAS 2020-12-06 string-to-sign layouts, CloudFront signatures verified against generated RSA keys) and with live MinIO and Azurite tests in CI.

The design:

- **Behaviour** `Converger.Uploads.Storage`: `put/4`, `get/2`, `delete/2`, `signed_get_url/3` (expiry plus response content-type and content-disposition overrides), `presigned_put_url/3`, and optional `local_path/2`. Every callback takes the backend config first.
- **Backends**:

| Backend | Auth | Signed GET | Presigned PUT |
| --- | --- | --- | --- |
| `S3Storage` (AWS S3, MinIO, R2) | AWS SigV4; `endpoint`, `region`, `path_style`, `session_token` | yes | yes |
| `GCSStorage` | XML API with HMAC keys, `GOOG4-HMAC-SHA256` (same signer, Google flavor). Service-account RSA signing is not implemented. | yes | yes |
| `AzureBlobStorage` | Shared Key for PUT, GET, DELETE | yes, Service SAS (`sv=2020-12-06`) | yes, SAS `sp=cw` |
| `LocalStorage` (dev, single node) | file system under `priv/uploads` by default, not served statically | streamed by the controller | no |

- **CDN layer** `Converger.Uploads.CDN` (`cdn:` config): CloudFront canned-policy signed URLs, Google Cloud CDN signed URLs, or `:plain` unsigned base URLs (Cloudflare in front of R2, Azure CDN or Front Door). With `sign_origin: true`, the backend's SAS query string is appended to the plain CDN URL. When a CDN is configured it takes precedence over the storage URL.
- **Attachments table**: `id`, `tenant_id`, `conversation_id`, `activity_id` (nullable, nilified on activity delete), `storage_key` (unique, `<tenant_id>/<attachment_id>`), `content_type`, `size`, `sha256`, `filename`. The upload controller records the attachment, creates the activity, then links them; if the activity cannot be created, it deletes the stored file.
- **Download endpoint** `GET /api/v1/converger/attachments/:id` requires a converger token. Another tenant's attachment, or another conversation's when the token is conversation-bound, is **404**. Local files are streamed with the sniffed type, `X-Content-Type-Options: nosniff`, `Content-Security-Policy: default-src 'none'; sandbox` and a `Content-Disposition`. Cloud backends answer **302** to a signed URL that expires after `signed_url_ttl` (300 s by default), with `Cache-Control: private, no-store` on the redirect.
- **Validation**: `MimeSniffer` detects the type from magic bytes and ignores the client's declared type. Valid UTF-8 that matches no signature is `text/plain`, so SVG and HTML are served as plain text. A global allowlist (`allowed_content_types`) with an optional per-tenant override (`tenants.allowed_upload_types`) rejects other types with **415**. `max_file_size` (default 10 MB) rejects oversize uploads with **413**, and `ConvergerWeb.MultipartParser` takes its request limit from it at runtime.

## Consequences

### Positive

- `contentUrl` resolves: 200 in dev (local streaming) and 302 to a working signed URL with cloud backends.
- Files survive redeploys and are shared across nodes when a cloud backend is used.
- Downloads are authenticated and tenant isolated; redirects are short-lived.
- Stored content cannot run as script in the browser, regardless of what the client claimed.
- No new runtime dependencies; one test approach for all providers.

### Negative and trade-offs

- Converger maintains its own SigV4, Azure and CDN signers. GCS signing and CloudFront/Google CDN signing are verified only with unit tests and stubs, not against the real services.
- Download URLs need an `Authorization` header, so a browser `<img>` tag cannot load them directly; clients must fetch them with the token.
- `LocalStorage` is not multi-node safe. For a release, `UPLOAD_DIR` must point at a persistent shared volume, or a cloud backend must be used.
- Buckets and containers must already exist and should be private; Converger does not create them.
- The `:plain` CDN mode makes files public to anyone holding the URL; keys are unguessable but not secret once shared.
- Not supported: CloudFront custom policies and signed cookies, Cloud CDN signed cookies and prefix signatures, Cloudflare token auth, Front Door token auth.

### Follow-ups

- Public direct-to-storage upload flow (reserve, presigned PUT, finalize and verify): backends and `Uploads.presigned_put_url/2` exist, but bytes uploaded that way would skip MIME sniffing, so a finalize step is required first. Not yet tracked by its own issue.
- No image dimension limits yet.
- Short-lived signed application URLs so browsers can load attachments without a header.
- Inbound media download from WhatsApp into the attachments table: [#37](https://github.com/AimTune/converger/issues/37).
- Retention and archival to object storage: [#30](https://github.com/AimTune/converger/issues/30).
- Typed attachment schema in the activity model: [#28](https://github.com/AimTune/converger/issues/28).

## Implementation

- Context: [`Converger.Uploads`](https://github.com/AimTune/converger/blob/main/lib/converger/uploads.ex) (`create_attachment/3`, `link_activity/2`, `get_attachment/2`, `download/1`, `presigned_put_url/2`, `delete_attachment/1`, default allowlist) and schema [`Converger.Uploads.Attachment`](https://github.com/AimTune/converger/blob/main/lib/converger/uploads/attachment.ex).
- Behaviour and backends: [`Storage`](https://github.com/AimTune/converger/blob/main/lib/converger/uploads/storage.ex), [`S3Storage`](https://github.com/AimTune/converger/blob/main/lib/converger/uploads/s3_storage.ex), [`GCSStorage`](https://github.com/AimTune/converger/blob/main/lib/converger/uploads/gcs_storage.ex), shared XML API [`S3Compatible`](https://github.com/AimTune/converger/blob/main/lib/converger/uploads/s3_compatible.ex), [`AzureBlobStorage`](https://github.com/AimTune/converger/blob/main/lib/converger/uploads/azure_blob_storage.ex), [`LocalStorage`](https://github.com/AimTune/converger/blob/main/lib/converger/uploads/local_storage.ex).
- Signers: [`Signers.SigV4`](https://github.com/AimTune/converger/blob/main/lib/converger/uploads/signers/sigv4.ex), [`Signers.Azure`](https://github.com/AimTune/converger/blob/main/lib/converger/uploads/signers/azure.ex), [`Signers.CDN`](https://github.com/AimTune/converger/blob/main/lib/converger/uploads/signers/cdn.ex); CDN URL builder [`Converger.Uploads.CDN`](https://github.com/AimTune/converger/blob/main/lib/converger/uploads/cdn.ex).
- Validation: [`Converger.Uploads.MimeSniffer`](https://github.com/AimTune/converger/blob/main/lib/converger/uploads/mime_sniffer.ex), [`ConvergerWeb.MultipartParser`](https://github.com/AimTune/converger/blob/main/lib/converger_web/multipart_parser.ex).
- Web: [`ConvergerWeb.ConvergerAPI.UploadController`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/converger/upload_controller.ex) (also rate limited with the `:upload` bucket, see [ADR-0013](0013-cluster-wide-rate-limiting-with-hammer-and-pubsub.md)) and [`ConvergerWeb.ConvergerAPI.AttachmentController`](https://github.com/AimTune/converger/blob/main/lib/converger_web/controllers/converger/attachment_controller.ex); routes in [`router.ex`](https://github.com/AimTune/converger/blob/main/lib/converger_web/router.ex).
- Migration [`20261008130000_create_attachments.exs`](https://github.com/AimTune/converger/blob/main/priv/repo/migrations/20261008130000_create_attachments.exs): the `attachments` table and `tenants.allowed_upload_types`.
- Configuration: defaults in [`config/config.exs`](https://github.com/AimTune/converger/blob/main/config/config.exs) (`config :converger, Converger.Uploads`, local storage in `priv/uploads`, 10 MB, 300 s TTL, no CDN). [`config/runtime.exs`](https://github.com/AimTune/converger/blob/main/config/runtime.exs) applies only when `UPLOAD_STORAGE` is set (never in test) and reads:

| Variable | Purpose |
| --- | --- |
| `UPLOAD_STORAGE` | `local`, `s3`, `minio`, `r2`, `gcs` or `azure` |
| `UPLOAD_DIR` | local backend directory |
| `S3_BUCKET`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_SESSION_TOKEN`, `S3_REGION`, `S3_ENDPOINT`, `S3_PATH_STYLE` | S3-compatible backends (path style defaults to true for `minio` and `r2`) |
| `GCS_BUCKET`, `GCS_HMAC_ACCESS_ID`, `GCS_HMAC_SECRET`, `GCS_ENDPOINT` | GCS with HMAC keys |
| `AZURE_STORAGE_ACCOUNT`, `AZURE_STORAGE_KEY`, `AZURE_STORAGE_CONTAINER`, `AZURE_STORAGE_ENDPOINT` | Azure Blob Storage |
| `UPLOAD_MAX_BYTES`, `UPLOAD_ALLOWED_TYPES`, `UPLOAD_SIGNED_URL_TTL` | limits, comma-separated allowlist, signed URL lifetime |
| `CDN_TYPE`, `CDN_BASE_URL`, `CDN_PATH_PREFIX`, `CDN_SIGN_ORIGIN` | CDN (`cloudfront`, `google_cdn`, `plain`) |
| `CLOUDFRONT_KEY_PAIR_ID`, `CLOUDFRONT_PRIVATE_KEY`, `CLOUDFRONT_PRIVATE_KEY_FILE` | CloudFront signing |
| `GOOGLE_CDN_KEY_NAME`, `GOOGLE_CDN_KEY` | Google Cloud CDN signing |

Tests in [`test/converger/uploads/`](https://github.com/AimTune/converger/tree/main/test/converger/uploads): signer vectors (`sigv4_test.exs`, `azure_signer_test.exs`, `cdn_test.exs`), `mime_sniffer_test.exs`, `Req.Test`-stubbed backends (`storage_backends_test.exs`, including path traversal for local storage), and live MinIO and Azurite tests (`storage_integration_test.exs`, tagged `:minio` and `:azurite`, excluded by default). The controller flow (upload then fetch, cross-tenant 404, conversation-scoped tokens, 415 for a spoofed `.png`, 413, 302 to S3, CDN precedence) is in [`test/converger_web/controllers/attachment_controller_test.exs`](https://github.com/AimTune/converger/blob/main/test/converger_web/controllers/attachment_controller_test.exs). The `storage-integration` job in [`.github/workflows/ci.yml`](https://github.com/AimTune/converger/blob/main/.github/workflows/ci.yml) runs the live tests with `bitnamilegacy/minio` and Azurite service containers (the upstream `minio/minio` image is no longer pullable from Docker Hub).

## Links

- Issue [#7](https://github.com/AimTune/converger/issues/7), pull request [#80](https://github.com/AimTune/converger/pull/80)
- Operator reference: [File storage](../storage.md)
- [AWS Signature Version 4](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_sigv.html), [Azure Shared Key authorization](https://learn.microsoft.com/en-us/rest/api/storageservices/authorize-with-shared-key), [Azure Service SAS](https://learn.microsoft.com/en-us/rest/api/storageservices/create-service-sas)
