#!/usr/bin/env bash
# Builds Presence Capture <version> for release: the app, with pcap-mcp and pcap inside it, signed
# inside-out with Developer ID and the hardened runtime; a signed DMG, notarized and stapled; and
# beside it, SHA256SUMS, a CycloneDX SBOM, what it was built with (build-info.json) and the release
# notes. Every credential comes from the environment, so it runs the same in GitHub Actions
# (.github/workflows/release.yml) and, if ever needed, on a Mac:
#
#   APPLE_CERTIFICATE           the Developer ID Application certificate and key: a .p12, base64
#   APPLE_CERTIFICATE_PASSWORD  its password
#   APPLE_SIGNING_IDENTITY      "Developer ID Application: <name> (<team>)"
#   APPLE_ID, APPLE_PASSWORD, APPLE_TEAM_ID   for notarytool (APPLE_PASSWORD is app-specific)
#
# The certificate goes into a keychain of its own, made for this run and deleted when it ends,
# with the search list put back as it was: nothing is left behind on the Mac it ran on.
#
# Usage: packages/daemon/release.sh <version> [out-dir] [--unsigned]
#   out-dir defaults to packages/daemon/.build/release
#   --unsigned: the same DMG, SBOM and sums, signed ad hoc and not notarized, with no credentials:
#   a check of the packaging, never a release.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="${1:?usage: release.sh <version> [out-dir] [--unsigned]}"
OUT_DIR="${2:-${SCRIPT_DIR}/.build/release}"
UNSIGNED=false
for arg in "$@"; do [[ "${arg}" == "--unsigned" ]] && UNSIGNED=true; done
[[ "${OUT_DIR}" == "--unsigned" ]] && OUT_DIR="${SCRIPT_DIR}/.build/release"
[[ "${VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "release.sh: the version is three numbers, as 0.1.0" >&2; exit 2; }

DMG_NAME="Presence-Capture-${VERSION}.dmg"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/presence-capture-release.XXXXXX")"
KEYCHAIN=""
ORIGINAL_KEYCHAINS=()

cleanup() {
  if [[ -n "${KEYCHAIN}" ]]; then
    if (( ${#ORIGINAL_KEYCHAINS[@]} )); then security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" || true; fi
    security delete-keychain "${KEYCHAIN}" || true
  fi
  rm -rf "${WORK}"
}
trap cleanup EXIT

if [[ "${UNSIGNED}" == false ]]; then
  for name in APPLE_CERTIFICATE APPLE_CERTIFICATE_PASSWORD APPLE_SIGNING_IDENTITY APPLE_ID APPLE_PASSWORD APPLE_TEAM_ID; do
    [[ -n "${!name:-}" ]] || { echo "release.sh: ${name} isn't set (or pass --unsigned to check the packaging)" >&2; exit 2; }
  done
fi

mkdir -p "${OUT_DIR}"
rm -f "${OUT_DIR}/${DMG_NAME}" "${OUT_DIR}/SHA256SUMS"

# The Apple credentials, kept from every step that doesn't need them (the build, the SBOM).
APPLE_VARIABLES=(-u APPLE_CERTIFICATE -u APPLE_CERTIFICATE_PASSWORD -u APPLE_SIGNING_IDENTITY -u APPLE_ID -u APPLE_PASSWORD -u APPLE_TEAM_ID)

# 1. Build: the bundle as build.sh makes it, signed ad hoc for now.
env "${APPLE_VARIABLES[@]}" PRESENCE_CAPTURE_VERSION="${VERSION}" PRESENCE_CAPTURE_SIGN_IDENTITY=- "${SCRIPT_DIR}/build.sh" "${WORK}/app" >/dev/null
APP="${WORK}/app/Presence Capture.app"

if [[ "${UNSIGNED}" == false ]]; then
  # 2. The certificate, in a keychain made for this run.
  KEYCHAIN="${WORK}/signing.keychain-db"
  KEYCHAIN_PASSWORD="$(openssl rand -hex 24)"
  [[ -n "${GITHUB_ACTIONS:-}" ]] && echo "::add-mask::${KEYCHAIN_PASSWORD}"
  security create-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN}"
  security set-keychain-settings -lut 3600 "${KEYCHAIN}"
  security unlock-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN}"
  printf '%s' "${APPLE_CERTIFICATE}" | base64 --decode > "${WORK}/certificate.p12"
  security import "${WORK}/certificate.p12" -k "${KEYCHAIN}" -P "${APPLE_CERTIFICATE_PASSWORD}" -f pkcs12 -T /usr/bin/codesign >/dev/null
  rm -f "${WORK}/certificate.p12"
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "${KEYCHAIN_PASSWORD}" "${KEYCHAIN}" >/dev/null
  # On the search list for this run only (codesign looks there for the certificate's chain); put
  # back as it was by cleanup.
  while IFS= read -r line; do
    ORIGINAL_KEYCHAINS+=("$(printf '%s' "${line}" | sed -E 's/^[[:space:]]*"(.*)"[[:space:]]*$/\1/')")
  done < <(security list-keychains -d user)
  security list-keychains -d user -s "${KEYCHAIN}" ${ORIGINAL_KEYCHAINS[@]+"${ORIGINAL_KEYCHAINS[@]}"}

  # 3. Inside-out: the readers, then the app with its entitlements. Hardened runtime, timestamped.
  sign() { codesign --force --timestamp --options runtime --keychain "${KEYCHAIN}" --sign "${APPLE_SIGNING_IDENTITY}" "$@"; }
  sign "${APP}/Contents/MacOS/pcap-mcp"
  sign "${APP}/Contents/MacOS/pcap"
  sign --entitlements "${SCRIPT_DIR}/PresenceCapture.entitlements" "${APP}"
  codesign --verify --strict --deep --verbose=2 "${APP}"
fi

# 4. The DMG: the app, and a link to Applications to drag it to.
mkdir -p "${WORK}/dmg"
cp -R "${APP}" "${WORK}/dmg/"
ln -s /Applications "${WORK}/dmg/Applications"
hdiutil create -volname "Presence Capture" -srcfolder "${WORK}/dmg" -fs HFS+ -format UDZO -ov "${OUT_DIR}/${DMG_NAME}" >/dev/null

if [[ "${UNSIGNED}" == false ]]; then
  codesign --force --timestamp --keychain "${KEYCHAIN}" --sign "${APPLE_SIGNING_IDENTITY}" "${OUT_DIR}/${DMG_NAME}"

  # 5. Notarized, then stapled, then checked as macOS will check it.
  xcrun notarytool submit "${OUT_DIR}/${DMG_NAME}" --apple-id "${APPLE_ID}" --password "${APPLE_PASSWORD}" --team-id "${APPLE_TEAM_ID}" \
    --wait --output-format json > "${WORK}/notary.json"
  STATUS="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).status)' "${WORK}/notary.json")"
  if [[ "${STATUS}" != "Accepted" ]]; then
    SUBMISSION="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).id)' "${WORK}/notary.json")"
    xcrun notarytool log "${SUBMISSION}" --apple-id "${APPLE_ID}" --password "${APPLE_PASSWORD}" --team-id "${APPLE_TEAM_ID}" >&2 || true
    echo "release.sh: notarization was ${STATUS}" >&2
    exit 1
  fi
  xcrun stapler staple "${OUT_DIR}/${DMG_NAME}"
  xcrun stapler validate "${OUT_DIR}/${DMG_NAME}"
  # Apple's assessment for a disk image (TN2206): the DMG's own signature, as when it's opened.
  spctl -a -vvv -t open --context context:primary-signature "${OUT_DIR}/${DMG_NAME}" 2>&1 | tee "${WORK}/spctl.txt"
  grep -q "source=Notarized Developer ID" "${WORK}/spctl.txt" || { echo "release.sh: Gatekeeper doesn't accept it as notarized" >&2; exit 1; }
fi

# 6. What it was built with, the SBOM, the sums and the notes.
env "${APPLE_VARIABLES[@]}" node "${SCRIPT_DIR}/scripts/release-info.mjs" --version "${VERSION}" --app "${APP}" --dmg "${OUT_DIR}/${DMG_NAME}" --out "${OUT_DIR}" \
  $([[ "${UNSIGNED}" == true ]] && echo --unsigned)
(cd "${OUT_DIR}" && shasum -a 256 "${DMG_NAME}" "Presence-Capture-${VERSION}.cdx.json" build-info.json > SHA256SUMS)
echo "release.sh: ${OUT_DIR}/${DMG_NAME}$([[ "${UNSIGNED}" == true ]] && echo " (unsigned: not a release)")"
