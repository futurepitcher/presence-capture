# Releasing

## What ships

| Artifact | How |
|----------|-----|
| `@presence-capture/schema` | npm, plus the git tag |
| `@presence-capture/mcp` | npm, plus the git tag |
| `presence-capture-daemon` | signed and notarised `.dmg` on GitHub Releases, plus a documented from-source build |

The daemon ships as a notarised binary because a capture daemon that requires a
build toolchain gets effectively no adopters. Both paths ship: the binary for
users, the source build for anyone who wants to verify it.

## Daemon release

Automated: [`release.yml`](.github/workflows/release.yml) and
[`packages/daemon/release.sh`](packages/daemon/release.sh). How it works is
in [docs/building.md](docs/building.md), and how anyone checks the result is
in [docs/verify.md](docs/verify.md).

1. On `main`, at the release candidate, check that CI is green, and that the
   checklist below is done.
2. Tag it: `git tag -a v0.1.0 -m v0.1.0 && git push origin v0.1.0`.
3. Approve the run in the `release` environment. It builds, signs, notarizes,
   staples and attests, then makes a **draft** release with the DMG,
   `SHA256SUMS`, the SBOM, `build-info.json` and the provenance bundle.
4. Check the draft as a user would ([docs/verify.md](docs/verify.md)),
   including the checks that must fail. Then publish it.
5. Update the cask in `futurepitcher/homebrew-tap` (its source is in
   `packaging/homebrew/`) with the version and the DMG's SHA-256.

A **dry run** is `release.yml` dispatched on a `v*` tag other than the
release's (for example `v0.0.0`). It builds, signs, notarizes and attests, and publishes nothing:
its files are a workflow artifact for seven days. Its attestation is the one
the must-fail check in docs/verify.md uses.

The `release` environment holds `APPLE_CERTIFICATE` (a base64 `.p12`),
`APPLE_CERTIFICATE_PASSWORD`, `APPLE_SIGNING_IDENTITY`, `APPLE_ID`,
`APPLE_PASSWORD` (app-specific) and `APPLE_TEAM_ID`.

Accepted obligations that come with shipping a signed binary:

- **An update channel.** Users must be reachable when a vulnerability lands.
  A capture tool with no update path is a liability.
- **A disclosure path that works.** See [SECURITY.md](SECURITY.md).
- **Published checksums.** The point is verifiability, not convenience.

## Version policy

The schema is at `0.x` and may break without a migration path until `1.0.0`;
see the stability statement in [`docs/spec/SCHEMA.md`](docs/spec/SCHEMA.md).
Packages are versioned together while this is a single-maintainer project.

## Pre-release checklist

- [ ] `npm test` green at the workspace root (both conformance suites)
- [ ] `docs/spec/SCHEMA.md` matches the suite — the suite wins on conflict
- [ ] ADR 0001 §7 coverage table in `packages/mcp/README.md` still accurate
- [ ] Threat model published and current
- [ ] No gated, revenue-limited or non-commercial model in the default install
