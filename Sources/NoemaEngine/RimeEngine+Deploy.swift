import Darwin
import Dispatch
import Foundation
import os

/// Isolated deployment. `RimeEngine` never calls librime's deployer itself: it runs
/// `noema-rime-deployer` in a subprocess against a fresh staging directory inside
/// `user_data_dir`, re-checks the staged build against its `DeployManifest`, and only
/// then swaps it in for `build/` with `rename(2)`. A failed, crashed, timed-out, or
/// unverifiable deployment leaves the live `build/` byte for byte unchanged.
///
/// Layout inside librime's `user_data_dir` (`rimeUserDataDir`; one file system, so every
/// rename is atomic):
/// - `.deploy-staging.<pid>.<uuid>/` — the deployer's user data dir; its `build/` is the
///   candidate. Its `.deploy.lock` is `flock`ed for the staging directory's whole life, so
///   recovery never removes a staging directory a live deployment still uses.
/// - `.build-old.<pid>.<uuid>/` — the previous `build/` between the two renames of a switch,
///   used only where `renamex_np(RENAME_SWAP)` is unsupported.
extension RimeEngine {
    public nonisolated static let deployerExecutableName = "noema-rime-deployer"
    nonisolated static let stagingPrefix = ".deploy-staging."
    nonisolated static let oldBuildPrefix = ".build-old."
    nonisolated static let deployLockName = ".deploy.lock"

    /// Makes `build/` loadable per `DeployPolicy`; false means Safe Mode or cancellation.
    /// Called with the user-data lock held. Makes no librime call and touches no engine
    /// state, so `start(configuration:cancellation:)` runs it off the main actor.
    nonisolated static func prepareBuild(configuration: RimeEngineConfiguration, cancellation: DeployCancellation) -> Bool {
        let user = configuration.rimeUserDataDir
        let build = user.appending(path: "build")
        // The learned-phrase translator loads `<rimeUserDataDir>/lua/noema_learned.lua`.
        if configuration.luaFile != nil, prepareSchemaSetWorkspace(configuration, gramPath: nil) == nil { return false }
        guard recoverInterruptedDeployments(configuration), !cancellation.isCancelled else { return false }
        let manifest = DeployManifest.validated(buildDir: build, schemaID: configuration.schemaID)
        if configuration.deployPolicy == .neverDeploy { return manifest != nil }
        guard let inputs = try? DeployManifest.inputs(
            sharedDataDir: configuration.sharedDataDir, userDataDir: user, luaFile: configuration.luaFile)
        else { return false }
        if configuration.deployPolicy == .deployIfNeeded, let manifest, manifest.inputs == inputs { return true }
        guard !cancellation.isCancelled else { return false }
        return deployIsolated(configuration, expecting: inputs, into: build, cancellation: cancellation)
    }

    /// Locates `noema-rime-deployer`: beside the main executable (the app bundle's
    /// `Contents/MacOS`), beside the image holding this code, and, when that image is a
    /// SwiftPM `.xctest` bundle, in the build directory holding the bundle. A candidate counts
    /// only when it is (or links to) a regular file and `access(X_OK)` allows running it, so a
    /// directory of that name never shadows the real executable.
    public nonisolated static func locateDeployer() -> URL? {
        var directories: [URL] = []
        if let executable = Bundle.main.executableURL {
            directories.append(executable.resolvingSymlinksInPath().deletingLastPathComponent())
        }
        var info = Dl_info()
        if dladdr(#dsohandle, &info) != 0, let name = info.dli_fname {
            let directory = URL(filePath: String(cString: name)).resolvingSymlinksInPath().deletingLastPathComponent()
            directories.append(directory)
            let bundle = directory.deletingLastPathComponent().deletingLastPathComponent()
            if directory.lastPathComponent == "MacOS", bundle.pathExtension == "xctest" {
                directories.append(bundle.deletingLastPathComponent())
            }
        }
        return directories.lazy
            .map { $0.appending(path: deployerExecutableName) }
            .first { isExecutableRegularFile($0.path) }
    }

    nonisolated static func isExecutableRegularFile(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && access(path, X_OK) == 0
    }

    // MARK: - Steps

    private nonisolated static func deployIsolated(
        _ configuration: RimeEngineConfiguration, expecting inputs: [DeployManifest.ManifestEntry], into build: URL,
        cancellation: DeployCancellation
    ) -> Bool {
        guard let deployer = configuration.deployerURL ?? Self.locateDeployer() else { return false }
        let tag = "\(getpid()).\(UUID().uuidString)"
        let staging = configuration.rimeUserDataDir.appending(path: Self.stagingPrefix + tag)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        } catch {
            return false
        }
        guard let lock = StagingLock.acquire(in: staging) else {
            try? FileManager.default.removeItem(at: staging)
            return false
        }
        // Remove the staging directory while still holding its lock, then drop the lock.
        defer {
            try? FileManager.default.removeItem(at: staging)
            lock.release()
        }
        guard runDeployer(configuration, deployer, staging: staging, cancellation: cancellation) else { return false }
        let staged = staging.appending(path: "build")
        guard let manifest = DeployManifest.validated(buildDir: staged, schemaID: configuration.schemaID),
              manifest.inputs == inputs,
              // Past this check the switch runs to completion: it is two renames.
              !cancellation.isCancelled
        else { return false }
        return switchBuild(configuration, to: staged, replacing: build, tag: tag)
    }

    /// Runs the deployer to completion within `deployTimeout`; true only on exit status 0.
    /// Its stderr goes to `<logDir>/noema-rime-deployer.log`. A timeout or `cancellation`
    /// sends SIGTERM, then SIGKILL after 2 s, and waits for the exit.
    private nonisolated static func runDeployer(
        _ configuration: RimeEngineConfiguration, _ deployer: URL, staging: URL, cancellation: DeployCancellation
    ) -> Bool {
        let process = Process()
        process.executableURL = deployer
        var arguments = [
            "--shared-dir", configuration.sharedDataDir.absoluteURL.path,
            "--user-dir", configuration.rimeUserDataDir.absoluteURL.path,
            "--staging-dir", staging.absoluteURL.path,
            "--log-dir", configuration.logDir.absoluteURL.path,
            "--schema", configuration.schemaID,
        ]
        if let set = configuration.schemaSetID { arguments += ["--schema-set", set.rawValue] }
        if let lua = configuration.luaFile { arguments += ["--lua-file", lua.absoluteURL.path] }
        process.arguments = arguments
        if let (opencc, overriding) = configuration.effectiveOpenCCDataDir {
            var environment = ProcessInfo.processInfo.environment
            if overriding || environment[RimeEngineConfiguration.openccDataDirVariable] == nil {
                environment[RimeEngineConfiguration.openccDataDirVariable] = opencc.path
                process.environment = environment
            }
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let logURL = configuration.logDir.appending(path: "\(Self.deployerExecutableName).log")
        let log = FileManager.default.createFile(atPath: logURL.path, contents: nil)
            ? (try? FileHandle(forWritingTo: logURL)) : nil
        defer { try? log?.close() }
        process.standardError = log ?? FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        guard cancellation.launch(process) else { return false }
        defer { cancellation.clearProcess() }
        let (seconds, attoseconds) = configuration.deployTimeout.components
        let deadline = DispatchTime.now() + max(0, Double(seconds) + Double(attoseconds) / 1e18)
        // Wake every 50 ms so a cancellation is noticed even if the deployer ignores SIGTERM.
        var finished = false
        while !finished, DispatchTime.now() < deadline, !cancellation.isCancelled {
            finished = exited.wait(timeout: min(deadline, .now() + 0.05)) == .success
        }
        if finished {
            return !cancellation.isCancelled && process.terminationReason == .exit && process.terminationStatus == 0
        }
        if process.processIdentifier > 0, process.isRunning { kill(process.processIdentifier, SIGTERM) }
        if exited.wait(timeout: .now() + 2) == .timedOut {
            if process.processIdentifier > 0, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            exited.wait()
        }
        return false
    }

    /// Replaces `build` with `staged`. With a live `build/`, one `renamex_np(RENAME_SWAP)`
    /// exchanges the two atomically (the old build ends up at `staged` and is removed with
    /// the staging directory). Where the file system does not support the swap (`ENOTSUP`,
    /// `EINVAL`): move the old build aside, move the staged one in, make that durable, and
    /// only then drop the old one; put the old one back if the second rename fails.
    nonisolated static func switchBuild(
        _ configuration: RimeEngineConfiguration, to staged: URL, replacing build: URL, tag: String
    ) -> Bool {
        let user = configuration.rimeUserDataDir
        let old = user.appending(path: Self.oldBuildPrefix + tag)
        var info = stat()
        let (buildStatus, buildErrno) = Self.lstatCapturingErrno(build, &info)
        let hadBuild: Bool
        if buildStatus == 0 {
            hadBuild = true
        } else if buildErrno == ENOENT {
            hadBuild = false
        } else {
            return false
        }
        if hadBuild, info.st_mode & S_IFMT == S_IFDIR {
            if renamex_np(staged.path, build.path, UInt32(RENAME_SWAP)) == 0 {
                syncDirectory(user)
                return true
            }
            guard errno == ENOTSUP || errno == EINVAL else { return false }
        }
        if hadBuild, rename(build.path, old.path) != 0 { return false }
        guard rename(staged.path, build.path) == 0 else {
            if hadBuild, rename(old.path, build.path) == 0 { syncDirectory(user) }
            return false
        }
        syncDirectory(user)
        if hadBuild {
            try? FileManager.default.removeItem(at: old)
            syncDirectory(user)
        }
        return true
    }

    /// After a crash mid-deployment: when `build/` is missing, put back the best build that
    /// was moved aside but never replaced (one that passes `DeployManifest.validated`, else
    /// any, newest modification time first), make that rename durable, and only then remove
    /// every other leftover staging directory and old build. A staging directory whose
    /// `.deploy.lock` is held (a deployment still running, in this process or another) is
    /// never removed. False (Safe Mode) when the state of `build/` or a candidate cannot be
    /// read or the restoring rename fails; every leftover is then kept, so a later boot can
    /// still recover.
    nonisolated static func recoverInterruptedDeployments(_ configuration: RimeEngineConfiguration) -> Bool {
        let fileManager = FileManager.default
        let user = configuration.rimeUserDataDir
        guard let names = try? fileManager.contentsOfDirectory(atPath: user.path) else { return false }
        let build = user.appending(path: "build")
        var info = stat()
        let (buildStatus, buildErrno) = Self.lstatCapturingErrno(build, &info)
        if buildStatus != 0 {
            guard buildErrno == ENOENT else { return false }
            var candidates: [OldBuild] = []
            for name in names where name.hasPrefix(Self.oldBuildPrefix) {
                let url = user.appending(path: name)
                var candidate = stat()
                let (candidateStatus, candidateErrno) = Self.lstatCapturingErrno(url, &candidate)
                guard candidateStatus == 0 else {
                    if candidateErrno == ENOENT { continue }
                    return false
                }
                guard candidate.st_mode & S_IFMT == S_IFDIR else { continue }
                candidates.append(OldBuild(
                    name: name,
                    isValid: DeployManifest.validated(buildDir: url, schemaID: configuration.schemaID) != nil,
                    modified: candidate.st_mtimespec))
            }
            if let best = candidates.max(by: { $0.isWorse(than: $1) }) {
                guard rename(user.appending(path: best.name).path, build.path) == 0 else { return false }
                syncDirectory(user)
            }
        }
        for name in names where name.hasPrefix(Self.oldBuildPrefix) || name.hasPrefix(Self.stagingPrefix) {
            let url = user.appending(path: name)
            var leftover = stat()
            // The restored build no longer exists under its old name.
            guard Self.lstatCapturingErrno(url, &leftover).0 == 0 else { continue }
            if name.hasPrefix(Self.stagingPrefix), leftover.st_mode & S_IFMT == S_IFDIR {
                // Held: a live deployment owns it. Free: take it, so none can start using it.
                guard let lock = StagingLock.acquire(in: url, creating: false) else { continue }
                try? fileManager.removeItem(at: url)
                lock.release()
                continue
            }
            try? fileManager.removeItem(at: url)
        }
        return true
    }

    /// An exclusive `flock` on `<staging>/.deploy.lock`.
    struct StagingLock {
        let descriptor: Int32

        /// The lock, or nil when another open file description holds it, or the lock file
        /// cannot be opened (`creating`: created `0600`, `O_NOFOLLOW`). A staging directory
        /// without a lock file (from before locks existed) is treated as free.
        static func acquire(in staging: URL, creating: Bool = true) -> StagingLock? {
            let path = staging.appending(path: RimeEngine.deployLockName).path
            let flags = O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (creating ? O_CREAT | O_EXCL : 0)
            let descriptor = open(path, flags, 0o600)
            guard descriptor >= 0 else {
                // No lock file: no deployment ever locked it. Lock the directory itself instead.
                if !creating, errno == ENOENT {
                    let directory = open(staging.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                    guard directory >= 0 else { return nil }
                    guard flock(directory, LOCK_EX | LOCK_NB) == 0 else {
                        close(directory)
                        return nil
                    }
                    return StagingLock(descriptor: directory)
                }
                return nil
            }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  flock(descriptor, LOCK_EX | LOCK_NB) == 0
            else {
                close(descriptor)
                return nil
            }
            return StagingLock(descriptor: descriptor)
        }

        /// Whether a live deployment holds the lock in `staging`.
        static func isHeld(in staging: URL) -> Bool {
            guard let lock = acquire(in: staging, creating: false) else { return true }
            lock.release()
            return false
        }

        func release() {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }

    private nonisolated static func lstatCapturingErrno(_ url: URL, _ info: inout stat) -> (Int32, Int32) {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return (-1, EINVAL) }
            let result = lstat(path, &info)
            return (result, result == 0 ? 0 : errno)
        }
    }

    /// A `.build-old.*` candidate for recovery, ranked valid first, then newest.
    private struct OldBuild {
        var name: String
        var isValid: Bool
        var modified: timespec

        func isWorse(than other: OldBuild) -> Bool {
            if isValid != other.isValid { return !isValid }
            if modified.tv_sec != other.modified.tv_sec { return modified.tv_sec < other.modified.tv_sec }
            if modified.tv_nsec != other.modified.tv_nsec { return modified.tv_nsec < other.modified.tv_nsec }
            return name < other.name
        }
    }

    private nonisolated static func syncDirectory(_ url: URL) {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        _ = fsync(descriptor)
        close(descriptor)
    }
}

/// Cancels a deployment from any thread. `cancel()` marks it cancelled and sends SIGTERM to
/// the running `noema-rime-deployer`, if any; `RimeEngine.prepareBuild` then stops at its
/// next step (the deploy loop polls every 50 ms and escalates to SIGKILL after 2 s), removes
/// its staging directory, and leaves `build/` untouched. Once cancelled, no new deployer starts.
///
/// `cancelAndFinishCleanup` is the synchronous variant for a process about to exit: it also
/// waits for the background `prepareBuild` and then runs the boot's abandon hook on the
/// caller's main-actor stack, so the cleanup never waits for a main-actor continuation.
public final class DeployCancellation: Sendable {
    private struct State {
        var cancelled = false
        var process: Process?
        /// Entered while `prepareBuild` runs off the main actor; left after it returns.
        var prepareGroup: DispatchGroup?
        /// Disarms the boot sentinel and releases the lock and the claim; runs at most once.
        var onAbandon: (@MainActor @Sendable () -> Void)?
    }

    // `Process` is not Sendable; every access to it goes through this lock.
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    public init() {}

    public var isCancelled: Bool { state.withLockUnchecked { $0.cancelled } }

    /// Marks the deployment cancelled and sends SIGTERM to a running deployer. Idempotent;
    /// never blocks.
    public func cancel() {
        let process = state.withLockUnchecked { state -> Process? in
            state.cancelled = true
            return state.process
        }
        if let process, process.processIdentifier > 0, process.isRunning {
            kill(process.processIdentifier, SIGTERM)
        }
    }

    /// For a caller about to exit, even from inside a `DispatchQueue.main` block (AppKit
    /// `terminate(_:)`, a signal source), where no main-actor continuation can run before the
    /// process ends: `cancel()`; SIGKILL the deployer if it outlives `deployerGrace`; wait up
    /// to `cleanupWait` for the background `prepareBuild` to return (it removes its staging
    /// directory and never touches the main actor, so this cannot deadlock); then run the
    /// boot's abandon hook here, synchronously: the sentinel is disarmed and the lock and the
    /// claim are released before this returns. If `prepareBuild` is still running after
    /// `cleanupWait`, the hook is skipped and the boot counts as unfinished.
    @MainActor
    public func cancelAndFinishCleanup(deployerGrace: Duration = .milliseconds(500), cleanupWait: Duration = .seconds(1)) {
        cancel()
        if let process = state.withLockUnchecked({ $0.process }) {
            let clock = ContinuousClock()
            let deadline = clock.now + deployerGrace
            while process.isRunning, clock.now < deadline { usleep(10_000) }
            if process.processIdentifier > 0, process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        if let group = state.withLockUnchecked({ $0.prepareGroup }) {
            let (seconds, attoseconds) = cleanupWait.components
            let wait = max(0, Double(seconds) + Double(attoseconds) / 1e18)
            guard group.wait(timeout: .now() + wait) == .success else { return }
        }
        let abandon = state.withLockUnchecked { state -> (@MainActor @Sendable () -> Void)? in
            defer { state.onAbandon = nil }
            return state.onAbandon
        }
        abandon?()
    }

    /// Installs the boot's abandon hook unless already cancelled (then false).
    func registerAbandon(_ abandon: @escaping @MainActor @Sendable () -> Void) -> Bool {
        state.withLockUnchecked { state -> Bool in
            guard !state.cancelled else { return false }
            state.onAbandon = abandon
            return true
        }
    }

    func clearAbandon() {
        state.withLockUnchecked { $0.onAbandon = nil }
    }

    /// A group entered for the coming `prepareBuild`, or nil when already cancelled.
    func enterPrepare() -> DispatchGroup? {
        state.withLockUnchecked { state -> DispatchGroup? in
            guard !state.cancelled else { return nil }
            let group = DispatchGroup()
            group.enter()
            state.prepareGroup = group
            return group
        }
    }

    /// Called once `prepareBuild` has returned, so its staging directory is already gone.
    func leavePrepare(_ group: DispatchGroup) {
        state.withLockUnchecked { state in
            if state.prepareGroup === group { state.prepareGroup = nil }
        }
        group.leave()
    }

    /// Starts `process` unless already cancelled; the check and the launch share the lock,
    /// so a concurrent `cancel()` either prevents the launch or sees the process.
    func launch(_ process: Process) -> Bool {
        state.withLockUnchecked { state -> Bool in
            guard !state.cancelled, (try? process.run()) != nil else { return false }
            state.process = process
            return true
        }
    }

    func clearProcess() {
        state.withLockUnchecked { $0.process = nil }
    }
}
