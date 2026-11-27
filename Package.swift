// swift-tools-version: 6.2
import PackageDescription

// Absolute package root derived from this manifest's location, so link flags
// never depend on the current directory or on a .git checkout.
let packageRoot = String(#filePath.dropLast("/Package.swift".count))
let librimeLib = "\(packageRoot)/vendor-out/librime/lib"

let package = Package(
    name: "Noema",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "noema-cli", targets: ["noema-cli"]),
        .executable(name: "NoemaIME", targets: ["NoemaIME"]),
        .executable(name: "noema-rime-deployer", targets: ["noema-rime-deployer"]),
        .executable(name: "NoemaAgent", targets: ["NoemaAgent"]),
    ],
    targets: [
        // C bridge to the vendored librime built by scripts/build/librime.sh.
        // Debug builds find librime in vendor-out; release builds only look in the
        // app bundle's Frameworks directory, never in a developer path.
        .target(
            name: "CRime",
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags(["-L", librimeLib]),
                .linkedLibrary("rime"),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", librimeLib], .when(configuration: .debug)),
                .unsafeFlags(
                    ["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"],
                    .when(configuration: .release)
                ),
            ]
        ),
        .target(name: "NoemaCore"),
        .target(name: "NoemaText"),
        // IME <-> agent IPC: wire format, XPC transport, peer verification, and the IME's
        // connection state machine. Zero TCC, like NoemaIME, which links it.
        .target(name: "NoemaIPC", dependencies: ["NoemaCore"]),
        // The canonical learning store: SQLite WAL `learning.sqlite`, its non-blocking writer, and
        // the `noema_learned.tsv` exporter. Zero networking; system SQLite3 only.
        .target(
            name: "NoemaLearning",
            dependencies: ["NoemaCore", "NoemaText"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(name: "NoemaEngine", dependencies: ["CRime", "NoemaCore", "NoemaLearning", "NoemaText"]),
        // Dictionary lockfile, verified downloads, safe archive extraction, and the installed
        // lexicon inventory. Runs in the agent or noema-cli, never in NoemaIME.
        .target(name: "NoemaLexiconAdmin", dependencies: ["NoemaCore", "NoemaLearning"]),
        .executableTarget(name: "noema-cli", dependencies: ["NoemaCore", "NoemaEngine", "NoemaLearning", "NoemaLexiconAdmin"]),
        // Engine-independent IMKit shell logic: session coordination, NSEvent bridging, and
        // the text-client and candidate-presenter seams. Zero TCC, like NoemaIME.
        .target(name: "NoemaIMEShell", dependencies: ["NoemaCore", "NoemaText"]),
        // The candidate panel: CoreText layout, caret placement, and the non-activating
        // NSPanel that implements CandidatePresenting. Zero TCC, like NoemaIME.
        .target(name: "NoemaUI", dependencies: ["NoemaCore", "NoemaIMEShell"]),
        // Input method executable bundled into NoemaIME.app by scripts/build/bundle.sh.
        .executableTarget(
            name: "NoemaIME", dependencies: ["NoemaCore", "NoemaEngine", "NoemaIMEShell", "NoemaIPC", "NoemaLearning", "NoemaUI"]),
        // The companion agent's logic: IPC service, LaunchAgent control, and the SwiftUI
        // Settings window. Never linked into NoemaIME.
        // The clipboard history store: privacy filter, CryptoKit AES-GCM at rest, encrypted image
        // blobs, and an in-memory FTS5 index. Agent only; never linked into NoemaIME.
        .target(
            name: "NoemaClipboardCore",
            dependencies: ["NoemaCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "NoemaAgentCore",
            dependencies: ["NoemaCore", "NoemaIPC", "NoemaLearning", "NoemaLexiconAdmin", "NoemaClipboardCore"]),
        // The companion agent executable bundled into Noema.app; no librime.
        .executableTarget(name: "NoemaAgent", dependencies: ["NoemaCore", "NoemaIPC", "NoemaAgentCore", "NoemaClipboardCore"]),
        // Isolated Rime deployment subprocess, bundled beside NoemaIME in Contents/MacOS.
        // RimeEngine runs it; librime's deployer never runs in the input method process.
        .executableTarget(name: "noema-rime-deployer", dependencies: ["CRime", "NoemaCore", "NoemaEngine"]),
        .testTarget(name: "NoemaCoreTests", dependencies: ["NoemaCore", "NoemaIPC", "NoemaText"]),
        // IPC wire format, state machine, real libxpc and SecCode, and the real NoemaAgent.
        .testTarget(
            name: "NoemaIPCTests",
            dependencies: [
                "NoemaCore", "NoemaIPC", "NoemaAgentCore", "NoemaAgent", "NoemaLearning", "NoemaLexiconAdmin", "NoemaClipboardCore",
            ]),
        // Privacy filter, tokenizer, CryptoKit, image guard, blob store, and the on-disk store.
        .testTarget(name: "NoemaClipboardCoreTests", dependencies: ["NoemaClipboardCore", "NoemaCore"]),
        // Pure engine logic (key mapping, boot guard); never initializes librime.
        .testTarget(name: "NoemaEngineTests", dependencies: ["NoemaCore", "NoemaEngine", "NoemaLearning"]),
        // The SQLite learning store, its writer, and the learned-phrase TSV export.
        .testTarget(name: "NoemaLearningTests", dependencies: ["NoemaCore", "NoemaLearning", "NoemaText"]),
        // Lockfile validation, loopback downloads, safe ZIP extraction, and the inventory.
        .testTarget(name: "NoemaLexiconAdminTests", dependencies: ["NoemaCore", "NoemaLearning", "NoemaLexiconAdmin"]),
        // NSEvent bridging and other shell logic that needs no engine.
        .testTarget(name: "NoemaIMEShellTests", dependencies: ["NoemaCore", "NoemaIMEShell"]),
        // Headless CoreText layout, width hysteresis, and caret placement of the panel.
        .testTarget(name: "NoemaUITests", dependencies: ["NoemaCore", "NoemaIMEShell", "NoemaUI"]),
        // Every test that initializes librime: one top-level serialized suite.
        // Depends on noema-rime-deployer, noema-cli, and NoemaIME so every `swift test` builds the
        // deployer RimeEngine spawns and the executables the end-to-end tests run.
        .testTarget(
            name: "CRimeTests",
            dependencies: [
                "CRime", "NoemaCore", "NoemaEngine", "NoemaIMEShell", "NoemaIPC", "NoemaAgentCore", "NoemaUI", "NoemaLearning", "NoemaText",
                "noema-rime-deployer", "noema-cli", "NoemaIME",
            ]
        ),
    ],
    // Swift 6 language mode: complete strict-concurrency checking for every Swift target.
    swiftLanguageModes: [.v6]
)
