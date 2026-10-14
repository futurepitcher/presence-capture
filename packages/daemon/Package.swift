// swift-tools-version: 6.0
// The macOS reference daemon. CaptureStore writes the store SCHEMA.md defines and
// must pass the store-layer conformance suite through pcap-driver; CaptureCore
// reads the screen and hears this Mac; PresenceCapture is the menu-bar app.
import PackageDescription

let package = Package(
    name: "PresenceCaptureDaemon",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PresenceCapture", targets: ["PresenceCapture"]),
        .executable(name: "pcap-driver", targets: ["PcapDriver"]),
        .executable(name: "pcap-mcp", targets: ["PcapMCP"]),
        .executable(name: "pcap", targets: ["PcapCLI"]),
        .library(name: "CaptureStore", targets: ["CaptureStore"]),
    ],
    targets: [
        // The store: sealing, revocation that erases, retention, and the rules applied before disk.
        .target(name: "CaptureStore", linkerSettings: [.linkedLibrary("sqlite3")]),
        // What can be tested without a screen: reading text, which window is in front, speech to text.
        .target(name: "CaptureCore"),
        // Recall (ADR 0008): the reader's in-memory index and its tools.
        .target(name: "CaptureRecall", dependencies: ["CaptureStore"]),
        // Connecting an agent: its grant, and pcap-mcp in its MCP config. Shared by `pcap connect`
        // and the menu's Connect an Agent….
        .target(name: "CaptureConnect", dependencies: ["CaptureStore"]),
        .executableTarget(name: "PresenceCapture", dependencies: ["CaptureStore", "CaptureCore", "CaptureConnect"]),
        // The conformance driver (docs/spec/DRIVER.md) over CaptureStore.
        .executableTarget(name: "PcapDriver", dependencies: ["CaptureStore"]),
        // The native MCP server (ADR 0008): reads through grants; writes only egress records.
        .executableTarget(name: "PcapMCP", dependencies: ["CaptureStore", "CaptureRecall"]),
        // pcap, the command line: grants, egress, forget, check, connect. A writer, in the app's bundle.
        .executableTarget(name: "PcapCLI", dependencies: ["CaptureStore", "CaptureConnect"]),
        .testTarget(name: "CaptureStoreTests", dependencies: ["CaptureStore"]),
        .testTarget(name: "CaptureCoreTests", dependencies: ["CaptureCore"]),
        .testTarget(name: "PresenceCaptureTests", dependencies: ["PresenceCapture", "CaptureStore"]),
        .testTarget(name: "CaptureRecallTests", dependencies: ["CaptureRecall", "CaptureStore"]),
        .testTarget(name: "CaptureConnectTests", dependencies: ["CaptureConnect", "CaptureStore"]),
    ],
    swiftLanguageModes: [.v5]
)
