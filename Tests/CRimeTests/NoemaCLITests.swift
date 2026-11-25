import Darwin
import Foundation
import NoemaCore
import NoemaEngine
import Testing

/// The real `noema-cli` and `NoemaIME` executables from the build directory, run as
/// subprocesses: `repl` on a real engine, `install` on a real ad-hoc signed bundle into a
/// temporary `--dest` (never `~/Library/Input Methods`, never registered or reloaded).
extension LibrimeSerializedTests {
    @Suite struct NoemaCLITests {
        // MARK: repl

        @Test func replTypesCommitsAndRemovesItsEphemeralDirectory() throws {
            let input = "nihao\n:select 1\nshi=\n:page prev\n<esc>\n:ascii on\nab\n:state\n:quit\nnever-read\n"
            let run = try Tool.cli(["repl"], stdin: input, cwd: Tool.repository)
            #expect(run.status == 0, "stderr: \(run.stderr)")
            let lines = run.stdout.split(separator: "\n").map(String.init)
            #expect(lines.contains("PREEDIT: ni hao [caret 6]"))
            #expect(lines.contains { $0.hasPrefix("CANDIDATES: 1.你好*") })
            #expect(lines.contains("COMMIT: 你好"))
            #expect(lines.contains { $0.hasPrefix("CANDIDATES: ") && $0.hasSuffix("[page 2]") })
            #expect(lines.contains("ASCII: on"))
            #expect(lines.contains("PASSTHROUGH: a") && lines.contains("PASSTHROUGH: b"))
            #expect(lines.contains("STATE: composing=false ascii=true schema=noema_pinyin safe-mode=none"))
            #expect(!run.stdout.contains("never-read"))

            let root = try #require(Self.ephemeralRoot(in: run.stderr))
            #expect(!FileManager.default.fileExists(atPath: root), "ephemeral directory \(root) must be removed")
        }

        @Test func replDirectCommitAndEOFTeardown() throws {
            let run = try Tool.cli(["repl", "--shared-dir", EngineWorkspace.shippedSharedData.path], stdin: "nihao,\n")
            #expect(run.status == 0, "stderr: \(run.stderr)")
            // The shipped punctuator turns , into ，; EOF without :quit still tears down.
            #expect(run.stdout.split(separator: "\n").contains("COMMIT: 你好，"))
            let root = try #require(Self.ephemeralRoot(in: run.stderr))
            #expect(!FileManager.default.fileExists(atPath: root))
        }

        @Test func replOnALockedUserDirIsSafeMode() throws {
            let workspace = try EngineWorkspace()
            try FileManager.default.createDirectory(at: workspace.user, withIntermediateDirectories: true)
            let holder = open(workspace.user.appending(path: BootGuard.lockFileName).path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            try #require(holder >= 0)
            defer { close(holder) }
            try #require(flock(holder, LOCK_EX | LOCK_NB) == 0)

            let run = try Tool.cli(
                ["repl", "--user-dir", workspace.user.path, "--log-dir", workspace.logs.path,
                 "--shared-dir", workspace.shared.path],
                stdin: "ni\n")
            #expect(run.status == 0, "stderr: \(run.stderr)")
            let lines = run.stdout.split(separator: "\n").map(String.init)
            #expect(lines.first == "[safe-mode: userDataDirLocked]")
            #expect(lines.contains("PASSTHROUGH: n") && lines.contains("PASSTHROUGH: i"))
            #expect(FileManager.default.fileExists(atPath: workspace.user.path), "a given --user-dir is never removed")
        }

        @Test func replRejectsBadArguments() throws {
            let conflicting = try Tool.cli(["repl", "--ephemeral", "--user-dir", "/tmp/x"], stdin: "")
            #expect(conflicting.status == 2)
            let missingDeployer = try Tool.cli(["repl", "--deployer", "/nonexistent/noema-rime-deployer"], stdin: "")
            #expect(missingDeployer.status == 1 && missingDeployer.stderr.contains("--deployer"))
        }

        /// Codex PR #18: SIGTERM while the deployer runs stops it, and the boot removes its
        /// staging directory and boot guard before the ephemeral directory goes.
        @Test func replSignalDuringEphemeralDeployCleansUpDeployerAndTempDir() throws {
            let deployer = try SlowDeployer()
            let repl = try ReplProcess(["repl", "--ephemeral", "--shared-dir", EngineWorkspace.shippedSharedData.path,
                                        "--deployer", deployer.wrapper.path])
            let root = try #require(repl.waitForEphemeralRoot())
            let pid = try #require(deployer.waitForPID(), "the slow deployer never started")
            #expect(FileManager.default.fileExists(atPath: root))

            kill(repl.process.processIdentifier, SIGTERM)
            #expect(repl.waitForExit(seconds: 3), "noema-cli repl did not exit after SIGTERM")
            #expect(repl.process.terminationReason == .exit && repl.process.terminationStatus == 128 + SIGTERM,
                    "status \(repl.process.terminationStatus), stderr: \(repl.stderr)")
            #expect(SlowDeployer.waitForDeath(pid), "deployer \(pid) was orphaned")
            #expect(!FileManager.default.fileExists(atPath: root), "ephemeral directory \(root) must be removed")
        }

        /// Codex PR #18: two signals during deployment on a persistent --user-dir are
        /// cancellations, not crashes, so the third run boots normally.
        @Test func replRepeatedSignalsDuringPersistentDeployDoNotTripCrashLoop() throws {
            let workspace = try EngineWorkspace()
            let fm = FileManager.default
            for attempt in 1...2 {
                let deployer = try SlowDeployer()
                let repl = try ReplProcess(["repl", "--user-dir", workspace.user.path, "--log-dir", workspace.logs.path,
                                            "--shared-dir", EngineWorkspace.shippedSharedData.path,
                                            "--deployer", deployer.wrapper.path])
                let pid = try #require(deployer.waitForPID(), "attempt \(attempt): the slow deployer never started")
                kill(repl.process.processIdentifier, SIGTERM)
                #expect(repl.waitForExit(seconds: 3), "attempt \(attempt): noema-cli repl did not exit")
                #expect(repl.process.terminationReason == .exit && repl.process.terminationStatus == 128 + SIGTERM)
                #expect(SlowDeployer.waitForDeath(pid), "attempt \(attempt): deployer \(pid) was orphaned")
                let entries = try fm.contentsOfDirectory(atPath: workspace.user.path)
                #expect(!entries.contains { $0.hasPrefix(".deploy-staging.") }, "attempt \(attempt): \(entries)")
                #expect(!entries.contains(BootGuard.sentinelFileName), "attempt \(attempt): boot guard left armed")
            }
            let run = try Tool.cli(
                ["repl", "--user-dir", workspace.user.path, "--log-dir", workspace.logs.path,
                 "--shared-dir", EngineWorkspace.shippedSharedData.path],
                stdin: "nihao<space>\n:quit\n")
            #expect(run.status == 0, "stderr: \(run.stderr)")
            #expect(run.stdout.split(separator: "\n").contains("COMMIT: 你好"), "stdout: \(run.stdout)")
            #expect(!run.stdout.contains("bootCrashLoop") && !run.stdout.contains("safe-mode"), "stdout: \(run.stdout)")
        }

        // MARK: NoemaIME probes

        @Test func imeProbesAnswerWithoutStartingTheServer() throws {
            let version = try Tool.run(Tool.binary("NoemaIME"), ["--version"])
            #expect(version.status == 0 && version.stdout == "NoemaIME \(NoemaVersion.current)\n")
            let bogus = try Tool.run(Tool.binary("NoemaIME"), ["--bogus"])
            #expect(bogus.status == 2 && bogus.stderr.contains("usage: NoemaIME"))
            let help = try Tool.run(Tool.binary("NoemaIME"), ["--help"])
            #expect(help.status == 0)
        }

        // MARK: install / reload

        @Test func installFreshThenUpgradeInPlace() throws {
            let fixture = try BundleFixture()
            let first = try fixture.install()
            #expect(first.status == 0, "stderr: \(first.stderr)")
            #expect(first.stderr.contains("warning: installing an ad-hoc signed bundle"))
            #expect(!first.stdout.contains("registered") && !first.stdout.contains("reloaded"),
                    "a custom --dest is never registered or reloaded by default")
            let target = fixture.dest.appending(path: "NoemaIME.app")
            #expect(try fixture.bundleIdentifier(at: target) == NoemaPaths.imeBundleID)
            #expect(try fixture.destEntries() == ["NoemaIME.app"], "no staging or old bundle is left behind")
            let firstInode = try fixture.inode(target)

            let second = try fixture.install()
            #expect(second.status == 0, "stderr: \(second.stderr)")
            #expect(try fixture.inode(target) != firstInode, "the upgrade swaps in a fresh copy")
            #expect(try fixture.destEntries() == ["NoemaIME.app"])
            let verify = try Tool.run("/usr/bin/codesign", ["--verify", "--strict", "--deep", target.path])
            #expect(verify.status == 0)
        }

        @Test func installRefusesAdhocWithoutOptIn() throws {
            let fixture = try BundleFixture()
            #expect(try fixture.install().status == 0)
            let target = fixture.dest.appending(path: "NoemaIME.app")
            let inode = try fixture.inode(target)
            let refused = try fixture.install(allowAdhoc: false)
            #expect(refused.status == 1)
            #expect(refused.stderr.contains("ad-hoc signed") && refused.stderr.contains("--allow-adhoc"))
            #expect(try fixture.inode(target) == inode, "the installed bundle is untouched")
            #expect(try fixture.destEntries() == ["NoemaIME.app"])
        }

        @Test func installRefusesATamperedSignature() throws {
            let fixture = try BundleFixture()
            #expect(try fixture.install().status == 0)
            let target = fixture.dest.appending(path: "NoemaIME.app")
            let inode = try fixture.inode(target)
            let yaml = fixture.app.appending(path: "Contents/Resources/rime-default/default.yaml")
            let handle = try FileHandle(forWritingTo: yaml)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("# tampered\n".utf8))
            try handle.close()
            let refused = try fixture.install()
            #expect(refused.status == 1 && refused.stderr.contains("code signature is invalid"))
            #expect(try fixture.inode(target) == inode)
            #expect(try fixture.destEntries() == ["NoemaIME.app"])
        }

        @Test func installRefusesAForeignTarget() throws {
            let fixture = try BundleFixture()
            let target = fixture.dest.appending(path: "NoemaIME.app")
            try FileManager.default.createDirectory(at: target.appending(path: "Contents"), withIntermediateDirectories: true)
            let foreign = Data(#"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.other</string></dict></plist>"#.utf8)
            try foreign.write(to: target.appending(path: "Contents/Info.plist"))
            let refused = try fixture.install()
            #expect(refused.status == 1 && refused.stderr.contains("not a Noema input method"))
            #expect(try Data(contentsOf: target.appending(path: "Contents/Info.plist")) == foreign)
            #expect(try fixture.destEntries() == ["NoemaIME.app"])
        }

        @Test func installRefusesSymlinks() throws {
            let fixture = try BundleFixture()
            let fm = FileManager.default
            // A symlinked --bundle.
            let linkedBundle = fixture.root.appending(path: "linked.app")
            try fm.createSymbolicLink(at: linkedBundle, withDestinationURL: fixture.app)
            let viaLink = try fixture.install(bundle: linkedBundle)
            #expect(viaLink.status == 1 && viaLink.stderr.contains("symlink"))
            // A symlinked --dest.
            let linkedDest = fixture.root.appending(path: "linked-dest")
            try fm.createSymbolicLink(at: linkedDest, withDestinationURL: fixture.dest)
            let intoLink = try fixture.install(dest: linkedDest)
            #expect(intoLink.status == 1 && intoLink.stderr.contains("symlink"))
            // A symlinked target inside --dest is never replaced.
            let elsewhere = fixture.root.appending(path: "elsewhere.app")
            try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
            let target = fixture.dest.appending(path: "NoemaIME.app")
            try fm.createSymbolicLink(at: target, withDestinationURL: elsewhere)
            let overLink = try fixture.install()
            #expect(overLink.status == 1)
            #expect(try fm.destinationOfSymbolicLink(atPath: target.path) == elsewhere.path)
            #expect(try fixture.destEntries() == ["NoemaIME.app"])
            // .. in a path is refused before anything happens.
            let dotdot = try Tool.cli(["install", "--bundle", fixture.app.path, "--dest", fixture.dest.path + "/../x"], stdin: "")
            #expect(dotdot.status == 2)
        }

        @Test func installRefusesAnIncompleteBundle() throws {
            let fixture = try BundleFixture()
            try FileManager.default.removeItem(at: fixture.app.appending(path: "Contents/MacOS/noema-rime-deployer"))
            let refused = try fixture.install()
            #expect(refused.status == 1 && refused.stderr.contains("noema-rime-deployer"))
            #expect(try fixture.destEntries().isEmpty)
        }

        /// A validly re-signed bundle without the shipped schema is still incomplete.
        @Test func installRefusesAResignedBundleWithoutRimeDefault() throws {
            let fixture = try BundleFixture()
            try FileManager.default.removeItem(at: fixture.app.appending(path: "Contents/Resources/rime-default"))
            let resigned = try Tool.run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", fixture.app.path])
            try #require(resigned.status == 0, "codesign: \(resigned.stderr)")
            let verify = try Tool.run("/usr/bin/codesign", ["--verify", "--strict", "--deep", fixture.app.path])
            try #require(verify.status == 0, "the re-signed bundle must pass codesign: \(verify.stderr)")
            let refused = try fixture.install()
            #expect(refused.status == 1 && refused.stderr.contains("rime-default"), "stderr: \(refused.stderr)")
            #expect(try fixture.destEntries().isEmpty)
        }

        /// `--reload` stops the process running the *old* bundle: its pid is taken before the
        /// swap, because afterwards its executable no longer lives at the target path.
        @Test func installReloadStopsTheProcessOfTheReplacedBundle() throws {
            let fixture = try BundleFixture()
            #expect(try fixture.install().status == 0)
            let target = fixture.dest.appending(path: "NoemaIME.app")
            let old = try SleeperProcess(at: target.appending(path: "Contents/MacOS/NoemaIME"))
            defer { old.kill() }

            var arguments = ["install", "--bundle", fixture.app.path, "--dest", fixture.dest.path]
            arguments += ["--allow-adhoc", "--no-register", "--reload"]
            let run = try Tool.cli(arguments, stdin: "")
            #expect(run.status == 0, "stderr: \(run.stderr)")
            #expect(run.stdout.contains("reloaded: stopped 1 NoemaIME process(es)"))
            #expect(old.waitForSIGTERMExit())
            #expect(try fixture.destEntries() == ["NoemaIME.app"])
            let again = try Tool.cli(["reload", "--bundle", target.path], stdin: "")
            #expect(again.status == 0 && again.stdout.contains("stopped 0 NoemaIME process(es)"), "no pending process is left")
        }

        /// `--no-reload` leaves the old process running and records it, so a later `reload`
        /// of the target still finds it although its bundle was renamed away and deleted.
        @Test func installNoReloadFollowedByReloadStopsOldProcess() throws {
            let fixture = try BundleFixture()
            #expect(try fixture.install().status == 0)
            let target = fixture.dest.appending(path: "NoemaIME.app")
            let old = try SleeperProcess(at: target.appending(path: "Contents/MacOS/NoemaIME"))
            defer { old.kill() }

            let install = try fixture.install()
            #expect(install.status == 0, "stderr: \(install.stderr)")
            #expect(!install.stdout.contains("reloaded"))
            usleep(200_000)
            #expect(old.process.isRunning, "--no-reload leaves the old process alone")

            let reload = try Tool.cli(["reload", "--bundle", target.path], stdin: "")
            #expect(reload.status == 0, "stderr: \(reload.stderr)")
            #expect(reload.stdout.contains("reload: stopped 1 NoemaIME process(es)"), "stdout: \(reload.stdout)")
            #expect(old.waitForSIGTERMExit())
            let again = try Tool.cli(["reload", "--bundle", target.path], stdin: "")
            #expect(again.status == 0 && again.stdout.contains("stopped 0 NoemaIME process(es)"), "the ledger is cleared")
        }

        /// A process that ignores SIGTERM makes `install --reload` and `reload` exit 1 without
        /// claiming it stopped, and stays recorded for the next `reload`.
        @Test func installReloadTimeoutExitsNonZeroAndPreservesPendingProcess() throws {
            let fixture = try BundleFixture()
            #expect(try fixture.install().status == 0)
            let target = fixture.dest.appending(path: "NoemaIME.app")
            let stubborn = try SleeperProcess(at: target.appending(path: "Contents/MacOS/NoemaIME"), ignoringSIGTERM: true)
            defer { stubborn.kill() }

            var arguments = ["install", "--bundle", fixture.app.path, "--dest", fixture.dest.path]
            arguments += ["--allow-adhoc", "--no-register", "--reload"]
            let install = try Tool.cli(arguments, stdin: "")
            #expect(install.status == 1, "stdout: \(install.stdout)")
            #expect(install.stdout.contains("installed ") && !install.stdout.contains("reloaded"))
            #expect(!install.stdout.contains("stopped 1"))
            #expect(install.stderr.contains("reload failed: signalled 1, stopped 0, 1 process(es) did not exit within 3 s"),
                    "stderr: \(install.stderr)")
            #expect(stubborn.process.isRunning)
            #expect(try fixture.destEntries() == ["NoemaIME.app"], "the install itself completed")

            let reload = try Tool.cli(["reload", "--bundle", target.path], stdin: "")
            #expect(reload.status == 1, "stdout: \(reload.stdout)")
            #expect(!reload.stdout.contains("stopped 1"))
            #expect(reload.stdout.contains("reload: signalled 1, stopped 0"), "the pending process was found again")
            #expect(reload.stderr.contains("1 process(es) did not exit within 3 s"))
            #expect(stubborn.process.isRunning)

            stubborn.kill()
            let after = try Tool.cli(["reload", "--bundle", target.path], stdin: "")
            #expect(after.status == 0 && after.stdout.contains("stopped 0 NoemaIME process(es)"), "a dead pending process is pruned")
        }

        @Test func reloadWithNothingRunningSucceeds() throws {
            let fixture = try BundleFixture()
            let run = try Tool.cli(["reload", "--bundle", fixture.app.path], stdin: "")
            #expect(run.status == 0, "stderr: \(run.stderr)")
            #expect(run.stdout.contains("stopped 0 NoemaIME process(es)") && !run.stdout.contains("registered"))
            #expect(try Tool.cli(["reload", "--bogus"], stdin: "").status == 2)
        }

        /// A process running `<bundle>/Contents/MacOS/NoemaIME` is stopped; one running the
        /// same binary from another path is left alone.
        @Test func reloadStopsOnlyTheBundlesProcess() throws {
            let root = FileManager.default.temporaryDirectory.appending(path: "noema-reload-tests-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let bundle = root.appending(path: "NoemaIME.app")
            let target = try SleeperProcess(at: bundle.appending(path: "Contents/MacOS/NoemaIME"))
            let other = try SleeperProcess(at: root.appending(path: "other/NoemaIME"))
            defer { other.kill(); target.kill() }

            let run = try Tool.cli(["reload", "--bundle", bundle.path], stdin: "")
            #expect(run.status == 0, "stderr: \(run.stderr)")
            #expect(run.stdout.contains("stopped 1 NoemaIME process(es)"))
            #expect(target.waitForSIGTERMExit())
            #expect(other.process.isRunning, "a NoemaIME outside the bundle is not ours to stop")
        }

        private static func ephemeralRoot(in stderr: String) -> String? {
            guard let range = stderr.range(of: "user dir "), let end = stderr.range(of: "/user (ephemeral)") else { return nil }
            return String(stderr[range.upperBound..<end.lowerBound])
        }
    }
}

// MARK: - Helpers

enum Tool {
    static let repository = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// An executable product in the build directory that holds `noema-rime-deployer`.
    static func binary(_ name: String) throws -> String {
        let deployer = try #require(RimeEngine.locateDeployer(), "build noema-rime-deployer first")
        let url = deployer.deletingLastPathComponent().appending(path: name)
        try #require(FileManager.default.isExecutableFile(atPath: url.path), "\(name) is not built at \(url.path)")
        return url.path
    }

    static func cli(_ arguments: [String], stdin: String, cwd: URL? = nil) throws -> (status: Int32, stdout: String, stderr: String) {
        try run(binary("noema-cli"), arguments, stdin: stdin, cwd: cwd)
    }

    static func run(
        _ executable: String, _ arguments: [String], stdin: String = "", cwd: URL? = nil
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let root = FileManager.default.temporaryDirectory.appending(path: "noema-tool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appending(path: "stdin"), output = root.appending(path: "stdout"), errors = root.appending(path: "stderr")
        try Data(stdin.utf8).write(to: input)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        FileManager.default.createFile(atPath: errors.path, contents: nil)
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        process.standardInput = try FileHandle(forReadingFrom: input)
        process.standardOutput = try FileHandle(forWritingTo: output)
        process.standardError = try FileHandle(forWritingTo: errors)
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus,
                try String(contentsOf: output, encoding: .utf8), try String(contentsOf: errors, encoding: .utf8))
    }
}

/// A `--deployer` that never finishes: a shell wrapper that records its PID, then `exec`s
/// the compiled sleeper (same PID), which sleeps until a signal or 60 s.
final class SlowDeployer {
    let root: URL
    var wrapper: URL { root.appending(path: "slow-deployer") }
    var pidFile: URL { root.appending(path: "pid") }

    init() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appending(path: "noema-slow-deployer-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let sleeper = root.appending(path: "sleeper")
        try SleeperProcess.compile(to: sleeper)
        let script = """
            #!/bin/sh
            echo $$ > '\(root.path)/pid.tmp' && mv '\(root.path)/pid.tmp' '\(pidFile.path)'
            exec '\(sleeper.path)'
            """
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try #require(chmod(wrapper.path, 0o755) == 0)
    }

    deinit {
        if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(pid, SIGKILL)
        }
        try? FileManager.default.removeItem(at: root)
    }

    /// The running deployer's PID, once it has started (up to 10 s).
    func waitForPID() -> pid_t? {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while clock.now < deadline {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
               let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return pid }
            usleep(10_000)
        }
        return nil
    }

    /// True once `pid` no longer exists (up to 2 s).
    static func waitForDeath(_ pid: pid_t) -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while clock.now < deadline {
            if kill(pid, 0) != 0, errno == ESRCH { return true }
            usleep(10_000)
        }
        return false
    }
}

/// A real `noema-cli` started with an open stdin pipe (so it never sees EOF) and its
/// stderr in a file.
final class ReplProcess {
    let process = Process()
    private let stdin = Pipe()
    private let root: URL
    private var stderrURL: URL { root.appending(path: "stderr") }
    var stderr: String { (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? "" }

    init(_ arguments: [String]) throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appending(path: "noema-repl-process-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        fm.createFile(atPath: stderrURL.path, contents: nil)
        process.executableURL = URL(filePath: try Tool.binary("noema-cli"))
        process.arguments = arguments
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = try FileHandle(forWritingTo: stderrURL)
        try process.run()
    }

    deinit {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: root)
    }

    /// The ephemeral root from the startup banner (up to 10 s).
    func waitForEphemeralRoot() -> String? {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while clock.now < deadline {
            let text = stderr
            if let range = text.range(of: "user dir "), let end = text.range(of: "/user (ephemeral)") {
                return String(text[range.upperBound..<end.lowerBound])
            }
            usleep(10_000)
        }
        return nil
    }

    func waitForExit(seconds: Int) -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(seconds)
        while process.isRunning, clock.now < deadline { usleep(10_000) }
        return !process.isRunning
    }
}

/// A plain `arm64` C program compiled into `executable` and started: it writes a
/// readiness file, then sleeps until a signal (SIGTERM, unless `ignoringSIGTERM`) or 60 s.
/// Compiled rather than a copied `/bin/sleep`, whose re-signed arm64e platform copy
/// crashes on some hosts.
final class SleeperProcess {
    static let source = """
        #include <fcntl.h>
        #include <signal.h>
        #include <string.h>
        #include <unistd.h>
        int main(int argc, char **argv) {
            const char *ready = 0;
            for (int i = 1; i < argc; i++) {
                if (strcmp(argv[i], "--ignore-sigterm") == 0) signal(SIGTERM, SIG_IGN);
                else if (strcmp(argv[i], "--ready") == 0 && i + 1 < argc) ready = argv[++i];
            }
            alarm(60);
            if (ready) {
                int fd = open(ready, O_CREAT | O_WRONLY | O_TRUNC, 0600);
                if (fd >= 0) { write(fd, "1", 1); close(fd); }
            }
            for (;;) pause();
        }
        """

    let process = Process()

    /// Compiles and ad-hoc signs the sleeper into `executable` without starting it.
    static func compile(to executable: URL) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appending(path: "noema-sleeper-src-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let sourceURL = work.appending(path: "sleeper.c")
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: executable)
        let compiled = try Tool.run("/usr/bin/clang", ["-arch", "arm64", "-O1", "-o", executable.path, sourceURL.path])
        try #require(compiled.status == 0, "clang: \(compiled.stderr)")
        let signed = try Tool.run("/usr/bin/codesign", ["--force", "--sign", "-", executable.path])
        try #require(signed.status == 0, "codesign: \(signed.stderr)")
    }

    init(at executable: URL, ignoringSIGTERM: Bool = false) throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appending(path: "noema-sleeper-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        try Self.compile(to: executable)

        let ready = work.appending(path: "ready")
        process.executableURL = executable
        process.arguments = (ignoringSIGTERM ? ["--ignore-sigterm"] : []) + ["--ready", ready.path]
        try process.run()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while !fm.fileExists(atPath: ready.path), process.isRunning, clock.now < deadline { usleep(10_000) }
        try #require(fm.fileExists(atPath: ready.path) && process.isRunning, "the helper did not start")
    }

    /// Waits up to 10 s for the exit; true when SIGTERM ended it.
    func waitForSIGTERMExit() -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(10)
        while process.isRunning, clock.now < deadline { usleep(10_000) }
        guard !process.isRunning else { return false }
        return process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGTERM
    }

    func kill() {
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }

    deinit { kill() }
}

/// A real, ad-hoc signed `NoemaIME.app` assembled from the debug products, the vendored
/// librime, the shipped schema, and the Info.plist template, plus an empty `--dest`.
final class BundleFixture {
    let root: URL
    var app: URL { root.appending(path: "src/NoemaIME.app") }
    var dest: URL { root.appending(path: "Input Methods") }

    init() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appending(path: "noema-install-tests-\(UUID().uuidString)")
        let contents = root.appending(path: "src/NoemaIME.app/Contents")
        for directory in ["MacOS", "Frameworks", "Resources"] {
            try fm.createDirectory(at: contents.appending(path: directory), withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: root.appending(path: "Input Methods"), withIntermediateDirectories: true)
        let template = try String(contentsOf: Tool.repository.appending(path: "Resources/IME/Info.plist.in"), encoding: .utf8)
        try template.replacingOccurrences(of: "${NOEMA_VERSION}", with: "0.0.0-test")
            .replacingOccurrences(of: "${NOEMA_BUILD}", with: "1")
            .write(to: contents.appending(path: "Info.plist"), atomically: true, encoding: .utf8)
        for name in ["NoemaIME", "noema-rime-deployer"] {
            try fm.copyItem(atPath: try Tool.binary(name), toPath: contents.appending(path: "MacOS/\(name)").path)
        }
        let dylib = contents.appending(path: "Frameworks/librime.1.dylib")
        try fm.copyItem(at: Tool.repository.appending(path: "vendor-out/librime/lib/librime.1.dylib"), to: dylib)
        try fm.copyItem(at: EngineWorkspace.shippedSharedData, to: contents.appending(path: "Resources/rime-default"))
        // Inside-out, like bundle.sh: nested code first, then the bundle.
        for target in [dylib.path, contents.appending(path: "MacOS/noema-rime-deployer").path,
                       contents.appending(path: "MacOS/NoemaIME").path, app.path] {
            let signed = try Tool.run("/usr/bin/codesign", ["--force", "--sign", "-", "--timestamp=none", target])
            try #require(signed.status == 0, "codesign \(target): \(signed.stderr)")
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func install(bundle: URL? = nil, dest: URL? = nil, allowAdhoc: Bool = true) throws -> (status: Int32, stdout: String, stderr: String) {
        var arguments = ["install", "--bundle", (bundle ?? app).path, "--dest", (dest ?? self.dest).path,
                         "--no-register", "--no-reload"]
        if allowAdhoc { arguments.append("--allow-adhoc") }
        return try Tool.cli(arguments, stdin: "")
    }

    func destEntries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dest.path).sorted()
    }

    func inode(_ url: URL) throws -> UInt64 {
        var info = stat()
        try #require(lstat(url.path, &info) == 0)
        return UInt64(info.st_ino)
    }

    func bundleIdentifier(at app: URL) throws -> String? {
        let data = try Data(contentsOf: app.appending(path: "Contents/Info.plist"))
        return (try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])?["CFBundleIdentifier"] as? String
    }
}
