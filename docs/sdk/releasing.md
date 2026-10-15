---
title: Releasing the SDKs
description: How every Converger SDK package is released from CI - the registry, the trigger, the workflow and the one-time setup of each, mostly trusted publishing (OIDC) with no stored token.
sidebar_position: 10
---

Every SDK package is released from GitHub Actions. Most registries use **trusted publishing**: the job's GitHub OIDC
token is exchanged for a short-lived publish credential, so no registry token is stored in the repository. Version
0.1.0 was published by hand ([#187](https://github.com/AimTune/converger/issues/187)); 0.1.1 of every package was
released by the workflows below ([#188](https://github.com/AimTune/converger/issues/188)), and so are later versions.

## Packages

| Package | Registry | Trigger | Workflow | Credential |
| --- | --- | --- | --- | --- |
| `@converger/agent`, `create-converger-agent` | npm | manual (`workflow_dispatch`, dry run by default) | `agent-ts-publish.yml` | npm trusted publishing |
| `@converger/client` | npm | tag `client-ts-vX.Y.Z` | `client-ts-publish.yml` | npm trusted publishing |
| `converger-agent` | PyPI | manual (`workflow_dispatch`, `publish` checked) | `agent-sdk-python-release.yml` | PyPI trusted publishing |
| `converger` | PyPI | tag `client-python/vX.Y.Z` | `sdk-python-release.yml` | PyPI trusted publishing |
| `Converger.Agent` | NuGet | manual (`workflow_dispatch`, dry run by default) | `agent-dotnet-publish.yml` | nuget.org trusted publishing (`NuGet/login`) |
| `converger_client` | Hex | tag `client-elixir/vX.Y.Z` | `sdk-elixir-release.yml` | `HEX_API_KEY` secret |
| `converger_agent` | Hex | tag `agent-elixir/vX.Y.Z` | `agent-elixir-release.yml` | `HEX_API_KEY` secret |
| `packages/client-go`, `packages/agent-go` | Go module proxy | tag `packages/client-go/vX.Y.Z` or `packages/agent-go/vX.Y.Z` | `sdk-go-release.yml` | none: the tag is the release |

Every workflow first checks that the version it is asked to release equals the version in the package
(`package.json`, `_version.py`, `<Version>` in the `.csproj`, `@version` in `mix.exs`, `const Version` in Go), then
runs the package's tests, and only then publishes. Each publishing job runs in a GitHub environment (`npm`, `pypi`,
`nuget`, `hex`), created on its first run; give those environments required reviewers if every release should wait
for a maintainer's approval.

## One-time setup

**GitHub environments** (repository Settings → Environments): `npm`, `pypi`, `nuget` and `hex`, each with the
maintainers as required reviewers.

**npm.** On npmjs.com, each package (Settings → Trusted publisher) gets a GitHub Actions publisher: organization
`AimTune`, repository `converger`, environment `npm`, workflow `agent-ts-publish.yml` for `@converger/agent` and
`create-converger-agent`, `client-ts-publish.yml` for `@converger/client`. Trusted publishing needs npm 11.5.1 or
newer, which the workflows install; packages are published with `npm publish` (the npm CLI does the OIDC exchange)
and get provenance automatically.

**PyPI.** On pypi.org, each project (Manage → Publishing → Add a new publisher, GitHub): owner `AimTune`, repository
`converger`, environment `pypi`, workflow `agent-sdk-python-release.yml` for `converger-agent` and
`sdk-python-release.yml` for `converger`.

**NuGet.** On nuget.org, a trusted publishing policy for repository `AimTune/converger` and workflow
`agent-dotnet-publish.yml` (environment `nuget`), and the `NUGET_USER` repository variable with the nuget.org profile
name that owns the policy.

**Hex.** Hex has no trusted publishing. Create a key with the `api:write` permission on hex.pm (Dashboard → Keys) and
store it as the `HEX_API_KEY` secret of the `hex` environment. Both Elixir workflows use it.

**Go.** Nothing: `proxy.golang.org` serves a version as soon as its tag exists, and pkg.go.dev picks it up. The
license file in each module directory lets pkg.go.dev show the documentation.

## Cutting a release

1. Bump the version in the package and add its section to the package's `CHANGELOG.md` (the release notes are
   reviewed in the pull request; see [Changelog and releases](../contributing.md#changelog-and-releases)).
2. Merge the pull request.
3. Start the release from `main`:
   - **Tags:** `git tag -a <tag> -m "<package> <version>" && git push origin <tag>`, for example
     `client-python/v0.2.0` or `packages/agent-go/v0.2.0`. Push tags one at a time: GitHub creates no workflow run
     for any of them when more than three tags are pushed at once.
   - **Manual workflows:** Actions → the workflow → Run workflow, with the version; run it once as a dry run, then
     again with the dry run unchecked.
4. Approve the job in its environment when GitHub asks.

A published version can never be uploaded again on any of these registries; a broken release is fixed with a new
patch version.
