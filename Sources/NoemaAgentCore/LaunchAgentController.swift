import Foundation
import NoemaCore
import ServiceManagement

/// Registration state of the `Noema.app` LaunchAgent (`SMAppService.Status`).
public enum LaunchAgentStatus: String, Sendable, Hashable, CaseIterable {
    case enabled
    /// Registered, waiting for the user in System Settings > General > Login Items.
    case requiresApproval
    case notRegistered
    /// The plist is not in `Contents/Library/LaunchAgents` (e.g. an unbundled build).
    case notFound
    case unsupported
}

/// The boundary to launchd registration; tests substitute a recording fake.
public protocol LaunchAgentControlling: Sendable {
    var status: LaunchAgentStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettingsLoginItems()
}

/// `SMAppService.agent(plistName:)` for `Contents/Library/LaunchAgents/<plistName>`.
public struct SMAppServiceLaunchAgentController: LaunchAgentControlling {
    public let plistName: String

    public init(plistName: String = NoemaPaths.agentLaunchAgentPlistName) {
        self.plistName = plistName
    }

    private var service: SMAppService { SMAppService.agent(plistName: plistName) }

    public var status: LaunchAgentStatus {
        switch service.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .notFound
        @unknown default: .unsupported
        }
    }

    public func register() throws { try service.register() }
    public func unregister() throws { try service.unregister() }
    public func openSystemSettingsLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}
