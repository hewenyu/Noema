import Darwin
import Foundation
import NoemaCore
import NoemaLearning
import NoemaText

/// Moves a pre-schema-set installation's user data into the built-in set.
///
/// Before schema sets, librime's `user_data_dir` was the root itself: `noema_pinyin.userdb`,
/// `*.custom.yaml`, `user.yaml`, and `installation.yaml` sit directly in `<root>`. The built-in
/// set now runs in `<root>/sets/builtin/`, so on the first built-in boot after the upgrade,
/// under the root lock:
///
/// 1. `migrateFilesIfNeeded`, before `prepareBuild`: copies every legacy config file and
///    `*.userdb` directory that `sets/builtin/` lacks (regular files and real directories
///    only, never a symlink; never overwriting), so the first deployment compiles the user's
///    patches. A userdb is copied into `.migrate.<name>.<pid>.<uuid>` and renamed into place,
///    so a crash leaves either no copy or a whole one. The root originals stay for a downgrade.
/// 2. `importLegacyUserDBs`, after `initialize` and before the first session: exports each
///    migrated Mandarin pinyin userdb and merges its live entries into `learning.sqlite`
///    (`LearningStore.importMigratedEntries`, which keeps the larger frequency, so a retry
///    never doubles one), then exports `noema_learned.tsv`.
///
/// Only when both finish is `sets/builtin/.legacy-migrated` written; until then every boot
/// retries, and an import failure never blocks the boot. A root without legacy files is
/// marked at once.
public enum LegacyRootMigrator {
    public static let markerFileName = ".legacy-migrated"
    static let temporaryPrefix = ".migrate."
    static let legacyConfigNames: Set<String> = ["user.yaml", "installation.yaml"]
    static let userDBSuffix = ".userdb"
    /// Exported userdb entries count at most this much once imported.
    public static let maximumImportedFrequency: Int64 = 1_000_000

    /// What phase 1 left for phase 2.
    public struct PendingMigration: Sendable, Hashable {
        /// Base names (`noema_pinyin`) of the legacy userdbs now in the built-in set.
        public var userDBs: [String]
        /// Whether every legacy file and userdb is now in the built-in set; the marker is
        /// written only then.
        public var filesComplete: Bool
    }

    public static func markerURL(builtinDir: URL) -> URL { builtinDir.appending(path: markerFileName) }

    public static func isMigrated(builtinDir: URL) -> Bool { FileSafety.isRegularFile(markerURL(builtinDir: builtinDir)) }

    // MARK: Phase 1

    /// Copies the legacy root files into `builtinDir`. Nil when nothing is pending: already
    /// migrated, a fresh root (marked here), or a root or `builtinDir` that is not a real
    /// directory (refused, nothing touched).
    public static func migrateFilesIfNeeded(root: URL, builtinDir: URL) -> PendingMigration? {
        if isMigrated(builtinDir: builtinDir) { return nil }
        let sets = builtinDir.deletingLastPathComponent()
        guard FileSafety.isRealDirectory(root), FileSafety.isRealDirectory(sets), FileSafety.isRealDirectory(builtinDir),
              let names = try? FileManager.default.contentsOfDirectory(atPath: root.path)
        else { return nil }
        removeLeftovers(in: builtinDir)

        var userDBs: [String] = []
        var complete = true
        var foundLegacy = false
        for name in names.sorted() where FileSafety.isPlainName(name) {
            let source = root.appending(path: name)
            let target = builtinDir.appending(path: name)
            if name.hasSuffix(".custom.yaml") || legacyConfigNames.contains(name) {
                guard FileSafety.isRegularFile(source) else { continue }
                foundLegacy = true
                if FileSafety.fileType(target) != nil { continue }
                do {
                    try FileSafety.writeAtomically(DeployManifest.readRegularFile(source), to: target, mode: 0o644)
                } catch {
                    complete = false
                }
            } else if name.hasSuffix(userDBSuffix) {
                let base = String(name.dropLast(userDBSuffix.count))
                guard FileSafety.isPlainName(base), FileSafety.isRealDirectory(source) else { continue }
                foundLegacy = true
                if FileSafety.fileType(target) == nil, !copyUserDB(source, to: target, in: builtinDir) {
                    complete = false
                    continue
                }
                if FileSafety.isRealDirectory(target) { userDBs.append(base) }
            }
        }
        guard foundLegacy else {
            return writeMarker(builtinDir: builtinDir) ? nil : PendingMigration(userDBs: [], filesComplete: true)
        }
        return PendingMigration(userDBs: userDBs, filesComplete: complete)
    }

    /// Copies the regular files of the directory `source` into a temporary directory in
    /// `parent`, then renames it to `target` (`RENAME_EXCL`). Any failure removes the copy.
    static func copyUserDB(_ source: URL, to target: URL, in parent: URL) -> Bool {
        let temporary = parent.appending(
            path: "\(temporaryPrefix)\(target.lastPathComponent).\(getpid()).\(UUID().uuidString)", directoryHint: .isDirectory)
        guard mkdir(temporary.path, 0o755) == 0 else { return false }
        var ok = false
        defer { if !ok { try? FileManager.default.removeItem(at: temporary) } }
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: source.path) else { return false }
        for entry in entries where FileSafety.isPlainName(entry) {
            let file = source.appending(path: entry)
            // LevelDB keeps only regular files here; a symlink or subdirectory (`lost/`) is skipped.
            guard FileSafety.isRegularFile(file) else { continue }
            guard copyRegularFile(file, to: temporary.appending(path: entry)) else { return false }
        }
        FileSafety.syncDirectory(temporary)
        guard renamex_np(temporary.path, target.path, UInt32(RENAME_EXCL)) == 0 else { return false }
        ok = true
        FileSafety.syncDirectory(parent)
        return true
    }

    /// Streams the regular file `source` (opened `O_NOFOLLOW`, checked with `fstat`) into a
    /// new file `target` (`O_EXCL | O_NOFOLLOW`), keeping its permission bits, and `fsync`s it.
    static func copyRegularFile(_ source: URL, to target: URL) -> Bool {
        let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { return false }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }
        let output = open(target.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, info.st_mode & 0o777)
        guard output >= 0 else { return false }
        var ok = fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_DATA)) == 0
        ok = ok && fsync(output) == 0
        ok = close(output) == 0 && ok
        return ok
    }

    /// Removes `.migrate.*` entries an interrupted earlier attempt left in `directory`
    /// (`removeItem` unlinks a symlink itself, never its target).
    static func removeLeftovers(in directory: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix(temporaryPrefix) {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }

    @discardableResult
    static func writeMarker(builtinDir: URL) -> Bool {
        (try? FileSafety.writeAtomically(Data("1\n".utf8), to: markerURL(builtinDir: builtinDir), mode: 0o644)) != nil
    }

    // MARK: Phase 2

    /// Merges the live entries of each userdb in `dictNames` (exported through `levers`, so
    /// librime must be initialized on `builtinDir` with no session open) into
    /// `<root>/learning.sqlite`, exports `noema_learned.tsv` into `builtinDir`, and, when
    /// that all succeeded and `filesComplete`, writes the marker. Returns whether it did.
    @discardableResult
    public static func importLegacyUserDBs(
        _ dictNames: [String], filesComplete: Bool, root: URL, builtinDir: URL, levers: any UserDictLevers
    ) -> Bool {
        var entries: [ImportedEntry] = []
        for dictName in dictNames where FileSafety.isPlainName(dictName) {
            guard let exported = export(dictName, builtinDir: builtinDir, levers: levers) else { return false }
            entries += parseExportedUserDB(exported)
        }
        if !dictNames.isEmpty {
            do {
                let store = try LearningStore(url: NoemaPaths.learningStoreURL(root: root))
                defer { store.close() }
                try store.importMigratedEntries(entries.map { ($0.event, $0.frequency) })
                _ = try LearnedSnapshotExporter.export(
                    from: store, to: builtinDir.appending(path: NoemaPaths.learnedTSVFileName))
            } catch {
                return false
            }
        }
        return filesComplete && writeMarker(builtinDir: builtinDir)
    }

    /// The export of `dictName` read from a fresh `0600` file in a private `.migrate.` directory.
    static func export(_ dictName: String, builtinDir: URL, levers: any UserDictLevers) -> String? {
        let directory = builtinDir.appending(
            path: "\(temporaryPrefix)probe.\(getpid()).\(UUID().uuidString)", directoryHint: .isDirectory)
        guard mkdir(directory.path, 0o700) == 0 else { return nil }
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = directory.appending(path: "export.tsv")
        let descriptor = open(probe.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        close(descriptor)
        guard levers.exportUserDict(dictName, to: probe) >= 0,
              let data = try? DeployManifest.readRegularFile(probe, maxSize: 1 << 30)
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// One learnable userdb entry and the frequency it carries over.
    public struct ImportedEntry: Sendable, Hashable {
        public var event: LearningCommitEvent
        public var frequency: Int64
    }

    /// The learnable entries of a userdb export: `<text>\t<code>\t<count>` lines, the count a
    /// plain integer (`export_user_dict`) or `c=<n> d=<…> t=<…>` (a raw userdb dump). Comments,
    /// blank and malformed lines, deleted entries (`c <= 0`), codes with a control character, and entries that are not
    /// canonical Mandarin full pinyin over Han text (`LearningCommitEvent.normalized`) are
    /// skipped. Frequencies are clamped to `1...maximumImportedFrequency`.
    public static func parseExportedUserDB(_ text: String) -> [ImportedEntry] {
        var result: [ImportedEntry] = []
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            guard !line.hasPrefix("#") else { continue }
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard columns.count >= 2, !columns[0].isEmpty, !columns[1].isEmpty else { continue }
            let count = columns.count >= 3 ? commitCount(columns[2]) : 1
            guard let count, count > 0 else { continue }
            let code = columns[1].trimmingCharacters(in: .whitespaces)
            guard !code.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { continue }
            let event = LearningCommitEvent(
                rawInput: TextNormalization.compactPinyinKey(code), preedit: code, text: columns[0],
                isMandarinPinyinSchema: true)
            guard let normalized = event.normalized(), normalized.text == columns[0] else { continue }
            result.append(ImportedEntry(event: event, frequency: min(count, maximumImportedFrequency)))
        }
        return result
    }

    /// `100` or the `c=` field of `c=100 d=0.5 t=1`; nil when neither parses.
    static func commitCount(_ field: String) -> Int64? {
        let trimmed = field.trimmingCharacters(in: .whitespaces)
        if let plain = Int64(trimmed) { return plain }
        for part in trimmed.split(separator: " ") where part.hasPrefix("c=") {
            return Int64(part.dropFirst(2))
        }
        return nil
    }
}
