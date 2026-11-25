import CryptoKit
import Darwin
import Foundation

/// What a deployment consumed and produced, written by `noema-rime-deployer` to
/// `build/.noema-deploy-manifest.json` and checked by `RimeEngine` before it trusts a build.
///
/// - `inputs`: every regular file under `sharedDataDir` (recursively, as `shared/<path>`) and
///   every top-level `*.custom.yaml` in `userDataDir` (as `user/<name>`), sorted by path. Any
///   added, changed, deleted, or renamed input changes this list, so `deployIfNeeded`
///   redeploys exactly when `inputs` differs from a fresh `DeployManifest.inputs(...)`.
/// - `outputs`: every regular file under `build/` except the manifest itself, sorted by path.
/// - `requiredDictionaries`: the compiled schema's `translator/dictionary`; each needs
///   `<dict>.table.bin` and `<dict>.prism.bin` among `outputs`.
public struct DeployManifest: Codable, Equatable, Sendable {
    public struct ManifestEntry: Codable, Hashable, Sendable {
        /// `/`-separated, relative, without `.` or `..` components.
        public var relativePath: String
        public var size: UInt64
        /// Lowercase hex SHA-256 of the file contents.
        public var sha256: String

        public init(relativePath: String, size: UInt64, sha256: String) {
            self.relativePath = relativePath
            self.size = size
            self.sha256 = sha256
        }
    }

    public static let currentVersion = 1
    public static let fileName = ".noema-deploy-manifest.json"

    public var version: Int
    public var schemaID: String
    public var inputs: [ManifestEntry]
    public var outputs: [ManifestEntry]
    public var requiredDictionaries: [String]

    public init(
        version: Int = DeployManifest.currentVersion,
        schemaID: String,
        inputs: [ManifestEntry],
        outputs: [ManifestEntry],
        requiredDictionaries: [String]
    ) {
        self.version = version
        self.schemaID = schemaID
        self.inputs = inputs
        self.outputs = outputs
        self.requiredDictionaries = requiredDictionaries
    }

    public enum Failure: Error, Equatable, Sendable {
        /// A path could not be read, listed, or hashed.
        case unreadable(String)
        /// A path that must be a regular file or a real directory is something else.
        case notRegular(String)
    }

    // MARK: Required outputs

    /// Outputs a usable build of `schemaID` must contain.
    public static func requiredOutputPaths(schemaID: String, dictionaries: [String]) -> [String] {
        ["default.yaml", "\(schemaID).schema.yaml"]
            + dictionaries.flatMap { ["\($0).table.bin", "\($0).prism.bin"] }
    }

    // MARK: Inputs

    /// The current deploy inputs on disk. Symlinked files are hashed through to their
    /// target; symlinked directories are not descended. Throws when anything is unreadable,
    /// so a doubtful input set is never mistaken for an unchanged one.
    public static func inputs(sharedDataDir: URL, userDataDir: URL) throws(Failure) -> [ManifestEntry] {
        var entries: [ManifestEntry] = []
        for relative in try regularFiles(under: sharedDataDir, followingFileSymlinks: true) {
            let (size, digest) = try hashFile(sharedDataDir.appending(path: relative))
            entries.append(ManifestEntry(relativePath: "shared/\(relative)", size: size, sha256: digest))
        }
        for name in try userCustomPatchNames(in: userDataDir) {
            let (size, digest) = try hashFile(userDataDir.appending(path: name))
            entries.append(ManifestEntry(relativePath: "user/\(name)", size: size, sha256: digest))
        }
        return entries.sorted { $0.relativePath < $1.relativePath }
    }

    /// Top-level `*.custom.yaml` names in `userDataDir` that are (or link to) regular files.
    public static func userCustomPatchNames(in userDataDir: URL) throws(Failure) -> [String] {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: userDataDir.path)
        } catch {
            throw .unreadable(userDataDir.path)
        }
        var patches: [String] = []
        for name in names.sorted() where name.hasSuffix(".custom.yaml") {
            var info = stat()
            guard stat(userDataDir.appending(path: name).path, &info) == 0 else { throw .unreadable(name) }
            if info.st_mode & S_IFMT == S_IFREG { patches.append(name) }
        }
        return patches
    }

    // MARK: Outputs

    /// Every regular file under `buildDir` except the manifest, hashed. A symlink or any
    /// other non-regular, non-directory entry fails: a build never points outside itself.
    public static func outputs(buildDir: URL) throws(Failure) -> [ManifestEntry] {
        var entries: [ManifestEntry] = []
        for relative in try regularFiles(under: buildDir, followingFileSymlinks: false) where relative != fileName {
            let (size, digest) = try hashFile(buildDir.appending(path: relative), followSymlink: false)
            entries.append(ManifestEntry(relativePath: relative, size: size, sha256: digest))
        }
        return entries
    }

    // MARK: Validation

    /// The manifest in `buildDir` when the build is complete and intact: the manifest
    /// decodes with `version == 1` and `schemaID`, lists `default.yaml`, the schema, and both
    /// compiled files of every required dictionary, and every listed output is still a
    /// regular file inside `buildDir` with the recorded size and SHA-256. Nil otherwise.
    public static func validated(buildDir: URL, schemaID: String) -> DeployManifest? {
        guard isRealDirectory(buildDir.path),
              let data = try? readRegularFile(buildDir.appending(path: fileName)),
              let manifest = try? JSONDecoder().decode(DeployManifest.self, from: data),
              manifest.version == currentVersion, manifest.schemaID == schemaID
        else { return nil }
        let listed = Set(manifest.outputs.map(\.relativePath))
        guard listed.count == manifest.outputs.count,
              requiredOutputPaths(schemaID: schemaID, dictionaries: manifest.requiredDictionaries)
                .allSatisfy(listed.contains)
        else { return nil }
        for entry in manifest.outputs {
            guard let components = safeComponents(entry.relativePath), entry.relativePath != fileName else { return nil }
            // Every parent inside build/ must be a real directory, never a symlink out of it.
            var parent = buildDir
            for component in components.dropLast() {
                parent = parent.appending(path: component)
                guard isRealDirectory(parent.path) else { return nil }
            }
            guard let (size, digest) = try? hashFile(buildDir.appending(path: entry.relativePath), followSymlink: false),
                  size == entry.size, digest == entry.sha256
            else { return nil }
        }
        return manifest
    }

    // MARK: Encoding

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    // MARK: File helpers

    /// SHA-256 and size of a regular file, read in 1 MiB chunks. With `followSymlink`
    /// false a symlink fails instead of being read through.
    public static func hashFile(_ url: URL, followSymlink: Bool = true) throws(Failure) -> (UInt64, String) {
        let flags = O_RDONLY | O_CLOEXEC | O_NONBLOCK | (followSymlink ? 0 : O_NOFOLLOW)
        let descriptor = open(url.path, flags)
        guard descriptor >= 0 else { throw .unreadable(url.path) }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw .unreadable(url.path) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw .notRegular(url.path) }
        var hasher = SHA256()
        var size: UInt64 = 0
        let chunk = 1 << 20
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunk, alignment: 1)
        defer { buffer.deallocate() }
        while true {
            let count = read(descriptor, buffer.baseAddress, chunk)
            if count < 0 {
                if errno == EINTR { continue }
                throw .unreadable(url.path)
            }
            if count == 0 { break }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[0..<count]))
            size += UInt64(count)
        }
        return (size, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }

    /// Contents of a regular file; a symlink or anything else fails.
    static func readRegularFile(_ url: URL) throws(Failure) -> Data {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw .unreadable(url.path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw .unreadable(url.path) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw .notRegular(url.path) }
        do {
            return try handle.readToEnd() ?? Data()
        } catch {
            throw .unreadable(url.path)
        }
    }

    static func isRealDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// Path components of a manifest path, or nil when it is empty, absolute, or holds
    /// an empty, `.`, or `..` component.
    static func safeComponents(_ path: String) -> [Substring]? {
        guard !path.isEmpty, !path.hasPrefix("/") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return components
    }

    /// Relative paths of the regular files under `root`, sorted. Directories are walked
    /// with `lstat`, so a symlinked directory is never descended. A symlink to a regular
    /// file counts when `followingFileSymlinks`; any other entry kind fails the walk.
    static func regularFiles(under root: URL, followingFileSymlinks: Bool) throws(Failure) -> [String] {
        guard isRealDirectory(root.path) else { throw .notRegular(root.path) }
        var result: [String] = []
        var pending: [String] = [""]
        while let relative = pending.popLast() {
            let directory = relative.isEmpty ? root : root.appending(path: relative)
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            } catch {
                throw .unreadable(directory.path)
            }
            for name in names {
                let child = relative.isEmpty ? name : "\(relative)/\(name)"
                let path = root.appending(path: child).path
                var info = stat()
                guard lstat(path, &info) == 0 else { throw .unreadable(path) }
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    pending.append(child)
                case S_IFREG:
                    result.append(child)
                case S_IFLNK where followingFileSymlinks:
                    var target = stat()
                    guard stat(path, &target) == 0 else { throw .unreadable(path) }
                    // A linked directory is not descended (librime would follow it, but
                    // a cycle could not be bounded); a linked file is an input.
                    if target.st_mode & S_IFMT == S_IFREG { result.append(child) }
                default:
                    throw .notRegular(path)
                }
            }
        }
        return result.sorted()
    }
}
