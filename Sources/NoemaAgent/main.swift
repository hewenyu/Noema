// NoemaAgent: the companion agent executable inside Noema.app (LSUIElement, menu bar).
//
// A long option (`--version`, `--help`) is a headless probe answered before AppKit is
// touched, so verify-bundle.sh and tests can run the binary; an unknown long option exits
// 2 at once. Anything else starts the agent: check in to the launchd Mach service
// `NoemaPaths.agentMachServiceName`, post `NoemaPaths.agentReadyNotificationName`, and own
// the status item and the Settings window. A direct launch (not by launchd) cannot check
// in: it hands over to an already running instance, or stays up in standby so Settings
// can register the LaunchAgent.
import AppKit
import Dispatch
import Foundation
import NoemaAgentCore
import NoemaCore
import NoemaIPC
import notify
import SwiftUI

let usage = """
    usage: NoemaAgent [option]

    Without an option, runs the Noema companion agent (launched by launchd via SMAppService).

    options:
      --version   print the NoemaAgent version
      -h, --help  print this help
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

@MainActor
final class AgentAppDelegate: NSObject, NSApplicationDelegate {
    private let log = NoemaLog.agent("lifecycle")
    private let model = AgentStatusModel(agentVersion: bundleVersion(), launchAgent: SMAppServiceLaunchAgentController())
    private(set) var coordinator: AgentServiceCoordinator?
    private var statusItem: NSStatusItem?
    private var statusMenuItem: NSMenuItem?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ad-hoc development builds accept the ad-hoc IME by signing identifier; a
        // certificate-signed agent enforces strict, pinned to its own Team ID and certificate.
        let policy = PeerIdentityPolicy.resolved(
            requested: .allowAdHocForTesting(signingIdentifiers: [NoemaPaths.imeBundleID]),
            selfIdentity: SelfCodeIdentity.current())
        let transport = XPCListenerServerTransport(machService: NoemaPaths.agentMachServiceName, policy: policy)
        let model = model
        let coordinator = AgentServiceCoordinator(
            transport: transport, agentVersion: bundleVersion(),
            onOpenSettings: { section in
                DispatchQueue.main.async { MainActor.assumeIsolated { AgentAppDelegate.current?.showSettings(section: section) } }
            },
            onChange: { snapshot in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        model.apply(snapshot)
                        AgentAppDelegate.current?.refreshStatusMenu()
                    }
                }
            })
        self.coordinator = coordinator

        switch coordinator.start() {
        case .listening:
            notify_post(NoemaPaths.agentReadyNotificationName)
            log.info("checked in to \(NoemaPaths.agentMachServiceName, privacy: .public)")
            installStatusItem()
        case .standbyNotLaunchdManaged:
            if let other = otherRunningInstance() {
                log.info("another NoemaAgent (pid \(other.processIdentifier, privacy: .public)) is running; handing over")
                other.activate()
                coordinator.stop()
                exit(0)
            }
            log.info("not launched by launchd; standing by so Settings can register the LaunchAgent")
            installStatusItem()
            showSettings(section: .general)
        case .failed(let reason):
            log.error("IPC listener failed: \(reason, privacy: .public)")
            installStatusItem()
        case .idle:
            installStatusItem()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(section: nil)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }

    private func otherRunningInstance() -> NSRunningApplication? {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: NoemaPaths.agentBundleID)
            .first { $0.processIdentifier != me && !$0.isTerminated }
    }

    // MARK: - Status item

    private func installStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let url = Bundle.main.url(forResource: "menu-icon", withExtension: "pdf"), let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            item.button?.image = image
        } else {
            item.button?.title = "N"
        }
        item.button?.toolTip = "Noema"

        let menu = NSMenu()
        let settings = NSMenuItem(title: "打开设置…", action: #selector(openSettingsFromMenu(_:)), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let status = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        statusMenuItem = status
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出 Noema", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
        refreshStatusMenu()
    }

    func refreshStatusMenu() {
        let service = model.service
        statusMenuItem?.title = "\(service.listenerState.title) · 输入法 \(service.connectedPeers)"
    }

    @objc private func openSettingsFromMenu(_ sender: Any?) {
        showSettings(section: nil)
    }

    // MARK: - Settings window

    func showSettings(section: SettingsSectionID?) {
        if let section { model.selectedSection = section }
        model.refreshLaunchAgentStatus()
        let window = settingsWindow ?? makeSettingsWindow()
        settingsWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeSettingsWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsRootView(model: model)))
        window.title = "Noema 设置"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 720, height: 480))
        window.center()
        return window
    }

    nonisolated(unsafe) static weak var current: AgentAppDelegate?
}

@MainActor
func installMainMenu() {
    let main = NSMenu()
    func submenu(_ title: String, _ items: [NSMenuItem]) {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        holder.submenu = menu
        main.addItem(holder)
    }
    func item(_ title: String, _ selector: String, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
    submenu("Noema", [item("退出 Noema", "terminate:", "q")])
    submenu("编辑", [
        item("撤销", "undo:", "z"), item("重做", "redo:", "z", [.command, .shift]), .separator(),
        item("剪切", "cut:", "x"), item("拷贝", "copy:", "c"), item("粘贴", "paste:", "v"), item("全选", "selectAll:", "a"),
    ])
    submenu("窗口", [item("关闭", "performClose:", "w"), item("最小化", "performMiniaturize:", "m")])
    NSApp.mainMenu = main
}

@MainActor
func runAgent() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    installMainMenu()

    let delegate = AgentAppDelegate()
    AgentAppDelegate.current = delegate
    app.delegate = delegate

    // SIGTERM (launchd, logout) and SIGINT: stop the listener, cancelling every peer
    // session, then exit.
    var signalSources: [any DispatchSourceSignal] = []
    for signalNumber in [SIGTERM, SIGINT] {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { delegate.coordinator?.stop() }
            exit(0)
        }
        source.resume()
        signalSources.append(source)
    }

    app.run()
    withExtendedLifetime((delegate, signalSources)) {}
    delegate.coordinator?.stop()
    exit(0)
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments {
case ["--version"]:
    print("NoemaAgent \(bundleVersion())")
    exit(0)
case ["-h"], ["--help"]:
    print(usage)
    exit(0)
default:
    if arguments.contains(where: { $0.hasPrefix("--") }) {
        fputs(usage + "\n", stderr)
        exit(2)
    }
    MainActor.assumeIsolated { runAgent() }
}
