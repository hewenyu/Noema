import Darwin
import Foundation
import NoemaCore
@testable import NoemaIPC
import Testing

/// Records every state an `IPCConnectionManager` reports, in order.
final class StateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [IPCConnectionState] = []
    private var messages: [AgentToIME] = []

    func record(_ state: IPCConnectionState) { lock.withLock { states.append(state) } }
    func record(_ message: AgentToIME) { lock.withLock { messages.append(message) } }
    var history: [IPCConnectionState] { lock.withLock { states } }
    var received: [AgentToIME] { lock.withLock { messages } }

    /// The history with reconnect delays and cooldown instants reduced to their kind.
    var shape: [String] {
        history.map { state in
            switch state {
            case .idle: "idle"
            case .connecting(let attempt): "connecting(\(attempt))"
            case .healthy: "healthy"
            case .degraded(let reason): "degraded(\(reason.rawValue))"
            case .reconnecting(let attempt, _): "reconnecting(\(attempt))"
            case .circuitOpen(let failures, _): "circuitOpen(\(failures))"
            }
        }
    }

    func attach(to manager: IPCConnectionManager) {
        manager.setStateObserver { [self] in record($0) }
        manager.setMessageHandler { [self] in record($0) }
    }
}

/// Polls `condition` every 5 ms until it holds or `timeout` passes.
func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() { return true }
        usleep(5_000)
    }
    return condition()
}

enum TestBinaries {
    /// The directory holding the test bundle, i.e. SwiftPM's bin path.
    static var binDirectory: URL {
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0, let name = info.dli_fname else {
            return URL(filePath: FileManager.default.currentDirectoryPath).appending(path: ".build/debug")
        }
        var url = URL(filePath: String(cString: name)).resolvingSymlinksInPath().deletingLastPathComponent()
        while url.path != "/" && url.pathExtension != "xctest" { url = url.deletingLastPathComponent() }
        return url.deletingLastPathComponent()
    }

    static func path(_ name: String) throws -> String {
        let url = binDirectory.appending(path: name)
        try #require(FileManager.default.isExecutableFile(atPath: url.path), "\(name) is not built at \(url.path)")
        return url.path
    }

    static func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        let stderr = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: stdout, as: UTF8.self), String(decoding: stderr, as: UTF8.self))
    }
}

/// A plain C program, ad-hoc signed with `identifier`, that sleeps until killed: a real
/// ad-hoc peer whose audit token the verifier can inspect.
final class AdHocPeerProcess {
    static let identifier = "dev.noema.tests.adhoc-peer"
    let process = Process()
    let root: URL

    init() throws {
        let fm = FileManager.default
        root = fm.temporaryDirectory.appending(path: "noema-adhoc-peer-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appending(path: "peer.c"), binary = root.appending(path: "peer")
        try "#include <unistd.h>\nint main(void) { for (;;) pause(); }\n".write(to: source, atomically: true, encoding: .utf8)
        let compiled = try TestBinaries.run("/usr/bin/clang", ["-arch", "arm64", "-O1", "-o", binary.path, source.path])
        try #require(compiled.status == 0, "clang failed: \(compiled.stderr)")
        let signed = try TestBinaries.run(
            "/usr/bin/codesign", ["--force", "--sign", "-", "--identifier", Self.identifier, binary.path])
        try #require(signed.status == 0, "codesign failed: \(signed.stderr)")
        process.executableURL = binary
        try process.run()
    }

    /// The child's audit token via its task name port.
    func auditToken() throws -> Data {
        var port: mach_port_t = 0
        try #require(task_name_for_pid(mach_task_self_, process.processIdentifier, &port) == KERN_SUCCESS)
        defer { mach_port_deallocate(mach_task_self_, port) }
        return try #require(PeerIdentityVerifier.auditToken(ofTask: port))
    }

    func stop() {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: root)
    }
}

extension PeerIdentityPolicy {
    /// This test process by signing identifier, for real libxpc round trips. Tests run
    /// inside Apple's `swiftpm-testing-helper`, platform code for which libxpc's Team ID
    /// requirements never match, so libxpc tests pin the identifier (or a certificate, see
    /// `selfStrictByCertificate()`), not the Team ID.
    static func selfTest() throws -> PeerIdentityPolicy {
        let identifier = try #require(SelfCodeIdentity.current()?.signingIdentifier, "the test process has no valid signature")
        return .allowAdHocForTesting(signingIdentifiers: [identifier])
    }

    /// The anti-downgrade resolution of an ad-hoc request for this process: strict and
    /// pinned to its own Team ID and certificate when the runner is certificate-signed.
    static func resolvedSelf() throws -> PeerIdentityPolicy {
        let me = try #require(SelfCodeIdentity.current(), "the test process has no valid signature")
        let identifier = try #require(me.signingIdentifier)
        return .resolved(requested: .allowAdHocForTesting(signingIdentifiers: [identifier]), selfIdentity: me)
    }

    /// Strict, pinned to this process's leaf certificate (`sha1` replaces it), no Team ID;
    /// nil when the runner is not certificate-signed.
    static func selfStrictByCertificate(sha1: String? = nil) throws -> PeerIdentityPolicy? {
        let me = try #require(SelfCodeIdentity.current())
        guard me.isCertificateSigned, let identifier = me.signingIdentifier, let leaf = me.leafCertificateSHA1 else { return nil }
        return .strict(signingIdentifiers: [identifier], teamID: nil, leafCertificateSHA1: sha1 ?? leaf, requireHardenedRuntime: me.hasHardenedRuntime)
    }
}

/// Envelope helpers for crafted agent frames.
func agentFrame(_ message: AgentToIME, generationID: UInt64?, sequence: UInt64 = 1) throws -> Data {
    try IPCWireCodec.encode(IPCEnvelope(sequence: sequence, message: message, generationID: generationID))
}
