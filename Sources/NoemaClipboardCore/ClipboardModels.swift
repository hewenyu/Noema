import Foundation

/// What a history entry holds.
public enum ClipboardItemKind: String, Sendable, Hashable, Codable, CaseIterable {
    case text
    case image
}

/// `.sensitive` entries look like secrets (`ClipboardPrivacyFilter.classifySensitivity`): the
/// panel masks them until revealed and they expire after `sensitiveTTLSeconds`. Every entry,
/// standard or sensitive, is AES-GCM sealed at rest.
public enum ClipboardSensitivity: String, Sendable, Hashable, Codable, CaseIterable {
    case standard
    case sensitive
}

/// The panel's segmented filter.
public enum ClipboardFilter: String, Sendable, Hashable, Codable, CaseIterable {
    case all
    case text
    case image
    case pinned

    public var title: String {
        switch self {
        case .all: "全部"
        case .text: "文本"
        case .image: "图片"
        case .pinned: "已固定"
        }
    }
}

/// The app that owned the pasteboard (or was frontmost) when an entry was copied. A value
/// snapshot: never an `NSRunningApplication`.
public struct ClipboardSourceApp: Sendable, Hashable, Codable {
    public var bundleID: String?
    public var name: String?
    public var pid: Int32?

    public init(bundleID: String?, name: String?, pid: Int32? = nil) {
        self.bundleID = bundleID
        self.name = name
        self.pid = pid
    }
}

/// One history entry without its payload: what the list, the inspector, and the FTS index
/// need. `preview` is a short decrypted excerpt held only in memory (nil for images and for
/// entries that could not be decrypted).
public struct ClipboardEntryMetadata: Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: ClipboardItemKind
    public var source: ClipboardSourceApp
    public var byteSize: Int
    public var charCount: Int
    public var lineCount: Int
    public var imageWidth: Int?
    public var imageHeight: Int?
    public var blobDigest: String?
    public var sensitivity: ClipboardSensitivity
    public var isPinned: Bool
    public var createdAt: Date
    public var lastUsedAt: Date
    public var expiresAt: Date?
    public var preview: String?
    public var keyVersion: Int

    public init(
        id: String, kind: ClipboardItemKind, source: ClipboardSourceApp, byteSize: Int, charCount: Int, lineCount: Int,
        imageWidth: Int? = nil, imageHeight: Int? = nil, blobDigest: String? = nil, sensitivity: ClipboardSensitivity,
        isPinned: Bool, createdAt: Date, lastUsedAt: Date, expiresAt: Date?, preview: String?, keyVersion: Int = 1
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.byteSize = byteSize
        self.charCount = charCount
        self.lineCount = lineCount
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.blobDigest = blobDigest
        self.sensitivity = sensitivity
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.expiresAt = expiresAt
        self.preview = preview
        self.keyVersion = keyVersion
    }
}

/// A decrypted payload: plain text, or a canonical PNG with its PNG thumbnail.
public enum ClipboardEntryContent: Sendable, Hashable {
    case text(String)
    case image(pngData: Data, thumbnailData: Data, width: Int, height: Int)

    public var kind: ClipboardItemKind {
        switch self {
        case .text: .text
        case .image: .image
        }
    }
}

/// The pasteboard as the privacy filter sees it: metadata only. Payload reads are lazy
/// closures the caller runs only after `ClipboardPrivacyFilter.evaluate` returns `.capture`,
/// so a filtered copy is never read.
public struct ClipboardCaptureSnapshot {
    public var changeCount: Int
    /// Pasteboard-level types (`NSPasteboard.types`).
    public var pasteboardTypes: [String]
    /// The types of each `NSPasteboardItem`.
    public var itemTypes: [[String]]
    public var source: ClipboardSourceApp?
    public var isSecureInputActive: Bool
    public var readString: () -> String?
    public var readData: (String) -> Data?

    public init(
        changeCount: Int, pasteboardTypes: [String], itemTypes: [[String]] = [], source: ClipboardSourceApp?,
        isSecureInputActive: Bool, readString: @escaping () -> String? = { nil },
        readData: @escaping (String) -> Data? = { _ in nil }
    ) {
        self.changeCount = changeCount
        self.pasteboardTypes = pasteboardTypes
        self.itemTypes = itemTypes
        self.source = source
        self.isSecureInputActive = isSecureInputActive
        self.readString = readString
        self.readData = readData
    }

    /// Every type on the pasteboard and on each item.
    public var allTypes: Set<String> {
        Set(pasteboardTypes).union(itemTypes.joined())
    }
}

/// Why a pasteboard change was not recorded.
public enum ClipboardSkipReason: Sendable, Hashable {
    /// `IsSecureEventInputEnabled()`: a password field is focused.
    case secureInput
    /// Noema's own paste-back (`ignoredSelfChangeCounts` or `dev.noema.clipboard.self-paste`).
    case selfPaste
    /// A concealed/transient/auto-generated or password-manager marker type.
    case privacyMarker(String)
    /// The source app is on the blocklist.
    case blockedSource(String)
    /// File URLs only: the store never reads files from disk.
    case fileOnly
    /// No text or image type.
    case unsupported
}

/// What to read once the filter allows a change.
public enum ClipboardCapturePlan: Sendable, Hashable {
    case text
    /// The image type to read: `public.png` when offered, else TIFF, JPEG, or HEIC.
    case image(type: String)
}

public enum ClipboardCaptureDecision: Sendable, Hashable {
    case capture(ClipboardCapturePlan)
    case skip(ClipboardSkipReason)
}

/// Storage limits. Byte caps apply before decoding or encrypting anything.
public struct ClipboardStorageQuota: Sendable, Hashable {
    public var maxItems: Int
    public var maxTextBytes: Int
    public var maxImageBytes: Int
    public var maxTotalImageBytes: Int
    public var defaultTTLSeconds: TimeInterval
    public var sensitiveTTLSeconds: TimeInterval

    public init(
        maxItems: Int = 2_000, maxTextBytes: Int = 2 << 20, maxImageBytes: Int = 25 << 20,
        maxTotalImageBytes: Int = 200 << 20, defaultTTLSeconds: TimeInterval = 30 * 86_400,
        sensitiveTTLSeconds: TimeInterval = 15 * 60
    ) {
        self.maxItems = maxItems
        self.maxTextBytes = maxTextBytes
        self.maxImageBytes = maxImageBytes
        self.maxTotalImageBytes = maxTotalImageBytes
        self.defaultTTLSeconds = defaultTTLSeconds
        self.sensitiveTTLSeconds = sensitiveTTLSeconds
    }

    public static let `default` = ClipboardStorageQuota()

    public func ttl(for sensitivity: ClipboardSensitivity) -> TimeInterval {
        sensitivity == .sensitive ? sensitiveTTLSeconds : defaultTTLSeconds
    }
}

public enum ClipboardStoreState: Sendable, Hashable {
    case ready
    /// The login keychain refused the master key (locked, or access denied): no reads of
    /// sealed payloads, no writes, never plaintext. `retryUnlock()` tries again.
    case keychainLocked
}

public enum ClipboardError: Error, Sendable, Hashable {
    case keychainLocked
    case keychainFailure(Int32)
    case keyCorrupted
    case storeLocked
    case closed
    case openFailed(String, code: Int32)
    case notRegularFile(String)
    case notPrivateDirectory(String)
    case sqlite(String, code: Int32)
    case encryptionFailed
    case decryptionFailed
    case emptyContent
    case textTooLarge(Int)
    case imageTooLarge(Int)
    case imageDimensionsRejected(width: Int, height: Int)
    case imageDecodeFailed
    case invalidDigest(String)
    case blobIO(String, errno: Int32)
    case notFound(String)
}
