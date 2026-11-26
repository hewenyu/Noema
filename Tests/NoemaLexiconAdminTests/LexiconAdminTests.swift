import Darwin
import Foundation
import NoemaCore
import NoemaLearning
import NoemaLexiconAdmin
import Testing

let repositoryRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Suite struct DictionaryLockfileTests {
    static let validDigest = "e74bd5fcc3636d6c50d0bb1198da9346d4de862407519bd20ea5cc335cc2d26b"

    func lockfile(_ entries: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["version": 1, "entries": entries])
    }

    func schemaSetEntry(id: String = "rime-ice", set: String = "rime-ice", url: String = "https://example.org/a.zip",
                        sha: String = validDigest, gram: String? = nil) -> [String: Any] {
        var entry: [String: Any] = [
            "id": id, "kind": "schemaSet", "schemaSetID": set, "displayName": "x", "upstream": "https://example.org",
            "release": "1", "url": url, "sha256": sha, "size": 10, "license": "GPL-3.0", "archive": "zip",
            "defaultSchemaID": "rime_ice",
        ]
        if let gram { entry["optionalGramID"] = gram }
        return entry
    }

    @Test func vendoredLockfilePinsEverySetAndTheOptionalGram() throws {
        let lockfile = try DictionaryLockfile.load(from: repositoryRoot.appending(path: "vendor/dictionaries.lock.json"))
        for set in [SchemaSetID.wanxiang, .rimeIce, .mint] {
            let entry = try #require(lockfile.entry(for: set), "\(set) is pinned")
            #expect(entry.url.hasPrefix("https://"))
            #expect(entry.defaultSchemaID == set.defaultSchemaID)
            #expect(entry.size > 0 && !entry.license.isEmpty)
        }
        #expect(lockfile.entry(for: .mint)?.stripComponents == 1)
        let gram = try #require(lockfile.entry("wanxiang-lts-zh-hans"))
        #expect(gram.kind == .gram && gram.fileName == "wanxiang-lts-zh-hans.gram")
        #expect(lockfile.entry(for: .wanxiang)?.optionalGramID == gram.id)
        #expect(lockfile.entry(for: .builtin) == nil)
    }

    @Test(arguments: [
        String(repeating: "0", count: 64),           // placeholder
        String(repeating: "a", count: 64),           // placeholder
        String(validDigest.dropLast()),              // 63 digits
        validDigest.uppercased(),                    // not lowercase
        "sha256:" + validDigest,                     // prefixed
        String(validDigest.dropLast()) + "g",        // not hex
    ])
    func rejectsMalformedOrPlaceholderDigests(_ digest: String) throws {
        let data = try lockfile([schemaSetEntry(sha: digest)])
        #expect(throws: DictionaryLockfile.ValidationError.invalidSHA256(id: "rime-ice")) { try DictionaryLockfile.parse(data) }
    }

    @Test func urlsMustBeHTTPSUnlessLoopbackIsExplicitlyAllowed() throws {
        let loopback = try lockfile([schemaSetEntry(url: "http://127.0.0.1:8080/a.zip")])
        #expect(throws: DictionaryLockfile.ValidationError.self) { try DictionaryLockfile.parse(loopback) }
        #expect(try DictionaryLockfile.parse(loopback, allowLoopbackHTTP: true).entries.count == 1)
        for url in ["http://example.org/a.zip", "http://localhost/a.zip", "ftp://example.org/a.zip", "file:///tmp/a.zip",
                    "https://user:pw@example.org/a.zip", "https:///a.zip"] {
            let data = try lockfile([schemaSetEntry(url: url)])
            #expect(throws: DictionaryLockfile.ValidationError.invalidURL(id: "rime-ice", url), "\(url)") {
                try DictionaryLockfile.parse(data, allowLoopbackHTTP: true)
            }
        }
    }

    @Test func rejectsDuplicatesUnknownReferencesAndVersions() throws {
        let duplicate = try lockfile([schemaSetEntry(), schemaSetEntry(set: "mint")])
        #expect(throws: DictionaryLockfile.ValidationError.duplicateID("rime-ice")) { try DictionaryLockfile.parse(duplicate) }
        let sameSet = try lockfile([schemaSetEntry(), schemaSetEntry(id: "other")])
        #expect(throws: DictionaryLockfile.ValidationError.duplicateID("schemaSetID rime-ice")) { try DictionaryLockfile.parse(sameSet) }
        let dangling = try lockfile([schemaSetEntry(gram: "missing")])
        #expect(throws: DictionaryLockfile.ValidationError.unknownReference(id: "rime-ice", "missing")) {
            try DictionaryLockfile.parse(dangling)
        }
        let builtin = try lockfile([schemaSetEntry(set: "builtin")])
        #expect(throws: DictionaryLockfile.ValidationError.missingField(id: "rime-ice", "schemaSetID")) {
            try DictionaryLockfile.parse(builtin)
        }
        let future = try JSONSerialization.data(withJSONObject: ["version": 2, "entries": []])
        #expect(throws: DictionaryLockfile.ValidationError.unsupportedVersion(2)) { try DictionaryLockfile.parse(future) }
        let badID = try lockfile([schemaSetEntry(id: "../x")])
        #expect(throws: DictionaryLockfile.ValidationError.invalidID("../x")) { try DictionaryLockfile.parse(badID) }
    }
}

@Suite struct SafeArchiveExtractorTests {
    let directory: TemporaryDirectory
    var destination: URL { directory.url.appending(path: "schemas/rime-ice") }

    init() throws { directory = try TemporaryDirectory() }

    func write(_ zip: ZipBuilder) throws -> (URL, String) {
        let data = try zip.build()
        let url = directory.url.appending(path: "archive-\(UUID().uuidString).zip")
        try data.write(to: url)
        return (url, sha256Hex(data))
    }

    /// Nothing but the archives exists outside `destination` after a refused extraction.
    func expectNothingExtracted() throws {
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let schemas = directory.url.appending(path: "schemas")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: schemas.path)) ?? []
        #expect(leftovers.isEmpty, "\(leftovers)")
        #expect(!FileManager.default.fileExists(atPath: directory.url.appending(path: "evil").path))
    }

    @Test func extractsAValidArchiveAtomicallyAndReplacesAnOldOne() throws {
        var zip = ZipBuilder()
        zip.directory("cn_dicts")
        zip.file("default.yaml", "schema_list: []\n")
        zip.file("rime_ice.schema.yaml", "schema: {schema_id: rime_ice}\n", deflate: true)
        zip.file("cn_dicts/base.dict.yaml", String(repeating: "你好\tni hao\t1\n", count: 50), deflate: true)
        let (archive, digest) = try write(zip)
        let report = try SafeArchiveExtractor.extract(archive: archive, expectedSHA256: digest, into: destination)
        #expect(report.files == 3 && report.directories == 1)
        #expect(try String(contentsOf: destination.appending(path: "cn_dicts/base.dict.yaml"), encoding: .utf8).hasPrefix("你好\tni hao"))
        var info = stat()
        #expect(lstat(destination.path, &info) == 0 && info.st_mode & 0o777 == 0o700)

        // A second extraction swaps in the new tree and drops the old one.
        var next = ZipBuilder()
        next.file("default.yaml", "schema_list: [rime_ice]\n")
        let (second, secondDigest) = try write(next)
        try SafeArchiveExtractor.extract(archive: second, expectedSHA256: secondDigest, into: destination)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["default.yaml"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.url.appending(path: "schemas").path) == ["rime-ice"])
    }

    @Test func stripsTheRootDirectoryOfASourceArchive() throws {
        var zip = ZipBuilder()
        zip.directory("oh-my-rime-abc")
        zip.file("oh-my-rime-abc/default.yaml", "x\n")
        zip.file("oh-my-rime-abc/dicts/a.dict.yaml", "y\n")
        let (archive, digest) = try write(zip)
        try SafeArchiveExtractor.extract(archive: archive, expectedSHA256: digest, into: destination, stripComponents: 1)
        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "dicts/a.dict.yaml").path))
        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "default.yaml").path))
    }

    @Test func checksTheDigestBeforeReadingAnyHeader() throws {
        let garbage = directory.url.appending(path: "garbage.zip")
        try Data("not a zip at all, just some bytes long enough to scan".utf8).write(to: garbage)
        let wrong = String(repeating: "ab", count: 32)
        // A wrong digest is reported as such, never as "not a zip": parsing never started.
        #expect(throws: SafeArchiveExtractor.Failure.sha256Mismatch(expected: wrong, actual: sha256Hex(Data("not a zip at all, just some bytes long enough to scan".utf8)))) {
            try SafeArchiveExtractor.extract(archive: garbage, expectedSHA256: wrong, into: destination)
        }
        // Negative control: with the right digest the same bytes reach the parser.
        #expect(throws: SafeArchiveExtractor.Failure.notAZip("no end of central directory record")) {
            try SafeArchiveExtractor.extract(archive: garbage, expectedSHA256: sha256Hex(Data("not a zip at all, just some bytes long enough to scan".utf8)), into: destination)
        }

        var zip = ZipBuilder()
        zip.file("default.yaml", "x\n")
        let (archive, _) = try write(zip)
        #expect(throws: SafeArchiveExtractor.Failure.self) {
            try SafeArchiveExtractor.extract(archive: archive, expectedSHA256: wrong, into: destination)
        }
        try expectNothingExtracted()
    }

    @Test func refusesASymlinkedArchive() throws {
        var zip = ZipBuilder()
        zip.file("default.yaml", "x\n")
        let (archive, digest) = try write(zip)
        let link = directory.url.appending(path: "link.zip")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: archive)
        #expect(throws: SafeArchiveExtractor.Failure.notRegularFile(link.path)) {
            try SafeArchiveExtractor.extract(archive: link, expectedSHA256: digest, into: destination)
        }
    }

    @Test(arguments: ["../evil", "a/../../evil", "/etc/evil", "a\\..\\evil", "./a", "a//b", "C:/evil", "a/\u{0}b"])
    func refusesPathTraversal(_ name: String) throws {
        var zip = ZipBuilder()
        zip.file("default.yaml", "x\n")
        zip.file(name, "pwned\n")
        let (archive, digest) = try write(zip)
        #expect(throws: SafeArchiveExtractor.Failure.self) {
            try SafeArchiveExtractor.extract(archive: archive, expectedSHA256: digest, into: destination)
        }
        do {
            try SafeArchiveExtractor.extract(archive: archive, expectedSHA256: digest, into: destination)
        } catch {
            guard case .unsafeEntry = error else {
                Issue.record("\(name): expected unsafeEntry, got \(error)")
                return
            }
        }
        try expectNothingExtracted()
    }

    @Test func refusesSymlinksFIFOsAndDevices() throws {
        for (name, mode) in [("link", UInt32(0o120777)), ("fifo", 0o010644), ("dev", 0o020644), ("sock", 0o140644)] {
            var zip = ZipBuilder()
            zip.file("default.yaml", "x\n")
            zip.items.append(.init(name: name, data: Data("/etc/passwd".utf8), mode: mode))
            let (archive, digest) = try write(zip)
            #expect(throws: SafeArchiveExtractor.Failure.self, "\(name)") {
                try SafeArchiveExtractor.extract(archive: archive, expectedSHA256: digest, into: destination)
            }
            try expectNothingExtracted()
        }
    }

    /// macOS `zip`/Archive Utility write host 19 ("OS X") with the same Unix `st_mode`; a
    /// symlink, FIFO, or device from that host is refused like one from host 3.
    @Test func refusesSpecialFilesFromAMacOSHost() throws {
        for (name, mode) in [("link", UInt32(0o120777)), ("fifo", 0o010644), ("dev", 0o020644)] {
            var zip = ZipBuilder()
            zip.file("default.yaml", "x\n")
            zip.items.append(.init(name: name, data: Data("/etc/passwd".utf8), mode: mode, madeBy: 0x1314))
            let (archive, digest) = try write(zip)
            do {
                try SafeArchiveExtractor.extract(archive: archive, expectedSHA256: digest, into: destination)
                Issue.record("\(name) from host 19 was extracted")
            } catch {
                guard case .unsafeEntry(name, _) = error else {
                    Issue.record("\(name): expected unsafeEntry, got \(error)")
                    continue
                }
            }
            try expectNothingExtracted()
        }
        // Negative control: a regular file from host 19 extracts.
        var zip = ZipBuilder()
        zip.items.append(.init(name: "default.yaml", data: Data("x\n".utf8), mode: 0o100644, madeBy: 0x1314))
        let (archive, digest) = try write(zip)
        #expect(try SafeArchiveExtractor.extract(archive: archive, expectedSHA256: digest, into: destination).files == 1)
    }

    /// `schemas/` is a symlink to another directory: the install refuses before creating
    /// anything there, so not a byte lands in the symlink's target.
    @Test func refusesASymlinkedDestinationParent() throws {
        let elsewhere = directory.url.appending(path: "elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let schemas = directory.url.appending(path: "schemas")
        try FileManager.default.createSymbolicLink(at: schemas, withDestinationURL: elsewhere)
        var zip = ZipBuilder()
        zip.file("default.yaml", "x\n")
        let (archive, digest) = try write(zip)
        #expect(throws: SafeArchiveExtractor.Failure.notRegularFile(schemas.path)) {
            try SafeArchiveExtractor.extract(archive: archive, expectedSHA256: digest, into: destination)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
        // Negative control: the same archive installs once `schemas/` is a real directory.
        try FileManager.default.removeItem(at: schemas)
        #expect(try SafeArchiveExtractor.extract(archive: archive, expectedSHA256: digest, into: destination).files == 1)
    }

    /// The EOCD record must end exactly at its declared comment: a real comment is fine,
    /// bytes appended after the record (or a lying comment length) are not a ZIP.
    @Test func endOfCentralDirectoryMustMatchItsCommentLength() throws {
        var commented = ZipBuilder()
        commented.file("default.yaml", "x\n")
        commented.comment = Data("built by a test".utf8)
        let (good, goodDigest) = try write(commented)
        #expect(try SafeArchiveExtractor.extract(archive: good, expectedSHA256: goodDigest, into: destination).files == 1)
        try FileManager.default.removeItem(at: destination)

        var lying = commented
        lying.declaredCommentLength = 3
        let (bad, badDigest) = try write(lying)
        #expect(throws: SafeArchiveExtractor.Failure.notAZip("no end of central directory record")) {
            try SafeArchiveExtractor.extract(archive: bad, expectedSHA256: badDigest, into: destination)
        }
        try expectNothingExtracted()
    }

    /// A ratio limit large enough to overflow `compressed * maxRatio` disables the ratio
    /// check instead of trapping.
    @Test func anOverflowingRatioLimitDoesNotTrap() throws {
        var zip = ZipBuilder()
        zip.file("default.yaml", String(repeating: "x", count: 64))
        let (archive, digest) = try write(zip)
        let limits = SafeArchiveExtractor.Limits(maxRatio: .max)
        #expect(try SafeArchiveExtractor.extract(archive: archive, expectedSHA256: digest, into: destination, limits: limits).files == 1)
    }

    @Test func refusesCaseOrNormalizationInsensitiveDuplicates() throws {
        for (first, second) in [("Default.yaml", "default.yaml"), ("caf\u{E9}.yaml", "cafe\u{301}.yaml")] {
            var zip = ZipBuilder()
            zip.file(first, "a\n")
            zip.file(second, "b\n")
            let (archive, digest) = try write(zip)
            #expect(throws: SafeArchiveExtractor.Failure.unsafeEntry(second, reason: "duplicate entry")) {
                try SafeArchiveExtractor.extract(archive: archive, expectedSHA256: digest, into: destination)
            }
            try expectNothingExtracted()
        }
    }

    @Test func refusesOversizedHighRatioAndTooManyEntries() throws {
        // 1 MiB of zeros deflates far beyond 100:1.
        var bomb = ZipBuilder()
        bomb.items.append(.init(name: "zeros.dict.yaml", data: Data(count: 1 << 20), deflate: true))
        let (bombArchive, bombDigest) = try write(bomb)
        #expect(throws: SafeArchiveExtractor.Failure.ratioExceeded("zeros.dict.yaml")) {
            try SafeArchiveExtractor.extract(archive: bombArchive, expectedSHA256: bombDigest, into: destination)
        }
        // Negative control: the same archive passes with a looser ratio.
        let loose = SafeArchiveExtractor.Limits(maxRatio: 100_000)
        #expect(try SafeArchiveExtractor.extract(
            archive: bombArchive, expectedSHA256: bombDigest, into: destination, limits: loose).totalBytes == 1 << 20)
        try FileManager.default.removeItem(at: destination)

        var big = ZipBuilder()
        big.items.append(.init(name: "a.dict.yaml", data: Data(repeating: 0x61, count: 600)))
        big.items.append(.init(name: "b.dict.yaml", data: Data(repeating: 0x62, count: 600)))
        let (bigArchive, bigDigest) = try write(big)
        #expect(throws: SafeArchiveExtractor.Failure.tooLarge(1200)) {
            try SafeArchiveExtractor.extract(
                archive: bigArchive, expectedSHA256: bigDigest, into: destination,
                limits: .init(maxTotalUncompressedBytes: 1000))
        }

        var many = ZipBuilder()
        for index in 0..<6 { many.file("f\(index).yaml", "x\n") }
        let (manyArchive, manyDigest) = try write(many)
        #expect(throws: SafeArchiveExtractor.Failure.tooManyEntries(6)) {
            try SafeArchiveExtractor.extract(
                archive: manyArchive, expectedSHA256: manyDigest, into: destination, limits: .init(maxEntries: 5))
        }
        try expectNothingExtracted()
    }

    @Test func refusesAnEntryThatInflatesPastItsDeclaredSize() throws {
        var zip = ZipBuilder()
        zip.items.append(.init(name: "liar.yaml", data: Data(repeating: 0x61, count: 4000), deflate: true, declaredSize: 100))
        let (archive, digest) = try write(zip)
        #expect(throws: SafeArchiveExtractor.Failure.corrupt("liar.yaml", reason: "inflates past its declared size")) {
            try SafeArchiveExtractor.extract(archive: archive, expectedSHA256: digest, into: destination)
        }
        try expectNothingExtracted()
    }
}

@Suite struct DictionaryDownloaderTests {
    @Test func downloadsFromLoopbackVerifiesAndInstallsASchemaSet() async throws {
        let directory = try TemporaryDirectory()
        var zip = ZipBuilder()
        zip.file("default.yaml", "schema_list: [{schema: rime_ice}]\n")
        zip.file("cn_dicts/8105.dict.yaml", "---\nname: 8105\n...\n一\tyi\n", deflate: true)
        let body = try zip.build()
        let server = try LoopbackHTTPServer(routes: [
            "/ice.zip": .init(status: 200, body: body),
            "/moved": .init(status: 302, headers: ["Location": "/ice.zip"]),
        ])
        defer { server.stop() }
        let json: [String: Any] = ["version": 1, "entries": [[
            "id": "rime-ice", "kind": "schemaSet", "schemaSetID": "rime-ice", "displayName": "雾凇", "upstream": "x",
            "release": "t", "url": server.url("/moved"), "sha256": sha256Hex(body), "size": body.count,
            "license": "GPL-3.0", "archive": "zip", "defaultSchemaID": "rime_ice",
        ]]]
        let lockfile = try DictionaryLockfile.parse(try JSONSerialization.data(withJSONObject: json), allowLoopbackHTTP: true)
        let installer = LexiconInstaller(root: directory.url, downloader: DictionaryDownloader(allowLoopbackHTTP: true))
        let installed = try await installer.install(try #require(lockfile.entry(for: .rimeIce)))
        #expect(installed == NoemaPaths.downloadedSchemaDir(.rimeIce, root: directory.url))
        #expect(FileManager.default.fileExists(atPath: installed.appending(path: "cn_dicts/8105.dict.yaml").path))
        #expect(server.requests == ["/moved", "/ice.zip"])
        let downloads = try FileManager.default.contentsOfDirectory(atPath: directory.url.appending(path: ".downloads").path)
        #expect(downloads.isEmpty, "the verified download was consumed: \(downloads)")
    }

    @Test func rejectsWrongDigestWrongSizeHTTPErrorsAndPlainHTTP() async throws {
        let directory = try TemporaryDirectory()
        let body = Data("payload".utf8)
        let server = try LoopbackHTTPServer(routes: [
            "/file": .init(status: 200, body: body),
            "/escape": .init(status: 302, headers: ["Location": "http://example.org/file"]),
        ])
        defer { server.stop() }
        let downloader = DictionaryDownloader(allowLoopbackHTTP: true)
        let target = directory.url.appending(path: "dl")
        let wrong = String(repeating: "cd", count: 32)

        await #expect(throws: DictionaryDownloader.Failure.sha256Mismatch(expected: wrong, actual: sha256Hex(body))) {
            try await downloader.download(url: server.url("/file"), expectedSHA256: wrong, expectedSize: 7, into: target)
        }
        await #expect(throws: DictionaryDownloader.Failure.tooLarge(7)) {
            try await downloader.download(url: server.url("/file"), expectedSHA256: sha256Hex(body), expectedSize: 3, into: target)
        }
        await #expect(throws: DictionaryDownloader.Failure.sizeMismatch(expected: 100, actual: 7)) {
            try await downloader.download(url: server.url("/file"), expectedSHA256: sha256Hex(body), expectedSize: 100, into: target)
        }
        await #expect(throws: DictionaryDownloader.Failure.http(status: 404)) {
            try await downloader.download(url: server.url("/missing"), expectedSHA256: sha256Hex(body), expectedSize: 7, into: target)
        }
        await #expect(throws: DictionaryDownloader.Failure.disallowedURL("http://example.org/file")) {
            try await downloader.download(url: server.url("/escape"), expectedSHA256: sha256Hex(body), expectedSize: 7, into: target)
        }
        await #expect(throws: DictionaryDownloader.Failure.disallowedURL(server.url("/file"))) {
            try await DictionaryDownloader().download(
                url: server.url("/file"), expectedSHA256: sha256Hex(body), expectedSize: 7, into: target)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty, "every refused download was removed")

        // Negative control: the right digest and size succeed, into a 0600 file.
        let download = try await downloader.download(
            url: server.url("/file"), expectedSHA256: sha256Hex(body), expectedSize: 7, into: target)
        #expect(try Data(contentsOf: download.file) == body)
        var info = stat()
        #expect(lstat(download.file.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
    }
}

@Suite struct LexiconInventoryTests {
    @Test func reportsDictionariesUserDBsModelsAndLearningStats() throws {
        let directory = try TemporaryDirectory()
        let root = directory.url.appending(path: "rime")
        let builtin = directory.url.appending(path: "rime-default")
        let fileManager = FileManager.default
        func write(_ text: String, _ url: URL) throws {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("abc", builtin.appending(path: "noema_pinyin.dict.yaml"))
        try write("schema", builtin.appending(path: "noema_pinyin.schema.yaml"))
        let ice = NoemaPaths.downloadedSchemaDir(.rimeIce, root: root)
        try write("12345", ice.appending(path: "rime_ice.dict.yaml"))
        try write("1234567", ice.appending(path: "cn_dicts/8105.dict.yaml"))
        try fileManager.createSymbolicLink(at: ice.appending(path: "linked.dict.yaml"), withDestinationURL: builtin.appending(path: "noema_pinyin.dict.yaml"))
        let iceSet = NoemaPaths.schemaSetUserDataDir(.rimeIce, root: root)
        try write("leveldb", iceSet.appending(path: "rime_ice.userdb/000001.log"))
        try write("gram!", NoemaPaths.modelsDir(root: root).appending(path: "wanxiang-lts-zh-hans.gram"))
        let store = try LearningStore(url: NoemaPaths.learningStoreURL(root: root))
        try store.recordBatch([LearningCommitEvent(rawInput: "nihao", text: "你好")])
        store.close()

        let inventory = LexiconInventory.scan(root: root, builtinSharedDataDir: builtin)
        #expect(inventory.dictionaries(for: .builtin).map(\.relativePath) == ["noema_pinyin.dict.yaml"])
        #expect(inventory.dictionaries(for: .rimeIce).map(\.relativePath) == ["cn_dicts/8105.dict.yaml", "rime_ice.dict.yaml"],
                "the symlinked dictionary is skipped")
        #expect(inventory.totalDictionaryBytes(for: .rimeIce) == 12)
        #expect(inventory.userDBs.map { "\($0.schemaSetID.rawValue)/\($0.name)/\($0.byteSize)" } == ["rime-ice/rime_ice/7"])
        #expect(inventory.models.map { "\($0.fileName)/\($0.byteSize)" } == ["wanxiang-lts-zh-hans.gram/5"])
        #expect(inventory.learning?.entryCount == 1 && inventory.learningError == nil)
    }

    @Test func aMissingStoreIsNotAnError() throws {
        let directory = try TemporaryDirectory()
        let inventory = LexiconInventory.scan(root: directory.url, builtinSharedDataDir: nil)
        #expect(inventory.dictionaries.isEmpty && inventory.learning == nil && inventory.learningError == nil)
        #expect(!FileManager.default.fileExists(atPath: NoemaPaths.learningStoreURL(root: directory.url).path))
    }
}
