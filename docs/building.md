# Building Presence Capture

## From source

You need macOS 14 or later, and Xcode 26 or later for its Swift toolchain.
Hearing and dictation need macOS 26 to run. Releases are built for Apple
silicon only, since the release runner is arm64 and an Intel slice would ship
untested. On an Intel Mac, build from source: everything here runs there,
except what needs Apple Intelligence (Tidy What I Say).

```sh
git clone https://github.com/futurepitcher/presence-capture
cd presence-capture
packages/daemon/build.sh            # → packages/daemon/.build/app/Presence Capture.app
```

You don't need to notarize anything to run what you built. Notarization is for
software downloaded from the internet.

Signing does matter, though, for two things macOS ties to a program's
signature:
- **permissions** (Screen Recording, Microphone, Accessibility, Input
  Monitoring);
- **Keychain trust**: the store's key is shared with `pcap-mcp` and `pcap` by
  their signatures.

`build.sh` signs with an **Apple Development** certificate if your keychain has
one. A free Apple ID gives you one through Xcode (Settings → Accounts →
Manage Certificates). Rebuilds then keep their permissions and Keychain
trust. Without one, the build is signed ad hoc, and macOS asks for the
permissions again after every rebuild.

To sign with a particular identity, set `PRESENCE_CAPTURE_SIGN_IDENTITY` to its
SHA-1 hash, or to `-` for ad hoc. To give the build a version, set
`PRESENCE_CAPTURE_VERSION`.

The tests:

```sh
npm ci && npm test                       # the reference and both conformance suites
(cd packages/daemon && swift test)       # the Swift implementation
```

## A release

Releases are made only by
[`release.yml`](../.github/workflows/release.yml), from a `v*` tag, on a
GitHub-hosted runner, in the protected `release` environment. That
environment holds the Apple credentials and asks the maintainer to approve
each run. [`release.sh`](../packages/daemon/release.sh) does the work:
1. builds the app, with `pcap-mcp` and `pcap` inside it;
2. signs it inside-out with Developer ID and the hardened runtime;
3. makes the DMG, signs it, notarizes it and staples it;
4. writes the SBOM, `build-info.json`, the notes and `SHA256SUMS`.

The certificate goes into a keychain made for that run and deleted at its end,
with the keychain search list put back as it was.

`release.sh <version> <dir> --unsigned` makes the same DMG, SBOM and sums with
no credentials. It's signed ad hoc and not notarized, which makes it a check
of the packaging, never a release.

The maintainer's steps are in [RELEASING.md](../RELEASING.md).

## Verifiable, not reproducible

A release isn't promised to be bit-for-bit reproducible in 0.1. What's
recorded instead lets anyone check what they have, and compare it with what
they build:
- the commit and tag it was built from;
- the runner image;
- the exact macOS, Xcode and Swift versions (`build-info.json`);
- checksums;
- a provenance attestation ([verify.md](verify.md)).

What stands in the way of bit-for-bit builds:
- **Signatures and notarization tickets** include timestamps and Apple's own
  signatures. Two builds of the same source differ there, by design.
- **The DMG** (HFS+, compressed by `hdiutil`) records creation times.
- **Swift builds** can embed paths and vary between toolchain builds.

A future release may strip and compare the unsigned Mach-O bodies of the three
programs between a release and a source build. That's the meaningful
comparison for this kind of app, and it's left for after 0.1.
