// noema-rime-deployer: compiles Rime schemas into an isolated staging directory.
//
// usage: noema-rime-deployer --shared-dir <dir> --user-dir <dir> --staging-dir <dir>
//                            --log-dir <dir> --schema <id>
//                            [--schema-set <set>] [--lua-file <noema_learned.lua>]
//        noema-rime-deployer --version
//
// `RimeEngine` runs this as a subprocess, so librime's deployer never runs in the input
// method process and never writes the live `user_data_dir`. `--schema` must be a plain
// name (no `/`, `..`, or NUL). In the fresh, empty `--staging-dir`, which must be a real
// directory (not a symlink) other than `--user-dir` and `--shared-dir`, holding nothing but
// the caller's `.deploy.lock` (a regular file), it:
//   1. copies only the top-level `*.custom.yaml` of `--user-dir` (never its userdbs, lock
//      files, or `build/`), each of which must be a regular file, never a symlink, and
//      checks each copy against the input snapshot;
//   2. with `--lua-file`, copies it to `staging/lua/noema_learned.lua` and adds
//      `lua_translator@*noema_learned` to the `"engine/translators/+"` sequence of the
//      staged `<schema>.custom.yaml` patch (`SchemaPatch`: creating the file or key, or
//      joining the user's own `engine/translators/+` sequence, never duplicating a key);
//      `rime.lua` is never written;
//   3. points librime at `--shared-dir` and the staging directory and deploys; with
//      `--lua-file`, the compiled `engine/translators` must list
//      `lua_translator@*noema_learned`;
//   4. requires `staging/build/default.yaml`, `<schema>.schema.yaml`, the `.table.bin` of
//      every dictionary and the `.prism.bin` of every prism the schema names (for
//      `translator`, `reverse_lookup`, and each `script_translator@<tag>`/
//      `table_translator@<tag>`: `<ns>/dictionary`, and `<ns>/prism` or else that
//      dictionary), all non-empty, and loads the schema in a real session;
//   5. writes `staging/build/.noema-deploy-manifest.json` (`DeployManifest`, with
//      `requiredPrisms` and, with `--schema-set`, `schemaSetID`).
// Exit 0 only when every step succeeds and the inputs did not change while deploying;
// 1 on any failure (reason on stderr), 64 on usage errors.
import CRime
import Darwin
import Foundation
import NoemaCore
import NoemaEngine

func fail(_ message: String, status: Int32 = 1) -> Never {
    fputs("noema-rime-deployer: \(message)\n", stderr)
    exit(status)
}

struct Options {
    var shared: URL
    var user: URL
    var staging: URL
    var logs: URL
    var schemaID: String
    var schemaSet: SchemaSetID?
    var luaFile: URL?
}

/// The one entry the caller may create in `--staging-dir` before the deployer runs.
let deployLockName = ".deploy.lock"
let learnedTranslator = "lua_translator@*noema_learned"

func parseOptions(_ arguments: [String]) -> Options {
    var values: [String: String] = [:]
    var index = 0
    let required: Set = ["--shared-dir", "--user-dir", "--staging-dir", "--log-dir", "--schema"]
    let known = required.union(["--schema-set", "--lua-file"])
    while index < arguments.count {
        let flag = arguments[index]
        guard known.contains(flag), index + 1 < arguments.count, !arguments[index + 1].isEmpty else {
            fail("unknown or incomplete argument: \(flag)", status: 64)
        }
        guard values.updateValue(arguments[index + 1], forKey: flag) == nil else { fail("repeated \(flag)", status: 64) }
        index += 2
    }
    for flag in required.sorted() where values[flag] == nil { fail("missing \(flag)", status: 64) }
    func directory(_ flag: String) -> URL {
        let path = values[flag]!
        guard path.hasPrefix("/") else { fail("\(flag) must be absolute: \(path)", status: 64) }
        return URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
    }
    let schemaID = values["--schema"]!
    guard DeployManifest.isSafeName(schemaID) else { fail("--schema must be a plain name: \(schemaID)", status: 64) }
    var schemaSet: SchemaSetID?
    if let raw = values["--schema-set"] {
        guard let set = SchemaSetID(rawValue: raw) else { fail("unknown --schema-set: \(raw)", status: 64) }
        schemaSet = set
    }
    var luaFile: URL?
    if let path = values["--lua-file"] {
        guard path.hasPrefix("/") else { fail("--lua-file must be absolute: \(path)", status: 64) }
        luaFile = URL(filePath: path).standardizedFileURL
    }
    return Options(
        shared: directory("--shared-dir"), user: directory("--user-dir"), staging: directory("--staging-dir"),
        logs: directory("--log-dir"), schemaID: schemaID, schemaSet: schemaSet, luaFile: luaFile
    )
}

/// The canonical path of an existing directory, or nil.
func realDirectoryPath(_ url: URL) -> String? {
    guard let resolved = realpath(url.path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// `--staging-dir` must be a real directory itself (`lstat`, so never a symlink) and must
/// not be `--user-dir` or `--shared-dir` under any other spelling.
func checkStagingDirectory(_ options: Options) {
    var info = stat()
    guard lstat(options.staging.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
        fail("--staging-dir must be a real directory, not a symlink: \(options.staging.path)")
    }
    guard let staging = realDirectoryPath(options.staging) else { fail("cannot resolve \(options.staging.path)") }
    for (flag, url) in [("--user-dir", options.user), ("--shared-dir", options.shared)] {
        guard let other = realDirectoryPath(url) else { fail("cannot resolve \(flag) \(url.path)") }
        guard other != staging else { fail("--staging-dir must differ from \(flag): \(options.staging.path)") }
    }
}

func requireNoThrow<T>(_ what: String, _ body: () throws -> T) -> T {
    do {
        return try body()
    } catch {
        fail("\(what): \(error)")
    }
}

/// Copies the user's `*.custom.yaml` patches into the staging directory, byte for byte,
/// and checks each copy against the snapshot taken before.
func copyCustomPatches(_ options: Options, expected inputs: [DeployManifest.ManifestEntry]) {
    let names = requireNoThrow("listing \(options.user.path)") { try DeployManifest.userCustomPatchNames(in: options.user) }
    for name in names {
        let source = options.user.appending(path: name)
        let target = options.staging.appending(path: name)
        // O_NOFOLLOW | O_NONBLOCK, fstat S_IFREG, size cap: never a link out of --user-dir.
        let data = requireNoThrow("reading \(source.path)") { try DeployManifest.readRegularFile(source) }
        requireNoThrow("writing \(target.path)") { try data.write(to: target, options: .withoutOverwriting) }
        let (size, digest) = requireNoThrow("hashing \(target.path)") { try DeployManifest.hashFile(target, followSymlink: false) }
        guard inputs.contains(DeployManifest.ManifestEntry(relativePath: "user/\(name)", size: size, sha256: digest)) else {
            fail("user/\(name) changed while deploying")
        }
    }
}

/// Copies `--lua-file` to `staging/lua/noema_learned.lua`, checked against the input
/// snapshot, and patches the staged `<schema>.custom.yaml` to append the translator.
func installLearnedTranslator(_ options: Options, expected inputs: [DeployManifest.ManifestEntry]) {
    guard let luaFile = options.luaFile else { return }
    let data = requireNoThrow("reading \(luaFile.path)") { try DeployManifest.readRegularFile(luaFile) }
    let entry = requireNoThrow("hashing \(luaFile.path)") { try DeployManifest.extraInputs(luaFile: luaFile) }
    guard entry.allSatisfy(inputs.contains) else { fail("\(luaFile.path) changed while deploying") }
    let luaDirectory = options.staging.appending(path: "lua", directoryHint: .isDirectory)
    requireNoThrow("creating \(luaDirectory.path)") {
        try FileManager.default.createDirectory(at: luaDirectory, withIntermediateDirectories: false)
    }
    let target = luaDirectory.appending(path: NoemaPaths.learnedLuaFileName)
    requireNoThrow("writing \(target.path)") { try data.write(to: target, options: .withoutOverwriting) }
    guard DeployManifest.sha256(of: try? DeployManifest.readRegularFile(target)) == DeployManifest.sha256(of: data) else {
        fail("\(target.path) does not match \(luaFile.path)")
    }

    let patchURL = options.staging.appending(path: "\(options.schemaID).custom.yaml")
    var existing: String?
    if FileManager.default.fileExists(atPath: patchURL.path) {
        let bytes = requireNoThrow("reading \(patchURL.path)") { try DeployManifest.readRegularFile(patchURL) }
        guard let text = String(data: bytes, encoding: .utf8) else { fail("\(patchURL.path) is not UTF-8") }
        existing = text
    }
    guard let patched = SchemaPatch.appendingTranslator(learnedTranslator, to: existing) else {
        fail("\(patchURL.path) has no block `patch:` mapping to add \(learnedTranslator) to")
    }
    requireNoThrow("writing \(patchURL.path)") { try Data(patched.utf8).write(to: patchURL, options: .atomic) }
}

/// Runs `body` with traits whose C strings live exactly as long as the call.
func withTraits<T>(_ options: Options, _ body: (inout RimeTraits) -> T) -> T {
    var traits = RimeTraits()
    noema_rime_traits_init(&traits)
    let sources = [
        options.shared.path, options.staging.path, "Noema", "noema", NoemaVersion.current.description,
        "rime.noema.deployer", options.logs.path,
    ]
    let strings: [UnsafeMutablePointer<CChar>] = sources.map { source in
        guard let copy = strdup(source) else { fatalError("strdup failed") }
        return copy
    }
    defer { strings.forEach { free($0) } }
    traits.shared_data_dir = UnsafePointer(strings[0])
    traits.user_data_dir = UnsafePointer(strings[1])
    traits.distribution_name = UnsafePointer(strings[2])
    traits.distribution_code_name = UnsafePointer(strings[3])
    traits.distribution_version = UnsafePointer(strings[4])
    traits.app_name = UnsafePointer(strings[5])
    traits.log_dir = UnsafePointer(strings[6])
    traits.min_log_level = 2
    return body(&traits)
}

/// Every dictionary and prism the compiled schema names, each deduplicated in order: for
/// `translator`, `reverse_lookup`, and the tag of each `script_translator@<tag>` or
/// `table_translator@<tag>` in `engine/translators`, `<ns>/dictionary` and `<ns>/prism`
/// (else that dictionary). Each must be a plain name. With `required`, `engine/translators`
/// must list it, else the deploy fails.
func requiredDictionaries(
    api: UnsafeMutablePointer<RimeApi>, schemaID: String, requiringTranslator required: String?
) -> (dictionaries: [String], prisms: [String]) {
    var config = RimeConfig()
    guard api.pointee.schema_open(schemaID, &config) != 0 else { fail("cannot open compiled schema \(schemaID)") }
    defer { _ = api.pointee.config_close(&config) }
    func string(_ key: String) -> String? {
        api.pointee.config_get_cstring(&config, key).map { String(cString: $0) }
    }
    var namespaces = ["translator", "reverse_lookup"]
    let translators = api.pointee.config_list_size(&config, "engine/translators")
    let components = (0..<max(translators, 0)).compactMap { string("engine/translators/@\($0)") }
    // A patch librime merged without the learned translator must never pass as a deploy.
    if let required, !components.contains(required) {
        fail("compiled build/\(schemaID).schema.yaml engine/translators lacks \(required): \(components)")
    }
    for component in components {
        for prefix in ["script_translator@", "table_translator@"] where component.hasPrefix(prefix) {
            let tag = String(component.dropFirst(prefix.count))
            guard DeployManifest.isSafeName(tag) else { fail("translator tag is not a plain name: \(component)") }
            namespaces.append(tag)
        }
    }
    var dictionaries: [String] = []
    var prisms: [String] = []
    for namespace in namespaces {
        guard let dictionary = string("\(namespace)/dictionary"), !dictionary.isEmpty else { continue }
        guard DeployManifest.isSafeName(dictionary) else {
            fail("\(namespace)/dictionary is not a plain name: \(dictionary)")
        }
        let prism = string("\(namespace)/prism").flatMap { $0.isEmpty ? nil : $0 } ?? dictionary
        guard DeployManifest.isSafeName(prism) else { fail("\(namespace)/prism is not a plain name: \(prism)") }
        if !dictionaries.contains(dictionary) { dictionaries.append(dictionary) }
        if !prisms.contains(prism) { prisms.append(prism) }
    }
    return (dictionaries, prisms)
}

/// Opens a session on the staged build and requires librime to report `schemaID` active.
func schemaLoads(api: UnsafeMutablePointer<RimeApi>, schemaID: String) -> Bool {
    let session = api.pointee.create_session()
    guard session != 0 else { return false }
    defer { _ = api.pointee.destroy_session(session) }
    guard api.pointee.select_schema(session, schemaID) != 0 else { return false }
    var status = RimeStatus()
    noema_rime_status_init(&status)
    guard api.pointee.get_status(session, &status) != 0 else { return false }
    defer { _ = api.pointee.free_status(&status) }
    return status.schema_id.map { String(cString: $0) } == schemaID
}

func deploy(_ options: Options) {
    let fileManager = FileManager.default
    guard noema_rime_engine_api_available(), let api = noema_rime_get_api(),
          api.pointee.schema_open != nil, api.pointee.config_close != nil, api.pointee.config_get_cstring != nil,
          api.pointee.config_list_size != nil
    else { fail("librime API table lacks members the deployer requires") }
    // The staging directory must be fresh: never deploy over anything, least of all a live build.
    checkStagingDirectory(options)
    let existing = requireNoThrow("listing \(options.staging.path)") { try fileManager.contentsOfDirectory(atPath: options.staging.path) }
    guard existing.allSatisfy({ $0 == deployLockName }) else {
        fail("--staging-dir must be an empty directory: \(options.staging.path)")
    }
    if !existing.isEmpty {
        var info = stat()
        guard lstat(options.staging.appending(path: deployLockName).path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            fail("\(deployLockName) in --staging-dir must be a regular file")
        }
    }
    requireNoThrow("creating \(options.logs.path)") { try fileManager.createDirectory(at: options.logs, withIntermediateDirectories: true) }

    let inputs = requireNoThrow("snapshotting inputs") {
        try DeployManifest.inputs(sharedDataDir: options.shared, userDataDir: options.user, luaFile: options.luaFile)
    }
    copyCustomPatches(options, expected: inputs)
    installLearnedTranslator(options, expected: inputs)

    let build = options.staging.appending(path: "build")
    let (dictionaries, prisms) = withTraits(options) { traits -> ([String], [String]) in
        api.pointee.setup(&traits)
        api.pointee.deployer_initialize(&traits)
        guard api.pointee.deploy() != 0 else { fail("librime deployment failed; see \(options.logs.path)") }
        api.pointee.initialize(&traits)
        defer { api.pointee.finalize() }
        guard schemaLoads(api: api, schemaID: options.schemaID) else { fail("schema \(options.schemaID) does not load") }
        return requiredDictionaries(
            api: api, schemaID: options.schemaID, requiringTranslator: options.luaFile == nil ? nil : learnedTranslator)
    }

    for name in DeployManifest.requiredOutputPaths(schemaID: options.schemaID, dictionaries: dictionaries, prisms: prisms) {
        let url = build.appending(path: name)
        let (size, _) = requireNoThrow("required output build/\(name)") { try DeployManifest.hashFile(url, followSymlink: false) }
        guard size > 0 else { fail("required output build/\(name) is empty") }
    }
    let outputs = requireNoThrow("hashing outputs") { try DeployManifest.outputs(buildDir: build) }
    let after = requireNoThrow("re-snapshotting inputs") {
        try DeployManifest.inputs(sharedDataDir: options.shared, userDataDir: options.user, luaFile: options.luaFile)
    }
    guard after == inputs else { fail("inputs changed while deploying; retry") }

    let manifest = DeployManifest(
        schemaID: options.schemaID, inputs: inputs, outputs: outputs, requiredDictionaries: dictionaries,
        requiredPrisms: prisms, schemaSetID: options.schemaSet?.rawValue)
    let data = requireNoThrow("encoding the manifest") { try manifest.encoded() }
    requireNoThrow("writing the manifest") { try data.write(to: build.appending(path: DeployManifest.fileName), options: .atomic) }
    guard DeployManifest.validated(buildDir: build, schemaID: options.schemaID) == manifest else {
        fail("the staged build does not validate against its own manifest")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--version"] {
    print("noema-rime-deployer \(NoemaVersion.current)")
    exit(0)
}
deploy(parseOptions(arguments))
exit(0)
