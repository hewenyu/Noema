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
