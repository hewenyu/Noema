/// Errors shared across Noema modules.
public enum NoemaError: Error, Sendable, Hashable, Codable {
    /// librime could not be loaded or its API table is incomplete.
    case engineUnavailable(reason: String)
    /// A librime call returned failure.
    case engineCallFailed(function: String)
    /// A message or file declared a format version this build cannot read.
    case unsupportedVersion(found: Int, supported: ClosedRange<Int>)
    /// Input that violates a documented precondition.
    case invalidArgument(String)
}
