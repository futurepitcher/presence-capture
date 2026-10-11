# Governance

## The pledge

**The core of Presence Capture is Apache-2.0, and stays Apache-2.0.**

The core is:
- the specification (`docs/spec/`);
- the migrations and conformance suite (`packages/schema`);
- the driver protocol;
- the capture daemons (`packages/daemon`, and the Windows daemon to come);
- the MCP server (`packages/mcp`).

Specifically:

- **No relicensing.** The core won't move to a more restrictive licence: not
  source-available, not copyleft, and not a licence that limits use by
  revenue or field.
- **No contributor licence agreement.** Contributions are made under Apache-2.0
  and certified with a sign-off (below). Nobody, including the maintainer, gets
  rights over your contribution that the licence doesn't give everyone.
- **No paid gate on capture, memory or erasure.** Capturing, remembering,
  searching, revoking and proving what was erased are never behind a payment,
  an account or a licence key.

The pledge exists because this category has been burned: tools people built
on were relicensed or shut down. A capture substrate is only worth adopting if
it can't be taken back. Apache-2.0 already guarantees that anyone can fork the
code as it stands. This pledge says the project itself won't try.

## Funding

- **GitHub Sponsors**, from the start.
- **Paid support, from 0.1.0 on**, for builders and teams who want hands-on
  help: priority support, help connecting their own agent stack, and custom
  plugins. It sells time, never features.
- **PresenceOS**, the project's first adopter, covers costs in the meantime.

There is no hosted service, and no plan for one. Anything paid is help, an
add-on or a plugin. Nothing paid is ever part of the core.

## Decisions

| What | How |
|------|-----|
| Day-to-day changes | A pull request, reviewed by a maintainer and passing CI |
| Architecture | An ADR in [`docs/adr/`](docs/adr), merged by a maintainer |
| The specification, the driver protocol, the MCP surface | An [RFC](rfcs/README.md), open for comment for at least 14 days, landing with the conformance tests that enforce it |
| Anything that weakens erasure, privacy levels or the serving trust boundary | An RFC and an ADR, with the reason written down. The tests that hold these lines are changed only alongside them |
| Governance, including this document | An RFC. **The pledge can't be weakened by any process.** |

## Roles

**Maintainers** review and merge, triage issues, cut releases and steward the
spec. Today there's one: [@futurepitcher](https://github.com/futurepitcher).

**Becoming a maintainer.** Sustained, careful work earns it: for example,
several substantive merged pull requests, a conformant implementation, or
steady review and triage. A maintainer nominates. The nomination is open in
Discussions for 7 days, and the existing maintainers decide. Maintainers who
step back move to emeritus and can return.

As soon as there are three maintainers, decisions that would otherwise be the
lead maintainer's alone are taken by lazy consensus among them, falling back
to a majority vote.

## Contributions and sign-off

Every commit carries a [Developer Certificate of Origin](https://developercertificate.org/)
sign-off. By adding it, you certify you have the right to submit the work
under the project's licence:

```sh
git commit -s -m "fix(schema): ..."
```

CI checks that every commit in a pull request is signed off by its author.

## Security and conduct

Vulnerabilities go through private advisories ([SECURITY.md](SECURITY.md)),
never public issues. Conduct is covered by
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
