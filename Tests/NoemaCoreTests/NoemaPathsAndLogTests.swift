import Foundation
import NoemaCore
import Testing

@Suite struct NoemaPathsAndLogTests {
    static let repository = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The identifiers must match the Info.plist template IMKit reads.
    @Test func identifiersMatchTheInfoPlistTemplate() throws {
        let data = try Data(contentsOf: Self.repository.appending(path: "Resources/IME/Info.plist.in"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["CFBundleIdentifier"] as? String == NoemaPaths.imeBundleID)
        #expect(plist["InputMethodConnectionName"] as? String == NoemaPaths.imeConnectionName)
        #expect(plist["InputMethodServerControllerClass"] as? String == NoemaPaths.imeControllerClassName)
        #expect(plist["CFBundleExecutable"] as? String == NoemaPaths.imeExecutableName)
        let modes = try #require((plist["ComponentInputModeDict"] as? [String: Any])?["tsInputModeListKey"] as? [String: Any])
        #expect(modes.keys.contains(NoemaPaths.zhHansInputModeID))
    }

    /// The agent identifiers must match the agent Info.plist and LaunchAgent plist.
    @Test func agentIdentifiersMatchTheAgentPlists() throws {
        let info = try Self.plist("Resources/Agent/Info.plist.in")
        #expect(info["CFBundleIdentifier"] as? String == NoemaPaths.agentBundleID)
        #expect(info["CFBundleExecutable"] as? String == NoemaPaths.agentExecutableName)
        #expect(info["LSUIElement"] as? Bool == true)
        let agent = try Self.plist("Resources/Agent/\(NoemaPaths.agentLaunchAgentPlistName)")
        #expect(agent["Label"] as? String == NoemaPaths.agentBundleID)
        #expect(agent["BundleProgram"] as? String == "Contents/MacOS/\(NoemaPaths.agentExecutableName)")
        #expect((agent["MachServices"] as? [String: Bool])?[NoemaPaths.agentMachServiceName] == true)
        #expect(agent["AssociatedBundleIdentifiers"] as? [String] == [NoemaPaths.agentBundleID])
        #expect(NoemaPaths.agentBundleName == "Noema.app")
        #expect(NoemaPaths.agentReadyNotificationName.hasPrefix("dev.noema."))
    }

    static func plist(_ relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repository.appending(path: relativePath))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test func standardPathsHangOffTheHomeDirectory() {
        let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)
        #expect(NoemaPaths.rimeUserDataDir(homeDirectory: home).path == "/Users/someone/Library/Application Support/Noema/rime")
        #expect(NoemaPaths.logDir(homeDirectory: home).path == "/Users/someone/Library/Logs/Noema")
        #expect(NoemaPaths.inputMethodsDir(homeDirectory: home).path == "/Users/someone/Library/Input Methods")
        #expect(NoemaPaths.installedIMEBundleURL(homeDirectory: home).path == "/Users/someone/Library/Input Methods/NoemaIME.app")
    }

    @Test func sharedDataDirResolutionOrder() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "noema-paths-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appending(path: "work")
        let installed = root.appending(path: "installed/NoemaIME.app")
        let fm = FileManager.default
        let app = root.appending(path: "Running.app")
        try fm.createDirectory(at: app.appending(path: "Contents/Resources"), withIntermediateDirectories: true)
        let bundle = try #require(Bundle(path: app.path))
        func plant(_ dir: URL, file: Bool = true) throws {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if file { try "x".write(to: dir.appending(path: "default.yaml"), atomically: true, encoding: .utf8) }
        }
        #expect(NoemaPaths.resolveSharedDataDir(bundle: bundle, workingDirectory: work, installedBundle: installed) == nil)

        let dist = work.appending(path: "dist/NoemaIME.app/Contents/Resources/rime-default")
        try plant(dist)
        #expect(NoemaPaths.resolveSharedDataDir(bundle: bundle, workingDirectory: work, installedBundle: installed)?.path == dist.path)

        let fromInstalled = installed.appending(path: "Contents/Resources/rime-default")
        try plant(fromInstalled)
        #expect(NoemaPaths.resolveSharedDataDir(bundle: bundle, workingDirectory: work, installedBundle: installed)?.path == fromInstalled.path)

        // A directory without default.yaml is skipped, and so is a default.yaml that is a directory.
        let checkout = work.appending(path: "Resources/rime-default")
        try plant(checkout, file: false)
        try fm.createDirectory(at: checkout.appending(path: "default.yaml"), withIntermediateDirectories: true)
        #expect(NoemaPaths.resolveSharedDataDir(bundle: bundle, workingDirectory: work, installedBundle: installed)?.path == fromInstalled.path)
        try fm.removeItem(at: checkout.appending(path: "default.yaml"))
        try plant(checkout)
        #expect(NoemaPaths.resolveSharedDataDir(bundle: bundle, workingDirectory: work, installedBundle: installed)?.path == checkout.path)

        // The running bundle's own resources win over everything else.
        let fromBundle = try #require(bundle.resourceURL).appending(path: "rime-default")
        try plant(fromBundle)
        #expect(NoemaPaths.resolveSharedDataDir(bundle: bundle, workingDirectory: work, installedBundle: installed)?.path == fromBundle.path)

        let candidates = NoemaPaths.sharedDataDirCandidates(bundle: bundle, workingDirectory: work, installedBundle: installed)
        #expect(candidates.count == 4 && candidates.last?.path == dist.path)
    }

    @Test func logSubsystemsArePerComponent() {
        #expect(NoemaLog.Subsystem.allCases.map(\.rawValue) == [
            "dev.noema.ime", "dev.noema.engine", "dev.noema.cli", "dev.noema.deployer", "dev.noema.agent", "dev.noema.ipc",
        ])
        // Creating loggers has no side effects beyond os_log handles.
        _ = NoemaLog.ime("test"); _ = NoemaLog.engine("test"); _ = NoemaLog.cli("test"); _ = NoemaLog.deployer("test")
        _ = NoemaLog.agent("test"); _ = NoemaLog.ipc("test")
    }
}
