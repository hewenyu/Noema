import Foundation
import NoemaCore
import NoemaIPC
import NoemaLexiconAdmin
import SwiftUI

extension SettingsSectionID {
    /// The sidebar order; raw cases stay append-only on the wire.
    public static let sidebarOrder: [SettingsSectionID] = [.general, .quickActions, .lexicon, .other]

    public var title: String {
        switch self {
        case .general: "基础设置"
        case .quickActions: "快速操作"
        case .other: "其他"
        case .lexicon: "词库"
        }
    }

    public var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .quickActions: "bolt"
        case .other: "ellipsis.circle"
        case .lexicon: "books.vertical"
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
            List(SettingsSectionID.sidebarOrder, id: \.self, selection: $model.selectedSection) { section in
                Label(section.title, systemImage: section.symbolName).tag(section)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
        } detail: {
            switch model.selectedSection ?? .general {
            case .general: GeneralSettingsView(model: model)
            case .quickActions: QuickActionsSettingsView(model: model)
            case .other: OtherSettingsView(model: model)
            case .lexicon: LexiconSettingsView(model: model)
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

/// "快速操作": the v-mode shortcuts and the emoji candidate switch.
struct QuickActionsSettingsView: View {
    @Bindable var model: AgentStatusModel

    /// What each `v` shortcut does; agent actions show whether they are available yet.
    static func status(of item: VMenuItem) -> String {
        guard let action = item.quickAction else { return "离线可用" }
        if action.isImplemented { return "可用" }
        return "计划中（\(action.plannedMilestone ?? "")）"
    }

    var body: some View {
        Form {
            Section {
                ForEach(VMenuItem.allCases, id: \.self) { item in
                    LabeledContent {
                        Text(Self.status(of: item)).foregroundStyle(.secondary)
                    } label: {
                        Text("v\(item.rawValue)  \(item.title)").monospacedDigit()
                    }
                }
            } header: {
                Text("v 模式")
            } footer: {
                Text("空闲时按 v 打开九宫格菜单：方向键或 Tab 移动，回车或空格选择，Esc 或退格退出。v1+2 直接计算（空格上屏 3），v= 开始一个算式，vv 输入字母 v，v 后接其他字母（如 vim）按回车原样上屏。正在拼音输入时 v 照常参与拼写（lv → 绿）。")
            }
            Section {
                Toggle("候选中显示 Emoji", isOn: Binding(
                    get: { model.service.settings.emojiCandidatesEnabled },
                    set: { model.setEmojiCandidatesEnabled($0) }))
            } header: {
                Text("Emoji")
            } footer: {
                Text("在“你好”“开心”等词后追加 👋、😊 等候选；首选候选不变，Emoji 上屏不会写入学习库。只影响内置方案，万象、雾凇、薄荷使用各自的 Emoji 设置。")
            }
            Section {
                EmptyView()
            } footer: {
                Text("这些操作由 Noema Agent 承载，所需权限只授予 Noema.app；输入法本身不申请任何权限。安全输入（密码框）期间 v 模式不会启动。")
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

extension SchemaSwitchPhase {
    public var title: String {
        switch self {
        case .compiling: "正在编译"
        case .pendingIdle: "等待当前输入结束"
        case .ready: "已切换"
        case .failed: "切换失败"
        }
    }
}

/// Byte counts as the Finder shows them (`ByteCountFormatter`, file style).
func formattedBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

/// "词库": the active schema set and the switch to another, the installed dictionaries, and
/// a read-only summary of the canonical learning store.
struct LexiconSettingsView: View {
    @Bindable var model: AgentStatusModel

    var body: some View {
        Group {
            if let lexicon = model.lexicon {
                LexiconSettingsForm(lexicon: lexicon, service: model.service)
            } else {
                ContentUnavailableView("词库不可用", systemImage: "books.vertical", description: Text("Noema Agent 尚未启动 IPC 服务。"))
            }
        }
        .navigationTitle(SettingsSectionID.lexicon.title)
    }
}

struct LexiconSettingsForm: View {
    let lexicon: LexiconController
    let service: AgentServiceSnapshot

    var body: some View {
        Form {
            Section("方案集") {
                LabeledContent("当前方案集", value: lexicon.activeSchemaSetID.displayName)
                ForEach(SchemaSetID.allCases) { set in
                    LabeledContent {
                        HStack {
                            if set == lexicon.activeSchemaSetID {
                                Text("使用中").foregroundStyle(.secondary)
                            } else if lexicon.installedSets.contains(set) {
                                Button("切换") { lexicon.switchTo(schemaSetID: set) }
                            }
                            if set != .builtin, !lexicon.installedSets.contains(set) {
                                installControl(for: set)
                            }
                        }
                    } label: {
                        Text(set.displayName)
                    }
                }
                if let status = lexicon.switchStatus(in: service) {
                    LabeledContent("切换状态", value: "\(status.schemaSetID.displayName)：\(status.phase.title)")
                    if let detail = status.detail, status.phase == .failed {
                        Text(detail).foregroundStyle(.red).font(.callout)
                    }
                }
                if let error = lexicon.lastSwitchError {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
            }
            Section("已安装的词典") {
                let dictionaries = lexicon.inventory?.dictionaries ?? []
                if dictionaries.isEmpty {
                    Text("没有找到 *.dict.yaml").foregroundStyle(.secondary)
                } else {
                    Table(dictionaries) {
                        TableColumn("方案集") { Text($0.schemaSetID.displayName) }
                        TableColumn("文件") { Text($0.relativePath).textSelection(.enabled) }
                        TableColumn("大小") { Text(formattedBytes($0.byteSize)).monospacedDigit() }
                    }
                    .frame(minHeight: 160)
                }
            }
            Section("共享学习库（learning.sqlite，只读）") {
                if let stats = lexicon.inventory?.learning {
                    LabeledContent("已学习词条", value: "\(stats.entryCount)")
                    LabeledContent("用户词组", value: "\(stats.userPhraseCount)")
                    LabeledContent("累计上屏", value: "\(stats.totalFrequency)")
                    LabeledContent("最新修订", value: "\(stats.latestRevision)")
                    ForEach(stats.watermarks, id: \.self) { mark in
                        LabeledContent(
                            "投影水位 · \(SchemaSetID(rawValue: mark.schemaSet)?.displayName ?? mark.schemaSet) · \(mark.dictName)",
                            value: "修订 \(mark.lastRevision) · \(mark.projectedCount) 条")
                    }
                } else if let error = lexicon.inventory?.learningError {
                    Text("无法读取：\(String(describing: error))").foregroundStyle(.red).font(.callout)
                } else {
                    Text("尚未学习任何词条").foregroundStyle(.secondary)
                }
            }
            Section {
                Button(lexicon.isRefreshing ? "正在刷新…" : "刷新") { Task { await lexicon.refresh() } }
                    .disabled(lexicon.isRefreshing)
            } footer: {
                Text("切换由输入法在后台编译，正在输入时会等到本次输入结束；Agent 只读取学习库，从不写入。")
            }
        }
        .formStyle(.grouped)
        .task { await lexicon.refresh() }
        // The IME saves `active-schema-set.json` before it reports `ready`: rescan then, so
        // 当前方案集 and 使用中 follow the switch at once.
        .onChange(of: service.lastSchemaSwitchStatus) { _, status in
            if status?.phase == .ready { Task { await lexicon.refresh() } }
        }
    }

    @ViewBuilder
    private func installControl(for set: SchemaSetID) -> some View {
        switch lexicon.installStates[set] ?? .idle {
        case .installing:
            ProgressView().controlSize(.small)
        case .failed(let reason):
            Button("重试安装") { Task { await lexicon.install(schemaSetID: set) } }
                .help(reason)
        case .idle, .installed:
            Button("下载安装") { Task { await lexicon.install(schemaSetID: set) } }
        }
    }
}
