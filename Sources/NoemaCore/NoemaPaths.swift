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

    // MARK: - Schema sets and learning (all under `rimeUserDataDir`, one volume)

    /// `NoemaIME.app/Contents/Resources/rime-lua` and its learned-phrase translator.
    public static let rimeLuaDirectoryName = "rime-lua"
    public static let learnedLuaFileName = "noema_learned.lua"
    public static let learnedTSVFileName = "noema_learned.tsv"
    public static let learningStoreFileName = "learning.sqlite"

    /// `<root>/sets/<set>/`: the set's own Rime `user_data_dir` (`build/`, userdbs,
    /// `user.yaml`, `lua/`, `noema_learned.tsv`, `*.custom.yaml`).
    public static func schemaSetUserDataDir(_ set: SchemaSetID, root: URL = rimeUserDataDir()) -> URL {
        root.appending(path: "sets/\(set.directoryName)", directoryHint: .isDirectory)
    }

    /// `<root>/schemas/<set>/`: the extracted schema and dictionary sources of a downloaded
    /// set, its Rime `shared_data_dir`. The built-in set uses `resolveSharedDataDir` instead.
    public static func downloadedSchemaDir(_ set: SchemaSetID, root: URL = rimeUserDataDir()) -> URL {
        root.appending(path: "schemas/\(set.directoryName)", directoryHint: .isDirectory)
    }

    /// `<root>/models/`: verified `.gram` language models, hard-linked into each set.
    public static func modelsDir(root: URL = rimeUserDataDir()) -> URL {
        root.appending(path: "models", directoryHint: .isDirectory)
    }

    /// `<root>/snapshots/<set>/`: SHA-256-verified userdb TSV snapshots and their sidecars.
    public static func userDBSnapshotsDir(_ set: SchemaSetID, root: URL = rimeUserDataDir()) -> URL {
        root.appending(path: "snapshots/\(set.directoryName)", directoryHint: .isDirectory)
    }

    /// `<root>/learning.sqlite`: the canonical learning store (WAL).
    public static func learningStoreURL(root: URL = rimeUserDataDir()) -> URL {
        root.appending(path: learningStoreFileName)
    }

    /// `<root>/active-schema-set.json`.
    public static func activeSchemaSetURL(root: URL = rimeUserDataDir()) -> URL {
        root.appending(path: ActiveSchemaSetRecord.fileName)
    }

    /// The bundled `noema_learned.lua`: the first regular file among
    /// `<bundle resources>/rime-lua/`, `<workingDirectory>/Resources/rime-lua/`, and
    /// `<installedBundle>/Contents/Resources/rime-lua/`.
    public static func resolveLearnedLua(
        bundle: Bundle = .main,
        workingDirectory: URL = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory),
        installedBundle: URL = installedIMEBundleURL()
    ) -> URL? {
        var candidates: [URL] = []
        if let resources = bundle.resourceURL {
            candidates.append(resources.appending(path: "\(rimeLuaDirectoryName)/\(learnedLuaFileName)"))
        }
        candidates.append(workingDirectory.appending(path: "Resources/\(rimeLuaDirectoryName)/\(learnedLuaFileName)"))
        candidates.append(installedBundle.appending(path: "Contents/Resources/\(rimeLuaDirectoryName)/\(learnedLuaFileName)"))
        return candidates.first(where: FileSafety.isRegularFile)
    }

    /// The Rime `shared_data_dir` of an installed `set`, or nil: `builtinSharedDataDir` for
    /// the built-in set, else `schemas/<set>/` when it is a real directory holding a regular
    /// `default.yaml` and `<schemaID>.schema.yaml` (default: the set's `defaultSchemaID`).
    public static func installedSchemaDir(
        _ set: SchemaSetID, schemaID: String? = nil, root: URL = rimeUserDataDir(), builtinSharedDataDir: URL?
    ) -> URL? {
        if set == .builtin { return builtinSharedDataDir }
        let schema = schemaID ?? set.defaultSchemaID
        guard FileSafety.isPlainName(schema) else { return nil }
        let directory = downloadedSchemaDir(set, root: root)
        guard FileSafety.isRealDirectory(directory),
              FileSafety.isRegularFile(directory.appending(path: "default.yaml")),
              FileSafety.isRegularFile(directory.appending(path: "\(schema).schema.yaml"))
        else { return nil }
        return directory
    }

    /// `dictionaries.lock.json`: `vendor/` in a checkout, `Contents/Resources/` in `Noema.app`.
    public static let dictionaryLockfileName = "dictionaries.lock.json"

    /// The first regular file among `<bundle resources>/dictionaries.lock.json` and
    /// `<workingDirectory>/vendor/dictionaries.lock.json`.
    public static func resolveDictionaryLockfile(
        bundle: Bundle = .main,
        workingDirectory: URL = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)
    ) -> URL? {
        var candidates: [URL] = []
        if let resources = bundle.resourceURL { candidates.append(resources.appending(path: dictionaryLockfileName)) }
        candidates.append(workingDirectory.appending(path: "vendor/\(dictionaryLockfileName)"))
        return candidates.first(where: FileSafety.isRegularFile)
    }

    static func holdsDefaultYAML(_ directory: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return false }
        let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appending(path: "default.yaml").path)
        return attributes?[.type] as? FileAttributeType == .typeRegular
    }
}
