import CRime
import Darwin
import Dispatch
import Foundation
import NoemaCore
import NoemaLearning

/// What `switchSchemaSet` did.
public struct SchemaSetSwitchReport: Sendable {
    public var schemaSetID: SchemaSetID
    public var schemaID: String
    /// The userdb the guardian checked (`translator/user_dict`, else `translator/dictionary`),
    /// nil when the schema has none or disables it.
    public var userDictName: String?
    /// Whether the target schema spells Mandarin pinyin. When false the guardian still checks
    /// the userdb but never projects `learning.sqlite` (full-pinyin keys) into it.
    public var isMandarinPinyinSchema: Bool
    /// The guardian's outcome; nil when it did not run (no levers API, no user dict).
    public var userDBOutcome: UserDBGuardian.MaintenanceOutcome?
    /// Why the guardian failed, if it did; the switch still completes.
    public var userDBFailure: UserDBGuardian.Failure?
    /// Lines written to `<set>/noema_learned.tsv`; nil without a learning store.
    public var learnedLines: Int?
    /// The `.gram` linked into the set, if any.
    public var linkedGram: URL?
    public var savedActiveRecord: Bool
}

/// Hot switch between isolated schema sets under one root lock.
///
/// Every set has its own librime `user_data_dir` at `<root>/sets/<set>/` (`build/`,
/// userdbs, `lua/`, `noema_learned.tsv`, `*.custom.yaml`), so their LevelDB userdbs never
/// mix; the boot guard, its lock, `learning.sqlite`, and `active-schema-set.json` stay in
/// `<root>`. The switch keeps serving keys on the current set while the target is prepared
/// and deployed off the main actor; only the final quiescent step (flush learning, destroy
/// the session, finalize, initialize the target, check its userdb, open a session) blocks.
extension RimeEngine {
    /// Switches to `set`, whose schema sources are in `sharedDataDir`, opening `schemaID`
    /// (default: the set's `defaultSchemaID`).
    ///
    /// 1. Off the main actor: create `sets/<set>/`, copy `luaFile` to its `lua/`, hard-link
    ///    `gramPath` (`link(2)`, same volume) as `sets/<set>/<name>.gram`, and make its
    ///    `build/` loadable (`prepareBuild`, the isolated deployer). Failure throws and leaves
    ///    the current set running untouched.
    ///    With `waitUntilIdle`, the switch then waits (awaiting it again after every wake)
    ///    until no composition is open, so the user's preedit is never destroyed.
    /// 2. `learningWriter.flush()`, arm the boot sentinel, destroy the session, finalize.
    /// 3. Initialize librime on the target; with no session open, `UserDBGuardian` checks
    ///    the userdb and projects `learningStore` into it; export `noema_learned.tsv`.
    /// 4. Open a session on `schemaID`, disarm, save `active-schema-set.json`. If the target
    ///    will not open, the previous set is restored (or, failing that, Safe Mode) and this throws.
    @discardableResult
    public func switchSchemaSet(
        to set: SchemaSetID,
        sharedDataDir: URL,
        schemaID: String? = nil,
        learningStore: LearningStore? = nil,
        learningWriter: LearningStoreWriter? = nil,
        luaFile: URL? = nil,
        gramPath: URL? = nil,
        cancellation: DeployCancellation = DeployCancellation(),
        waitUntilIdle: (@MainActor () async -> Void)? = nil
    ) async throws(NoemaError) -> SchemaSetSwitchReport {
        guard isOperational else { throw .engineUnavailable(reason: "engine is in Safe Mode or shut down") }
        guard !isSwitchingSchemaSet else { throw .engineUnavailable(reason: "a schema-set switch is already running") }
        let targetSchema = schemaID ?? set.defaultSchemaID
        guard FileSafety.isPlainName(targetSchema) else { throw .invalidArgument("schema ID is not a plain name: \(targetSchema)") }
        isSwitchingSchemaSet = true
        defer { isSwitchingSchemaSet = false }

        var target = configuration
        target.schemaSetID = set
        target.sharedDataDir = sharedDataDir
        target.schemaID = targetSchema
        target.luaFile = luaFile
        let prepared = await withCheckedContinuation { (continuation: CheckedContinuation<URL??, Never>) in
            // Entered so `cancellation.cancelAndFinishCleanup` waits for the staging cleanup.
            guard let group = cancellation.enterPrepare() else {
                continuation.resume(returning: nil)
                return
            }
            let configuration = target
            DispatchQueue.global(qos: .userInitiated).async {
                defer { cancellation.leavePrepare(group) }
                guard let gram = Self.prepareSchemaSetWorkspace(configuration, gramPath: gramPath),
                      Self.prepareBuild(configuration: configuration, cancellation: cancellation)
                else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: .some(gram))
            }
        }
        guard isOperational, !cancellation.isCancelled else { throw .engineUnavailable(reason: "switch cancelled") }
        guard let linkedGram = prepared else {
            throw .engineCallFailed(function: "prepare schema set \(set.rawValue)")
        }
        // Never destroy a composition: wait for the next idle boundary. Re-checked after
        // every wake, because a key may start a new composition before this task resumes.
        if let waitUntilIdle {
            while currentState.isComposing, isOperational, !cancellation.isCancelled {
                await waitUntilIdle()
                // A hook that returned while still composing never spins the main actor.
                if currentState.isComposing { try? await Task.sleep(for: .milliseconds(20)) }
            }
            guard isOperational, !cancellation.isCancelled else { throw .engineUnavailable(reason: "switch cancelled") }
        }

        learningWriter?.flush()
        guard case .proceed = resources.bootGuard.arm() else {
            throw .engineUnavailable(reason: "boot guard refused the switch")
        }
        let previous = configuration
        resources.finalizeRime()
        configuration = target
        initializeRime()

        // A shape or non-Mandarin schema's userdb is keyed by its own codes: the guardian
        // keeps it healthy but never fills it with full-pinyin entries or a watermark.
        let isPinyin = isMandarinPinyinSchema(schemaID: targetSchema)
        var report = SchemaSetSwitchReport(
            schemaSetID: set, schemaID: targetSchema, userDictName: nil, isMandarinPinyinSchema: isPinyin,
            userDBOutcome: nil, userDBFailure: nil, learnedLines: nil, linkedGram: linkedGram, savedActiveRecord: false)
        if let dictName = userDictName(schemaID: targetSchema), let levers = RimeUserDictLevers() {
            report.userDictName = dictName
            let guardian = UserDBGuardian(
                schemaSet: set, userDataDir: target.rimeUserDataDir,
                snapshotsDir: NoemaPaths.userDBSnapshotsDir(set, root: target.userDataDir), levers: levers)
            do {
                report.userDBOutcome = try guardian.maintain(dictName, store: isPinyin ? learningStore : nil)
            } catch {
                report.userDBFailure = error
            }
        }
        if let learningStore {
            report.learnedLines = try? LearnedSnapshotExporter.export(
                from: learningStore, to: target.rimeUserDataDir.appending(path: NoemaPaths.learnedTSVFileName))
        }

        guard openSession() else {
            resources.finalizeRime()
            configuration = previous
            initializeRime()
            guard openSession() else {
                enterSafeMode(.engineInitFailed)
                throw .engineCallFailed(function: "select_schema \(targetSchema)")
            }
            resources.bootGuard.disarm()
            refreshState()
            throw .engineCallFailed(function: "select_schema \(targetSchema)")
        }
        resources.bootGuard.disarm()
        let record = ActiveSchemaSetRecord(schemaSetID: set, schemaID: targetSchema)
        report.savedActiveRecord = (try? record.save(to: NoemaPaths.activeSchemaSetURL(root: target.userDataDir))) != nil
        refreshState()
        return report
    }

    /// Re-exports `noema_learned.tsv` for the running set; the translator picks it up on
    /// its next size check or session. Returns the number of lines, or nil without a set.
    @discardableResult
    public func refreshLearnedPhrases(from store: LearningStore) -> Int? {
        guard configuration.schemaSetID != nil else { return nil }
        return try? LearnedSnapshotExporter.export(
            from: store, to: configuration.rimeUserDataDir.appending(path: NoemaPaths.learnedTSVFileName))
    }

    private func initializeRime() {
        withTraits { traits in
            RimeProcessLifecycle.setupIfNeeded(owner: resources.owner, api: api, traits: &traits)
            api.pointee.initialize(&traits)
        }
        resources.isInitialized = true
    }

    /// `translator/user_dict`, else `translator/dictionary`, of the compiled schema; nil when
    /// neither is set, `translator/enable_user_dict` is false, or the name is not plain.
    func userDictName(schemaID: String) -> String? {
        guard let schemaOpen = api.pointee.schema_open, let configClose = api.pointee.config_close,
              let getCString = api.pointee.config_get_cstring
        else { return nil }
        var config = RimeConfig()
        guard schemaOpen(schemaID, &config) != 0 else { return nil }
        defer { _ = configClose(&config) }
        if let getBool = api.pointee.config_get_bool {
            var enabled: Int32 = 1
            if getBool(&config, "translator/enable_user_dict", &enabled) != 0, enabled == 0 { return nil }
        }
        for key in ["translator/user_dict", "translator/dictionary"] {
            if let value = getCString(&config, key).map({ String(cString: $0) }), !value.isEmpty {
                return FileSafety.isPlainName(value) ? value : nil
            }
        }
        return nil
    }

    /// Lowercase substrings of a schema ID, `translator/dictionary`, or `translator/prism`
    /// that mark a schema whose codes are not Mandarin pinyin (shape codes, Zhuyin,
    /// Cantonese and other languages), even one whose primary translator is
    /// `script_translator` (Jyutping, Zhuyin). Double pinyin (`double_pinyin_flypy`,
    /// `xiaohe`) is Mandarin pinyin: its preedit spells full pinyin and its userdb is keyed
    /// by it, so it is not listed.
    nonisolated static let nonMandarinPinyinMarkers = [
        "wubi", "cangjie", "stroke", "erbi", "zhengma", "bopomofo", "zhuyin", "jyutping", "jyut6ping3",
        "cantonese", "hakka", "array", "quick", "dayi", "kana", "hangul", "easy_en", "melt_eng", "english",
        "tiger", "wugniu", "soutzoe", "xingma",
    ]

    /// Whether the compiled schema `schemaID` spells Mandarin pinyin (full, double, or
    /// jianpin): `engine/translators` lists an untagged `script_translator` and no untagged
    /// `table_translator` (the primary translator of Wubi, Cangjie, Stroke, Zhengma; full
    /// pinyin uses only tagged ones such as `table_translator@custom_phrase`), and neither
    /// the schema ID, `translator/dictionary`, nor `translator/prism` names a
    /// `nonMandarinPinyinMarkers` entry. Fail-closed: false for an empty ID, a schema that
    /// will not open, or a librime without the config API.
    func isMandarinPinyinSchema(schemaID: String) -> Bool {
        guard !schemaID.isEmpty, let schemaOpen = api.pointee.schema_open, let configClose = api.pointee.config_close,
              let getCString = api.pointee.config_get_cstring, let listSize = api.pointee.config_list_size
        else { return false }
        var config = RimeConfig()
        guard schemaOpen(schemaID, &config) != 0 else { return false }
        defer { _ = configClose(&config) }
        let translators = (0..<listSize(&config, "engine/translators")).compactMap { index in
            getCString(&config, "engine/translators/@\(index)").map { String(cString: $0) }
        }
        guard translators.contains("script_translator"), !translators.contains("table_translator") else { return false }
        var names = [schemaID]
        for key in ["translator/dictionary", "translator/prism"] {
            if let value = getCString(&config, key) { names.append(String(cString: value)) }
        }
        return !names.contains { name in
            let lowered = name.lowercased()
            return Self.nonMandarinPinyinMarkers.contains { lowered.contains($0) }
        }
    }

    /// Creates `sets/<set>/` (and its `lua/`), installs `luaFile` there as
    /// `noema_learned.lua`, and hard-links `gramPath` into it. Returns the linked gram (or
    /// `.some(nil)` with none), nil on failure. Makes no librime call.
    nonisolated static func prepareSchemaSetWorkspace(_ configuration: RimeEngineConfiguration, gramPath: URL?) -> URL?? {
        let directory = configuration.rimeUserDataDir
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        guard FileSafety.isRealDirectory(directory) else { return nil }
        if let luaFile = configuration.luaFile {
            let luaDirectory = directory.appending(path: "lua", directoryHint: .isDirectory)
            guard (try? fileManager.createDirectory(at: luaDirectory, withIntermediateDirectories: true)) != nil,
                  FileSafety.isRealDirectory(luaDirectory),
                  let data = try? DeployManifest.readRegularFile(luaFile),
                  (try? FileSafety.writeAtomically(
                      data, to: luaDirectory.appending(path: NoemaPaths.learnedLuaFileName), mode: 0o644)) != nil
            else { return nil }
        }
        guard let gramPath else { return .some(nil) }
        guard let linked = linkGram(gramPath, into: directory) else { return nil }
        return .some(linked)
    }

    /// Hard-links the regular file `gram` as `<directory>/<name>.gram`, atomically replacing
    /// a different file of that name (`link(2)` to a temporary name, then `rename(2)`).
    nonisolated static func linkGram(_ gram: URL, into directory: URL) -> URL? {
        guard gram.pathExtension == "gram", FileSafety.isPlainName(gram.lastPathComponent) else { return nil }
        var source = stat()
        guard lstat(gram.path, &source) == 0, source.st_mode & S_IFMT == S_IFREG else { return nil }
        let target = directory.appending(path: gram.lastPathComponent)
        var existing = stat()
        if lstat(target.path, &existing) == 0, existing.st_mode & S_IFMT == S_IFREG,
           existing.st_dev == source.st_dev, existing.st_ino == source.st_ino {
            return target
        }
        let temporary = directory.appending(path: ".\(gram.lastPathComponent).link.\(getpid()).\(UUID().uuidString)")
        guard link(gram.path, temporary.path) == 0 else { return nil }
        guard rename(temporary.path, target.path) == 0 else {
            unlink(temporary.path)
            return nil
        }
        FileSafety.syncDirectory(directory)
        return target
    }
}
