import CRime
import NoemaCore

/// Facts about the librime library loaded into this process.
public struct RimeRuntimeInfo: Sendable, Hashable, Codable {
    /// librime version string, e.g. "1.17.0".
    public let version: String
    /// Registration state of each probed module name.
    public let modules: [String: Bool]

    public init(version: String, modules: [String: Bool]) {
        self.version = version
        self.modules = modules
    }

    /// True when every probed module is registered.
    public var allModulesRegistered: Bool { modules.values.allSatisfy { $0 } }
}

/// Read-only access to the process-global librime API table.
///
/// librime is a process-wide singleton; this type never calls setup/initialize,
/// so it is safe to query from any thread. The raw `RimeApi` pointer stays internal.
public enum RimeRuntime {
    /// Modules Noema requires from the merged librime build.
    public static let requiredModules = ["core", "dict", "gears", "levers", "lua", "octagram", "grammar"]

    /// True when the linked librime exposes the API members Noema calls.
    public static var isAvailable: Bool { noema_rime_api_available() != 0 }

    /// The librime version string.
    public static func version() throws(NoemaError) -> String {
        guard let get_version = try api().pointee.get_version, let cString = get_version() else {
            throw .engineCallFailed(function: "get_version")
        }
        return String(cString: cString)
    }

    /// Whether a module with this name is registered (statically or as a merged plugin).
    public static func hasModule(_ name: String) throws(NoemaError) -> Bool {
        guard let find_module = try api().pointee.find_module else {
            throw .engineCallFailed(function: "find_module")
        }
        return name.withCString { find_module($0) } != nil
    }

    /// Version plus registration state of `modules`.
    public static func info(probing modules: [String] = requiredModules) throws(NoemaError) -> RimeRuntimeInfo {
        var registered: [String: Bool] = [:]
        for name in modules {
            registered[name] = try hasModule(name)
        }
        return RimeRuntimeInfo(version: try version(), modules: registered)
    }

    private static func api() throws(NoemaError) -> UnsafeMutablePointer<RimeApi> {
        guard isAvailable, let api = rime_get_api() else {
            throw .engineUnavailable(reason: "rime_get_api() returned an incomplete API table")
        }
        return api
    }
}
