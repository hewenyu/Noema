import Darwin
import Dispatch
import Foundation
import NoemaCore
import NoemaEngine

/// `noema-cli repl`: drive a real `RimeEngine` from stdin, one line at a time.
///
/// A line is either a `:command` or a run of keys: printable ASCII characters and `<name>`
/// tokens. Each key prints `COMMIT: <text>` when it commits and `PASSTHROUGH: <key>` when
/// the engine leaves it to the client (both, in that order, for a DirectCommit); then the
/// line ends with `PREEDIT:`/`CANDIDATES:` while composing, or `IDLE`. stdout is flushed
/// after every line. Without `--user-dir` the session runs in a temporary directory that is
/// removed on exit (`:quit`, EOF, SIGINT, or SIGTERM).
enum ReplCommand {
    static let usage = """
        usage: noema-cli repl [--ephemeral | --user-dir <dir>] [--shared-dir <dir>] [--log-dir <dir>]
                              [--schema <id>] [--deployer <path>]

          --ephemeral         temporary user and log directories, removed on exit (default
                              unless --user-dir is given)
          --user-dir <dir>    Rime user_data_dir (takes its single-writer lock)
          --shared-dir <dir>  Rime shared_data_dir (default: the bundled or checked-out rime-default)
          --log-dir <dir>     librime log directory (default: inside the user directory's parent temp
                              directory when ephemeral, else ~/Library/Logs/Noema)
          --schema <id>       schema to select (default noema_pinyin)
          --deployer <path>   noema-rime-deployer executable (default: beside noema-cli)

        \(helpText)
        """

    static let helpText = """
        keys:     letters, digits, punctuation, and <space> <enter> <return> <esc> <bs> <del>
                  <tab> <left> <right> <up> <down> <pgup> <pgdn> <home> <end>, e.g. nihao<space>
        commands: :select <n>  :page next|prev  :ascii on|off  :commit  :clear  :reset
                  :state  :help  :quit (:q)
        """

    @MainActor
    static func run(_ arguments: [String]) -> Never {
        if arguments == ["-h"] || arguments == ["--help"] {
            print(usage)
            exit(0)
        }
        let session: ReplSession
        do {
            session = try ReplSession(configuration: try parse(arguments))
        } catch {
            fputs("noema-cli repl: \(error.message)\n", stderr)
            if error.status == 2 { fputs(usage + "\n", stderr) }
            exit(error.status)
        }
        session.start()
    }

    struct Configuration {
        var userDataDir: URL?
        var sharedDataDir: URL?
        var logDir: URL?
        var schemaID: String
        var deployerURL: URL?
    }

    static func parse(_ arguments: [String]) throws(CLIError) -> Configuration {
        var parser = OptionParser(command: "repl", arguments: arguments)
        let (values, flags) = try parser.parse(
            valued: ["--user-dir", "--shared-dir", "--log-dir", "--schema", "--deployer"], flags: ["--ephemeral"])
        if flags.contains("--ephemeral"), values["--user-dir"] != nil {
            throw CLIError("--ephemeral and --user-dir conflict", status: 2)
        }
        return Configuration(
            userDataDir: values["--user-dir"].map { absoluteURL($0) },
            sharedDataDir: values["--shared-dir"].map { absoluteURL($0) },
            logDir: values["--log-dir"].map { absoluteURL($0) },
            schemaID: values["--schema"] ?? "noema_pinyin",
            deployerURL: values["--deployer"].map { absoluteURL($0, isDirectory: false) }
        )
    }
}

/// One repl run: the engine, the temporary directory it owns, and the line interpreter.
@MainActor
final class ReplSession {
    private let engine: RimeEngine
    private let ephemeralRoot: URL?
    private var signalSources: [any DispatchSourceSignal] = []
    private var isTornDown = false

    init(configuration: ReplCommand.Configuration) throws(CLIError) {
        let fileManager = FileManager.default
        guard let shared = configuration.sharedDataDir ?? NoemaPaths.resolveSharedDataDir(bundle: .main) else {
            throw CLIError("no rime-default found; pass --shared-dir <dir> (e.g. Resources/rime-default)")
        }
        guard let deployer = configuration.deployerURL ?? RimeEngine.locateDeployer() else {
            throw CLIError("noema-rime-deployer not found beside noema-cli; build it (swift build) or pass --deployer <path>")
        }
        var info = stat()
        guard stat(deployer.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, access(deployer.path, X_OK) == 0 else {
            throw CLIError("--deployer is not an executable file: \(deployer.path)")
        }
        let user: URL
        let logs: URL
        if let userDataDir = configuration.userDataDir {
            ephemeralRoot = nil
            user = userDataDir
            logs = configuration.logDir ?? NoemaPaths.logDir()
        } else {
            let root = fileManager.temporaryDirectory.appending(path: "noema-repl-\(UUID().uuidString)", directoryHint: .isDirectory)
            do {
                try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            } catch {
                throw CLIError("cannot create a temporary directory: \(error.localizedDescription)")
            }
            ephemeralRoot = root
            user = root.appending(path: "user", directoryHint: .isDirectory)
            logs = configuration.logDir ?? root.appending(path: "log", directoryHint: .isDirectory)
        }
        do {
            engine = try RimeEngine(configuration: RimeEngineConfiguration(
                sharedDataDir: shared, userDataDir: user, logDir: logs,
                schemaID: configuration.schemaID, deployerURL: deployer))
        } catch {
            if let ephemeralRoot { try? fileManager.removeItem(at: ephemeralRoot) }
            throw CLIError("engine unavailable: \(error)")
        }
        fputs("noema repl: schema \(configuration.schemaID), user dir \(user.path)\(ephemeralRoot == nil ? "" : " (ephemeral)"); :help for help\n", stderr)
    }

    /// Prints the Safe Mode banner, then reads stdin on a background thread and runs each
    /// line on the main queue, in order, until `:quit`, EOF, or a signal.
    func start() -> Never {
        if let reason = engine.safeModeReason { emit("[safe-mode: \(reason.rawValue)]") }
        flush()
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { ReplSession.current?.teardown() }
                exit(128 + signalNumber)
            }
            source.resume()
            signalSources.append(source)
        }
        ReplSession.current = self
        let reader = Thread {
            while let line = readLine(strippingNewline: true) {
                DispatchQueue.main.async { MainActor.assumeIsolated { ReplSession.current?.handle(line) } }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { ReplSession.current?.teardown() }
                exit(0)
            }
        }
        reader.start()
        dispatchMain()
    }

    static var current: ReplSession?

    func finish(status: Int32) -> Never {
        teardown()
        exit(status)
    }

    /// Shuts the engine down (releasing librime and the user-data lock) and removes the
    /// ephemeral directory. Idempotent.
    func teardown() {
        guard !isTornDown else { return }
        isTornDown = true
        engine.shutdown()
        if let ephemeralRoot { try? FileManager.default.removeItem(at: ephemeralRoot) }
        flush()
    }

    // MARK: - Lines

    func handle(_ rawLine: String) {
        defer { flush() }
        let line = rawLine.trimmingCharacters(in: .newlines)
        if line.hasPrefix(":") {
            command(line.dropFirst().split(separator: " ", omittingEmptySubsequences: true).map(String.init))
            return
        }
        guard !line.isEmpty else { return }
        if let reason = engine.safeModeReason { emit("[safe-mode: \(reason.rawValue)]") }
        for (name, event) in Self.keys(in: line) {
            report(engine.processKey(event), key: name)
        }
        printState()
    }

    private func command(_ words: [String]) {
        switch (words.first ?? "", Array(words.dropFirst())) {
        case ("select", let rest):
            guard rest.count == 1, let number = Int(rest[0]), number >= 1 else {
                return emit("ERROR: :select takes a 1-based candidate number")
            }
            let result = engine.selectCandidate(at: number - 1)
            if !result.handled { emit("ERROR: no candidate \(number) on this page") }
            report(result, key: nil)
            printState()
        case ("page", ["next"]), ("page", ["prev"]):
            engine.changePage(backward: words[1] == "prev")
            printState()
        case ("ascii", ["on"]), ("ascii", ["off"]):
            engine.setASCIIMode(words[1] == "on")
            emit("ASCII: \(engine.currentState.isASCIIMode ? "on" : "off")")
        case ("commit", []):
            report(engine.commitComposition(), key: nil)
            printState()
        case ("clear", []):
            engine.clearComposition()
            printState()
        case ("reset", []):
            engine.resetSession()
            printState()
        case ("state", []):
            let state = engine.currentState
            emit("STATE: composing=\(state.isComposing) ascii=\(state.isASCIIMode) schema=\(state.schemaID ?? "-") safe-mode=\(state.safeModeReason?.rawValue ?? "none")")
            printState()
        case ("help", []):
            emit(ReplCommand.helpText)
        case ("quit", []), ("q", []):
            finish(status: 0)
        default:
            emit("ERROR: unknown command :\(words.joined(separator: " ")); :help lists commands")
        }
    }

    private func report(_ result: KeyHandlingResult, key: String?) {
        if let committed = result.committedText, !committed.isEmpty { emit("COMMIT: \(committed)") }
        if let key, !result.handled { emit("PASSTHROUGH: \(key)") }
    }

    private func printState() {
        let state = engine.currentState
        guard state.isComposing else { return emit("IDLE") }
        emit("PREEDIT: \(state.preedit) [caret \(state.caretUTF16Offset)]")
        let list = state.candidates.enumerated().map { index, item in
            "\(item.label ?? String(index + 1)).\(item.text)\(index == state.highlightedIndex ? "*" : "")"
        }
        emit("CANDIDATES: \(list.joined(separator: " ")) [page \(state.pageIndex + 1)\(state.isLastPage ? ", last" : "")]")
    }

    private func emit(_ text: String) { print(text) }
    private func flush() { fflush(stdout) }

    // MARK: - Key tokens

    static let namedKeys: [String: KeyEvent] = [
        "space": KeyEvent(keyCode: VirtualKeyCode.space, characters: " "),
        "enter": KeyEvent(keyCode: VirtualKeyCode.return, characters: "\r"),
        "return": KeyEvent(keyCode: VirtualKeyCode.return, characters: "\r"),
        "esc": KeyEvent(keyCode: VirtualKeyCode.escape, characters: "\u{1B}"),
        "bs": KeyEvent(keyCode: VirtualKeyCode.delete, characters: "\u{7F}"),
        "del": KeyEvent(keyCode: VirtualKeyCode.forwardDelete, characters: "\u{F728}", modifiers: .function),
        "tab": KeyEvent(keyCode: VirtualKeyCode.tab, characters: "\t"),
        "left": KeyEvent(keyCode: VirtualKeyCode.leftArrow, characters: "", modifiers: .function),
        "right": KeyEvent(keyCode: VirtualKeyCode.rightArrow, characters: "", modifiers: .function),
        "up": KeyEvent(keyCode: VirtualKeyCode.upArrow, characters: "", modifiers: .function),
        "down": KeyEvent(keyCode: VirtualKeyCode.downArrow, characters: "", modifiers: .function),
        "pgup": KeyEvent(keyCode: VirtualKeyCode.pageUp, characters: "", modifiers: .function),
        "pgdn": KeyEvent(keyCode: VirtualKeyCode.pageDown, characters: "", modifiers: .function),
        "home": KeyEvent(keyCode: VirtualKeyCode.home, characters: "", modifiers: .function),
        "end": KeyEvent(keyCode: VirtualKeyCode.end, characters: "", modifiers: .function),
    ]

    /// The keys a line types, each with its display name. A `<` that does not open a known
    /// `<name>` token is the `<` character; non-ASCII characters are skipped.
    static func keys(in line: String) -> [(String, KeyEvent)] {
        var keys: [(String, KeyEvent)] = []
        var rest = Substring(line)
        while let character = rest.first {
            if character == "<", let close = rest.firstIndex(of: ">"),
               let event = namedKeys[String(rest[rest.index(after: rest.startIndex)..<close]).lowercased()]
            {
                keys.append((String(rest[...close]), event))
                rest = rest[rest.index(after: close)...]
                continue
            }
            rest = rest.dropFirst()
            guard character.isASCII, let scalar = character.unicodeScalars.first, (0x20..<0x7F).contains(scalar.value)
            else { continue }
            if character == " " {
                keys.append(("<space>", namedKeys["space"]!))
            } else {
                let modifiers: KeyModifiers = character.isUppercase ? .shift : []
                keys.append((String(character), KeyEvent(keyCode: 0, characters: String(character), modifiers: modifiers)))
            }
        }
        return keys
    }
}
