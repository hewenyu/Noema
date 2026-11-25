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
/// Layout inside `user_data_dir` (one file system, so every rename is atomic):
/// - `.deploy-staging.<pid>.<uuid>/` — the deployer's user data dir; its `build/` is the candidate.
/// - `.build-old.<pid>.<uuid>/` — the previous `build/` between the two renames of a switch.
extension RimeEngine {
    public nonisolated static let deployerExecutableName = "noema-rime-deployer"
    nonisolated static let stagingPrefix = ".deploy-staging."
    nonisolated static let oldBuildPrefix = ".build-old."

    /// Makes `build/` loadable per `DeployPolicy`; false means Safe Mode or cancellation.
    /// Called with the user-data lock held. Makes no librime call and touches no engine
    /// state, so `start(configuration:cancellation:)` runs it off the main actor.
    nonisolated static func prepareBuild(configuration: RimeEngineConfiguration, cancellation: DeployCancellation) -> Bool {
        let user = configuration.userDataDir
        let build = user.appending(path: "build")
        guard recoverInterruptedDeployments(configuration), !cancellation.isCancelled else { return false }
        let manifest = DeployManifest.validated(buildDir: build, schemaID: configuration.schemaID)
        if configuration.deployPolicy == .neverDeploy { return manifest != nil }
        guard let inputs = try? DeployManifest.inputs(
            sharedDataDir: configuration.sharedDataDir, userDataDir: user)
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
        let staging = configuration.userDataDir.appending(path: Self.stagingPrefix + tag)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        } catch {
            return false
        }
        defer { try? FileManager.default.removeItem(at: staging) }
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
        process.arguments = [
            "--shared-dir", configuration.sharedDataDir.absoluteURL.path,
            "--user-dir", configuration.userDataDir.absoluteURL.path,
            "--staging-dir", staging.absoluteURL.path,
            "--log-dir", configuration.logDir.absoluteURL.path,
            "--schema", configuration.schemaID,
        ]
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

    /// Replaces `build` with `staged`: move the old build aside, move the staged one in,
    /// make that durable, and only then drop the old one; put the old one back if the
    /// second rename fails.
    private nonisolated static func switchBuild(
        _ configuration: RimeEngineConfiguration, to staged: URL, replacing build: URL, tag: String
    ) -> Bool {
        let user = configuration.userDataDir
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
    /// every other leftover staging directory and old build. False (Safe Mode) when the state
    /// of `build/` or a candidate cannot be read or the restoring rename fails; every
    /// leftover is then kept, so a later boot can still recover.
    private nonisolated static func recoverInterruptedDeployments(_ configuration: RimeEngineConfiguration) -> Bool {
        let fileManager = FileManager.default
        let user = configuration.userDataDir
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
            try? fileManager.removeItem(at: url)
        }
        return true
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
public final class DeployCancellation: Sendable {
    private struct State {
        var cancelled = false
        var process: Process?
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

    /// `cancel()`, then waits up to `grace` for a running deployer to exit and sends it
    /// SIGKILL if it has not, so a process about to `exit` leaves no orphan deployer.
    public func cancelTerminatingDeployer(grace: Duration = .milliseconds(500)) {
        cancel()
        guard let process = state.withLockUnchecked({ $0.process }) else { return }
        let clock = ContinuousClock()
        let deadline = clock.now + grace
        while process.isRunning, clock.now < deadline { usleep(10_000) }
        if process.processIdentifier > 0, process.isRunning { kill(process.processIdentifier, SIGKILL) }
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
