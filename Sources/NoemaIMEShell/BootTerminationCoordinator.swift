import Dispatch
import Foundation
import NoemaCore

/// Bounded boot cleanup shared by every way the input method process ends: AppKit
/// termination (`applicationShouldTerminate` → `.terminateLater`), `SIGTERM`/`SIGINT`, and
/// the code after `NSApplication.run()` returns. `shutdown` cancels a running boot and
/// returns its task; the boot task then removes its staging directory and disarms the boot
/// sentinel on the main actor, so exiting before it finishes would count the interruption
/// as a crash (three in a row trip `bootCrashLoop`). The wait is bounded by `timeout`,
/// well under `noema-cli reload`'s 3 s.
@MainActor
public enum BootTerminationCoordinator {
    /// Shuts down and returns at once. Returns `false` when no boot was running (exit now;
    /// `onComplete` never runs); otherwise `true`, and `onComplete` runs exactly once on the
    /// main actor when the boot task finishes or `timeout` elapses, whichever comes first.
    public static func beginShutdown(
        timeout: Duration = .seconds(1),
        shutdown: () -> Task<Void, Never>?,
        onComplete: @escaping @MainActor () -> Void
    ) -> Bool {
        guard let bootTask = shutdown() else { return false }
        let once = Once(onComplete)
        let delay = seconds(timeout)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { once.fire() }
        }
        // The same bound as a run-loop timer in the common modes: AppKit's `.terminateLater`
        // loop keeps firing it even when entered from a main-queue block, where the main
        // dispatch queue (and so the asyncAfter above) cannot drain.
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { once.fire() }
        }
        RunLoop.main.add(timer, forMode: .common)
        Task { @MainActor in
            await bootTask.value
            once.fire()
        }
        return true
    }

    /// Shuts down and, if a boot was running, pumps the main run loop until the boot task
    /// finishes or `timeout` elapses: for synchronous exits (`applicationWillTerminate`,
    /// after `NSApplication.run()` returns) where nothing can be deferred.
    public static func awaitShutdownSynchronously(
        timeout: Duration = .seconds(1),
        shutdown: () -> Task<Void, Never>?
    ) {
        guard let bootTask = shutdown() else { return }
        let finished = Flag()
        Task { @MainActor in
            await bootTask.value
            finished.value = true
        }
        let deadline = Date().addingTimeInterval(seconds(timeout))
        while !finished.value, Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let (whole, attoseconds) = duration.components
        return TimeInterval(whole) + TimeInterval(attoseconds) / 1e18
    }

    @MainActor private final class Once {
        private var action: (@MainActor () -> Void)?
        init(_ action: @escaping @MainActor () -> Void) { self.action = action }
        func fire() {
            guard let action else { return }
            self.action = nil
            action()
        }
    }

    @MainActor private final class Flag {
        var value = false
    }
}
