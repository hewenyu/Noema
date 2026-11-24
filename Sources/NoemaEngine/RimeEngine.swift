import CRime
import Foundation
import NoemaCore

/// Where an engine finds its schemas and keeps its user data.
public struct RimeEngineConfiguration: Sendable, Hashable {
    public enum DeployPolicy: String, Sendable, Hashable, Codable {
        /// Deploy when the staged build is missing or older than any shared YAML file.
        case deployIfNeeded
        /// Always run a workspace deployment before loading.
        case forceDeploy
        /// Never deploy; a missing build enters Safe Mode (`engineInitFailed`).
        case neverDeploy
    }

    /// Read-only schema sources (`default.yaml`, `*.schema.yaml`, `*.dict.yaml`).
    public var sharedDataDir: URL
    /// Writable, single-writer Rime user data: `build/`, userdbs, the boot guard.
    public var userDataDir: URL
    public var logDir: URL
    public var schemaID: String
    public var deployPolicy: DeployPolicy
    /// Consecutive unfinished boots that put the next boot into Safe Mode.
    public var bootFailureThreshold: Int

    public init(
        sharedDataDir: URL,
        userDataDir: URL,
        logDir: URL,
        schemaID: String = "noema_pinyin",
        deployPolicy: DeployPolicy = .deployIfNeeded,
        bootFailureThreshold: Int = 2
    ) {
        self.sharedDataDir = sharedDataDir
        self.userDataDir = userDataDir
        self.logDir = logDir
        self.schemaID = schemaID
        self.deployPolicy = deployPolicy
        self.bootFailureThreshold = bootFailureThreshold
    }
}

/// `TypingEngine` over the in-process librime.
///
/// Boot: claim the process-wide librime (a second live engine throws), take the
/// user-data `flock`, arm the boot-guard sentinel, deploy if needed, initialize, open a
/// session on `schemaID`, then disarm. Any refusal or failure on that path leaves the
/// engine in Safe Mode: it releases librime, the lock, and the claim, makes no further
/// librime calls, and answers every key with `handled: false` and `.safeMode`.
///
/// Every call that can commit drains `RimeCommit`, and every call rebuilds
/// `currentState` from `RimeContext` and `RimeStatus`, freeing each struct before return.
@MainActor
public final class RimeEngine: TypingEngine {
    public let configuration: RimeEngineConfiguration
    public private(set) var currentState: CompositionState
    public var isSafeMode: Bool { currentState.isSafeMode }
    public var safeModeReason: SafeModeReason? { currentState.safeModeReason }
    public private(set) var isShutDown = false

    private let resources: RimeEngineResources
    private let api: UnsafeMutablePointer<RimeApi>
    private var generation: UInt64 = 0

    /// Throws `.engineUnavailable` when librime lacks a required API member or another
    /// `RimeEngine` in this process has not been shut down. Every other failure enters
    /// Safe Mode instead of throwing.
    public init(configuration: RimeEngineConfiguration) throws(NoemaError) {
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
        boot(clearingSentinel: false)
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
        var handled = api.pointee.process_key(resources.session, keycode, mask) != 0
        let committed = drainCommit()
        var state = refreshState()
        // Escape must never leave a composition open while reporting the key unhandled.
        if !handled, wasComposing, state.isComposing, keycode == RimeKeyMapper.Keysym.escape {
            api.pointee.clear_composition(resources.session)
            state = refreshState()
            handled = true
        }
        return KeyHandlingResult(handled: handled || committed != nil, committedText: committed, state: state)
    }

    public func selectCandidate(at index: Int) -> KeyHandlingResult {
        if let degraded = degradedResult() { return degraded }
        guard currentState.candidates.indices.contains(index) else {
            return KeyHandlingResult(handled: false, state: currentState)
        }
        guard ensureSession() else { return unavailableResult() }
        let selected = api.pointee.select_candidate_on_current_page(resources.session, index) != 0
        let committed = drainCommit()
        return KeyHandlingResult(handled: selected, committedText: committed, state: refreshState())
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
        _ = api.pointee.commit_composition(resources.session)
        let committed = drainCommit()
        return KeyHandlingResult(handled: committed != nil, committedText: committed, state: refreshState())
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

    private var isOperational: Bool { !isShutDown && !isSafeMode }

    private func boot(clearingSentinel: Bool) {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: configuration.userDataDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: configuration.logDir, withIntermediateDirectories: true)
        } catch {
            return enterSafeMode(.userDataDirUnwritable)
        }
        let guardian = resources.bootGuard
        if clearingSentinel {
            switch guardian.acquireLock() {
            case .acquired: guardian.clear()
            case .locked: return enterSafeMode(.userDataDirLocked)
            case .failed(let reason): return enterSafeMode(reason)
            }
        }
        switch guardian.begin() {
        case .proceed: break
        case .locked: return enterSafeMode(.userDataDirLocked)
        case .enterSafeMode(let reason): return enterSafeMode(reason)
        }

        let loaded = withTraits { traits -> Bool in
            RimeProcessLifecycle.setupIfNeeded(owner: resources.owner, api: api, traits: &traits)
            api.pointee.deployer_initialize(&traits)
            if needsDeploy(), configuration.deployPolicy != .neverDeploy {
                guard api.pointee.deploy() != 0 else {
                    api.pointee.finalize()
                    return false
                }
            }
            guard isBuildComplete() else {
                api.pointee.finalize()
                return false
            }
            api.pointee.initialize(&traits)
            resources.isInitialized = true
            return true
        }
        guard loaded, openSession() else { return enterSafeMode(.engineInitFailed) }
        guardian.disarm()
        refreshState()
    }

    private func openSession() -> Bool {
        let session = api.pointee.create_session()
        guard session != 0 else { return false }
        resources.session = session
        guard api.pointee.select_schema(session, configuration.schemaID) != 0 else { return false }
        return readStatus().schemaID == configuration.schemaID
    }

    /// Recreates the session if librime dropped it (e.g. stale-session cleanup).
    private func ensureSession() -> Bool {
        if resources.session != 0, api.pointee.find_session(resources.session) != 0 { return true }
        resources.session = 0
        if openSession() { return true }
        enterSafeMode(.engineInitFailed)
        return false
    }

    private func enterSafeMode(_ reason: SafeModeReason) {
        // Releases librime, the lock, and the claim; Safe Mode makes no librime calls.
        resources.releaseAll()
        currentState = .empty(generationID: nextGeneration(), schemaID: configuration.schemaID, safeModeReason: reason)
    }

    /// Staged outputs the schema needs, relative to `user_data_dir/build`.
    private var stagedFiles: [String] { ["default.yaml", "\(configuration.schemaID).schema.yaml"] }

    private func isBuildComplete() -> Bool {
        let build = configuration.userDataDir.appending(path: "build")
        return stagedFiles.allSatisfy { FileManager.default.fileExists(atPath: build.appending(path: $0).path) }
    }

    private func needsDeploy() -> Bool {
        if configuration.deployPolicy == .forceDeploy || !isBuildComplete() { return true }
        let fileManager = FileManager.default
        let build = configuration.userDataDir.appending(path: "build")
        func modified(_ url: URL) -> Date? {
            (try? fileManager.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }
        let staged = stagedFiles.compactMap { modified(build.appending(path: $0)) }
        guard staged.count == stagedFiles.count, let oldestStaged = staged.min() else { return true }
        let sources = (try? fileManager.contentsOfDirectory(
            at: configuration.sharedDataDir, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return sources.contains { url in
            url.pathExtension == "yaml" && (modified(url).map { $0 > oldestStaged } ?? true)
        }
    }

    /// Runs `body` with traits whose C strings live exactly as long as the call.
    private func withTraits<T>(_ body: (inout RimeTraits) -> T) -> T {
        var traits = RimeTraits()
        noema_rime_traits_init(&traits)
        let sources: [String] = [
            configuration.sharedDataDir.path, configuration.userDataDir.path, "Noema", "noema",
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

    @discardableResult
    private func refreshState() -> CompositionState {
        let status = readStatus()
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
            let selectKeys = menu.select_keys.map { Array(String(cString: $0)) } ?? []
            candidates.reserveCapacity(count)
            for index in 0..<count {
                let item = items[index]
                var label: String?
                if let labels = context.select_labels, let text = labels[index] {
                    label = String(cString: text)
                } else if index < selectKeys.count {
                    label = String(selectKeys[index])
                } else {
                    label = String(index + 1 == 10 ? 0 : index + 1)
                }
                candidates.append(CandidateItem(
                    text: item.text.map { String(cString: $0) } ?? "",
                    comment: item.comment.map { String(cString: $0) }.flatMap { $0.isEmpty ? nil : $0 },
                    label: label
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
