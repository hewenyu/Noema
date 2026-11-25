import AppKit
import Darwin
import Foundation
import NoemaCore
import NoemaEngine
import NoemaIMEShell
import Testing

/// `RimeEngine.start(configuration:cancellation:)`, the path `EngineHost` boots the input
/// method with: the real deployer (behind a wrapper that delays it) runs off the main actor
/// while the main actor keeps serving the coordinator, and a cancelled boot stops the
/// deployer and releases everything.
extension LibrimeSerializedTests {
    @MainActor
    @Suite struct AsyncBootTests {
        @Test func deploymentDoesNotBlockTheMainActor() async throws {
            let workspace = try EngineWorkspace()
            let real = try #require(RimeEngine.locateDeployer())
            let wrapper = try workspace.deployerScript("/bin/sleep 1.5\nexec '\(real.path)' \"$@\"")
            let slot = EngineSlot()
            let coordinator = InputSessionCoordinator(
                engineProvider: { slot.engine }, candidatePresenter: RecordingPresenter(), isSecureInputEnabled: { false })
            let client = RecordingClient()
            let token = UUID()

            let clock = ContinuousClock()
            let begun = clock.now
            let boot = Task { @MainActor in
                try await RimeEngine.start(configuration: workspace.configuration(deployerURL: wrapper))
            }
            // A 50 ms main-actor timer fires on time while the deployer sleeps.
            let tick = clock.now
            try await Task.sleep(for: .milliseconds(50))
            #expect(clock.now - tick < .milliseconds(500), "the main actor was blocked by the boot")
            // Keys during the boot pass through at once.
            let keyStart = clock.now
            #expect(!coordinator.handleKey(.text("a"), token: token, client: client))
            #expect(clock.now - keyStart < .milliseconds(100))
            #expect(clock.now - begun < .milliseconds(1500), "still booting when the key arrived")
            #expect(client.calls.isEmpty)

            let engine = try await boot.value
            defer { engine.shutdown() }
            #expect(!engine.isSafeMode)
            #expect(clock.now - begun >= .milliseconds(1500), "the delayed deployer really ran")
            slot.engine = engine
            for key in "nihao" { #expect(coordinator.handleKey(.text(key), token: token, client: client)) }
            #expect(coordinator.handleKey(.key(VirtualKeyCode.space, " "), token: token, client: client))
            #expect(client.calls.last == .insert("你好"))
            #expect(!FileManager.default.fileExists(atPath: workspace.sentinel.path))
        }

        /// Cancelling the task (`onCancel`), or `cancelTerminatingDeployer` then cancelling
        /// (what `EngineHost.shutdown()` does), stops the deployer within 2 s, disarms the
        /// sentinel, releases the lock and the claim, and leaves no staging directory.
        @Test(arguments: [false, true])
        func cancelledBootStopsTheDeployerAndReleasesEverything(synchronousCancel: Bool) async throws {
            let workspace = try EngineWorkspace()
            // One earlier unfinished boot: a cancelled boot left armed would trip the guard.
            try workspace.writeSentinel(#"{"consecutiveFailures":1,"lastAttemptEpoch":1}"#)
            let pidFile = workspace.root.appending(path: "deployer.pid")
            let wrapper = try workspace.deployerScript("echo $$ > '\(pidFile.path)'\nexec /bin/sleep 15")
            let cancellation = DeployCancellation()
            let boot = Task { @MainActor in
                try await RimeEngine.start(configuration: workspace.configuration(deployerURL: wrapper), cancellation: cancellation)
            }
            let clock = ContinuousClock()
            let waitStart = clock.now
            while !FileManager.default.fileExists(atPath: pidFile.path), clock.now - waitStart < .seconds(10) {
                try await Task.sleep(for: .milliseconds(20))
            }
            try await Task.sleep(for: .milliseconds(50))
            let pidText = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let pid = try #require(pid_t(pidText))
            #expect(kill(pid, 0) == 0, "the deployer is running")

            let cancelled = clock.now
            if synchronousCancel { cancellation.cancelTerminatingDeployer() }
            boot.cancel()
            let result = await boot.result
            #expect(clock.now - cancelled < .seconds(2))
            guard case .failure(let error) = result else {
                Issue.record("a cancelled boot must not return an engine")
                return
            }
            #expect(error as? NoemaError == .engineUnavailable(reason: "boot cancelled"))
            #expect(kill(pid, 0) != 0 && errno == ESRCH, "the deployer was stopped")
            #expect(!FileManager.default.fileExists(atPath: workspace.sentinel.path), "a cancelled boot is not a crash")
            #expect(try workspace.deployLeftovers().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: workspace.user.appending(path: "build").path))

            let holder = open(workspace.user.appending(path: BootGuard.lockFileName).path, O_RDWR | O_CLOEXEC)
            try #require(holder >= 0)
            #expect(flock(holder, LOCK_EX | LOCK_NB) == 0, "the user-data lock was released")
            close(holder)

            // The claim is free and the next boot is not a crash loop.
            let engine = try await RimeEngine.start(configuration: workspace.configuration())
            defer { engine.shutdown() }
            #expect(!engine.isSafeMode)
            engine.type("nihao")
            #expect(engine.currentState.candidates.first?.text == "你好")
        }

        /// Cancelled before it starts: the boot guard is not touched and no deployer runs.
        @Test func bootCancelledBeforeStartTouchesNothing() async throws {
            let workspace = try EngineWorkspace()
            let record = #"{"consecutiveFailures":1,"lastAttemptEpoch":1}"#
            try workspace.writeSentinel(record)
            let marker = workspace.root.appending(path: "deployer-ran")
            let wrapper = try workspace.deployerScript("touch '\(marker.path)'\nexit 1")
            let cancellation = DeployCancellation()
            cancellation.cancel()
            do {
                let engine = try await RimeEngine.start(
                    configuration: workspace.configuration(policy: .forceDeploy, deployerURL: wrapper), cancellation: cancellation)
                engine.shutdown()
                Issue.record("a cancelled boot must not return an engine")
            } catch {
                #expect(error == .engineUnavailable(reason: "boot cancelled"))
            }
            #expect(try String(contentsOf: workspace.sentinel, encoding: .utf8) == record, "the boot guard was touched")
            #expect(!FileManager.default.fileExists(atPath: marker.path))
            // The claim was released.
            let engine = try await RimeEngine.start(configuration: workspace.configuration())
            defer { engine.shutdown() }
            #expect(!engine.isSafeMode)
        }

        /// AppKit termination mid-boot (`applicationShouldTerminate` → `.terminateLater`, then
        /// `reply(toApplicationShouldTerminate:)` exits): the reply waits for the cancelled
        /// boot's cleanup, so two interrupted boots in a row on the same `user_data_dir` leave
        /// no armed sentinel and the third boot types normally instead of `bootCrashLoop`.
        /// The process "exits" when the reply fires: the sentinel is restored to its bytes at
        /// that moment, as if the cleanup still pending had never run.
        @Test func appKitTerminateLaterCleansUpRepeatedBootInterruptionsWithoutCrashLoop() async throws {
            let workspace = try EngineWorkspace()
            for round in 1...2 {
                let pidFile = workspace.root.appending(path: "deployer-\(round).pid")
                let wrapper = try workspace.deployerScript("echo $$ > '\(pidFile.path)'\nexec /bin/sleep 15")
                let host = try await InterruptibleBoot(configuration: workspace.configuration(deployerURL: wrapper), pidFile: pidFile)
                let pid = try #require(host.deployerPID)
                #expect(kill(pid, 0) == 0, "round \(round): the deployer is running")

                let delegate = TerminationDelegateDouble(shutdown: host.shutdown)
                let clock = ContinuousClock()
                let asked = clock.now
                var exitSnapshot: ExitSnapshot?
                var replies = 0
                let reply = delegate.applicationShouldTerminate { terminate in
                    replies += 1
                    #expect(terminate)
                    exitSnapshot = ExitSnapshot(workspace: workspace, deployerPID: pid)
                }
                #expect(reply == .terminateLater, "round \(round): a running boot defers termination")
                while exitSnapshot == nil, clock.now - asked < .seconds(5) {
                    try await Task.sleep(for: .milliseconds(10))
                }
                #expect(clock.now - asked < .seconds(2), "round \(round): the reply is bounded")
                let snapshot = try #require(exitSnapshot)
                // Past the 1 s fallback: the reply still fired exactly once.
                try await Task.sleep(for: .milliseconds(1200))
                #expect(replies == 1)
                #expect(!snapshot.deployerAlive, "round \(round): the deployer was stopped")
                #expect(snapshot.stagingLeftovers.isEmpty, "round \(round): staging was removed")
                #expect(snapshot.sentinel == nil, "round \(round): the boot sentinel was disarmed")

                await host.boot.value
                try snapshot.restoreSentinel(in: workspace)
            }

            let engine = try await RimeEngine.start(configuration: workspace.configuration())
            defer { engine.shutdown() }
            #expect(!engine.isSafeMode, "two AppKit-terminated boots are not a crash loop")
            let coordinator = InputSessionCoordinator(
                engineProvider: { engine }, candidatePresenter: RecordingPresenter(), isSecureInputEnabled: { false })
            let client = RecordingClient()
            let token = UUID()
            for key in "nihao" { #expect(coordinator.handleKey(.text(key), token: token, client: client)) }
            #expect(coordinator.handleKey(.key(VirtualKeyCode.space, " "), token: token, client: client))
            #expect(client.calls.last == .insert("你好"))
        }

        /// The synchronous exits (`applicationWillTerminate`, after `NSApplication.run()`
        /// returns) pump the main run loop until the cancelled boot has cleaned up. It runs as
        /// a run-loop block, like an AppKit event handler, not inside a main-queue job.
        @Test func synchronousShutdownAwaitCleansUpPostRunLoopBoot() async throws {
            let workspace = try EngineWorkspace()
            try workspace.writeSentinel(#"{"consecutiveFailures":1,"lastAttemptEpoch":1}"#)
            let pidFile = workspace.root.appending(path: "deployer.pid")
            let wrapper = try workspace.deployerScript("echo $$ > '\(pidFile.path)'\nexec /bin/sleep 15")
            let host = try await InterruptibleBoot(configuration: workspace.configuration(deployerURL: wrapper), pidFile: pidFile)
            let pid = try #require(host.deployerPID)

            let user = workspace.user, sentinel = workspace.sentinel
            let clock = ContinuousClock()
            let began = clock.now
            let snapshot: ExitSnapshot = await withCheckedContinuation { continuation in
                RunLoop.main.perform {
                    MainActor.assumeIsolated {
                        BootTerminationCoordinator.awaitShutdownSynchronously(shutdown: host.shutdown)
                        continuation.resume(returning: ExitSnapshot(user: user, sentinel: sentinel, deployerPID: pid))
                    }
                }
            }
            #expect(clock.now - began < .seconds(2))
            #expect(!snapshot.deployerAlive, "the deployer was stopped")
            #expect(snapshot.stagingLeftovers.isEmpty, "staging was removed")
            #expect(snapshot.sentinel == nil, "the boot sentinel was disarmed before exit")
            await host.boot.value
            // Nothing booting: returns at once without pumping.
            let idle = clock.now
            BootTerminationCoordinator.awaitShutdownSynchronously(shutdown: { nil })
            #expect(clock.now - idle < .milliseconds(50))
        }

        /// No boot running: `.terminateNow` at once, and the deferred reply never fires.
        @Test func terminateNowWhenNotBooting() async throws {
            var replies = 0
            let delegate = TerminationDelegateDouble(shutdown: { nil })
            #expect(delegate.applicationShouldTerminate { _ in replies += 1 } == .terminateNow)
            try await Task.sleep(for: .milliseconds(1200))
            #expect(replies == 0)
        }

        /// A Safe Mode decision returns at once and runs no deployer.
        @Test func crashLoopReturnsSafeModeWithoutDeploying() async throws {
            let workspace = try EngineWorkspace()
            try workspace.writeSentinel(#"{"consecutiveFailures":2,"lastAttemptEpoch":1}"#)
            let marker = workspace.root.appending(path: "deployer-ran")
            let wrapper = try workspace.deployerScript("touch '\(marker.path)'\nexit 1")
            let engine = try await RimeEngine.start(configuration: workspace.configuration(deployerURL: wrapper))
            defer { engine.shutdown() }
            #expect(engine.safeModeReason == .bootCrashLoop)
            #expect(!FileManager.default.fileExists(atPath: marker.path))
            engine.expectEverythingPassesThrough()
        }
    }
}

@MainActor
final class EngineSlot {
    var engine: RimeEngine?
}

/// What `EngineHost` does around a boot, against a workspace: `RimeEngine.start` in a
/// `Task<Void, Never>`, and a `shutdown` that stops the deployer, cancels the task, and
/// returns it. Initialization waits until the (slow) deployer has written its pid.
@MainActor
final class InterruptibleBoot {
    let boot: Task<Void, Never>
    let cancellation: DeployCancellation
    private(set) var deployerPID: pid_t?
    private(set) var shutDown = false

    init(configuration: RimeEngineConfiguration, pidFile: URL) async throws {
        let cancellation = DeployCancellation()
        self.cancellation = cancellation
        boot = Task { @MainActor in
            if let engine = try? await RimeEngine.start(configuration: configuration, cancellation: cancellation) {
                Issue.record("a cancelled boot must not return an engine")
                engine.shutdown()
            }
        }
        let clock = ContinuousClock()
        let start = clock.now
        while !FileManager.default.fileExists(atPath: pidFile.path), clock.now - start < .seconds(10) {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(50))
        let text = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        deployerPID = pid_t(text)
    }

    func shutdown() -> Task<Void, Never>? {
        if shutDown { return boot }
        shutDown = true
        cancellation.cancelTerminatingDeployer()
        boot.cancel()
        return boot
    }
}

/// `InputMethodAppDelegate.applicationShouldTerminate`, with `reply` standing in for
/// `NSApplication.reply(toApplicationShouldTerminate:)`.
@MainActor
struct TerminationDelegateDouble {
    let shutdown: () -> Task<Void, Never>?

    func applicationShouldTerminate(reply: @escaping @MainActor (Bool) -> Void) -> NSApplication.TerminateReply {
        let waiting = BootTerminationCoordinator.beginShutdown(shutdown: shutdown, onComplete: { reply(true) })
        return waiting ? .terminateLater : .terminateNow
    }
}

/// The workspace at the moment the process would exit.
struct ExitSnapshot {
    let deployerAlive: Bool
    let stagingLeftovers: [String]
    let sentinel: Data?

    init(workspace: EngineWorkspace, deployerPID: pid_t) {
        self.init(user: workspace.user, sentinel: workspace.sentinel, deployerPID: deployerPID)
    }

    init(user: URL, sentinel: URL, deployerPID: pid_t) {
        deployerAlive = kill(deployerPID, 0) == 0
        stagingLeftovers = ((try? FileManager.default.contentsOfDirectory(atPath: user.path)) ?? ["<unreadable>"])
            .filter { $0.hasPrefix(".deploy-staging.") || $0.hasPrefix(".build-old.") || $0 == "<unreadable>" }
        self.sentinel = try? Data(contentsOf: sentinel)
    }

    /// Puts the sentinel back as it was at exit, undoing cleanup that ran only because the
    /// test process kept running.
    func restoreSentinel(in workspace: EngineWorkspace) throws {
        if let sentinel {
            try sentinel.write(to: workspace.sentinel)
        } else if FileManager.default.fileExists(atPath: workspace.sentinel.path) {
            try FileManager.default.removeItem(at: workspace.sentinel)
        }
    }
}

extension EngineWorkspace {
    func configuration(
        policy: RimeEngineConfiguration.DeployPolicy = .deployIfNeeded, deployerURL: URL? = nil
    ) -> RimeEngineConfiguration {
        RimeEngineConfiguration(sharedDataDir: shared, userDataDir: user, logDir: logs, deployPolicy: policy, deployerURL: deployerURL)
    }

    /// An executable `/bin/sh` script standing in for `noema-rime-deployer`.
    func deployerScript(_ body: String) throws -> URL {
        let url = root.appending(path: "deployer-\(UUID().uuidString).sh")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try #require(Darwin.chmod(url.path, 0o755) == 0)
        return url
    }
}
