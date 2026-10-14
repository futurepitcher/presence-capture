# Verifying a release

Every Presence Capture release is built in GitHub Actions, on a GitHub-hosted
runner, from a `v*` tag, by [`release.yml`](../.github/workflows/release.yml).
It's signed with Developer ID, notarized by Apple, and attested: GitHub records
which workflow built the DMG, from which commit and tag. You can check all of
that before you open it.

## The attestation

With the [GitHub CLI](https://cli.github.com) (version 2.49 or later), for
release `0.1.0`:

```sh
gh attestation verify Presence-Capture-0.1.0.dmg \
  -R futurepitcher/presence-capture \
  --signer-workflow futurepitcher/presence-capture/.github/workflows/release.yml \
  --source-ref refs/tags/v0.1.0 \
  --deny-self-hosted-runners
```

It passes only for a DMG that:
- this repository's `release.yml` built (`--signer-workflow`), not some other
  workflow, such as CI;
- was built from the `v0.1.0` tag (`--source-ref`), not a dry run or another
  version;
- was built on a GitHub-hosted runner (`--deny-self-hosted-runners`).

To pin the exact commit too, add `--source-digest <commit>`. That's the commit
the release notes and `build-info.json` name, and the one the `v0.1.0` tag
points to.

These checks **must fail**. Trying them is how you know the policy is real:
- a DMG from a dry run, or from a different tag;
- the command above with `--source-ref refs/tags/v0.0.0`;
- the command above with
  `--signer-workflow futurepitcher/presence-capture/.github/workflows/ci.yml`.

## Checksums

The release's `SHA256SUMS` covers the DMG, the SBOM and `build-info.json`:

```sh
shasum -a 256 -c SHA256SUMS
```

The DMG's SHA-256 is also in the release notes, and in the Homebrew cask.

## Apple's checks

```sh
xcrun stapler validate Presence-Capture-0.1.0.dmg
spctl -a -vvv -t install Presence-Capture-0.1.0.dmg   # accepted, source=Notarized Developer ID
```

## What it's made of

- `Presence-Capture-<version>.cdx.json` is a CycloneDX SBOM. Presence Capture
  has no third-party runtime dependencies. The SBOM lists its three programs
  (`PresenceCapture`, `pcap-mcp`, `pcap`) with their hashes, and the macOS
  frameworks and libraries they link.
- `build-info.json` records the commit, the tag, the runner image, and the
  macOS, Xcode and Swift versions it was built with.

Builds are verifiable, not bit-for-bit reproducible.
[building.md](building.md) says why, and how to build it yourself.
