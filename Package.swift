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
        .target(name: "NoemaIPC"),
        .target(name: "NoemaEngine", dependencies: ["CRime", "NoemaCore"]),
        .executableTarget(name: "noema-cli", dependencies: ["NoemaCore", "NoemaEngine"]),
        // Input method executable bundled into NoemaIME.app by scripts/build/bundle.sh.
        .executableTarget(name: "NoemaIME", dependencies: ["NoemaCore", "NoemaEngine"]),
        .testTarget(name: "NoemaCoreTests", dependencies: ["NoemaCore", "NoemaIPC", "NoemaText"]),
        // Pure engine logic (key mapping, boot guard); never initializes librime.
        .testTarget(name: "NoemaEngineTests", dependencies: ["NoemaCore", "NoemaEngine"]),
        // Every test that initializes librime: one top-level serialized suite.
        .testTarget(name: "CRimeTests", dependencies: ["CRime", "NoemaCore", "NoemaEngine"]),
    ],
    // Swift 6 language mode: complete strict-concurrency checking for every Swift target.
    swiftLanguageModes: [.v6]
)
