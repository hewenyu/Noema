import Foundation
import NoemaCore
import NoemaIPC
import NoemaLearning
import NoemaLexiconAdmin
import Observation

/// The Settings "词库" section's model, on the main actor.
///
/// Reads, never writes, what the input method owns: `LexiconInventory.scan` (installed
/// `*.dict.yaml` files and their sizes, userdbs, models, and `learning.sqlite` statistics
/// through a `.readOnly` connection) and `active-schema-set.json`, both off the main actor.
/// Installs a downloaded set from the lockfile (`LexiconInstaller`: verified download and
/// safe extraction into `schemas/<set>/`, off the main actor), and asks the running
/// `NoemaIME` to switch over XPC; the IME compiles and switches, and reports each phase.
@MainActor
@Observable
public final class LexiconController {
    public enum InstallState: Sendable, Hashable {
        case idle
        case installing
        case installed
        case failed(String)
    }

    /// What the agent can send the IME: the request ID and how many IME peers it reached.
    public typealias SwitchRequester = @MainActor (SchemaSetID, String?) -> (requestID: UUID, recipients: Int)

    public private(set) var inventory: LexiconInventory?
    public private(set) var activeRecord: ActiveSchemaSetRecord?
    public private(set) var lockfile: DictionaryLockfile?
    public private(set) var lockfileError: String?
    public private(set) var installedSets: Set<SchemaSetID> = [.builtin]
    public private(set) var installStates: [SchemaSetID: InstallState] = [:]
    /// The switch this controller requested last.
    public private(set) var lastRequest: (requestID: UUID, schemaSetID: SchemaSetID)?
    public private(set) var lastSwitchError: String?
    public private(set) var isRefreshing = false

    @ObservationIgnored public let root: URL
    @ObservationIgnored public let builtinSharedDataDir: URL?
    @ObservationIgnored public let lockfileURL: URL?
    @ObservationIgnored private let requestSwitch: SwitchRequester
    @ObservationIgnored private let installer: LexiconInstaller

    public init(
        root: URL = NoemaPaths.rimeUserDataDir(),
        builtinSharedDataDir: URL? = NoemaPaths.resolveSharedDataDir(bundle: .main),
        lockfileURL: URL? = NoemaPaths.resolveDictionaryLockfile(bundle: .main),
        installer: LexiconInstaller? = nil,
        requestSwitch: @escaping SwitchRequester
    ) {
        self.root = root
        self.builtinSharedDataDir = builtinSharedDataDir
        self.lockfileURL = lockfileURL
        self.installer = installer ?? LexiconInstaller(root: root)
        self.requestSwitch = requestSwitch
    }

    /// The set the IME boots into: the saved record's, else the built-in set.
    public var activeSchemaSetID: SchemaSetID { activeRecord?.schemaSetID ?? .builtin }

    /// `requestID`'s latest status in `service`, or nil when the IME has not reported it yet.
    public func switchStatus(in service: AgentServiceSnapshot) -> SchemaSetSwitchStatus? {
        guard let lastRequest, let status = service.lastSchemaSwitchStatus, status.requestID == lastRequest.requestID
        else { return nil }
        return status
    }

    /// Rescans the inventory, the active record, and the lockfile off the main actor.
    public func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        let root = root, builtin = builtinSharedDataDir, lockfileURL = lockfileURL
        let scan = await Task.detached(priority: .utility) { () -> Scan in
            var lockfile: DictionaryLockfile?
            var lockfileError: String?
            if let lockfileURL {
                do {
                    lockfile = try DictionaryLockfile.load(from: lockfileURL)
                } catch {
                    lockfileError = "\(error)"
                }
            } else {
                lockfileError = "no \(NoemaPaths.dictionaryLockfileName)"
            }
            let installed = Set(SchemaSetID.allCases.filter {
                NoemaPaths.installedSchemaDir($0, root: root, builtinSharedDataDir: builtin) != nil || $0 == .builtin
            })
            return Scan(
                inventory: LexiconInventory.scan(root: root, builtinSharedDataDir: builtin),
                activeRecord: ActiveSchemaSetRecord.load(from: NoemaPaths.activeSchemaSetURL(root: root)),
                lockfile: lockfile, lockfileError: lockfileError, installed: installed)
        }.value
        inventory = scan.inventory
        activeRecord = scan.activeRecord
        lockfile = scan.lockfile
        lockfileError = scan.lockfileError
        installedSets = scan.installed
    }

    /// Downloads, verifies, and extracts the lockfile's entry for `schemaSetID` into
    /// `schemas/<set>/`, off the main actor, then refreshes.
    public func install(schemaSetID: SchemaSetID) async {
        guard schemaSetID != .builtin else { return }
        if lockfile == nil { await refresh() }
        guard let entry = lockfile?.entry(for: schemaSetID) else {
            installStates[schemaSetID] = .failed(lockfileError ?? "the lockfile has no \(schemaSetID.rawValue) entry")
            return
        }
        installStates[schemaSetID] = .installing
        let installer = installer
        let outcome = await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                try await installer.install(entry)
                return nil
            } catch {
                return "\(error)"
            }
        }.value
        installStates[schemaSetID] = outcome.map(InstallState.failed) ?? .installed
        await refresh()
    }

    /// Asks the running IME to switch to `schemaSetID`; returns the request ID, or nil when
    /// the set is not installed or no IME is connected.
    @discardableResult
    public func switchTo(schemaSetID: SchemaSetID, schemaID: String? = nil) -> UUID? {
        guard installedSets.contains(schemaSetID) else {
            lastSwitchError = "\(schemaSetID.displayName) 尚未安装"
            return nil
        }
        let (requestID, recipients) = requestSwitch(schemaSetID, schemaID)
        lastRequest = (requestID, schemaSetID)
        lastSwitchError = recipients == 0 ? "输入法未连接到 Noema Agent，切换未发送" : nil
        return recipients == 0 ? nil : requestID
    }

    private struct Scan: Sendable {
        var inventory: LexiconInventory
        var activeRecord: ActiveSchemaSetRecord?
        var lockfile: DictionaryLockfile?
        var lockfileError: String?
        var installed: Set<SchemaSetID>
    }
}

extension AgentServiceCoordinator {
    /// A `LexiconController.SwitchRequester` sending through this coordinator.
    public var schemaSwitchRequester: LexiconController.SwitchRequester {
        { [weak self] set, schemaID in
            guard let self else { return (UUID(), 0) }
            let requestID = self.requestSchemaSetSwitch(schemaSetID: set, schemaID: schemaID)
            return (requestID, self.snapshot.lastSchemaSwitchRecipients)
        }
    }
}
