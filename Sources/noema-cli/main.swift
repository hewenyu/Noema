import NoemaCore
import NoemaEngine

#if canImport(Darwin)
import Darwin
#endif

let usage = """
    usage: noema-cli <command>

    commands:
      version      print the Noema version
      check-rime   print the linked librime version and required module status
      install      install NoemaIME.app into ~/Library/Input Methods (install --help)
      reload       stop running NoemaIME processes so macOS relaunches them (reload --help)
      repl         type into a real Rime engine from stdin (repl --help)
    """

func printError(_ message: String) {
    fputs(message + "\n", stderr)
}

func checkRime() -> Int32 {
    do {
        let info = try RimeRuntime.info()
        print("librime \(info.version)")
        for name in RimeRuntime.requiredModules {
            let ok = info.modules[name] ?? false
            print("  module \(name): \(ok ? "registered" : "MISSING")")
        }
        guard info.allModulesRegistered else {
            printError("check-rime: required librime modules are missing")
            return 1
        }
        return 0
    } catch {
        printError("check-rime: \(error)")
        return 1
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "version":
    print("noema \(NoemaVersion.current)")
    exit(0)
case "check-rime":
    exit(checkRime())
case "install":
    exit(InstallCommand.run(Array(arguments.dropFirst())))
case "reload":
    exit(ReloadCommand.run(Array(arguments.dropFirst())))
case "repl":
    ReplCommand.run(Array(arguments.dropFirst()))
case "-h", "--help", "help":
    print(usage)
    exit(0)
default:
    printError(usage)
    exit(2)
}
