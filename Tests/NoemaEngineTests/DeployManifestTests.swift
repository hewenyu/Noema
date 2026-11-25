import Darwin
import Foundation
import NoemaEngine
import Testing

/// `DeployManifest` on real files in a throwaway directory; never initializes librime.
@Suite struct DeployManifestTests {
    let root: URL
    var shared: URL { root.appending(path: "shared") }
    var user: URL { root.appending(path: "user") }
    var build: URL { root.appending(path: "build") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "noema-manifest-tests-\(UUID().uuidString)")
        for directory in [shared, shared.appending(path: "lua"), user, build] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try write("schema_list: []\n", to: shared.appending(path: "default.yaml"))
        try write("-- lua\n", to: shared.appending(path: "lua/extra.lua"))
        try write("patch: {}\n", to: user.appending(path: "s.custom.yaml"))
        try write("not an input\n", to: user.appending(path: "user.yaml"))
        for name in ["default.yaml", "s.schema.yaml", "d.table.bin", "d.prism.bin", "d.reverse.bin"] {
            try write("compiled \(name)\n", to: build.appending(path: name))
        }
    }

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeManifest(dictionaries: [String] = ["d"], edit: (inout DeployManifest) -> Void = { _ in }) throws {
        var manifest = DeployManifest(
            schemaID: "s",
            inputs: try DeployManifest.inputs(sharedDataDir: shared, userDataDir: user),
            outputs: try DeployManifest.outputs(buildDir: build),
            requiredDictionaries: dictionaries
        )
        edit(&manifest)
        try manifest.encoded().write(to: build.appending(path: DeployManifest.fileName))
    }

    @Test func inputsCoverSharedFilesRecursivelyAndOnlyUserPatches() throws {
        defer { cleanUp() }
        let inputs = try DeployManifest.inputs(sharedDataDir: shared, userDataDir: user)
        #expect(inputs.map(\.relativePath) == ["shared/default.yaml", "shared/lua/extra.lua", "user/s.custom.yaml"])
        #expect(inputs[0].size == 16 && inputs[0].sha256.count == 64)
    }

    @Test func everyKindOfInputChangeChangesTheInputs() throws {
        defer { cleanUp() }
        let original = try DeployManifest.inputs(sharedDataDir: shared, userDataDir: user)
        func current() throws -> [DeployManifest.ManifestEntry] {
            try DeployManifest.inputs(sharedDataDir: shared, userDataDir: user)
        }
        // Same size, same modification time, different bytes.
        let lua = shared.appending(path: "lua/extra.lua")
        let date = try #require(try FileManager.default.attributesOfItem(atPath: lua.path)[.modificationDate] as? Date)
        try write("-- LUA\n", to: lua)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: lua.path)
        #expect(try current() != original)
        try write("-- lua\n", to: lua)
        #expect(try current() == original)
        // Rename, deletion.
        try FileManager.default.moveItem(at: lua, to: shared.appending(path: "lua/renamed.lua"))
        #expect(try current() != original)
        try FileManager.default.removeItem(at: shared.appending(path: "lua/renamed.lua"))
        #expect(try current() != original)
        try write("-- lua\n", to: lua)
        try FileManager.default.removeItem(at: user.appending(path: "s.custom.yaml"))
        #expect(try current() != original)
    }

    @Test func intactBuildValidates() throws {
        defer { cleanUp() }
        try writeManifest()
        let manifest = try #require(DeployManifest.validated(buildDir: build, schemaID: "s"))
        #expect(manifest.outputs.map(\.relativePath) == ["d.prism.bin", "d.reverse.bin", "d.table.bin", "default.yaml", "s.schema.yaml"])
        #expect(DeployManifest.validated(buildDir: build, schemaID: "other") == nil, "another schema's build")
    }

    @Test(arguments: ["d.table.bin", "d.prism.bin", "default.yaml", "s.schema.yaml", "d.reverse.bin"])
    func deletedOutputFailsValidation(_ name: String) throws {
        defer { cleanUp() }
        try writeManifest()
        try FileManager.default.removeItem(at: build.appending(path: name))
        #expect(DeployManifest.validated(buildDir: build, schemaID: "s") == nil)
    }

    @Test func requiredDictionaryOutputMustBeListed() throws {
        defer { cleanUp() }
        try writeManifest { $0.outputs.removeAll { $0.relativePath == "d.table.bin" } }
        #expect(DeployManifest.validated(buildDir: build, schemaID: "s") == nil)
    }

    @Test func changedBytesFailValidation() throws {
        defer { cleanUp() }
        try writeManifest()
        try write("compiled d.table.bix\n", to: build.appending(path: "d.table.bin"))
        #expect(DeployManifest.validated(buildDir: build, schemaID: "s") == nil)
    }

    @Test func symlinkedOutputFailsValidation() throws {
        defer { cleanUp() }
        try writeManifest()
        let table = build.appending(path: "d.table.bin")
        let outside = root.appending(path: "outside.bin")
        try FileManager.default.moveItem(at: table, to: outside)
        try FileManager.default.createSymbolicLink(at: table, withDestinationURL: outside)
        #expect(DeployManifest.validated(buildDir: build, schemaID: "s") == nil)
        #expect(throws: DeployManifest.Failure.self) { try DeployManifest.outputs(buildDir: build) }
    }

    @Test(arguments: ["../outside.bin", "/etc/hosts", "./d.table.bin", "", "a//b"])
    func escapingOutputPathFailsValidation(_ path: String) throws {
        defer { cleanUp() }
        try write("compiled d.table.bin\n", to: root.appending(path: "outside.bin"))
        try writeManifest { manifest in
            manifest.outputs.append(DeployManifest.ManifestEntry(relativePath: path, size: 0, sha256: ""))
        }
        #expect(DeployManifest.validated(buildDir: build, schemaID: "s") == nil)
    }

    @Test(arguments: ["symlink", "directory", "fifo"])
    func nonRegularCustomPatchFailsTheSnapshot(_ kind: String) throws {
        defer { cleanUp() }
        let evil = user.appending(path: "evil.custom.yaml")
        switch kind {
        case "symlink":
            try FileManager.default.createSymbolicLink(at: evil, withDestinationURL: URL(filePath: "/etc/hosts"))
        case "directory":
            try FileManager.default.createDirectory(at: evil, withIntermediateDirectories: false)
        default:
            try #require(mkfifo(evil.path, 0o600) == 0)
        }
        #expect(throws: DeployManifest.Failure.notRegular(evil.path)) {
            try DeployManifest.userCustomPatchNames(in: user)
        }
        #expect(throws: DeployManifest.Failure.notRegular(evil.path)) {
            try DeployManifest.inputs(sharedDataDir: shared, userDataDir: user)
        }
        #expect(throws: DeployManifest.Failure.self) { try DeployManifest.readRegularFile(evil) }
    }

    @Test func symlinkedSharedFileIsAnInputButAnythingElseLinkedFails() throws {
        defer { cleanUp() }
        let outside = root.appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try write("-- linked\n", to: outside.appending(path: "linked.lua"))
        let file = shared.appending(path: "linked.lua")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside.appending(path: "linked.lua"))
        #expect(try DeployManifest.inputs(sharedDataDir: shared, userDataDir: user).contains { $0.relativePath == "shared/linked.lua" })
        try FileManager.default.removeItem(at: file)

        let directory = shared.appending(path: "linked-dir")
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)
        #expect(throws: DeployManifest.Failure.notRegular(directory.path)) {
            try DeployManifest.inputs(sharedDataDir: shared, userDataDir: user)
        }
        try FileManager.default.removeItem(at: directory)

        let dangling = shared.appending(path: "lua/dangling.lua")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: root.appending(path: "missing.lua"))
        #expect(throws: DeployManifest.Failure.notRegular(dangling.path)) {
            try DeployManifest.inputs(sharedDataDir: shared, userDataDir: user)
        }
        try FileManager.default.removeItem(at: dangling)

        let fifo = outside.appending(path: "pipe")
        try #require(mkfifo(fifo.path, 0o600) == 0)
        let linkedFIFO = shared.appending(path: "pipe.yaml")
        try FileManager.default.createSymbolicLink(at: linkedFIFO, withDestinationURL: fifo)
        #expect(throws: DeployManifest.Failure.notRegular(linkedFIFO.path)) {
            try DeployManifest.inputs(sharedDataDir: shared, userDataDir: user)
        }
    }

    @Test(arguments: ["file", "symlink", "directory"])
    func unlistedEntryInBuildFailsValidation(_ kind: String) throws {
        defer { cleanUp() }
        try writeManifest()
        #expect(DeployManifest.validated(buildDir: build, schemaID: "s") != nil)
        let extra = build.appending(path: "extra.yaml")
        switch kind {
        case "file": try write("extra: true\n", to: extra)
        case "symlink": try FileManager.default.createSymbolicLink(at: extra, withDestinationURL: build.appending(path: "default.yaml"))
        default:
            try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: false)
            try write("nested\n", to: extra.appending(path: "nested.yaml"))
        }
        #expect(DeployManifest.validated(buildDir: build, schemaID: "s") == nil)
    }

    @Test(arguments: ["default.yaml", "s.schema.yaml", "d.table.bin", "d.prism.bin"])
    func emptyRequiredOutputFailsValidation(_ name: String) throws {
        defer { cleanUp() }
        try write("", to: build.appending(path: name))
        try writeManifest()
        #expect(try DeployManifest.outputs(buildDir: build).contains { $0.relativePath == name && $0.size == 0 })
        #expect(DeployManifest.validated(buildDir: build, schemaID: "s") == nil)
    }

    @Test func oversizedManifestFailsValidation() throws {
        defer { cleanUp() }
        try writeManifest()
        #expect(DeployManifest.validated(buildDir: build, schemaID: "s") != nil)
        let manifest = build.appending(path: DeployManifest.fileName)
        let handle = try FileHandle(forWritingTo: manifest)
        try handle.truncate(atOffset: UInt64(DeployManifest.maxReadSize) + 1)
        try handle.close()
        #expect(throws: DeployManifest.Failure.tooLarge(manifest.path)) { try DeployManifest.readRegularFile(manifest) }
        #expect(DeployManifest.validated(buildDir: build, schemaID: "s") == nil)
        let small = build.appending(path: "default.yaml")
        #expect(throws: DeployManifest.Failure.tooLarge(small.path)) { try DeployManifest.readRegularFile(small, maxSize: 4) }
        #expect(try DeployManifest.readRegularFile(small) == Data("compiled default.yaml\n".utf8))
    }

    @Test func unsafeDictionaryNameFailsValidation() throws {
        defer { cleanUp() }
        try writeManifest(dictionaries: ["d", "../d"])
        #expect(DeployManifest.validated(buildDir: build, schemaID: "s") == nil)
    }

    @Test(arguments: [("noema_pinyin", true), ("rime_ice.extended", true), ("", false), ("a/b", false),
                      ("..", false), ("../x", false), ("x..y", false), ("x\0y", false)])
    func safeNames(_ name: String, _ safe: Bool) {
        #expect(DeployManifest.isSafeName(name) == safe)
    }

    @Test func wrongVersionOrCorruptManifestFailsValidation() throws {
        defer { cleanUp() }
        try writeManifest { $0.version = 2 }
        #expect(DeployManifest.validated(buildDir: build, schemaID: "s") == nil)
        try write("{ not json", to: build.appending(path: DeployManifest.fileName))
        #expect(DeployManifest.validated(buildDir: build, schemaID: "s") == nil)
        try FileManager.default.removeItem(at: build.appending(path: DeployManifest.fileName))
        #expect(DeployManifest.validated(buildDir: build, schemaID: "s") == nil)
    }
}
