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

## Daemon release requirements

Not yet automated — the pipeline needs a Mac and credentials this repository
does not hold.

1. Apple Developer ID Application certificate in the signing keychain.
2. `codesign` with hardened runtime and the capture entitlements.
3. `xcrun notarytool submit --wait`, then `xcrun stapler staple`.
4. Publish the `.dmg` with its SHA-256 in the release notes, so a cautious
   adopter can build from source and compare.

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
