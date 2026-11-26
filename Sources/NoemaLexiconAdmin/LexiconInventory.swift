import Darwin
import Foundation
import NoemaCore
import NoemaLearning

/// What is installed: every `*.dict.yaml` of the built-in `rime-default`, each downloaded
/// `schemas/<set>/`, and each set's own `sets/<set>/`, with exact byte sizes; each set's
/// userdbs; the `.gram` models; and the learning store's statistics, read through a
/// `.readOnly` connection. Walks with `lstat` and never follows a symlink.
public struct LexiconInventory: Sendable, Hashable {
    public enum Source: String, Sendable, Hashable, Codable {
        /// The shipped `rime-default` (`builtin` set).
        case builtin
        /// `schemas/<set>/`, extracted from a lockfile download.
        case downloaded
        /// `sets/<set>/`, the set's own user data.
        case user
    }

    public struct Dictionary: Sendable, Hashable, Codable, Identifiable {
        public var id: String { "\(schemaSetID.rawValue)/\(source.rawValue)/\(relativePath)" }
        public var schemaSetID: SchemaSetID
        public var source: Source
        /// Relative to the scanned directory, e.g. `cn_dicts/8105.dict.yaml`.
        public var relativePath: String
        public var byteSize: Int64
    }

    public struct UserDB: Sendable, Hashable, Codable {
        public var schemaSetID: SchemaSetID
        public var name: String
        public var byteSize: Int64
    }

    public struct Model: Sendable, Hashable, Codable {
        public var fileName: String
        public var byteSize: Int64
    }

    public var dictionaries: [Dictionary]
    public var userDBs: [UserDB]
    public var models: [Model]
    public var learning: LearningStoreStats?
    /// Why the learning store could not be read, when it exists but failed to open.
    public var learningError: LearningStoreError?

    public func dictionaries(for set: SchemaSetID) -> [Dictionary] { dictionaries.filter { $0.schemaSetID == set } }

    public func totalDictionaryBytes(for set: SchemaSetID) -> Int64 {
        dictionaries(for: set).reduce(0) { $0 + $1.byteSize }
    }

    /// Deepest directory level scanned below each root; Rime dictionaries sit one or two deep.
    public static let maximumDepth = 4

    /// Scans `root` (`NoemaPaths.rimeUserDataDir()`) and the built-in `sharedDataDir`.
    public static func scan(root: URL, builtinSharedDataDir: URL?) -> LexiconInventory {
        var dictionaries: [Dictionary] = []
        if let builtin = builtinSharedDataDir {
            dictionaries += dictYAMLs(under: builtin).map {
                Dictionary(schemaSetID: .builtin, source: .builtin, relativePath: $0.0, byteSize: $0.1)
            }
        }
        var userDBs: [UserDB] = []
        for set in SchemaSetID.allCases {
            if set != .builtin {
                dictionaries += dictYAMLs(under: NoemaPaths.downloadedSchemaDir(set, root: root)).map {
                    Dictionary(schemaSetID: set, source: .downloaded, relativePath: $0.0, byteSize: $0.1)
                }
            }
            let setDir = NoemaPaths.schemaSetUserDataDir(set, root: root)
            dictionaries += dictYAMLs(under: setDir, maximumDepth: 0).map {
                Dictionary(schemaSetID: set, source: .user, relativePath: $0.0, byteSize: $0.1)
            }
            for name in (try? FileManager.default.contentsOfDirectory(atPath: setDir.path))?.sorted() ?? []
            where name.hasSuffix(".userdb") {
                let url = setDir.appending(path: name)
                guard FileSafety.isRealDirectory(url) else { continue }
                userDBs.append(UserDB(
                    schemaSetID: set, name: String(name.dropLast(".userdb".count)),
                    byteSize: regularFiles(under: url, maximumDepth: 1).reduce(0) { $0 + $1.1 }))
            }
        }
        let models = regularFiles(under: NoemaPaths.modelsDir(root: root), maximumDepth: 0)
            .filter { $0.0.hasSuffix(".gram") }
            .map { Model(fileName: $0.0, byteSize: $0.1) }

        var learning: LearningStoreStats?
        var learningError: LearningStoreError?
        let storeURL = NoemaPaths.learningStoreURL(root: root)
        if FileSafety.fileType(storeURL) != nil {
            do {
                let store = try LearningStore(url: storeURL, mode: .readOnly)
                defer { store.close() }
                learning = try store.stats()
            } catch {
                learningError = error
            }
        }
        return LexiconInventory(
            dictionaries: dictionaries, userDBs: userDBs, models: models, learning: learning, learningError: learningError)
    }

    static func dictYAMLs(under root: URL, maximumDepth: Int = maximumDepth) -> [(String, Int64)] {
        regularFiles(under: root, maximumDepth: maximumDepth).filter { $0.0.hasSuffix(".dict.yaml") }
    }

    /// Regular files under `root` (relative path, size), sorted; symlinks and special files
    /// are skipped, symlinked directories never entered.
    static func regularFiles(under root: URL, maximumDepth: Int) -> [(String, Int64)] {
        guard FileSafety.isRealDirectory(root) else { return [] }
        var result: [(String, Int64)] = []
        var pending: [(String, Int)] = [("", 0)]
        while let (relative, depth) = pending.popLast() {
            let directory = relative.isEmpty ? root : root.appending(path: relative)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [] {
                let child = relative.isEmpty ? name : "\(relative)/\(name)"
                var info = stat()
                guard lstat(root.appending(path: child).path, &info) == 0 else { continue }
                switch info.st_mode & S_IFMT {
                case S_IFREG: result.append((child, Int64(info.st_size)))
                case S_IFDIR where depth < maximumDepth: pending.append((child, depth + 1))
                default: continue
                }
            }
        }
        return result.sorted { $0.0 < $1.0 }
    }
}

/// Installs lockfile entries: a schema set is downloaded, verified, and extracted to
/// `schemas/<set>/`; a `.gram` is downloaded, verified, and renamed to `models/<fileName>`.
public struct LexiconInstaller: Sendable {
    public let root: URL
    public let downloader: DictionaryDownloader
    public let limits: SafeArchiveExtractor.Limits

    public init(root: URL, downloader: DictionaryDownloader = DictionaryDownloader(), limits: SafeArchiveExtractor.Limits = .default) {
        self.root = root
        self.downloader = downloader
        self.limits = limits
    }

    public enum Failure: Error, Sendable, Hashable {
        case download(DictionaryDownloader.Failure)
        case extract(SafeArchiveExtractor.Failure)
        case io(String)
    }

    /// Where `entry` is installed.
    public func destination(of entry: DictionaryLockfile.Entry) -> URL? {
        switch entry.kind {
        case .schemaSet: entry.schemaSetID.map { NoemaPaths.downloadedSchemaDir($0, root: root) }
        case .gram: entry.fileName.map { NoemaPaths.modelsDir(root: root).appending(path: $0) }
        }
    }

    @discardableResult
    public func install(_ entry: DictionaryLockfile.Entry) async throws(Failure) -> URL {
        guard let destination = destination(of: entry) else { throw .io("entry \(entry.id) has no destination") }
        let downloads = root.appending(path: ".downloads", directoryHint: .isDirectory)
        let download: DictionaryDownloader.Download
        do {
            download = try await downloader.download(entry, into: downloads)
        } catch {
            throw .download(error)
        }
        defer { unlink(download.file.path) }
        switch entry.archive {
        case .zip:
            do {
                try SafeArchiveExtractor.extract(
                    archive: download.file, expectedSHA256: entry.sha256, into: destination,
                    stripComponents: entry.stripComponents ?? 0, limits: limits)
            } catch {
                throw .extract(error)
            }
        case .raw:
            let directory = destination.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw .io("creating \(directory.path): \(error)")
            }
            guard FileSafety.isRealDirectory(directory) else { throw .io("\(directory.path) is not a real directory") }
            guard rename(download.file.path, destination.path) == 0 else {
                throw .io("installing \(destination.path): errno \(errno)")
            }
            FileSafety.syncDirectory(directory)
        }
        return destination
    }
}
