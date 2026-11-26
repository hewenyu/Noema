import Foundation

/// Identifiers and standard locations shared by `NoemaIME`, `NoemaAgent`, `noema-cli`, and
/// tests. The identifiers mirror `Resources/IME/Info.plist.in`, `Resources/Agent/Info.plist.in`,
/// and `Resources/Agent/dev.noema.agent.plist`; `NoemaPathsAndLogTests` keeps them in step.
public enum NoemaPaths {
    public static let imeBundleID = "dev.noema.inputmethod.NoemaIME"
    public static let imeConnectionName = "dev.noema.inputmethod.NoemaIME_Connection"
    public static let imeControllerClassName = "NoemaInputController"
    public static let zhHansInputModeID = "dev.noema.inputmethod.NoemaIME.zhHans"
    public static let imeBundleName = "NoemaIME.app"
    public static let imeExecutableName = "NoemaIME"
    public static let rimeDefaultDirectoryName = "rime-default"

    /// The companion agent `Noema.app` and its LaunchAgent (`SMAppService.agent`).
    public static let agentBundleID = "dev.noema.agent"
    public static let agentBundleName = "Noema.app"
    public static let agentExecutableName = "NoemaAgent"
    /// `Noema.app/Contents/Library/LaunchAgents/<name>`, registered with `SMAppService.agent(plistName:)`.
    public static let agentLaunchAgentPlistName = "dev.noema.agent.plist"
    /// The launchd Mach service `NoemaAgent` checks in and `NoemaIME` connects to.
    public static let agentMachServiceName = "dev.noema.agent.ipc"
    /// Darwin notification `NoemaAgent` posts once its listener is up; clients reconnect at once.
    public static let agentReadyNotificationName = "dev.noema.agent.ready"

    /// `~/Library/Application Support/Noema/rime`: the single-writer Rime `user_data_dir`.
    public static func rimeUserDataDir(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory.appending(path: "Library/Application Support/Noema/rime", directoryHint: .isDirectory)
    }

    /// `~/Library/Logs/Noema`.
    public static func logDir(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appending(path: "Library/Logs/Noema", directoryHint: .isDirectory)
    }

    /// `~/Library/Input Methods`.
    public static func inputMethodsDir(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appending(path: "Library/Input Methods", directoryHint: .isDirectory)
    }

    /// `~/Library/Input Methods/NoemaIME.app`.
    public static func installedIMEBundleURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        inputMethodsDir(homeDirectory: homeDirectory).appending(path: imeBundleName, directoryHint: .isDirectory)
    }

    /// The shipped Rime `shared_data_dir`: the first candidate holding a regular
    /// `default.yaml`, checked in order:
    /// 1. `<bundle resources>/rime-default` (the running `NoemaIME.app`);
    /// 2. `<workingDirectory>/Resources/rime-default` (a source checkout);
    /// 3. `<installedBundle>/Contents/Resources/rime-default`;
    /// 4. `<workingDirectory>/dist/NoemaIME.app/Contents/Resources/rime-default`.
    public static func resolveSharedDataDir(
        bundle: Bundle = .main,
        workingDirectory: URL = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory),
        installedBundle: URL = installedIMEBundleURL()
    ) -> URL? {
        sharedDataDirCandidates(bundle: bundle, workingDirectory: workingDirectory, installedBundle: installedBundle)
            .first(where: holdsDefaultYAML)
    }

    /// Every candidate `resolveSharedDataDir` checks, in order.
    public static func sharedDataDirCandidates(bundle: Bundle, workingDirectory: URL, installedBundle: URL) -> [URL] {
        var candidates: [URL] = []
        if let resources = bundle.resourceURL {
            candidates.append(resources.appending(path: rimeDefaultDirectoryName, directoryHint: .isDirectory))
        }
        candidates.append(workingDirectory.appending(path: "Resources/\(rimeDefaultDirectoryName)", directoryHint: .isDirectory))
        candidates.append(installedBundle.appending(path: "Contents/Resources/\(rimeDefaultDirectoryName)", directoryHint: .isDirectory))
        candidates.append(workingDirectory.appending(
            path: "dist/\(imeBundleName)/Contents/Resources/\(rimeDefaultDirectoryName)", directoryHint: .isDirectory))
        return candidates
    }

    static func holdsDefaultYAML(_ directory: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return false }
        let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appending(path: "default.yaml").path)
        return attributes?[.type] as? FileAttributeType == .typeRegular
    }
}
