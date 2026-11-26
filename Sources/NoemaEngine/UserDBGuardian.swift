import CRime
import Darwin
import Foundation
import NoemaCore
import NoemaLearning

/// The librime levers calls `UserDBGuardian` makes. `RimeUserDictLevers` is the real one; it
/// is valid only between `initialize` and `finalize`, with no session open, so no userdb is
/// held by a translator. `backup_user_dict`/`restore_user_dict` are deliberately absent:
/// they write into the working directory and report success on a corrupt userdb.
public protocol UserDictLevers {
    /// Names of the `*.userdb` in `user_data_dir`.
    func userDictNames() -> [String]
    /// Entries exported to `file` (`<text>\t<code>\t<weight>`), or a negative number on failure.
    func exportUserDict(_ name: String, to file: URL) -> Int
    /// Entries imported from `file` (`<text>\t<code>\t<weight>`), or a negative number on failure.
    func importUserDict(_ name: String, from file: URL) -> Int
}

/// The levers API of the in-process librime.
struct RimeUserDictLevers: UserDictLevers {
    let levers: UnsafeMutablePointer<RimeLeversApi>

    init?() {
        guard let levers = noema_rime_get_levers_api() else { return nil }
        self.levers = levers
    }

    func userDictNames() -> [String] {
        var iterator = RimeUserDictIterator()
        guard levers.pointee.user_dict_iterator_init(&iterator) != 0 else { return [] }
        defer { levers.pointee.user_dict_iterator_destroy(&iterator) }
        var names: [String] = []
        while let name = levers.pointee.next_user_dict(&iterator) { names.append(String(cString: name)) }
        return names
    }

    func exportUserDict(_ name: String, to file: URL) -> Int {
        Int(levers.pointee.export_user_dict(name, file.path))
    }

    func importUserDict(_ name: String, from file: URL) -> Int {
        Int(levers.pointee.import_user_dict(name, file.path))
    }
}

/// Keeps one schema set's LevelDB userdbs healthy and in step with `learning.sqlite`.
/// Runs only in a quiescent window (librime initialized, no session), on the one process
/// that holds the root lock.
///
/// - **Health**: `<dict>.userdb` must be a real directory (`lstat`; a symlink is corrupt),
///   hold no LevelDB `lost/` directory (left by a repair that dropped data), export
///   (`export_user_dict >= 0`) into a private probe file, and export at least half the
///   entries the store last projected into it. Every watermark read or written here is the
///   one of `(schemaSet, dictName)`, never a set-wide one.
/// - **Snapshots**: `snapshots/<set>/<dict>.snapshot.tsv` plus `<dict>.snapshot.meta.json`
///   (SHA-256, size, entry count, the `learningRevision` it contains), written only after a
///   successful export, each through a `0600` temporary file, `fsync`, and `rename(2)`.
/// - **Recovery ladder**: quarantine the corrupt `.userdb` into `.quarantine/`; import the
///   latest snapshot whose SHA-256 verifies and replay store entries newer than its
///   `learningRevision`; or else rebuild from every store entry. Then the export must succeed
///   again, and the watermark records what the userdb now holds.
public struct UserDBGuardian {
    public enum Corruption: String, Sendable, Hashable, Codable {
        case notADirectory
        case lostDirectory
        case exportFailed
    }

    public enum Health: Sendable, Hashable {
        case healthy(exported: Int)
        /// No `<dict>.userdb` yet.
        case missing
        case corrupted(Corruption)
        /// Readable, but holds far fewer entries than were projected into it.
        case diverged(exported: Int, projected: Int64)
    }

    public enum RecoveryMethod: String, Sendable, Hashable, Codable {
        case snapshotAndReplay
        case fullRebuild
    }

    public struct RecoveryReport: Sendable, Hashable {
        public var method: RecoveryMethod
        public var quarantined: URL?
        public var imported: Int
        public var exported: Int

        public init(method: RecoveryMethod, quarantined: URL?, imported: Int, exported: Int) {
            self.method = method
            self.quarantined = quarantined
            self.imported = imported
            self.exported = exported
        }
    }

    public enum MaintenanceOutcome: Sendable, Hashable {
        case healthy(projected: Int)
        case recovered(RecoveryReport)
        case reprojected(imported: Int)
        case nothingToDo
    }

    public enum Failure: Error, Sendable, Hashable {
        case io(String)
        case exportFailed(String)
        case importFailed(String)
        case store(LearningStoreError)
    }

    public struct SnapshotMetadata: Codable, Sendable, Hashable {
        public static let currentVersion = 1
        public var version: Int
        public var schemaSetID: String
        public var dictName: String
        public var sha256: String
        public var size: UInt64
        public var entryCount: Int
        /// The store revision the userdb (and so this snapshot) holds every entry up to.
        public var learningRevision: Int64
        public var createdAt: Date
    }

    public let schemaSet: SchemaSetID
    /// The set's librime `user_data_dir` (`sets/<set>/`).
    public let userDataDir: URL
    /// `snapshots/<set>/`.
    public let snapshotsDir: URL
    public let levers: any UserDictLevers

    public static let quarantineDirectoryName = ".quarantine"

    public init(schemaSet: SchemaSetID, userDataDir: URL, snapshotsDir: URL, levers: any UserDictLevers) {
        self.schemaSet = schemaSet
        self.userDataDir = userDataDir
        self.snapshotsDir = snapshotsDir
        self.levers = levers
    }

    public func userDBURL(_ dictName: String) -> URL { userDataDir.appending(path: "\(dictName).userdb") }

    public static func snapshotURL(_ dictName: String, in directory: URL) -> URL {
        directory.appending(path: "\(dictName).snapshot.tsv")
    }

    public static func snapshotMetadataURL(_ dictName: String, in directory: URL) -> URL {
        directory.appending(path: "\(dictName).snapshot.meta.json")
    }

    // MARK: Health

    public func checkHealth(_ dictName: String, store: LearningStore? = nil) throws(Failure) -> Health {
        try requirePlainName(dictName)
        let userdb = userDBURL(dictName)
        guard let type = FileSafety.fileType(userdb) else { return .missing }
        guard type == S_IFDIR else { return .corrupted(.notADirectory) }
        if FileSafety.fileType(userdb.appending(path: "lost")) != nil { return .corrupted(.lostDirectory) }
        let exported = try withProbe { probe in levers.exportUserDict(dictName, to: probe) }
        guard exported >= 0 else { return .corrupted(.exportFailed) }
        if let store, let mark = try storeCall({ () throws(LearningStoreError) in try store.watermark(for: schemaSet, dictName: dictName) }),
           mark.projectedCount > 0, Int64(exported) * 2 < mark.projectedCount {
            return .diverged(exported: exported, projected: mark.projectedCount)
        }
        return .healthy(exported: exported)
    }

    // MARK: Projection

    /// Imports the store entries changed after the watermark of `(schemaSet, dictName)` and
    /// advances it; other userdbs of the set keep their own. A watermark ahead of the store
    /// (a replaced store) replays everything. Returns how many entries were imported.
    @discardableResult
    public func project(_ dictName: String, store: LearningStore) throws(Failure) -> Int {
        try requirePlainName(dictName)
        let latest = try storeCall { () throws(LearningStoreError) in try store.latestRevision() }
        var since = try storeCall { () throws(LearningStoreError) in
            try store.watermark(for: schemaSet, dictName: dictName)
        }?.lastRevision ?? 0
        if since > latest { since = 0 }
        let entries = try storeCall { () throws(LearningStoreError) in try store.entriesSince(revision: since) }
        let imported = entries.isEmpty ? 0 : try importEntries(entries, into: dictName)
        let count = try storeCall { () throws(LearningStoreError) in try store.stats() }.entryCount
        try storeCall { () throws(LearningStoreError) in
            try store.setWatermark(for: schemaSet, dictName: dictName, lastRevision: latest, projectedCount: count)
        }
        return imported
    }

    // MARK: Recovery

    /// Quarantines `<dict>.userdb` (when present) and rebuilds it: verified snapshot plus
    /// replay, else every store entry. Throws when the rebuilt userdb still cannot export.
    public func recover(_ dictName: String, store: LearningStore?) throws(Failure) -> RecoveryReport {
        try requirePlainName(dictName)
        var quarantined = try quarantine(dictName)
        var method = RecoveryMethod.fullRebuild
        var imported = 0
        var revision: Int64 = 0
        if let (snapshot, metadata) = Self.verifiedSnapshot(dictName, schemaSet: schemaSet, in: snapshotsDir) {
            let count = levers.importUserDict(dictName, from: snapshot)
            if count >= 0 {
                method = .snapshotAndReplay
                imported = count
                revision = metadata.learningRevision
            } else if let again = try quarantine(dictName) {
                quarantined = quarantined ?? again
            }
        }
        if let store {
            let latest = try storeCall { () throws(LearningStoreError) in try store.latestRevision() }
            if revision > latest { revision = 0 }
            let entries = try storeCall { () throws(LearningStoreError) in
                method == .snapshotAndReplay ? try store.entriesSince(revision: revision) : try store.allEntries()
            }
            if !entries.isEmpty { imported += try importEntries(entries, into: dictName) }
            let count = try storeCall { () throws(LearningStoreError) in try store.stats() }.entryCount
            try storeCall { () throws(LearningStoreError) in
                try store.setWatermark(for: schemaSet, dictName: dictName, lastRevision: latest, projectedCount: count)
            }
            revision = latest
        }
        let exported = try withProbe { probe in levers.exportUserDict(dictName, to: probe) }
        guard exported >= 0 else { throw .exportFailed("\(dictName) still fails to export after recovery") }
        _ = try? writeSnapshot(dictName, learningRevision: revision)
        return RecoveryReport(method: method, quarantined: quarantined, imported: imported, exported: exported)
    }

    /// Health check, then the cheapest fix: incremental projection and a fresh snapshot when
    /// healthy; a full re-projection when diverged; the recovery ladder when corrupt; a
    /// rebuild from the store when missing and the store has entries.
    public func maintain(_ dictName: String, store: LearningStore?) throws(Failure) -> MaintenanceOutcome {
        switch try checkHealth(dictName, store: store) {
        case .healthy:
            guard let store else { return .healthy(projected: 0) }
            let projected = try project(dictName, store: store)
            let revision = try storeCall { () throws(LearningStoreError) in try store.latestRevision() }
            if projected > 0 || Self.verifiedSnapshot(dictName, schemaSet: schemaSet, in: snapshotsDir) == nil {
                _ = try? writeSnapshot(dictName, learningRevision: revision)
            }
            return .healthy(projected: projected)
        case .diverged:
            guard let store else { return .nothingToDo }
            try storeCall { () throws(LearningStoreError) in try store.resetWatermark(for: schemaSet, dictName: dictName) }
            return .reprojected(imported: try project(dictName, store: store))
        case .corrupted:
            return .recovered(try recover(dictName, store: store))
        case .missing:
            guard let store, try storeCall({ () throws(LearningStoreError) in try store.stats() }).entryCount > 0 else {
                return .nothingToDo
            }
            return .recovered(try recover(dictName, store: store))
        }
    }

    /// Moves `<dict>.userdb` into `.quarantine/<dict>.userdb.<epoch>.<uuid>`; nil when absent.
    @discardableResult
    public func quarantine(_ dictName: String) throws(Failure) -> URL? {
        let userdb = userDBURL(dictName)
        guard FileSafety.fileType(userdb) != nil else { return nil }
        let directory = userDataDir.appending(path: Self.quarantineDirectoryName, directoryHint: .isDirectory)
        try makePrivateDirectory(directory)
        let target = directory.appending(
            path: "\(dictName).userdb.\(Int(Date().timeIntervalSince1970)).\(UUID().uuidString.prefix(8))")
        guard rename(userdb.path, target.path) == 0 else { throw .io("quarantining \(userdb.path): errno \(errno)") }
        FileSafety.syncDirectory(userDataDir)
        return target
    }

    // MARK: Snapshots

    /// Exports `<dict>.userdb` and, only when that succeeds, replaces the snapshot and its
    /// metadata atomically.
    @discardableResult
    public func writeSnapshot(_ dictName: String, learningRevision: Int64) throws(Failure) -> SnapshotMetadata {
        try requirePlainName(dictName)
        try makePrivateDirectory(snapshotsDir)
        let (count, data) = try withProbe { probe throws(Failure) -> (Int, Data?) in
            let count = levers.exportUserDict(dictName, to: probe)
            guard count >= 0 else { return (count, nil) }
            do {
                return (count, try DeployManifest.readRegularFile(probe, maxSize: 1 << 30))
            } catch {
                throw .io("reading the export of \(dictName): \(error)")
            }
        }
        guard count >= 0, let data else { throw .exportFailed(dictName) }
        let metadata = SnapshotMetadata(
            version: SnapshotMetadata.currentVersion, schemaSetID: schemaSet.rawValue, dictName: dictName,
            sha256: DeployManifest.sha256(of: data) ?? "", size: UInt64(data.count), entryCount: count,
            // Whole seconds: the ISO 8601 sidecar keeps no fraction, so a reread compares equal.
            learningRevision: learningRevision, createdAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)))
        do {
            try FileSafety.writeAtomically(data, to: Self.snapshotURL(dictName, in: snapshotsDir))
            try FileSafety.writeAtomically(
                try JSONEncoder.noema.encode(metadata), to: Self.snapshotMetadataURL(dictName, in: snapshotsDir))
        } catch {
            throw .io("writing the snapshot of \(dictName): \(error)")
        }
        return metadata
    }

    /// The snapshot of `dictName` and its metadata when both are regular files, the metadata
    /// names this set and dictionary, and the snapshot's size and SHA-256 match it.
    public static func verifiedSnapshot(
        _ dictName: String, schemaSet: SchemaSetID, in directory: URL
    ) -> (URL, SnapshotMetadata)? {
        let snapshot = snapshotURL(dictName, in: directory)
        guard let data = try? DeployManifest.readRegularFile(snapshotMetadataURL(dictName, in: directory), maxSize: 64 << 10),
              let metadata = try? JSONDecoder.noema.decode(SnapshotMetadata.self, from: data),
              metadata.version == SnapshotMetadata.currentVersion,
              metadata.schemaSetID == schemaSet.rawValue, metadata.dictName == dictName,
              let (size, digest) = try? DeployManifest.hashFile(snapshot, followSymlink: false),
              size == metadata.size, digest == metadata.sha256
        else { return nil }
        return (snapshot, metadata)
    }

    /// `<text>\t<pinyin_norm>\t<frequency>` lines, the levers import format. Entries that
    /// could inject a line or a comment (`LearnedEntry.isSafeForTSV`) are skipped.
    public static func importTSV(_ entries: [LearnedEntry]) -> Data {
        var text = ""
        for entry in entries where entry.isSafeForTSV { text += "\(entry.text)\t\(entry.pinyinNorm)\t\(max(entry.frequency, 1))\n" }
        return Data(text.utf8)
    }

    // MARK: Helpers

    private func importEntries(_ entries: [LearnedEntry], into dictName: String) throws(Failure) -> Int {
        let count = try withProbe { probe throws(Failure) -> Int in
            do {
                try FileSafety.writeAtomically(Self.importTSV(entries), to: probe)
            } catch {
                throw .io("writing the import of \(dictName): \(error)")
            }
            return levers.importUserDict(dictName, from: probe)
        }
        guard count >= 0 else { throw .importFailed(dictName) }
        return count
    }

    /// Runs `body` with a fresh `0600` file in a private temporary directory under
    /// `snapshotsDir`, removed afterwards.
    private func withProbe<T>(_ body: (URL) throws(Failure) -> T) throws(Failure) -> T {
        try makePrivateDirectory(snapshotsDir)
        let directory = snapshotsDir.appending(path: ".probe.\(getpid()).\(UUID().uuidString)", directoryHint: .isDirectory)
        guard mkdir(directory.path, 0o700) == 0 else { throw .io("creating \(directory.path): errno \(errno)") }
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = directory.appending(path: "probe.tsv")
        let descriptor = open(probe.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw .io("creating \(probe.path): errno \(errno)") }
        close(descriptor)
        return try body(probe)
    }

    private func makePrivateDirectory(_ url: URL) throws(Failure) {
        if FileSafety.isRealDirectory(url) { return }
        do {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw .io("creating \(url.path): \(error)")
        }
        guard FileSafety.isRealDirectory(url) else { throw .io("\(url.path) is not a directory") }
    }

    private func requirePlainName(_ name: String) throws(Failure) {
        guard FileSafety.isPlainName(name) else { throw .io("not a plain dictionary name: \(name)") }
    }

    private func storeCall<T>(_ body: () throws(LearningStoreError) -> T) throws(Failure) -> T {
        do {
            return try body()
        } catch {
            throw .store(error)
        }
    }
}
