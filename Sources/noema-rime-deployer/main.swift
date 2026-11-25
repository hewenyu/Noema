// noema-rime-deployer: compiles Rime schemas into an isolated staging directory.
//
// usage: noema-rime-deployer --shared-dir <dir> --user-dir <dir> --staging-dir <dir>
//                            --log-dir <dir> --schema <id>
//        noema-rime-deployer --version
//
// `RimeEngine` runs this as a subprocess, so librime's deployer never runs in the input
// method process and never writes the live `user_data_dir`. In the fresh, empty
// `--staging-dir` it:
//   1. copies only the top-level `*.custom.yaml` of `--user-dir` (never its userdbs, lock
//      files, or `build/`), checking each copy against the input snapshot;
//   2. points librime at `--shared-dir` and the staging directory and deploys;
//   3. requires `staging/build/default.yaml`, `<schema>.schema.yaml`, and the
//      `.table.bin`/`.prism.bin` of the schema's `translator/dictionary`, all non-empty,
//      and loads the schema in a real session;
//   4. writes `staging/build/.noema-deploy-manifest.json` (`DeployManifest`).
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
}

func parseOptions(_ arguments: [String]) -> Options {
    var values: [String: String] = [:]
    var index = 0
    let known: Set = ["--shared-dir", "--user-dir", "--staging-dir", "--log-dir", "--schema"]
    while index < arguments.count {
        let flag = arguments[index]
        guard known.contains(flag), index + 1 < arguments.count, !arguments[index + 1].isEmpty else {
            fail("unknown or incomplete argument: \(flag)", status: 64)
        }
        guard values.updateValue(arguments[index + 1], forKey: flag) == nil else { fail("repeated \(flag)", status: 64) }
        index += 2
    }
    for flag in known.sorted() where values[flag] == nil { fail("missing \(flag)", status: 64) }
    func directory(_ flag: String) -> URL {
        let path = values[flag]!
        guard path.hasPrefix("/") else { fail("\(flag) must be absolute: \(path)", status: 64) }
        return URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
    }
    return Options(
        shared: directory("--shared-dir"), user: directory("--user-dir"), staging: directory("--staging-dir"),
        logs: directory("--log-dir"), schemaID: values["--schema"]!
    )
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
        let data = requireNoThrow("reading \(source.path)") { try Data(contentsOf: source) }
        requireNoThrow("writing \(target.path)") { try data.write(to: target, options: .withoutOverwriting) }
        let (size, digest) = requireNoThrow("hashing \(target.path)") { try DeployManifest.hashFile(target, followSymlink: false) }
        guard inputs.contains(DeployManifest.ManifestEntry(relativePath: "user/\(name)", size: size, sha256: digest)) else {
            fail("user/\(name) changed while deploying")
        }
    }
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

/// The compiled schema's `translator/dictionary`, if it names one.
func requiredDictionaries(api: UnsafeMutablePointer<RimeApi>, schemaID: String) -> [String] {
    var config = RimeConfig()
    guard api.pointee.schema_open(schemaID, &config) != 0 else { fail("cannot open compiled schema \(schemaID)") }
    defer { _ = api.pointee.config_close(&config) }
    guard let value = api.pointee.config_get_cstring(&config, "translator/dictionary") else { return [] }
    let dictionary = String(cString: value)
    return dictionary.isEmpty ? [] : [dictionary]
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
          api.pointee.schema_open != nil, api.pointee.config_close != nil, api.pointee.config_get_cstring != nil
    else { fail("librime API table lacks members the deployer requires") }
    // The staging directory must be fresh: never deploy over anything, least of all a live build.
    let existing = requireNoThrow("listing \(options.staging.path)") { try fileManager.contentsOfDirectory(atPath: options.staging.path) }
    guard existing.isEmpty else { fail("--staging-dir must be an empty directory: \(options.staging.path)") }
    requireNoThrow("creating \(options.logs.path)") { try fileManager.createDirectory(at: options.logs, withIntermediateDirectories: true) }

    let inputs = requireNoThrow("snapshotting inputs") {
        try DeployManifest.inputs(sharedDataDir: options.shared, userDataDir: options.user)
    }
    copyCustomPatches(options, expected: inputs)

    let build = options.staging.appending(path: "build")
    let dictionaries = withTraits(options) { traits -> [String] in
        api.pointee.setup(&traits)
        api.pointee.deployer_initialize(&traits)
        guard api.pointee.deploy() != 0 else { fail("librime deployment failed; see \(options.logs.path)") }
        api.pointee.initialize(&traits)
        defer { api.pointee.finalize() }
        guard schemaLoads(api: api, schemaID: options.schemaID) else { fail("schema \(options.schemaID) does not load") }
        return requiredDictionaries(api: api, schemaID: options.schemaID)
    }

    for name in DeployManifest.requiredOutputPaths(schemaID: options.schemaID, dictionaries: dictionaries) {
        let url = build.appending(path: name)
        let (size, _) = requireNoThrow("required output build/\(name)") { try DeployManifest.hashFile(url, followSymlink: false) }
        guard size > 0 else { fail("required output build/\(name) is empty") }
    }
    let outputs = requireNoThrow("hashing outputs") { try DeployManifest.outputs(buildDir: build) }
    let after = requireNoThrow("re-snapshotting inputs") {
        try DeployManifest.inputs(sharedDataDir: options.shared, userDataDir: options.user)
    }
    guard after == inputs else { fail("inputs changed while deploying; retry") }

    let manifest = DeployManifest(
        schemaID: options.schemaID, inputs: inputs, outputs: outputs, requiredDictionaries: dictionaries)
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
