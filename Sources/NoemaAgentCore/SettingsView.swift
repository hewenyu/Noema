import Foundation
import NoemaCore
import NoemaIPC
import SwiftUI

extension SettingsSectionID {
    public var title: String {
        switch self {
        case .general: "基础设置"
        case .quickActions: "快速操作"
        case .other: "其他"
        }
    }

    public var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .quickActions: "bolt"
        case .other: "ellipsis.circle"
        }
    }
}

extension AgentListenerState {
    public var title: String {
        switch self {
        case .idle: "未启动"
        case .listening: "正在监听"
        case .standbyNotLaunchdManaged: "待命（非 launchd 启动，请注册登录项）"
        case .failed(let reason): "失败：\(reason)"
        }
    }
}

extension LaunchAgentStatus {
    public var title: String {
        switch self {
        case .enabled: "已启用"
        case .requiresApproval: "等待在“系统设置 > 通用 > 登录项”中批准"
        case .notRegistered: "未注册"
        case .notFound: "未找到 LaunchAgent（请从 Noema.app 运行）"
        case .unsupported: "不支持"
        }
    }
}

/// The Settings window: a sidebar of `SettingsSectionID` sections and their detail.
public struct SettingsRootView: View {
    @Bindable private var model: AgentStatusModel

    public init(model: AgentStatusModel) {
        self.model = model
    }

    public var body: some View {
        NavigationSplitView {
            List(SettingsSectionID.allCases, id: \.self, selection: $model.selectedSection) { section in
                Label(section.title, systemImage: section.symbolName).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
        } detail: {
            switch model.selectedSection ?? .general {
            case .general: GeneralSettingsView(model: model)
            case .quickActions: QuickActionsSettingsView()
            case .other: OtherSettingsView(model: model)
            }
        }
        .frame(minWidth: 680, minHeight: 440)
    }
}

struct GeneralSettingsView: View {
    @Bindable var model: AgentStatusModel

    var body: some View {
        Form {
            Section("伴生 Agent") {
                Toggle("登录时启动 Noema", isOn: Binding(
                    get: { model.isLaunchAgentRequested },
                    set: { model.setLaunchAgentEnabled($0) }))
                LabeledContent("LaunchAgent", value: model.launchAgentStatus.title)
                if model.launchAgentStatus == .requiresApproval {
                    Button("打开登录项设置…") { model.openLoginItems() }
                }
                if let error = model.lastLaunchAgentError {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
            }
            Section("输入法连接") {
                LabeledContent("IPC 监听", value: model.service.listenerState.title)
                LabeledContent("已连接的输入法", value: "\(model.service.connectedPeers)")
                LabeledContent("最近的对端", value: model.service.lastPeerIdentity?.signingIdentifier ?? "—")
                LabeledContent("输入法版本", value: model.service.lastHello?.clientVersion ?? "—")
                LabeledContent("引擎状态", value: model.service.lastEngineMode ?? model.service.lastHello?.engineMode ?? "—")
            }
            Section("版本") {
                LabeledContent("Noema Agent", value: model.agentVersion)
                LabeledContent("IPC 协议", value: "v\(IPCProtocolVersion.current.rawValue)")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(SettingsSectionID.general.title)
    }
}

struct QuickActionsSettingsView: View {
    private struct Item: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let status: String
    }

    private let items = [
        Item(id: "v-mode", title: "v 模式", symbol: "character.cursor.ibeam", status: "计划中（M2）"),
        Item(id: "clipboard", title: "剪贴板面板", symbol: "doc.on.clipboard", status: "计划中（M2）"),
        Item(id: "voice", title: "语音输入", symbol: "mic", status: "计划中（M3）"),
        Item(id: "rewrite", title: "AI 改写", symbol: "sparkles", status: "计划中（M3）"),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(items) { item in
                    LabeledContent {
                        Text(item.status).foregroundStyle(.secondary)
                    } label: {
                        Label(item.title, systemImage: item.symbol)
                    }
                }
            } footer: {
                Text("这些操作由 Noema Agent 承载，所需权限只授予 Noema.app；输入法本身不申请任何权限。")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(SettingsSectionID.quickActions.title)
    }
}

struct OtherSettingsView: View {
    @Bindable var model: AgentStatusModel

    var body: some View {
        Form {
            Section("路径") {
                LabeledContent("Rime 用户目录", value: NoemaPaths.rimeUserDataDir().path)
                LabeledContent("日志目录", value: NoemaPaths.logDir().path)
                LabeledContent("输入法", value: NoemaPaths.installedIMEBundleURL().path)
            }
            Section("诊断") {
                LabeledContent("日志子系统", value: "\(NoemaLog.Subsystem.agent.rawValue), \(NoemaLog.Subsystem.ipc.rawValue)")
                LabeledContent("已处理消息", value: "\(model.service.framesHandled)")
                LabeledContent("被拒绝的对端", value: "\(model.service.rejectedPeers)")
            }
            Section("隐私") {
                Text("输入法进程零 TCC：不联网、不读剪贴板、不录音、不使用辅助功能。安全输入（密码框）期间输入法不向 Agent 发送任何消息；IPC 只携带组字的计数与状态，从不携带按键、预编辑或上屏文本。")
                    .font(.callout)
            }
            Section("关于") {
                LabeledContent("版本", value: model.agentVersion)
                LabeledContent("Bundle ID", value: NoemaPaths.agentBundleID)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(SettingsSectionID.other.title)
    }
}
