// NoemaIME: the input method executable inside NoemaIME.app.
// It only links NoemaCore and NoemaEngine; `--check-rime` lets bundle
// verification prove that dyld resolves Contents/Frameworks/librime.1.dylib.
// Foundation is used only for Bundle.main: `--version` reports the version
// bundle.sh wrote into Contents/Info.plist.
import Foundation
import NoemaCore
import NoemaEngine

#if canImport(Darwin)
import Darwin
#endif

let usage = """
    usage: NoemaIME <option>

    options:
      --version      print the NoemaIME version
      --check-rime   print the bundled librime version and required module status
    """

/// The packaged CFBundleShortVersionString, or NoemaVersion.current when run unbundled.
func bundleVersion() -> String {
    if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        !version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
        return version
    }
    return NoemaVersion.current.description
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
            fputs("NoemaIME: required librime modules are missing\n", stderr)
            return 1
        }
        return 0
    } catch {
        fputs("NoemaIME: \(error)\n", stderr)
        return 1
    }
}

switch Array(CommandLine.arguments.dropFirst()) {
case ["--version"]:
    print("NoemaIME \(bundleVersion())")
    exit(0)
case ["--check-rime"]:
    exit(checkRime())
default:
    fputs(usage + "\n", stderr)
    exit(2)
}
