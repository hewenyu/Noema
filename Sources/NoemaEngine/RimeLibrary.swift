import CRime
import Foundation
import NoemaCore
import NoemaLearning

/// The engine's handle on the in-process librime for calls that read no main-actor state:
/// initialize, the quiescent userdb maintenance, opening a session, and reading the compiled
/// schema's config. `RimeEngine` uses it on the main actor and, while it holds librime
/// exclusively (booting, or `isInExclusiveMaintenance` during a switch: no key, no other
/// librime call), from one background queue.
///
/// `@unchecked Sendable`: `api` is librime's static function table, and `resources` is only
/// touched by whichever side holds librime exclusively at the time.
struct RimeLibrary: @unchecked Sendable {
    let api: UnsafeMutablePointer<RimeApi>
    let resources: RimeEngineResources

    /// What opening a session found: librime's reported schema and how it is classified.
    struct SessionOpening: @unchecked Sendable {
        /// True when the session reports `schemaID` active.
        var opened: Bool
        var schemaID: String?
        var isMandarinPinyin: Bool
        var secondaryInputRules: SecondaryInputRules
    }

    /// What the quiescent maintenance after `initialize` did (`initializeAndMaintain`).
    struct Maintenance: Sendable {
        var isMandarinPinyin = false
        var codeFormat = UserDictCodeFormat.toneless
        var userDictName: String?
        var outcome: UserDBGuardian.MaintenanceOutcome?
        var failure: UserDBGuardian.Failure?
        var learnedLines: Int?
    }

    func initialize(_ configuration: RimeEngineConfiguration) {
        configuration.exportOpenCCDataDir()
        Self.withTraits(configuration) { traits in
            RimeProcessLifecycle.setupIfNeeded(owner: resources.owner, api: api, traits: &traits)
            api.pointee.initialize(&traits)
        }
        resources.isInitialized = true
    }

    /// Where `initializeAndMaintain` finds the learning store.
    enum StoreSource {
        /// A switch: the caller's store (nil: none); the guardian checks the userdb either way.
        case given(LearningStore?)
        /// A boot: `<root>/learning.sqlite` when it already exists (opened and closed here; a
        /// fresh install never gets one); without it the guardian does not run.
        case onDiskIfPresent
    }

    /// Initializes librime on `configuration` and, in the quiescent window before any session
    /// (no translator holds a userdb), keeps its userdb in step with `learning.sqlite`, the one
    /// path both boot and `switchSchemaSet` take:
    /// 1. a built-in boot runs `LegacyRootMigrator` phase 2 (`migration`);
    /// 2. with a schema set, the levers API, a userdb for the schema, and a store (or a
    ///    `.given` source), `UserDBGuardian` checks the userdb and recovers it, projecting the
    ///    store only into a Mandarin pinyin schema, spelled as its dictionary spells codes;
    /// 3. with a schema set and a store, `noema_learned.tsv` is exported.
    func initializeAndMaintain(
        _ configuration: RimeEngineConfiguration, migration: LegacyRootMigrator.PendingMigration?, store source: StoreSource,
        isCancelled: () -> Bool = { false }
    ) -> Maintenance {
        if isCancelled() { return Maintenance() }
        initialize(configuration)
        if isCancelled() { return Maintenance() }
        importLegacyUserDBs(configuration, migration)
        if isCancelled() { return Maintenance() }
        let schemaID = configuration.schemaID
        var result = Maintenance(isMandarinPinyin: isMandarinPinyinSchema(schemaID: schemaID), codeFormat: userDictCodeFormat(schemaID: schemaID))
        guard let set = configuration.schemaSetID else { return result }
        var opened: LearningStore?
        let storeURL = NoemaPaths.learningStoreURL(root: configuration.userDataDir)
        if case .onDiskIfPresent = source, FileSafety.isRegularFile(storeURL) { opened = try? LearningStore(url: storeURL) }
        defer { opened?.close() }
        var store = opened
        var maintainWithoutStore = false
        if case .given(let given) = source { (store, maintainWithoutStore) = (given, true) }
        if !isCancelled(), store != nil || maintainWithoutStore, let dictName = userDictName(schemaID: schemaID), let levers = RimeUserDictLevers() {
            result.userDictName = dictName
            let guardian = UserDBGuardian(
                schemaSet: set, userDataDir: configuration.rimeUserDataDir,
                snapshotsDir: NoemaPaths.userDBSnapshotsDir(set, root: configuration.userDataDir), levers: levers,
                codeFormat: result.codeFormat)
            do {
                result.outcome = try guardian.maintain(
                    dictName, store: result.isMandarinPinyin ? store : nil, isCancelled: isCancelled)
            } catch {
                result.failure = error
            }
        }
        if !isCancelled(), let store {
            result.learnedLines = try? LearnedSnapshotExporter.export(
                from: store, to: configuration.rimeUserDataDir.appending(path: NoemaPaths.learnedTSVFileName))
        }
        return result
    }

    /// Phase 2 of `LegacyRootMigrator` for a built-in boot: merges the migrated Mandarin
    /// pinyin userdbs into `learning.sqlite`. A failure is retried on the next boot and never
    /// blocks this one.
    private func importLegacyUserDBs(_ configuration: RimeEngineConfiguration, _ migration: LegacyRootMigrator.PendingMigration?) {
        guard let migration, configuration.schemaSetID == .builtin else { return }
        let schemaID = configuration.schemaID
        let primary = isMandarinPinyinSchema(schemaID: schemaID) ? userDictName(schemaID: schemaID) : nil
        let names = migration.userDBs.filter { $0 == SchemaSetID.builtin.defaultSchemaID || $0 == primary }
        if names.isEmpty {
            if migration.filesComplete { LegacyRootMigrator.writeMarker(builtinDir: configuration.rimeUserDataDir) }
            return
        }
        guard let levers = RimeUserDictLevers() else { return }
        LegacyRootMigrator.importLegacyUserDBs(
            names, filesComplete: migration.filesComplete, root: configuration.userDataDir,
            builtinDir: configuration.rimeUserDataDir, levers: levers)
    }

    /// Creates a session (kept in `resources.session`, even when the schema will not
    /// select) and selects `schemaID`.
    func openSession(_ schemaID: String) -> SessionOpening {
        let session = api.pointee.create_session()
        guard session != 0 else { return SessionOpening(opened: false, isMandarinPinyin: false, secondaryInputRules: SecondaryInputRules()) }
        resources.session = session
        guard api.pointee.select_schema(session, schemaID) != 0 else {
            return SessionOpening(opened: false, isMandarinPinyin: false, secondaryInputRules: SecondaryInputRules())
        }
        var status = RimeStatus()
        noema_rime_status_init(&status)
        var reported: String?
        if api.pointee.get_status(session, &status) != 0 {
            reported = status.schema_id.map { String(cString: $0) }
            _ = api.pointee.free_status(&status)
        }
        let (isPinyin, rules) = classify(reported)
        return SessionOpening(opened: reported == schemaID, schemaID: reported, isMandarinPinyin: isPinyin, secondaryInputRules: rules)
    }

    /// `isMandarinPinyinSchema` and, for a pinyin schema, its `secondaryInputRules`.
    func classify(_ schemaID: String?) -> (isMandarinPinyin: Bool, rules: SecondaryInputRules) {
        guard let schemaID, isMandarinPinyinSchema(schemaID: schemaID) else { return (false, SecondaryInputRules()) }
        return (true, secondaryInputRules(schemaID: schemaID))
    }

    /// Runs `body` with traits whose C strings live exactly as long as the call.
    static func withTraits<T>(_ configuration: RimeEngineConfiguration, _ body: (inout RimeTraits) -> T) -> T {
        var traits = RimeTraits()
        noema_rime_traits_init(&traits)
        let sources: [String] = [
            configuration.sharedDataDir.path, configuration.rimeUserDataDir.path, "Noema", "noema",
            NoemaVersion.current.description, "rime.noema", configuration.logDir.path,
        ]
        // strdup only fails on allocation failure; treat that as fatal like any Swift allocation.
        let strings: [UnsafeMutablePointer<CChar>] = sources.map { source in
            guard let copy = strdup(source) else { fatalError("strdup failed") }
            return copy
        }
        defer { strings.forEach { free($0) } }
        traits.shared_data_dir = UnsafePointer(strings[0])
        traits.user_data_dir = UnsafePointer(strings[1])
        traits.distribution_name = UnsafePointer(strings[2])
        traits.distribution_code_name = UnsafePointer(strings[3])
        traits.distribution_version = UnsafePointer(strings[4])
        traits.app_name = UnsafePointer(strings[5])
        traits.log_dir = UnsafePointer(strings[6])
        traits.min_log_level = 2
        return body(&traits)
    }
}
