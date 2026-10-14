# Homebrew cask for Presence Capture (R3). It lives in futurepitcher/homebrew-tap, and is kept here
# so its changes are reviewed with the release. After a release, set `version` and `sha256` (the
# DMG's, from the release's SHA256SUMS) in the tap's copy.
cask "presence-capture" do
  version "0.1.0"
  sha256 "<the DMG's SHA-256, from the release's SHA256SUMS>"

  url "https://github.com/futurepitcher/presence-capture/releases/download/v#{version}/Presence-Capture-#{version}.dmg"
  name "Presence Capture"
  desc "Remembers what you see, hear and do on your Mac, for the agents you choose"
  homepage "https://github.com/futurepitcher/presence-capture"

  depends_on macos: ">= :sonoma"

  app "Presence Capture.app"
  binary "#{appdir}/Presence Capture.app/Contents/MacOS/pcap"

  # Settings only. The store (~/Library/Application Support/Presence Capture) is what the person
  # captured: it's theirs to delete, from the app (Forget) or by hand, never by an uninstall.
  zap trash: "~/Library/Preferences/ai.presenceos.capture.plist"
end
