import Darwin
import Dispatch
import Foundation
import NoemaCore
import NoemaEngine
import NoemaLearning
import NoemaLexiconAdmin

/// `noema-cli lexicon list | verify | switch <set>`: inspect and switch schema sets offline.
///
/// `list` and `verify` only read (the learning store through a `.readOnly` connection).
/// `switch` is the offline counterpart of the agent's request: it deploys the target set
/// through the isolated `noema-rime-deployer` (staging, `.deploy.lock`, atomic swap), runs
/// the userdb guardian and the learned-phrase export, and saves `active-schema-set.json`,
/// all under the root's `.noema-rime.lock`. When a running NoemaIME holds that lock it
/// refuses and changes nothing; switch from Settings › 词库 instead.
enum LexiconCommand {
    static let usage = """
        usage: noema-cli lexicon list   [--root <dir>] [--lockfile <path>] [--shared-dir <dir>]
               noema-cli lexicon verify [--root <dir>] [--lockfile <path>] [--shared-dir <dir>]
               noema-cli lexicon switch <set> [--schema <id>] [--root <dir>] [--shared-dir <dir>]
                                        [--log-dir <dir>] [--lua-file <path>] [--deployer <path>]

          <set>               builtin, wanxiang, rime-ice, or mint
          --root <dir>        the root user data directory (default ~/Library/Application Support/Noema/rime)
          --lockfile <path>   dictionaries.lock.json (default: vendor/ in a checkout)
          --shared-dir <dir>  the built-in rime-default (default: the bundled or checked-out one)
          --schema <id>       the schema to open (default: the set's own)
          --lua-file <path>   noema_learned.lua (default: the bundled or checked-out one)
          --deployer <path>   noema-rime-deployer executable (default: beside noema-cli)
        """

    struct Options {
        var root: URL
        var lockfile: URL?
        var sharedDataDir: URL?
        var logDir: URL
        var luaFile: URL?
        var deployer: URL?
        var schemaID: String?
    }

    static func run(_ arguments: [String]) -> Int32 {
        guard let subcommand = arguments.first else {
            fputs(usage + "\n", stderr)
            return 2
        }
        if ["-h", "--help", "help"].contains(subcommand) {
            print(usage)
            return 0
        }
        var rest = Array(arguments.dropFirst())
        var target: String?
        if subcommand == "switch" {
            guard let first = rest.first, !first.hasPrefix("--") else {
                fputs("noema-cli lexicon switch: name a schema set\n" + usage + "\n", stderr)
                return 2
            }
            target = first
            rest.removeFirst()
        }
        let options: Options
        do {
            options = try parse(rest, command: "lexicon \(subcommand)")
        } catch {
            fputs("noema-cli \(error.message)\n", stderr)
            if error.status == 2 { fputs(usage + "\n", stderr) }
            return error.status
        }
        switch subcommand {
        case "list": return list(options)
        case "verify": return verify(options)
        case "switch":
            guard let target, let set = SchemaSetID(rawValue: target) else {
                fputs("noema-cli lexicon switch: unknown schema set \(target ?? "")\n" + usage + "\n", stderr)
                return 2
            }
            return runOnMainActor { await switchSet(set, options) }
        default:
            fputs(usage + "\n", stderr)
            return 2
        }
    }

    static func parse(_ arguments: [String], command: String) throws(CLIError) -> Options {
        var parser = OptionParser(command: command, arguments: arguments)
        let (values, _) = try parser.parse(
            valued: ["--root", "--lockfile", "--shared-dir", "--log-dir", "--lua-file", "--deployer", "--schema"], flags: [])
        if let schema = values["--schema"], !FileSafety.isPlainName(schema) {
            throw CLIError("\(command): --schema must be a plain name", status: 2)
        }
        return Options(
            root: values["--root"].map { absoluteURL($0) } ?? NoemaPaths.rimeUserDataDir(),
            lockfile: values["--lockfile"].map { absoluteURL($0, isDirectory: false) } ?? NoemaPaths.resolveDictionaryLockfile(),
            sharedDataDir: values["--shared-dir"].map { absoluteURL($0) } ?? NoemaPaths.resolveSharedDataDir(bundle: .main),
            logDir: values["--log-dir"].map { absoluteURL($0) } ?? NoemaPaths.logDir(),
            luaFile: values["--lua-file"].map { absoluteURL($0, isDirectory: false) } ?? NoemaPaths.resolveLearnedLua(bundle: .main),
            deployer: values["--deployer"].map { absoluteURL($0, isDirectory: false) },
            schemaID: values["--schema"])
    }

    // MARK: - list

    static func list(_ options: Options) -> Int32 {
        if let url = options.lockfile {
            do {
                let lockfile = try DictionaryLockfile.load(from: url)
                print("lockfile \(url.path) (version \(lockfile.version))")
                for entry in lockfile.entries {
                    print("  \(entry.id)\t\(entry.kind.rawValue)\t\(entry.release)\t\(formatted(entry.size))\tsha256 \(entry.sha256.prefix(12))…\t\(entry.license)")
                }
            } catch {
                print("lockfile \(url.path): INVALID (\(error))")
            }
        } else {
            print("lockfile: none found (pass --lockfile <path>)")
        }
        let active = ActiveSchemaSetRecord.load(from: NoemaPaths.activeSchemaSetURL(root: options.root))
        print("active \(active.map { "\($0.schemaSetID.rawValue) (\($0.schemaID))" } ?? "builtin (no active-schema-set.json)")")
        let inventory = LexiconInventory.scan(root: options.root, builtinSharedDataDir: options.sharedDataDir)
        for set in SchemaSetID.allCases {
            let installed = NoemaPaths.installedSchemaDir(set, root: options.root, builtinSharedDataDir: options.sharedDataDir) != nil
            print("set \(set.rawValue)\t\(installed ? "installed" : "not installed")\t\(formatted(inventory.totalDictionaryBytes(for: set)))")
            for dictionary in inventory.dictionaries(for: set) {
                print("  \(dictionary.source.rawValue)\t\(dictionary.relativePath)\t\(formatted(dictionary.byteSize))")
            }
            for userdb in inventory.userDBs where userdb.schemaSetID == set {
                print("  userdb\t\(userdb.name).userdb\t\(formatted(userdb.byteSize))")
            }
        }
        for model in inventory.models { print("model \(model.fileName)\t\(formatted(model.byteSize))") }
        if let stats = inventory.learning {
            print("learning entries=\(stats.entryCount) userPhrases=\(stats.userPhraseCount) commits=\(stats.totalFrequency) revision=\(stats.latestRevision)")
            for mark in stats.watermarks {
                print("  watermark \(mark.schemaSet)\trevision \(mark.lastRevision)\tprojected \(mark.projectedCount)")
            }
        } else if let error = inventory.learningError {
            print("learning: unreadable (\(error))")
        } else {
            print("learning: no learning.sqlite yet")
        }
        return 0
    }

    // MARK: - verify

    static func verify(_ options: Options) -> Int32 {
        var failures = 0
        func bad(_ message: String) {
            print("FAIL \(message)")
            failures += 1
        }
        if let url = options.lockfile {
            do {
                let lockfile = try DictionaryLockfile.load(from: url)
                print("ok   lockfile \(url.path): \(lockfile.entries.count) entries")
            } catch {
                bad("lockfile \(url.path): \(error)")
            }
        } else {
            bad("no dictionaries.lock.json found (pass --lockfile <path>)")
        }
        let record = ActiveSchemaSetRecord.load(from: NoemaPaths.activeSchemaSetURL(root: options.root))
        if let record, NoemaPaths.installedSchemaDir(
            record.schemaSetID, schemaID: record.schemaID, root: options.root, builtinSharedDataDir: options.sharedDataDir) == nil {
            bad("active-schema-set.json names \(record.schemaSetID.rawValue)/\(record.schemaID), which is not installed (NoemaIME boots builtin)")
        }
        for set in SchemaSetID.allCases {
            let build = NoemaPaths.schemaSetUserDataDir(set, root: options.root).appending(path: "build")
            // The schema the set runs: the active record's, else the one its build was made for.
            let deployed = (try? DeployManifest.readRegularFile(build.appending(path: DeployManifest.fileName)))
                .flatMap { try? JSONDecoder().decode(DeployManifest.self, from: $0) }?.schemaID
            let schemaID = record.flatMap { $0.schemaSetID == set ? $0.schemaID : nil } ?? deployed ?? set.defaultSchemaID
            guard NoemaPaths.installedSchemaDir(set, schemaID: schemaID, root: options.root, builtinSharedDataDir: options.sharedDataDir) != nil
            else {
                if set != .builtin, FileSafety.fileType(NoemaPaths.downloadedSchemaDir(set, root: options.root)) != nil {
                    bad("schemas/\(set.rawValue) exists but lacks default.yaml or \(schemaID).schema.yaml")
                }
                continue
            }
            if FileSafety.fileType(build) == nil {
                print("ok   \(set.rawValue): installed, not deployed yet")
            } else if let manifest = DeployManifest.validated(buildDir: build, schemaID: schemaID) {
                print("ok   \(set.rawValue): build/ verified for \(schemaID) (\(manifest.outputs.count) outputs)")
            } else {
                bad("\(set.rawValue): sets/\(set.rawValue)/build fails DeployManifest validation for \(schemaID); the next switch redeploys it")
            }
        }
        return failures == 0 ? 0 : 1
    }

    // MARK: - switch

    @MainActor
    static func switchSet(_ set: SchemaSetID, _ options: Options) async -> Int32 {
        guard let builtin = options.sharedDataDir else {
            fputs("noema-cli lexicon switch: no rime-default found; pass --shared-dir <dir>\n", stderr)
            return 1
        }
        let schemaID = options.schemaID ?? set.defaultSchemaID
        guard let shared = NoemaPaths.installedSchemaDir(set, schemaID: schemaID, root: options.root, builtinSharedDataDir: builtin)
        else {
            fputs("noema-cli lexicon switch: \(set.rawValue) is not installed under \(NoemaPaths.downloadedSchemaDir(set, root: options.root).path) (install it from Settings › 词库)\n", stderr)
            return 1
        }
        let lockMessage = "noema-cli lexicon switch: \(options.root.appending(path: BootGuard.lockFileName).path) is held (a running NoemaIME); switch from Settings › 词库 instead. Nothing changed.\n"
        // A clear refusal before any work; the engine takes the lock for real below.
        let probe = BootGuard(userDataDir: options.root)
        do {
            try FileManager.default.createDirectory(at: options.root, withIntermediateDirectories: true)
        } catch {
            fputs("noema-cli lexicon switch: cannot create \(options.root.path): \(error.localizedDescription)\n", stderr)
            return 1
        }
        switch probe.acquireLock() {
        case .acquired: probe.releaseLock()
        case .locked:
            fputs(lockMessage, stderr)
            return 1
        case .failed(let reason):
            fputs("noema-cli lexicon switch: cannot lock \(options.root.path): \(reason.rawValue)\n", stderr)
            return 1
        }
        let configuration = RimeEngineConfiguration(
            sharedDataDir: shared, userDataDir: options.root, logDir: options.logDir, schemaID: schemaID,
            deployerURL: options.deployer, schemaSetID: set, luaFile: options.luaFile)
        let engine: RimeEngine
        do {
            engine = try await RimeEngine.start(configuration: configuration)
        } catch {
            fputs("noema-cli lexicon switch: \(error)\n", stderr)
            return 1
        }
        defer { engine.shutdown() }
        if let reason = engine.safeModeReason {
            fputs(reason == .userDataDirLocked
                ? lockMessage
                : "noema-cli lexicon switch: \(set.rawValue) did not deploy (\(reason.rawValue)); its previous build/ is unchanged. See \(options.logDir.path)/noema-rime-deployer.log\n",
                stderr)
            return 1
        }
        // The root lock is held: this process is the single writer of learning.sqlite now.
        let store = try? LearningStore(url: NoemaPaths.learningStoreURL(root: options.root))
        defer { store?.close() }
        do {
            let report = try await engine.switchSchemaSet(
                to: set, sharedDataDir: shared, schemaID: schemaID, learningStore: store, luaFile: options.luaFile)
            print("switched to \(set.rawValue) (\(report.schemaID))")
            if let name = report.userDictName { print("  userdb \(name): \(report.userDBOutcome.map { "\($0)" } ?? "unchecked")") }
            if let failure = report.userDBFailure { print("  userdb maintenance failed: \(failure)") }
            if let lines = report.learnedLines { print("  noema_learned.tsv: \(lines) phrases") }
            print("  active-schema-set.json: \(report.savedActiveRecord ? "saved" : "NOT saved")")
            return report.savedActiveRecord ? 0 : 1
        } catch {
            fputs("noema-cli lexicon switch: \(error)\n", stderr)
            return 1
        }
    }

    // MARK: - Helpers

    static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Runs `body` on the main actor and waits, serving the main queue meanwhile.
    static func runOnMainActor(_ body: @escaping @MainActor () async -> Int32) -> Int32 {
        MainActor.assumeIsolated {
            _ = Task { @MainActor in exit(await body()) }
        }
        dispatchMain()
    }
}
