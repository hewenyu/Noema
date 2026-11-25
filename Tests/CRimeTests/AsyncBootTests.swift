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
