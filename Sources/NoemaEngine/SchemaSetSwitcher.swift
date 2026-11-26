import Foundation
import NoemaCore
import NoemaLearning

extension RimeEngineConfiguration {
    /// The configuration the input method boots: the set and schema of
    /// `<root>/active-schema-set.json` when that set is installed (`NoemaPaths.installedSchemaDir`),
    /// else the built-in set. Every set, the built-in one included, runs in its own
    /// `<root>/sets/<set>/` with `luaFile` as its learned-phrase translator.
    public static func activeSchemaSet(
        root: URL, builtinSharedDataDir: URL, logDir: URL, luaFile: URL?, deployerURL: URL? = nil,
        openccDataDir: URL? = nil
    ) -> RimeEngineConfiguration {
        var set = SchemaSetID.builtin
        var schemaID = SchemaSetID.builtin.defaultSchemaID
        var shared = builtinSharedDataDir
        if let record = ActiveSchemaSetRecord.load(from: NoemaPaths.activeSchemaSetURL(root: root)),
           let directory = NoemaPaths.installedSchemaDir(
               record.schemaSetID, schemaID: record.schemaID, root: root, builtinSharedDataDir: builtinSharedDataDir) {
            set = record.schemaSetID
            schemaID = record.schemaID
            shared = directory
        }
        return RimeEngineConfiguration(
            sharedDataDir: shared, userDataDir: root, logDir: logDir, schemaID: schemaID, deployerURL: deployerURL,
            schemaSetID: set, luaFile: luaFile, openccDataDir: openccDataDir)
    }
}

/// Runs the schema-set switches the agent requests inside the input method, without ever
/// destroying the user's composition and without blocking typing.
///
/// - A request that arrives mid-composition is parked and reported `.pendingIdle`; the
///   next composition change that leaves nothing composing (`compositionDidChange`) starts it.
///   A newer request replaces a parked one, which is reported `.failed` ("superseded").
/// - A started switch reports `.compiling` while `RimeEngine.switchSchemaSet` prepares and
///   deploys the target off the main actor; the current set keeps serving keys meanwhile.
///   If the user is composing again when the build is ready, it reports `.pendingIdle` and
///   waits for the next idle boundary before the quiescent step, which runs off the main
///   actor while every key passes through.
/// - `.ready` once the engine runs the target; `.failed` (with the reason) when it cannot,
///   and the previous set keeps running with its `build/` untouched.
@MainActor
public final class SchemaSetSwitcher {
    public struct Request: Sendable, Hashable {
        public var requestID: UUID
        public var schemaSetID: SchemaSetID
        public var schemaID: String?

        public init(requestID: UUID = UUID(), schemaSetID: SchemaSetID, schemaID: String? = nil) {
            self.requestID = requestID
            self.schemaSetID = schemaSetID
            self.schemaID = schemaID
        }
    }

    public struct Event: Sendable, Hashable {
        public var requestID: UUID
        public var schemaSetID: SchemaSetID
        public var phase: SchemaSwitchPhase
        public var detail: String?
    }

    /// The root `user_data_dir` (`schemas/`, `sets/`, `learning.sqlite`).
    public let root: URL
    public let builtinSharedDataDir: URL
    public let luaFile: URL?
    public var learningStore: LearningStore?
    public var learningWriter: LearningStoreWriter?
    /// Every phase change, in order.
    public var onEvent: (@MainActor (Event) -> Void)?
    public private(set) var lastReport: SchemaSetSwitchReport?

    private let engineProvider: @MainActor () -> RimeEngine?
    private var parked: Request?
    private var running: (request: Request, cancellation: DeployCancellation, task: Task<Void, Never>)?
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var isShutDown = false

    public init(
        root: URL, builtinSharedDataDir: URL, luaFile: URL?,
        learningStore: LearningStore? = nil, learningWriter: LearningStoreWriter? = nil,
        engineProvider: @escaping @MainActor () -> RimeEngine?
    ) {
        self.root = root
        self.builtinSharedDataDir = builtinSharedDataDir
        self.luaFile = luaFile
        self.learningStore = learningStore
        self.learningWriter = learningWriter
        self.engineProvider = engineProvider
    }

    /// True while a switch is parked or running.
    public var isBusy: Bool { parked != nil || running != nil }
    public var parkedRequest: Request? { parked }

    /// Starts `request` now when the engine is idle, else parks it until the next idle boundary.
    public func request(_ request: Request) {
        guard !isShutDown else { return emit(request, .failed, "the input method is shutting down") }
        guard let engine = engineProvider(), engine.isOperational else {
            return emit(request, .failed, "the engine is not running")
        }
        guard sharedDataDir(for: request) != nil else {
            return emit(request, .failed, "schema set \(request.schemaSetID.rawValue) is not installed")
        }
        if running != nil || engine.currentState.isComposing {
            if let superseded = parked { emit(superseded, .failed, "superseded by a newer request") }
            parked = request
            emit(request, .pendingIdle, running.map { "after the switch to \($0.request.schemaSetID.rawValue)" })
            return
        }
        start(request, on: engine)
    }

    /// Call with every composition change (`InputSessionCoordinator.onCompositionChange`).
    /// Leaving nothing composing wakes a waiting switch or starts the parked one.
    public func compositionDidChange(_ state: CompositionState) {
        guard !state.isComposing else { return }
        resumeIdleWaiters()
        startParkedIfIdle()
    }

    /// Cancels a running switch synchronously (its deployer stopped, its staging directory
    /// removed) and drops a parked one. Call before flushing learning and shutting the engine down.
    public func shutdown(deployerGrace: Duration = .milliseconds(500)) {
        guard !isShutDown else { return }
        isShutDown = true
        parked = nil
        if let running {
            running.cancellation.cancelAndFinishCleanup(deployerGrace: deployerGrace)
            running.task.cancel()
        }
        resumeIdleWaiters()
    }

    // MARK: - Running

    private func sharedDataDir(for request: Request) -> URL? {
        NoemaPaths.installedSchemaDir(
            request.schemaSetID, schemaID: request.schemaID, root: root, builtinSharedDataDir: builtinSharedDataDir)
    }

    private func startParkedIfIdle() {
        guard !isShutDown, running == nil, let next = parked, let engine = engineProvider(),
              !engine.currentState.isComposing
        else { return }
        parked = nil
        guard engine.isOperational else { return emit(next, .failed, "the engine is not running") }
        start(next, on: engine)
    }

    private func start(_ request: Request, on engine: RimeEngine) {
        guard let shared = sharedDataDir(for: request) else {
            return emit(request, .failed, "schema set \(request.schemaSetID.rawValue) is not installed")
        }
        let cancellation = DeployCancellation()
        emit(request, .compiling)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.run(request, on: engine, sharedDataDir: shared, cancellation: cancellation)
        }
        running = (request, cancellation, task)
    }

    private func run(_ request: Request, on engine: RimeEngine, sharedDataDir: URL, cancellation: DeployCancellation) async {
        var announcedWait = false
        do {
            let report = try await engine.switchSchemaSet(
                to: request.schemaSetID, sharedDataDir: sharedDataDir, schemaID: request.schemaID,
                learningStore: learningStore, learningWriter: learningWriter, luaFile: luaFile,
                cancellation: cancellation,
                waitUntilIdle: { [weak self] in
                    guard let self else { return }
                    if !announcedWait {
                        announcedWait = true
                        self.emit(request, .pendingIdle, "waiting for the composition to end")
                    }
                    await self.waitForIdle(engine)
                })
            lastReport = report
            emit(request, .ready, report.userDBFailure.map { "userdb maintenance failed: \($0)" })
        } catch {
            emit(request, .failed, String(describing: error))
        }
        running = nil
        startParkedIfIdle()
    }

    private func waitForIdle(_ engine: RimeEngine) async {
        guard !isShutDown, engine.currentState.isComposing else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func resumeIdleWaiters() {
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func emit(_ request: Request, _ phase: SchemaSwitchPhase, _ detail: String? = nil) {
        onEvent?(Event(requestID: request.requestID, schemaSetID: request.schemaSetID, phase: phase, detail: detail))
    }
}
