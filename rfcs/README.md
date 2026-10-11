# RFCs

A change to anything another implementation depends on goes through an RFC:
- the specification (`docs/spec/SCHEMA.md`);
- the driver protocol (`docs/spec/DRIVER.md`);
- the MCP tool surface;
- the shared cases (`packages/schema/cases/`);
- governance.

Bug fixes, tests that tighten an existing requirement, and documentation don't
need one.

## Process

1. Copy `0000-template.md` to `0000-short-name.md` and open a pull request.
   The PR number becomes the RFC number.
2. The RFC is open for comment for **at least 14 days**. Announce it in
   Discussions.
3. A maintainer accepts, declines or asks for changes, with the reason written
   in the PR.
4. An accepted RFC lands **with the conformance tests that enforce it**. A
   spec change without a test is incomplete, because the suite, not the
   prose, defines conformance.

## Versioning

The spec and the driver protocol carry their own versions. While at `0.x`, a
spec change may break without a migration path. From `1.0.0`, the event shape
and revocation semantics are backward compatible, and a breaking change needs
a new major version. Adding an optional field or op is a minor change.

## Index

None yet.
