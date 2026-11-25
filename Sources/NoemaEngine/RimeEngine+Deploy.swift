import Darwin
import Dispatch
import Foundation

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

    /// Makes `build/` loadable per `DeployPolicy`; false means Safe Mode. Called with the
    /// user-data lock held.
    func prepareBuild() -> Bool {
        let user = configuration.userDataDir
        let build = user.appending(path: "build")
        recoverInterruptedDeployments()
        let manifest = DeployManifest.validated(buildDir: build, schemaID: configuration.schemaID)
        if configuration.deployPolicy == .neverDeploy { return manifest != nil }
        guard let inputs = try? DeployManifest.inputs(
            sharedDataDir: configuration.sharedDataDir, userDataDir: user)
        else { return false }
        if configuration.deployPolicy == .deployIfNeeded, let manifest, manifest.inputs == inputs { return true }
        return deployIsolated(expecting: inputs, into: build)
    }

    /// Locates `noema-rime-deployer`: beside the main executable (the app bundle's
    /// `Contents/MacOS`), beside the image holding this code, and, when that image is a
    /// SwiftPM `.xctest` bundle, in the build directory holding the bundle.
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
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // MARK: - Steps

    private func deployIsolated(expecting inputs: [DeployManifest.ManifestEntry], into build: URL) -> Bool {
        guard let deployer = configuration.deployerURL ?? Self.locateDeployer() else { return false }
        let tag = "\(getpid()).\(UUID().uuidString)"
        let staging = configuration.userDataDir.appending(path: Self.stagingPrefix + tag)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        } catch {
            return false
        }
        defer { try? FileManager.default.removeItem(at: staging) }
        guard runDeployer(deployer, staging: staging) else { return false }
        let staged = staging.appending(path: "build")
        guard let manifest = DeployManifest.validated(buildDir: staged, schemaID: configuration.schemaID),
              manifest.inputs == inputs
        else { return false }
        return switchBuild(to: staged, replacing: build, tag: tag)
    }

    /// Runs the deployer to completion within `deployTimeout`; true only on exit status 0.
    /// Its stderr goes to `<logDir>/noema-rime-deployer.log`.
    private func runDeployer(_ deployer: URL, staging: URL) -> Bool {
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
        do {
            try process.run()
        } catch {
            return false
        }
        let (seconds, attoseconds) = configuration.deployTimeout.components
        let timeout = max(0, Double(seconds) + Double(attoseconds) / 1e18)
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
            return false
        }
        return process.terminationReason == .exit && process.terminationStatus == 0
    }

    /// Replaces `build` with `staged`: move the old build aside, move the staged one in,
    /// and put the old one back if the second rename fails.
    private func switchBuild(to staged: URL, replacing build: URL, tag: String) -> Bool {
        let old = configuration.userDataDir.appending(path: Self.oldBuildPrefix + tag)
        var info = stat()
        let hadBuild = lstat(build.path, &info) == 0
        if hadBuild, rename(build.path, old.path) != 0 { return false }
        guard rename(staged.path, build.path) == 0 else {
            if hadBuild { _ = rename(old.path, build.path) }
            return false
        }
        if hadBuild { try? FileManager.default.removeItem(at: old) }
        syncDirectory(configuration.userDataDir)
        return true
    }

    /// After a crash mid-deployment: put back a build that was moved aside but never
    /// replaced, and remove leftover staging directories and old builds.
    private func recoverInterruptedDeployments() {
        let fileManager = FileManager.default
        let user = configuration.userDataDir
        guard let names = try? fileManager.contentsOfDirectory(atPath: user.path) else { return }
        let build = user.appending(path: "build")
        var info = stat()
        var hasBuild = lstat(build.path, &info) == 0
        for name in names.sorted() where name.hasPrefix(Self.oldBuildPrefix) || name.hasPrefix(Self.stagingPrefix) {
            let url = user.appending(path: name)
            if !hasBuild, name.hasPrefix(Self.oldBuildPrefix), rename(url.path, build.path) == 0 {
                hasBuild = true
                continue
            }
            try? fileManager.removeItem(at: url)
        }
    }

    private func syncDirectory(_ url: URL) {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        _ = fsync(descriptor)
        close(descriptor)
    }
}
