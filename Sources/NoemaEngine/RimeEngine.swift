import CRime
import Foundation
import NoemaCore
import NoemaLearning
import NoemaText

/// Where an engine finds its schemas and keeps its user data.
public struct RimeEngineConfiguration: Sendable, Hashable {
    public enum DeployPolicy: String, Sendable, Hashable, Codable {
        /// Deploy when `build/` fails `DeployManifest.validated` or its recorded inputs differ
        /// from the current files under `sharedDataDir` and the top-level user `*.custom.yaml`.
        case deployIfNeeded
        /// Always run an isolated deployment before loading.
        case forceDeploy
        /// Never deploy; a missing, incomplete, or tampered build enters Safe Mode
        /// (`engineInitFailed`).
        case neverDeploy
    }

    /// Read-only schema sources (`default.yaml`, `*.schema.yaml`, `*.dict.yaml`).
    public var sharedDataDir: URL
    /// Writable, single-writer root: the boot guard and its lock always live here. Without
    /// `schemaSetID` it is also librime's `user_data_dir` (`build/`, userdbs).
    public var userDataDir: URL
    public var logDir: URL
    public var schemaID: String
    public var deployPolicy: DeployPolicy
    /// Consecutive unfinished boots that put the next boot into Safe Mode.
    public var bootFailureThreshold: Int
    /// The `noema-rime-deployer` executable. Nil locates it next to the main executable
    /// (`NoemaIME.app/Contents/MacOS`) or, for SwiftPM test bundles, in the build directory
    /// holding the `.xctest` bundle.
    public var deployerURL: URL?
    /// How long a deployment subprocess may run before it is terminated.
    public var deployTimeout: Duration
    /// The schema set to run. Set: librime's `user_data_dir` is `<userDataDir>/sets/<set>/`,
    /// isolated from every other set, under the one root lock. Nil: `userDataDir` itself.
    public var schemaSetID: SchemaSetID?
    /// `noema_learned.lua`, passed to the deployer as `--lua-file` and copied to
    /// `<rimeUserDataDir>/lua/`. Nil: no learned-phrase translator.
    public var luaFile: URL?
    /// The standard OpenCC data (`s2t.json`, `STCharacters.ocd2`, …), exported as
    /// `OPENCC_DATA_DIR` before librime initializes and to the deployer, so a schema set whose
    /// `opencc/` lacks a standard config still converts. librime's `Simplifier` first tries
    /// `<user_data_dir>/opencc/` and `<shared_data_dir>/opencc/`, so a pack's own files win;
    /// OpenCC consults `OPENCC_DATA_DIR` last, for the config file only (its dictionaries
    /// resolve beside the config). Nil: `bundledOpenCCDataDir()`, without overriding an
    /// `OPENCC_DATA_DIR` the process already has. Ignored unless a real directory.
    public var openccDataDir: URL?

    /// `<bundle resources>/opencc` (`NoemaIME.app/Contents/Resources/opencc`) when it is a
    /// real directory, else nil.
    public static func bundledOpenCCDataDir(bundle: Bundle = .main) -> URL? {
        guard let resources = bundle.resourceURL else { return nil }
        let directory = resources.appending(path: "opencc", directoryHint: .isDirectory)
        return FileSafety.isRealDirectory(directory) ? directory : nil
    }

    /// The OpenCC directory to export and whether it overrides an inherited `OPENCC_DATA_DIR`:
    /// an explicit real `openccDataDir` does, the bundled fallback does not.
    var effectiveOpenCCDataDir: (url: URL, overriding: Bool)? {
        if let openccDataDir, FileSafety.isRealDirectory(openccDataDir) { return (openccDataDir, true) }
        return Self.bundledOpenCCDataDir().map { ($0, false) }
    }

    /// Exports `effectiveOpenCCDataDir` as `OPENCC_DATA_DIR` in this process, calling
    /// `setenv` only when the value changes.
    func exportOpenCCDataDir() {
        guard let (url, overriding) = effectiveOpenCCDataDir else { return }
        let current = getenv(Self.openccDataDirVariable).map { String(cString: $0) }
        guard current != url.path, overriding || current == nil else { return }
        setenv(Self.openccDataDirVariable, url.path, 1)
    }

    public static let openccDataDirVariable = "OPENCC_DATA_DIR"

    /// librime's `user_data_dir`: `<userDataDir>/sets/<set>/` or `userDataDir`.
    public var rimeUserDataDir: URL {
        schemaSetID.map { NoemaPaths.schemaSetUserDataDir($0, root: userDataDir) } ?? userDataDir
    }

    public init(
        sharedDataDir: URL,
        userDataDir: URL,
        logDir: URL,
        schemaID: String = "noema_pinyin",
        deployPolicy: DeployPolicy = .deployIfNeeded,
        bootFailureThreshold: Int = 2,
        deployerURL: URL? = nil,
        deployTimeout: Duration = .seconds(60),
        schemaSetID: SchemaSetID? = nil,
        luaFile: URL? = nil,
        openccDataDir: URL? = nil
    ) {
        self.openccDataDir = openccDataDir
        self.sharedDataDir = sharedDataDir
        self.userDataDir = userDataDir
        self.logDir = logDir
        self.schemaID = schemaID
        self.deployPolicy = deployPolicy
        self.bootFailureThreshold = bootFailureThreshold
        self.deployerURL = deployerURL
        self.deployTimeout = deployTimeout
        self.schemaSetID = schemaSetID
        self.luaFile = luaFile
    }
}

/// `TypingEngine` over the in-process librime.
///
/// Boot: claim the process-wide librime (a second live engine throws), take the
/// user-data `flock`, arm the boot-guard sentinel, deploy if needed through the
/// `noema-rime-deployer` subprocess (see `RimeEngine+Deploy.swift`), initialize, open a
/// session on `schemaID`, then disarm. A built-in boot first migrates a pre-schema-set root
/// (`LegacyRootMigrator`). librime's deployer never runs in this process;
/// `start(configuration:cancellation:)` waits for it off the main actor. Any refusal or failure on that path leaves the
/// engine in Safe Mode: it releases librime, the lock, and the claim, makes no further
/// librime calls, and answers every key with `handled: false` and `.safeMode`.
///
/// Every call that can commit drains `RimeCommit`, and every call rebuilds
/// `currentState` from `RimeContext` and `RimeStatus`, freeing each struct before return.
@MainActor
public final class RimeEngine: TypingEngine {
    /// Changes only through `switchSchemaSet`.
    public internal(set) var configuration: RimeEngineConfiguration
    public private(set) var currentState: CompositionState {
        didSet { noteSegmentedPreedit() }
    }
    public var isSafeMode: Bool { currentState.isSafeMode }
    public var safeModeReason: SafeModeReason? { currentState.safeModeReason }
    public private(set) var isShutDown = false

    let resources: RimeEngineResources
    let api: UnsafeMutablePointer<RimeApi>
    private var generation: UInt64 = 0
    /// True while `switchSchemaSet` runs; a second switch is refused meanwhile.
    var isSwitchingSchemaSet = false
    /// Whether the live schema spells Mandarin pinyin (`isMandarinPinyinSchema(schemaID:)`),
    /// for `cachedSchemaID`. Recomputed when a session opens and whenever `refreshState`
    /// sees another schema (librime's own schema switcher); false until then (fail-closed).
    public private(set) var currentSchemaIsMandarinPinyin = false
    /// The live schema's reverse-lookup and recognizer rules (`secondaryInputRules(schemaID:)`),
    /// cached with `currentSchemaIsMandarinPinyin`; empty for a schema that is not pinyin.
    private(set) var currentSecondaryInputRules = SecondaryInputRules()
    private var cachedSchemaID: String?

    /// Whether `rawInput` went to the live schema's primary Mandarin pinyin translator, so its
    /// commit may be learned: the schema spells Mandarin pinyin, and the input neither starts
    /// with a reverse-lookup or other secondary translator's prefix (薄荷's `Uw` for Wubi 98)
    /// nor ends in a `recognizer/patterns` match (`currentSecondaryInputRules`).
    public func isPrimaryPinyinInput(_ rawInput: String) -> Bool {
        currentSchemaIsMandarinPinyin && !currentSecondaryInputRules.claims(rawInput)
    }

    /// Called on the main actor after every call that committed text containing a Han
    /// character, with the raw input and preedit captured before the call changed them.
    /// Keep it cheap: `recordCommits(to:)` installs one that only enqueues.
    public var onCommitObservation: (@MainActor (CommitObservation) -> Void)?

    /// Sends every Han commit to `writer` without blocking (nil stops recording). Nothing is
    /// recorded while `isSecureInputEnabled()` is true (pass `IsSecureEventInputEnabled`):
    /// defense in depth, since the shell already passes secure keys through unseen.
    public func recordCommits(
        to writer: LearningStoreWriter?, isSecureInputEnabled: @escaping @MainActor () -> Bool = { false }
    ) {
        guard let writer else {
            onCommitObservation = nil
            return
        }
        onCommitObservation = { observation in
            guard !isSecureInputEnabled() else { return }
            writer.enqueue(LearningCommitEvent(observation: observation))
        }
    }

    /// Throws `.engineUnavailable` when librime lacks a required API member or another
    /// `RimeEngine` in this process has not been shut down. Every other failure enters
    /// Safe Mode instead of throwing. A needed deployment blocks the caller for up to
    /// `deployTimeout`; `start(configuration:cancellation:)` runs it off the main actor.
    public convenience init(configuration: RimeEngineConfiguration) throws(NoemaError) {
        try self.init(claiming: configuration)
        boot(clearingSentinel: false)
    }

    /// Boots like `init(configuration:)`, but runs `prepareBuild` (the manifest check and
    /// any `noema-rime-deployer` run, which make no librime call) on a global queue, so the
    /// main actor keeps serving events. Locking, arming, `initialize`, and the session stay
    /// on the main actor. A Safe Mode decision returns at once with no background work.
    ///
    /// Cancelling the task, or `cancellation`, stops the deployer (SIGTERM, then SIGKILL)
    /// and throws `.engineUnavailable(reason: "boot cancelled")` after disarming the
    /// sentinel (a cancelled boot is not a crash) and releasing the lock and the claim;
    /// `build/` is left as it was. `cancellation.cancelAndFinishCleanup` does all of that
    /// before it returns, on the caller's main-actor stack, without waiting for this task.
    public static func start(
        configuration: RimeEngineConfiguration,
        cancellation: DeployCancellation = DeployCancellation()
    ) async throws(NoemaError) -> RimeEngine {
        let engine = try RimeEngine(claiming: configuration)
        // Cancelled before boot: touch no boot guard and spawn no deployer.
        if cancellation.isCancelled || Task.isCancelled {
            engine.abandonBoot()
            throw .engineUnavailable(reason: "boot cancelled")
        }
        guard engine.beginBoot(clearingSentinel: false) else { return engine }
        guard cancellation.registerAbandon({ engine.abandonBoot() }) else {
            engine.abandonBoot()
            throw .engineUnavailable(reason: "boot cancelled")
        }
        let (prepared, migration) = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<(Bool, LegacyRootMigrator.PendingMigration?), Never>) in
                guard let group = cancellation.enterPrepare() else {
                    continuation.resume(returning: (false, nil))
                    return
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    let migration = migrateLegacyRootFiles(configuration)
                    let ok = prepareBuild(configuration: configuration, cancellation: cancellation)
                    // Only after prepareBuild returned: its staging directory is gone.
                    cancellation.leavePrepare(group)
                    continuation.resume(returning: (ok, migration))
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        cancellation.clearAbandon()
        if cancellation.isCancelled || Task.isCancelled || engine.isShutDown {
            engine.abandonBoot()
            throw .engineUnavailable(reason: "boot cancelled")
        }
        engine.finishBoot(prepared: prepared, migration: migration)
        return engine
    }

    /// Checks the API table and claims librime; boots nothing.
    private init(claiming configuration: RimeEngineConfiguration) throws(NoemaError) {
        guard noema_rime_engine_api_available(), let api = noema_rime_get_api() else {
            throw .engineUnavailable(reason: "librime API table lacks members RimeEngine requires")
        }
        let resources = RimeEngineResources(
            bootGuard: BootGuard(userDataDir: configuration.userDataDir, threshold: configuration.bootFailureThreshold)
        )
        try RimeProcessLifecycle.claim(resources.owner)
        self.configuration = configuration
        self.api = api
        self.resources = resources
        self.currentState = .empty(schemaID: configuration.schemaID)
    }

    // MARK: - TypingEngine

    public func processKey(_ event: KeyEvent) -> KeyHandlingResult {
        if let degraded = degradedResult() { return degraded }
        let wasComposing = currentState.isComposing
        let mapped = RimeKeyMapper.map(event, isComposing: wasComposing, isASCIIMode: currentState.isASCIIMode)
        guard case .rime(let keycode, let mask) = mapped else {
            return KeyHandlingResult(handled: false, state: currentState)
        }
        guard ensureSession() else { return unavailableResult() }
        let before = captureBeforeCommit()
        var handled = api.pointee.process_key(resources.session, keycode, mask) != 0
        let committed = drainCommit()
        var state = refreshState()
        reportCommit(committed, before: before)
        // Escape must never leave a composition open while reporting the key unhandled.
        if !handled, wasComposing, state.isComposing, keycode == RimeKeyMapper.Keysym.escape {
            api.pointee.clear_composition(resources.session)
            state = refreshState()
            handled = true
        }
        // librime's answer stands even when it committed: an editor's DirectCommit commits
        // the composition and rejects the key, which the client must then still receive.
        return KeyHandlingResult(handled: handled, committedText: committed, state: state)
    }

    public func selectCandidate(at index: Int) -> KeyHandlingResult {
        if let degraded = degradedResult() { return degraded }
        guard currentState.candidates.indices.contains(index) else {
            return KeyHandlingResult(handled: false, state: currentState)
        }
        guard ensureSession() else { return unavailableResult() }
        let before = captureBeforeCommit()
        let selected = api.pointee.select_candidate_on_current_page(resources.session, index) != 0
        let committed = drainCommit()
        let state = refreshState()
        reportCommit(committed, before: before)
        return KeyHandlingResult(handled: selected, committedText: committed, state: state)
    }

    @discardableResult
    public func highlightCandidate(at index: Int) -> CompositionState {
        guard isOperational, currentState.candidates.indices.contains(index), ensureSession() else { return currentState }
        _ = api.pointee.highlight_candidate_on_current_page(resources.session, index)
        return refreshState()
    }

    @discardableResult
    public func changePage(backward: Bool) -> CompositionState {
        guard isOperational, currentState.isComposing, ensureSession() else { return currentState }
        _ = api.pointee.change_page(resources.session, backward ? 1 : 0)
        return refreshState()
    }

    @discardableResult
    public func setASCIIMode(_ enabled: Bool) -> CompositionState {
        guard isOperational, ensureSession() else { return currentState }
        api.pointee.set_option(resources.session, "ascii_mode", enabled ? 1 : 0)
        return refreshState()
    }

    public func commitComposition() -> KeyHandlingResult {
        if let degraded = degradedResult() { return degraded }
        guard currentState.isComposing else { return KeyHandlingResult(handled: false, state: currentState) }
        guard ensureSession() else { return unavailableResult() }
        let before = captureBeforeCommit()
        _ = api.pointee.commit_composition(resources.session)
        let committed = drainCommit()
        let state = refreshState()
        reportCommit(committed, before: before)
        return KeyHandlingResult(handled: committed != nil, committedText: committed, state: state)
    }

    @discardableResult
    public func clearComposition() -> CompositionState {
        guard isOperational, ensureSession() else { return currentState }
        api.pointee.clear_composition(resources.session)
        return refreshState()
    }

    public func resetSession() {
        guard isOperational else { return }
        if resources.session != 0 {
            _ = api.pointee.destroy_session(resources.session)
            resources.session = 0
        }
        guard openSession() else {
            enterSafeMode(.engineInitFailed)
            return
        }
        refreshState()
    }

    // MARK: - Lifecycle

    /// Leaves Safe Mode: clears the boot-guard sentinel under the lock and boots again.
    /// Returns true when the engine is operational afterwards.
    @discardableResult
    public func recoverFromSafeMode() -> Bool {
        guard !isShutDown else { return false }
        guard isSafeMode else { return true }
        do {
            try RimeProcessLifecycle.claim(resources.owner)
        } catch {
            return false
        }
        boot(clearingSentinel: true)
        return !isSafeMode
    }

    /// Destroys the session, finalizes librime, and releases the lock and the process
    /// claim, so another engine may start. Idempotent.
    public func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        resources.releaseAll()
        currentState = .empty(generationID: nextGeneration(), schemaID: configuration.schemaID)
    }

    // MARK: - Boot

    var isOperational: Bool { !isShutDown && !isSafeMode }

    private func boot(clearingSentinel: Bool) {
        guard beginBoot(clearingSentinel: clearingSentinel) else { return }
        let migration = Self.migrateLegacyRootFiles(configuration)
        finishBoot(
            prepared: Self.prepareBuild(configuration: configuration, cancellation: DeployCancellation()), migration: migration)
    }

    /// Phase 1 of `LegacyRootMigrator` for a built-in boot, under the root lock and before
    /// `prepareBuild`, so the first deployment compiles the migrated `*.custom.yaml`. Makes
    /// no librime call.
    nonisolated static func migrateLegacyRootFiles(_ configuration: RimeEngineConfiguration) -> LegacyRootMigrator.PendingMigration? {
        guard configuration.schemaSetID == .builtin else { return nil }
        return LegacyRootMigrator.migrateFilesIfNeeded(root: configuration.userDataDir, builtinDir: configuration.rimeUserDataDir)
    }

    /// Phase 2 of `LegacyRootMigrator`, in the quiescent window after `initialize` and before
    /// the first session: merges the migrated Mandarin pinyin userdbs into `learning.sqlite`.
    /// A failure is retried on the next boot and never blocks this one.
    private func importLegacyUserDBs(_ migration: LegacyRootMigrator.PendingMigration?) {
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

    /// Creates the directories, takes the lock, and arms the sentinel. False means the
    /// engine is already in Safe Mode and must not deploy.
    private func beginBoot(clearingSentinel: Bool) -> Bool {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: configuration.userDataDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: configuration.rimeUserDataDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: configuration.logDir, withIntermediateDirectories: true)
        } catch {
            enterSafeMode(.userDataDirUnwritable)
            return false
        }
        let guardian = resources.bootGuard
        if clearingSentinel {
            switch guardian.acquireLock() {
            case .acquired: guardian.clear()
            case .locked:
                enterSafeMode(.userDataDirLocked)
                return false
            case .failed(let reason):
                enterSafeMode(reason)
                return false
            }
        }
        switch guardian.begin() {
        case .proceed: return true
        case .locked: enterSafeMode(.userDataDirLocked)
        case .enterSafeMode(let reason): enterSafeMode(reason)
        }
        return false
    }

    /// After `prepareBuild`: initialize librime, open the session, and disarm, or enter
    /// Safe Mode with the sentinel left armed.
    private func finishBoot(prepared: Bool, migration: LegacyRootMigrator.PendingMigration? = nil) {
        guard prepared else { return enterSafeMode(.engineInitFailed) }
        configuration.exportOpenCCDataDir()
        withTraits { traits in
            RimeProcessLifecycle.setupIfNeeded(owner: resources.owner, api: api, traits: &traits)
            api.pointee.initialize(&traits)
        }
        resources.isInitialized = true
        importLegacyUserDBs(migration)
        guard openSession() else { return enterSafeMode(.engineInitFailed) }
        resources.bootGuard.disarm()
        refreshState()
    }

    /// A cancelled boot: disarm (cancellation is not a crash), release everything, and shut down.
    /// Idempotent: `cancelAndFinishCleanup` may already have run it.
    private func abandonBoot() {
        guard !isShutDown else { return }
        isShutDown = true
        resources.bootGuard.disarm()
        resources.releaseAll()
        currentState = .empty(generationID: nextGeneration(), schemaID: configuration.schemaID)
    }

    func openSession() -> Bool {
        let session = api.pointee.create_session()
        guard session != 0 else { return false }
        resources.session = session
        guard api.pointee.select_schema(session, configuration.schemaID) != 0 else { return false }
        let schemaID = readStatus().schemaID
        // A new session may run another set's build under the same schema ID: always re-classify.
        noteSchema(schemaID, force: true)
        return schemaID == configuration.schemaID
    }

    /// Re-classifies the live schema when it is not `cachedSchemaID` (or with `force`).
    private func noteSchema(_ schemaID: String?, force: Bool = false) {
        guard force || schemaID != cachedSchemaID else { return }
        cachedSchemaID = schemaID
        currentSchemaIsMandarinPinyin = schemaID.map { isMandarinPinyinSchema(schemaID: $0) } ?? false
        currentSecondaryInputRules = currentSchemaIsMandarinPinyin
            ? schemaID.map { secondaryInputRules(schemaID: $0) } ?? SecondaryInputRules() : SecondaryInputRules()
    }

    /// Recreates the session if librime dropped it (e.g. stale-session cleanup).
    private func ensureSession() -> Bool {
        if resources.session != 0, api.pointee.find_session(resources.session) != 0 { return true }
        resources.session = 0
        if openSession() { return true }
        enterSafeMode(.engineInitFailed)
        return false
    }

    func enterSafeMode(_ reason: SafeModeReason) {
        // Releases librime, the lock, and the claim; Safe Mode makes no librime calls.
        resources.releaseAll()
        currentState = .empty(generationID: nextGeneration(), schemaID: configuration.schemaID, safeModeReason: reason)
    }

    /// Runs `body` with traits whose C strings live exactly as long as the call.
    func withTraits<T>(_ body: (inout RimeTraits) -> T) -> T {
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

    // MARK: - Reading librime state

    private func nextGeneration() -> UInt64 {
        generation &+= 1
        return generation
    }

    private func degradedResult() -> KeyHandlingResult? {
        if isShutDown {
            return KeyHandlingResult(handled: false, state: currentState, degradation: .engineUnavailable)
        }
        if isSafeMode {
            return KeyHandlingResult(handled: false, state: currentState, degradation: .safeMode)
        }
        return nil
    }

    private func unavailableResult() -> KeyHandlingResult {
        KeyHandlingResult(handled: false, state: currentState, degradation: .safeMode)
    }

    /// The latest all-pinyin preedit of the current composition (`ni hao shi jie`) and the
    /// raw input it spelled, kept while a commit is observed: after a partial selection the
    /// preedit reads `你好shi jie` and no longer spells the whole raw input, so the commit
    /// that finishes the composition takes its syllable breaks from here. Dropped when
    /// composing ends and as soon as the raw input changes under a Han preedit (the user
    /// edited the rest after the selection: `你好shi jian` must not reuse `shi jie`).
    private var lastSegmentedPreedit: (rawInput: String, preedit: String)?

    private func noteSegmentedPreedit() {
        guard onCommitObservation != nil, currentState.isComposing else {
            lastSegmentedPreedit = nil
            return
        }
        let raw = noema_rime_get_input(resources.session).map { String(cString: $0) } ?? ""
        let preedit = currentState.preedit
        if !TextNormalization.containsHanCharacters(preedit), !TextNormalization.tonelessPinyinKey(preedit).isEmpty {
            lastSegmentedPreedit = (raw, preedit)
        } else if lastSegmentedPreedit?.rawInput != raw {
            lastSegmentedPreedit = nil
        }
    }

    /// The raw input and preedit before a call that may commit; nil when nobody observes.
    /// A preedit holding Han characters from a partial selection is replaced by the last
    /// all-pinyin preedit only when that preedit spelled this very raw input; otherwise an
    /// empty preedit goes out so `LearningCommitEvent.normalized` never pairs the tail's
    /// syllables with the committed Han characters and instead verifies `rawInput`.
    private func captureBeforeCommit() -> (rawInput: String, preedit: String)? {
        guard onCommitObservation != nil else { return nil }
        let raw = noema_rime_get_input(resources.session).map { String(cString: $0) } ?? ""
        let preedit = currentState.preedit
        if TextNormalization.containsHanCharacters(preedit) {
            if let segmented = lastSegmentedPreedit, segmented.rawInput == raw {
                return (raw, segmented.preedit)
            }
            return (raw, "")
        }
        return (raw, preedit)
    }

    private func reportCommit(_ committed: String?, before: (rawInput: String, preedit: String)?) {
        guard let before, let committed, let observer = onCommitObservation,
              !before.rawInput.isEmpty, TextNormalization.containsHanCharacters(committed)
        else { return }
        observer(CommitObservation(
            rawInput: before.rawInput, preedit: before.preedit, committedText: committed, schemaID: currentState.schemaID,
            isMandarinPinyinSchema: isPrimaryPinyinInput(before.rawInput)))
    }

    private func drainCommit() -> String? {
        var commit = RimeCommit()
        noema_rime_commit_init(&commit)
        guard api.pointee.get_commit(resources.session, &commit) != 0 else { return nil }
        defer { _ = api.pointee.free_commit(&commit) }
        guard let text = commit.text else { return nil }
        let string = String(cString: text)
        return string.isEmpty ? nil : string
    }

    private struct StatusSnapshot {
        var schemaID: String?
        var isComposing = false
        var isASCIIMode = false
    }

    private func readStatus() -> StatusSnapshot {
        var status = RimeStatus()
        noema_rime_status_init(&status)
        guard api.pointee.get_status(resources.session, &status) != 0 else { return StatusSnapshot() }
        defer { _ = api.pointee.free_status(&status) }
        return StatusSnapshot(
            schemaID: status.schema_id.map { String(cString: $0) },
            isComposing: status.is_composing != 0,
            isASCIIMode: status.is_ascii_mode != 0
        )
    }

    /// The label of candidate `index`: the schema's `alternative_select_labels` slot,
    /// else its select key, else its 1-based number (the tenth shows as 0). librime allocates
    /// `select_labels` with `page_size` slots, not `num_candidates`, so a slot at or past
    /// `pageSize` (clamped at 0) is never read.
    nonisolated static func candidateLabel(
        at index: Int,
        selectLabels: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
        pageSize: Int,
        selectKeys: [Character]
    ) -> String {
        if let selectLabels, index >= 0, index < max(pageSize, 0), let text = selectLabels[index] {
            return String(cString: text)
        }
        if selectKeys.indices.contains(index) { return String(selectKeys[index]) }
        return String(index + 1 == 10 ? 0 : index + 1)
    }

    @discardableResult
    func refreshState() -> CompositionState {
        let status = readStatus()
        noteSchema(status.schemaID)
        var context = RimeContext()
        noema_rime_context_init(&context)
        let generationID = nextGeneration()
        guard api.pointee.get_context(resources.session, &context) != 0 else {
            currentState = .empty(generationID: generationID, isASCIIMode: status.isASCIIMode, schemaID: status.schemaID)
            return currentState
        }
        defer { _ = api.pointee.free_context(&context) }

        let preedit = context.composition.preedit.map { String(cString: $0) } ?? ""
        let caret = UTF8OffsetConverter.offset(in: preedit, fromUTF8ByteOffset: Int(context.composition.cursor_pos))
        let selection = UTF8OffsetConverter.ranges(
            in: preedit,
            utf8Start: Int(context.composition.sel_start),
            utf8End: Int(context.composition.sel_end)
        )

        let menu = context.menu
        var candidates: [CandidateItem] = []
        if menu.num_candidates > 0, let items = menu.candidates {
            let count = Int(menu.num_candidates)
            let pageSize = Int(menu.page_size)
            let selectKeys = menu.select_keys.map { Array(String(cString: $0)) } ?? []
            candidates.reserveCapacity(count)
            for index in 0..<count {
                let item = items[index]
                candidates.append(CandidateItem(
                    text: item.text.map { String(cString: $0) } ?? "",
                    comment: item.comment.map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 },
                    label: Self.candidateLabel(
                        at: index, selectLabels: context.select_labels, pageSize: pageSize, selectKeys: selectKeys)
                ))
            }
        }

        currentState = CompositionState(
            preedit: preedit,
            caretUTF8Offset: caret.utf8,
            caretUTF16Offset: caret.utf16,
            selectionUTF8Range: selection.utf8,
            selectionUTF16Range: selection.utf16,
            commitTextPreview: context.commit_text_preview.map { String(cString: $0) },
            candidates: candidates,
            highlightedIndex: candidates.isEmpty ? nil : Int(menu.highlighted_candidate_index),
            pageIndex: Int(menu.page_no),
            pageSize: Int(menu.page_size),
            isLastPage: candidates.isEmpty || menu.is_last_page != 0,
            isComposing: status.isComposing || !preedit.isEmpty,
            isASCIIMode: status.isASCIIMode,
            schemaID: status.schemaID,
            generationID: generationID
        )
        return currentState
    }
}
