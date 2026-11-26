# Agent Note: XPCSession IPC with two-layer peer identity and fire-and-forget IME traffic, not NSXPCConnection or synchronous IME requests

Status: implemented

## Problem

M2（Issue #7）需要伴生 Agent `Noema.app` 的骨架（菜单栏、设置窗口、LaunchAgent 注册）以及 IME 与 Agent 之间的 IPC。[进程模型笔记](../../proposed/architecture/2026-11-23-process-model-and-permissions.md)要求：IMKit 进程零 TCC、按键热路径不被 Agent 拖慢、Agent 不可用时照常打字、过期响应按 `generationID` 丢弃。IPC 还是一条信任边界：任何本机进程都能查找 Mach 服务名，冒充 Agent 的进程不应收到输入元数据，冒充 IME 的进程不应能驱动 Agent。签名只有证书签名（发布）与 ad-hoc（CI、本机开发）两种，校验必须在两种构建中都能测试，又不能在发布构建里被降级为 ad-hoc。

## Decision

- **进程与注册**：`Noema.app`（`dev.noema.agent`，`LSUIElement`）内嵌 `Contents/Library/LaunchAgents/dev.noema.agent.plist`（`BundleProgram`、`MachServices` `dev.noema.agent.ipc`、`AssociatedBundleIdentifiers`、`KeepAlive` `SuccessfulExit: false`），经 `SMAppService.agent(plistName:)` 注册，设置窗口“基础设置”页提供 LaunchAgent 开关与状态，并可“打开登录项设置…”。`XPCListener(service:)` 在 launchd 之外 check-in 返回 `EPERM`：Agent 进入 `standbyNotLaunchdManaged`，若已有同 bundle ID 的实例在跑，就经 `NSWorkspace.openApplication` 让 LaunchServices 重新打开它（对方收到 `applicationShouldHandleReopen` 并显示设置窗口，最多等 1 s）后退出 0（重复启动交接）；否则只显示菜单与设置窗口，并订阅 `dev.noema.agent.ready`，launchd 托管的实例就绪后自行退出，菜单栏不会出现两个图标。check-in 成功后 `notify_post("dev.noema.agent.ready")`。
- **线格式**：XPC 字典键 `e` 承载 JSON `IPCEnvelope`（协议版本、`kind`、`sequence`、可选 `generationID`、载荷），上限 256 KiB，解码前先检查长度。`IMEToAgent` 为 `ime.*`，`AgentToIME` 为 `agent.*`；未知 `kind` 解码失败（两个 App 同版本发布）。需要回复的请求带键 `r`，监听端从处理函数返回一个新字典作为回复。
- **两层身份校验**：第 1 层是 `XPCPeerRequirement`（LWCR：`signing-identifier`，多个时用 `$in`；strict 且有 Team ID 时加 `team-identifier`），由 libxpc 在投递前执行。第 2 层是 `PeerIdentityVerifier`：每条消息 `SecCodeCreateWithXPCMessage`（或审计令牌 `kSecGuestAttributeAudit`）→ `SecCodeCheckValidityWithErrors` → 签名标识、ad-hoc 标志、Hardened Runtime、Team ID 与叶证书 SHA-1。失败时监听端断开该 peer，客户端丢帧并降级为 `peerRejected`。
- **防降级（fail closed）**：`PeerIdentityPolicy.resolved(requested:selfIdentity:)` 中，已固定（pinned）的 strict 请求原样保留；只有本进程经校验为有效 ad-hoc 签名时才采用 `allowAdHocForTesting`。本进程非 ad-hoc 时升级为 strict，固定到本进程的 Team ID 与叶证书，本进程有 Hardened Runtime 时也要求对端有；没有有效签名（`selfIdentity == nil`，例如替换或篡改 bundle 后 `SecCodeCheckValidity` 返回 `-67034`）或非 ad-hoc 却无 Team ID 与证书可固定时，得到未固定的 strict。未固定的 strict 拒绝一切对端，且 `xpcPeerRequirement` 为 nil：客户端在建立 `XPCSession` 之前就抛出 `peerRejected`（一条 `ime.hello` 都不发），监听端在创建 `XPCListener` 之前就抛出 `unpinnedStrictPolicy`（Agent 为 `.failed`，不发就绪通知）。
- **会话生命周期**：`ManagedXPCSession` 独占激活与取消：先以 `.inactive` 创建并设置 requirement 与处理函数，再 `activate()`；`cancel` 幂等，`deinit` 取消。监听端 `stop()` 先取消 listener，再在其队列上做一次 `queue.sync {}` 屏障，之后才清理 peer：`stop()` 之后到达的 accept 被拒绝，已在途的 adopt 不登记会话、在激活后立即取消，`stop()` 返回时不留活动会话。所有回调带 `attemptID`，`IPCConnectionManager` 只处理当前尝试的回调，其余计入 `ignoredStaleCallbacks`。
- **连接状态机**：`idle → connecting → healthy`，失败经 `degraded(reason)` 进入 `reconnecting`（基础 200 ms、上限 10 s 的指数退避加抖动），连续 5 次失败后 `circuitOpen` 冷却 30 s。握手（`ime.hello` → `agent.helloAck`）限时 500 ms，心跳 15 s；收到就绪通知时（防抖至少 100 ms）跳过退避与冷却立即重试；就绪通知未经认证，所以每次 `circuitOpen` 只允许一次由它触发的探测（`readyProbeUsedInCurrentCircuit`，healthy 或冷却自然到期时重置），本机进程每 100 ms 发一次也绕不过冷却。连接成功后失败计数清零。`helloAck` 只在 `connecting` 时生效，`heartbeatAck` 只在 `healthy` 时生效（不能在握手期间解除超时）；`helloAck` 与 `settingsSnapshot` 带单调的 `settingsRevision`（v1 追加字段，缺省为 0），低于已应用修订的设置快照被忽略。观察者里可重入调用 `stop()`：每次发布状态后都重查 `running`，定时器在已停止时立即取消。时钟与抖动可注入（`ManualIPCClock`、`FixedJitter`）。
- **IME 热路径**：IME 只发送即发即弃的元数据（组合的 `generationID`、是否在组字、候选数与 ASCII 模式，不含任何文本）。`sendFireAndForget` 在非 healthy 时直接丢弃（`droppedWhileUnhealthy`），组合更新在至多 32 条的发件箱里合并为最新一条，由串行队列发出，主线程从不等待 XPC。`CompositionIPCReporter` 在 `IsSecureEventInputEnabled()` 为真时什么都不发。`GenerationGate` 丢弃会话纪元（每次连接尝试一个新 `sessionEpoch`）不符、按 `kind` 低于或等于水位线的 Agent 消息；`agent.aiSuggestion` 还必须对应当前组合的 `generationID`。
- **边界**：`NoemaIPC` 只依赖 `NoemaCore`，与 IME 源码一起受 `check-imports.sh` 零 TCC 扫描，且不得导入 `ServiceManagement` 或 `NoemaAgentCore`。设置界面（SwiftUI `NavigationSplitView`：基础设置、快速操作、其他）在 `NoemaAgentCore`；`NoemaAgent` 只负责 AppKit 生命周期、状态栏与信号。

## Alternatives considered

- **`NSXPCConnection` 与 `@objc` 协议。** Rejected：需要 `NSSecureCoding` 类层次，类型不随 Swift 6 严格并发检查；macOS 26 的 `XPCSession`/`XPCListener` 原生支持 `XPCPeerRequirement`，JSON 信封还能在内存传输上做确定性测试。
- **只用 `XPCPeerRequirement`（单层）。** Rejected：Apple 平台代码（测试运行器 `swiftpm-testing-helper`）的 `team-identifier` 与 `isFromSameTeam` 永不匹配，LWCR 表达不了“非 ad-hoc + 固定叶证书 + Hardened Runtime”；第 2 层逐条消息校验审计令牌，覆盖这些条件，也覆盖会话建立后的每一帧。
- **只按 Team ID 校验。** Rejected：同一开发者账号签的任何 App 都能冒充；固定叶证书 SHA-1 与签名标识收窄到 Noema 自己的两个可执行文件。
- **IME 同步请求 Agent，等待上限 20 ms（进程模型笔记的原方案）。** Rejected：20 ms 已是单键 P95 预算（2 ms）的十倍，Agent 卡住时每个键都要付这个代价。M2 的 IME 没有需要同步结果的请求，所以只发即发即弃消息，Agent 结果（设置快照、AI 建议）异步推送并经 `GenerationGate` 过滤。
- **用 `xpc_dictionary_create_reply` 构造回复。** Rejected：Swift 覆盖层自己构造回复，手工调用会消费回复并断开连接；改为请求带 `r` 标志、处理函数返回新字典。
- **Agent 直接把 `Program` 写进 `~/Library/LaunchAgents`。** Rejected：`SMAppService.agent` 让用户在“登录项”中可见、可关，`BundleProgram` 随 App 移动；手写 plist 需要自己管理路径与卸载。
- **在 launchd 之外 check-in 失败时直接退出。** Rejected：开发时从终端启动会立即消失、无从调试；standby 状态仍提供菜单与设置窗口，并显示原因。

## Consequences

- 验收：`NoemaIPCTests` 在匿名 `XPCListener` 上做真实 libxpc 往返；`IMEAgentIPCTests` 用真实 `RimeEngine` 与真实 XPC Agent 打 500 键，第 150 键杀掉 Agent，提交结果与无 IPC 的参照运行逐字节一致，P95 < 2 ms（实测约 0.04 ms），状态走到 `circuitOpen(3)`，Agent 重启并 `notify_post` 后恢复 healthy；安全输入下 IME 发出 0 帧。
- 负控（破坏后对应测试失败、恢复后通过）：去掉 strict 下的 ad-hoc 拒绝、`attemptID` 判断、纪元判断、水位线 `stale` 判断、解码前长度检查、`CompositionIPCReporter` 的安全输入判断、`selfIdentity == nil` 的 fail closed、两端传输的未固定 strict 预检、`connecting` 时对 `heartbeatAck` 的忽略、就绪探测限流、状态发布后的 `running` 重查；`check-imports.sh` 在 `Sources/NoemaIPC` 出现 `import Network` 或 `import ServiceManagement`、IME 源码出现 `import NoemaAgentCore` 时失败；`verify-bundle.sh` 对签名 `Identifier=` 与 `dev.noema.inputmethod.NoemaIME`/`dev.noema.agent` 不符时 exit 1；`verify-bundle.sh` 对 `LSUIElement` 为 false、`BundleProgram` 错误、缺 `MachServices`、Agent 内含 `Frameworks` 以及目录中缺 `Noema.app` 均 exit 1。
- 风险：客户端的 requirement 只在对端消息到达时执行，所以第一条 `ime.hello`（版本与会话纪元，不含文本）仍会送达冒充者；冒充者的回复被拒，连接永不进入 healthy，之后的组合元数据不会发出。
- 风险：发布构建要求两个 App 由同一证书签名（叶证书 SHA-1 相同）；证书轮换必须同时重签两者，否则 IPC 降级为 `peerRejected`，打字不受影响。
- SDK 行为（macOS 26，实测）：`XPCListener` 默认已激活，再次 `activate()` 会陷入；释放未取消的活动会话、取消或释放从未激活的会话都会陷入，所以只经 `ManagedXPCSession` 持有会话；Mach 查找失败既抛错又调用 cancellation handler，回调按 `attemptID` 去重。
- 会话纪元每次连接尝试都换新值，所以重连后旧连接的 Agent 消息一律被丢弃；Agent 侧按 peer 记录组合水位线。
