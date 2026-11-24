import Darwin
import Foundation
import NoemaCore
import NoemaEngine
import Testing

/// BootGuard against real files, real rename(2), and real flock(2) in throwaway
/// directories; no librime involved.
@Suite struct BootGuardTests {
    final class Directory {
        let url: URL
        init() throws {
            url = FileManager.default.temporaryDirectory.appending(path: "noema-bootguard-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit {
            chmod(url.path, 0o755)
            try? FileManager.default.removeItem(at: url)
        }
        var sentinel: URL { url.appending(path: BootGuard.sentinelFileName) }
    }

    static func record(at url: URL) throws -> BootGuard.Record {
        try JSONDecoder().decode(BootGuard.Record.self, from: Data(contentsOf: url))
    }

    @Test func countsUnfinishedBootsAndEntersSafeModeAtThreshold() throws {
        let directory = try Directory()
        let clock = 1_700_000_000.5
        for attempt in 1...2 {
            let guardian = BootGuard(userDataDir: directory.url, threshold: 2, now: { clock })
            #expect(guardian.begin() == .proceed(attempt: attempt))
            #expect(try Self.record(at: directory.sentinel) == .init(consecutiveFailures: attempt, lastAttemptEpoch: clock))
            guardian.releaseLock() // a crash: never disarmed
        }
        let guardian = BootGuard(userDataDir: directory.url, threshold: 2)
        #expect(guardian.begin() == .enterSafeMode(.bootCrashLoop))
        // Refusing does not raise the count further.
        #expect(try Self.record(at: directory.sentinel).consecutiveFailures == 2)
        // Recovery clears it; the next boot is attempt 1 again.
        #expect(guardian.clear())
        #expect(guardian.begin() == .proceed(attempt: 1))
        #expect(guardian.disarm())
        #expect(!FileManager.default.fileExists(atPath: directory.sentinel.path))
    }

    @Test func successfulBootDisarmsSentinel() throws {
        let directory = try Directory()
        for _ in 0..<5 {
            let guardian = BootGuard(userDataDir: directory.url, threshold: 2)
            #expect(guardian.begin() == .proceed(attempt: 1))
            #expect(guardian.disarm())
        }
        #expect(!FileManager.default.fileExists(atPath: directory.sentinel.path))
    }

    @Test func thresholdOfOneRefusesAfterOneUnfinishedBoot() throws {
        let directory = try Directory()
        #expect(BootGuard(userDataDir: directory.url, threshold: 1).begin() == .proceed(attempt: 1))
        #expect(BootGuard(userDataDir: directory.url, threshold: 1).begin() == .enterSafeMode(.bootCrashLoop))
    }

    @Test(arguments: ["not json", "{}", #"{"consecutiveFailures":-1,"lastAttemptEpoch":0}"#, ""])
    func corruptedSentinelEntersSafeMode(_ contents: String) throws {
        let directory = try Directory()
        try contents.write(to: directory.sentinel, atomically: true, encoding: .utf8)
        let guardian = BootGuard(userDataDir: directory.url)
        #expect(guardian.begin() == .enterSafeMode(.bootGuardCorrupted))
        #expect(guardian.clear())
        #expect(guardian.begin() == .proceed(attempt: 1))
    }

    @Test func oversizedSentinelIsCorrupted() throws {
        let directory = try Directory()
        try Data(repeating: 0x20, count: 10_000).write(to: directory.sentinel)
        #expect(BootGuard(userDataDir: directory.url).begin() == .enterSafeMode(.bootGuardCorrupted))
    }

    @Test func symlinkedSentinelIsNeverFollowed() throws {
        let directory = try Directory()
        let target = directory.url.appending(path: "elsewhere.json")
        try #"{"consecutiveFailures":0,"lastAttemptEpoch":0}"#.write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: directory.sentinel, withDestinationURL: target)
        let guardian = BootGuard(userDataDir: directory.url)
        #expect(guardian.begin() == .enterSafeMode(.bootGuardCorrupted))
        #expect(guardian.clear())
        // clear() removed the link, not its target.
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(guardian.begin() == .proceed(attempt: 1))
    }

    @Test func directoryInPlaceOfSentinelIsCorrupted() throws {
        let directory = try Directory()
        try FileManager.default.createDirectory(at: directory.sentinel, withIntermediateDirectories: false)
        let guardian = BootGuard(userDataDir: directory.url)
        #expect(guardian.begin() == .enterSafeMode(.bootGuardCorrupted))
        #expect(guardian.clear())
        #expect(guardian.begin() == .proceed(attempt: 1))
    }

    @Test func readOnlyDirectoryIsUnwritable() throws {
        // root ignores mode bits, so the negative case only holds for ordinary users.
        try #require(geteuid() != 0)
        let directory = try Directory()
        // With the lock file absent, creating it fails.
        #expect(chmod(directory.url.path, 0o555) == 0)
        #expect(BootGuard(userDataDir: directory.url).begin() == .enterSafeMode(.userDataDirUnwritable))
        // With the lock file present, locking works but the sentinel write fails.
        #expect(chmod(directory.url.path, 0o755) == 0)
        FileManager.default.createFile(atPath: directory.url.appending(path: BootGuard.lockFileName).path, contents: nil)
        #expect(chmod(directory.url.path, 0o555) == 0)
        let guardian = BootGuard(userDataDir: directory.url)
        #expect(guardian.begin() == .enterSafeMode(.userDataDirUnwritable))
        #expect(!FileManager.default.fileExists(atPath: directory.sentinel.path))
        #expect(chmod(directory.url.path, 0o755) == 0)
        #expect(guardian.begin() == .proceed(attempt: 1))
    }

    @Test func missingDirectoryIsUnwritable() throws {
        let directory = try Directory()
        let missing = directory.url.appending(path: "absent/deeper")
        #expect(BootGuard(userDataDir: missing).begin() == .enterSafeMode(.userDataDirUnwritable))
    }

    /// An external holder (another process, or another descriptor in this one) keeps
    /// the lock: the guard reports `.locked` and touches neither sentinel nor count.
    @Test func externalLockHolderBlocksWithoutTouchingSentinel() throws {
        let directory = try Directory()
        try #"{"consecutiveFailures":1,"lastAttemptEpoch":5}"#.write(to: directory.sentinel, atomically: true, encoding: .utf8)
        let lockPath = directory.url.appending(path: BootGuard.lockFileName).path
        let external = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        try #require(external >= 0)
        #expect(flock(external, LOCK_EX | LOCK_NB) == 0)

        let guardian = BootGuard(userDataDir: directory.url)
        #expect(guardian.begin() == .locked)
        #expect(guardian.arm() == .locked)
        #expect(!guardian.holdsLock)
        #expect(try Self.record(at: directory.sentinel) == .init(consecutiveFailures: 1, lastAttemptEpoch: 5))

        flock(external, LOCK_UN)
        close(external)
        #expect(guardian.begin() == .proceed(attempt: 2))
        #expect(guardian.holdsLock)
        // While this guard holds it, a second guard on the same directory is locked out.
        #expect(BootGuard(userDataDir: directory.url).begin() == .locked)
        guardian.releaseLock()
        #expect(!guardian.holdsLock)
    }

    @Test func symlinkedLockFileIsRefused() throws {
        let directory = try Directory()
        let target = directory.url.appending(path: "target.lock")
        FileManager.default.createFile(atPath: target.path, contents: nil)
        try FileManager.default.createSymbolicLink(
            at: directory.url.appending(path: BootGuard.lockFileName), withDestinationURL: target)
        #expect(BootGuard(userDataDir: directory.url).begin() == .enterSafeMode(.bootGuardCorrupted))
    }

    @Test func releasingOnDeinitFreesTheLock() throws {
        let directory = try Directory()
        do {
            let guardian = BootGuard(userDataDir: directory.url)
            #expect(guardian.begin() == .proceed(attempt: 1))
        }
        #expect(BootGuard(userDataDir: directory.url).begin() == .proceed(attempt: 2))
    }
}
