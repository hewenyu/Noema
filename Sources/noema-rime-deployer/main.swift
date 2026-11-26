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
//   2. with `--lua-file`, copies it to `staging/lua/noema_learned.lua` and appends
//      `lua_translator@*noema_learned` to the schema's translators (`SchemaPatch`): a fresh
//      `<schema>.custom.yaml` when the user has none; otherwise the user's file, parsed by
//      librime only to list its `patch` keys, moves unchanged to
//      `<schema>.noema-user-custom.yaml` and a wrapper `<schema>.custom.yaml` includes its
//      `patch` and appends the translator; `rime.lua` is never written;
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
/// snapshot, and stages a `<schema>.custom.yaml` that appends the translator (`SchemaPatch`).
func installLearnedTranslator(
    _ options: Options, api: UnsafeMutablePointer<RimeApi>, expected inputs: [DeployManifest.ManifestEntry]
) {
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
    guard FileManager.default.fileExists(atPath: patchURL.path) else {
        let fresh = SchemaPatch.freshPatch(appending: learnedTranslator)
        requireNoThrow("writing \(patchURL.path)") { try Data(fresh.utf8).write(to: patchURL, options: .withoutOverwriting) }
        return
    }
    let bytes = requireNoThrow("reading \(patchURL.path)") { try DeployManifest.readRegularFile(patchURL) }
    guard let text = String(data: bytes, encoding: .utf8) else { fail("\(patchURL.path) is not UTF-8") }
    if SchemaPatch.names(learnedTranslator, in: text) { return }
    let configID = SchemaPatch.userPatchConfigID(schemaID: options.schemaID)
    let keys = userPatchKeys(api: api, yaml: text, path: patchURL.path, options: options)
    guard let wrapper = SchemaPatch.wrapper(appending: learnedTranslator, userConfigID: configID, userPatchKeys: keys) else {
        fail("\(patchURL.path) already uses every key that could append \(learnedTranslator): \(SchemaPatch.wrapperAppendKeys)")
    }
    let moved = options.staging.appending(path: "\(configID).yaml")
    requireNoThrow("writing \(moved.path)") { try bytes.write(to: moved, options: .withoutOverwriting) }
    requireNoThrow("writing \(patchURL.path)") { try Data(wrapper.utf8).write(to: patchURL, options: .atomic) }
}

/// The effective top-level keys of the `patch` mapping of `yaml`, read with librime's own
/// YAML parser (keys with `/` stay whole) and recursively following any `__include` /
/// `__patch` directives across `--staging-dir` and `--shared-dir` (plus local `:/...`
/// references), so keys introduced indirectly (such as `engine/translators/@next` via
/// `patch: { __include: common:/patch }`) are never overwritten by the wrapper.
func userPatchKeys(api: UnsafeMutablePointer<RimeApi>, yaml: String, path: String, options: Options) -> [String] {
    guard let load = api.pointee.config_load_string, let close = api.pointee.config_close,
          let begin = api.pointee.config_begin_map, let next = api.pointee.config_next, let end = api.pointee.config_end,
          let getCString = api.pointee.config_get_cstring
    else { fail("librime lacks the config API to read \(path)") }

    func resolveYAMLFile(stem: String) -> (url: URL, inShared: Bool)? {
        let trimmed = stem.hasSuffix(".yaml") ? String(stem.dropLast(5)) : stem
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.allSatisfy(DeployManifest.isSafeName) else { return nil }
        for (base, inShared) in [(options.staging, false), (options.shared, true)] {
            var url = base
            for component in parts.dropLast() { url = url.appending(path: component, directoryHint: .isDirectory) }
            url = url.appending(path: "\(parts.last!).yaml")
            if FileManager.default.fileExists(atPath: url.path) { return (url, inShared) }
        }
        return nil
    }

    /// Reads an external YAML file: `O_NOFOLLOW` under `--staging-dir` (never follows user
    /// symlinks), and allows regular-file symlinks under `--shared-dir` (matching
    /// `DeployManifest.inputs` and librime).
    func readExternalYAML(_ resolved: (url: URL, inShared: Bool)) -> String? {
        if !resolved.inShared {
            guard let bytes = try? DeployManifest.readRegularFile(resolved.url) else { return nil }
            return String(data: bytes, encoding: .utf8)
        }
        let maxYAMLBytes = 16 << 20
        let descriptor = open(resolved.url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= Int64(maxYAMLBytes)
        else { return nil }
        var data = Data()
        data.reserveCapacity(Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                if data.count + count > maxYAMLBytes { return nil }
                data.append(buffer, count: count)
            } else if count == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                return nil
            }
        }
        return String(data: data, encoding: .utf8)
    }

    func parseReference(_ raw: String) -> (stem: String?, mapPath: String) {
        let ref = raw.hasSuffix("?") ? String(raw.dropLast()) : raw
        guard let colon = ref.firstIndex(of: ":") else {
            return (nil, ref.hasPrefix("/") ? String(ref.dropFirst()) : ref)
        }
        let left = String(ref[..<colon])
        let right = String(ref[ref.index(after: colon)...])
        let mapPath = right.hasPrefix("/") ? String(right.dropFirst()) : right
        return (left.isEmpty ? nil : left, mapPath)
    }

    func splitDirective(
        in config: inout RimeConfig, at directivePath: String, refs: inout [String], inlineMaps: inout [String]
    ) {
        let listCount = api.pointee.config_list_size(&config, directivePath)
        if listCount > 0 {
            for index in 0..<listCount {
                let itemPath = "\(directivePath)/@\(index)"
                if let ref = getCString(&config, itemPath).map({ String(cString: $0) }), !ref.isEmpty {
                    refs.append(ref)
                } else {
                    inlineMaps.append(itemPath)
                }
            }
        } else if let single = getCString(&config, directivePath).map({ String(cString: $0) }), !single.isEmpty {
            refs.append(single)
        } else {
            inlineMaps.append(directivePath)
        }
    }

    var keys: [String] = []
    var visitedPatch: Set<String> = []
    var visitedRoot: Set<String> = []

    func collectPatch(in config: inout RimeConfig, fileKey: String, mapPath: String, depth: Int) {
        guard depth < 16 else { return }
        let token = "\(fileKey)#\(mapPath)"
        guard visitedPatch.insert(token).inserted else { return }
        var iterator = RimeConfigIterator()
        guard begin(&iterator, &config, mapPath) != 0 else { return }
        defer { end(&iterator) }
        var nestedRefs: [String] = []
        var inlineMapPaths: [String] = []
        while next(&iterator) != 0 {
            guard let rawKey = iterator.key else { continue }
            let key = String(cString: rawKey)
            if key == "__include" || key == "__patch" {
                let directivePath = iterator.path.map { String(cString: $0) } ?? (mapPath.isEmpty ? key : "\(mapPath)/\(key)")
                splitDirective(in: &config, at: directivePath, refs: &nestedRefs, inlineMaps: &inlineMapPaths)
            } else if !keys.contains(key) {
                keys.append(key)
            }
        }
        for inlinePath in inlineMapPaths {
            collectPatch(in: &config, fileKey: fileKey, mapPath: inlinePath, depth: depth + 1)
        }
        for ref in nestedRefs {
            let (stem, targetPath) = parseReference(ref)
            if let stem {
                guard let resolved = resolveYAMLFile(stem: stem), let text = readExternalYAML(resolved) else { continue }
                var external = RimeConfig()
                defer { _ = close(&external) }
                guard load(&external, text) != 0 else { continue }
                collectPatch(in: &external, fileKey: resolved.url.path, mapPath: targetPath, depth: depth + 1)
            } else {
                collectPatch(in: &config, fileKey: fileKey, mapPath: targetPath, depth: depth + 1)
            }
        }
    }

    /// Recursively traverses document/mapping roots (`__include` / `__patch` at root level,
    /// including multi-hop root includes and inline root `__patch` maps) and collects keys
    /// from any `patch` mapping found along the chain.
    func collectRoot(in config: inout RimeConfig, fileKey: String, rootPath: String, depth: Int) {
        guard depth < 16 else { return }
        let token = "\(fileKey)#\(rootPath)"
        guard visitedRoot.insert(token).inserted else { return }
        let patchPath = rootPath.isEmpty ? "patch" : "\(rootPath)/patch"
        collectPatch(in: &config, fileKey: fileKey, mapPath: patchPath, depth: depth)

        var refs: [String] = []
        var inlineMaps: [String] = []
        var iterator = RimeConfigIterator()
        if begin(&iterator, &config, rootPath) != 0 {
            defer { end(&iterator) }
            while next(&iterator) != 0 {
                guard let rawKey = iterator.key else { continue }
                let key = String(cString: rawKey)
                guard key == "__include" || key == "__patch" else { continue }
                let directivePath = iterator.path.map { String(cString: $0) } ?? (rootPath.isEmpty ? key : "\(rootPath)/\(key)")
                splitDirective(in: &config, at: directivePath, refs: &refs, inlineMaps: &inlineMaps)
            }
        }
        for inlinePath in inlineMaps {
            collectRoot(in: &config, fileKey: fileKey, rootPath: inlinePath, depth: depth + 1)
        }
        for ref in refs {
            let (stem, targetPath) = parseReference(ref)
            if let stem {
                guard let resolved = resolveYAMLFile(stem: stem), let text = readExternalYAML(resolved) else { continue }
                var external = RimeConfig()
                defer { _ = close(&external) }
                guard load(&external, text) != 0 else { continue }
                collectRoot(in: &external, fileKey: resolved.url.path, rootPath: targetPath, depth: depth + 1)
            } else {
                collectRoot(in: &config, fileKey: fileKey, rootPath: targetPath, depth: depth + 1)
            }
        }
    }

    var config = RimeConfig()
    defer { _ = close(&config) }
    guard load(&config, yaml) != 0 else { fail("\(path) is not YAML librime can parse") }
    collectRoot(in: &config, fileKey: path, rootPath: "", depth: 0)
    return keys
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
    installLearnedTranslator(options, api: api, expected: inputs)

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
