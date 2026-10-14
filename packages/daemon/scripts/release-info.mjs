#!/usr/bin/env node
/**
 * What a release is, written beside its DMG (release.sh, R3):
 *
 *   Presence-Capture-<version>.cdx.json  a CycloneDX 1.5 SBOM. There are no third-party runtime
 *                                        dependencies, so it lists the app's own programs (with
 *                                        their hashes) and the system libraries and frameworks
 *                                        they link, read from the binaries themselves (otool -L);
 *                                        the toolchain is its tools.
 *   build-info.json                      the source (commit, tag), the runner image, macOS,
 *                                        Xcode and Swift: what it was built from, and with.
 *   notes.md                             the release notes, with the DMG's SHA-256 and how to
 *                                        verify it (docs/verify.md).
 *
 *   node release-info.mjs --version 0.1.0 --app <Presence Capture.app> --dmg <dmg> --out <dir> [--unsigned]
 *
 * No dependencies.
 */

import { execFileSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { basename, join } from 'node:path';

const args = Object.fromEntries(process.argv.slice(2).reduce((pairs, word, i, all) => {
  if (word.startsWith('--')) pairs.push([word.slice(2), all[i + 1]?.startsWith('--') || all[i + 1] === undefined ? true : all[i + 1]]);
  return pairs;
}, []));
for (const name of ['version', 'app', 'dmg', 'out']) if (typeof args[name] !== 'string') throw new Error(`--${name} is required`);

const REPO = 'futurepitcher/presence-capture';
const run = (command, ...rest) => {
  try {
    return execFileSync(command, rest, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch {
    return null;
  }
};
const sha256 = (path) => createHash('sha256').update(readFileSync(path)).digest('hex');

const programs = ['PresenceCapture', 'pcap-mcp', 'pcap'].map((name) => ({ name, path: join(args.app, 'Contents/MacOS', name) }));

/** What a binary links, as `otool -L` says: system frameworks and libraries only. */
const linked = (path) => (run('otool', '-L', path) ?? '').split('\n').slice(1)
  .map((line) => line.trim().split(' (')[0])
  .filter((lib) => lib.startsWith('/System/Library/') || lib.startsWith('/usr/lib/'));

const macos = run('sw_vers', '-productVersion');
const libraries = [...new Set(programs.flatMap((p) => linked(p.path)))].sort();
const library = (path) => {
  const framework = path.match(/\/([^/]+)\.framework\//);
  return {
    type: framework ? 'framework' : 'library',
    'bom-ref': `system:${path}`,
    name: framework ? framework[1] : basename(path),
    version: macos ?? undefined,
    supplier: { name: 'Apple Inc.' },
    description: `Part of macOS, linked from ${path}`,
    scope: 'required',
  };
};

const swift = run('swift', '--version');
const xcode = run('xcodebuild', '-version');
const sbom = {
  bomFormat: 'CycloneDX',
  specVersion: '1.5',
  serialNumber: `urn:uuid:${randomUUID()}`,
  version: 1,
  metadata: {
    timestamp: new Date().toISOString(),
    tools: {
      components: [
        { type: 'application', name: 'release-info.mjs', supplier: { name: 'Presence Capture' } },
        ...(swift ? [{ type: 'application', name: 'Swift', version: swift.split('\n')[0] }] : []),
        ...(xcode ? [{ type: 'application', name: 'Xcode', version: xcode.split('\n').join(' ') }] : []),
      ],
    },
    component: {
      type: 'application',
      'bom-ref': 'presence-capture',
      name: 'Presence Capture',
      version: args.version,
      purl: `pkg:github/${REPO}@v${args.version}`,
      licenses: [{ license: { id: 'Apache-2.0' } }],
      hashes: [{ alg: 'SHA-256', content: sha256(args.dmg) }],
      externalReferences: [{ type: 'vcs', url: `https://github.com/${REPO}` }],
    },
  },
  components: [
    ...programs.map((p) => ({
      type: 'application',
      'bom-ref': `program:${p.name}`,
      name: p.name,
      version: args.version,
      licenses: [{ license: { id: 'Apache-2.0' } }],
      hashes: [{ alg: 'SHA-256', content: sha256(p.path) }],
    })),
    ...libraries.map(library),
  ],
  dependencies: [
    { ref: 'presence-capture', dependsOn: programs.map((p) => `program:${p.name}`) },
    ...programs.map((p) => ({ ref: `program:${p.name}`, dependsOn: linked(p.path).map((l) => `system:${l}`) })),
  ],
};
writeFileSync(join(args.out, `Presence-Capture-${args.version}.cdx.json`), `${JSON.stringify(sbom, null, 2)}\n`);

const env = process.env;
const info = {
  version: args.version,
  signed: !args.unsigned,
  source: {
    repository: env.GITHUB_REPOSITORY ?? REPO,
    commit: env.GITHUB_SHA ?? run('git', '-C', args.app, 'rev-parse', 'HEAD') ?? run('git', 'rev-parse', 'HEAD'),
    ref: env.GITHUB_REF ?? null,
  },
  runner: { image: env.ImageOS ?? null, imageVersion: env.ImageVersion ?? null, runId: env.GITHUB_RUN_ID ?? null },
  macos,
  xcode: xcode?.split('\n') ?? null,
  swift: swift?.split('\n')[0] ?? null,
  node: process.version,
};
writeFileSync(join(args.out, 'build-info.json'), `${JSON.stringify(info, null, 2)}\n`);

const dmg = basename(args.dmg);
writeFileSync(join(args.out, 'notes.md'), `Presence Capture ${args.version} for macOS 14 or later (dictation and hearing need macOS 26).

| File | SHA-256 |
|------|---------|
| \`${dmg}\` | \`${sha256(args.dmg)}\` |

Built in GitHub Actions on a GitHub-hosted runner from \`${info.source.commit ?? 'this tag'}\`, signed with Developer ID and notarized by Apple. To check that this DMG is that build, before you open it:

\`\`\`sh
gh attestation verify ${dmg} -R ${REPO} --signer-workflow ${REPO}/.github/workflows/release.yml --source-ref refs/tags/v${args.version} --deny-self-hosted-runners
shasum -a 256 -c SHA256SUMS
\`\`\`

The SBOM, what it was built with, and the full checks are attached; see [docs/verify.md](https://github.com/${REPO}/blob/main/docs/verify.md).
`);
