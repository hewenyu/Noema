# Agent Note: Thin IMKit shell plus companion agent, not a single all-in-one IMKit process or a CGEventTap bridge

Status: proposed

## Problem

输入法进程被注入到每一个接收文本输入的前台 App 的输入链路中：它一旦卡顿、崩溃或吞键，用户在所有 App 里都无法打字。Noema 同时需要语音识别、AI 建议、剪贴板历史、选区读取等能力，这些能力要求 Accessibility、Microphone、Speech Recognition 等 TCC 权限，并伴随网络、音频与大内存模型。如果把这些能力与按键热路径放进同一个进程，任何一处阻塞都会直接变成按键延迟或丢键，TCC 授权也会绑定在一个频繁重启、签名易漂移的 IMKit bundle 上。另外，选区读取的 `⌘C` 回退与剪贴板监听天然会接触密码等敏感数据，必须有明确的事务与过滤边界。

## Proposal

采用"薄壳 + 伴生 Agent"的多进程模型：

- **`NoemaIME.app`（IMKit 薄壳，零 TCC）**：只负责 `IMKInputController` 事件处理、组字与候选窗。不包含网络、AI/ASR、音频、剪贴板监听、AX 遍历或词库编译，不申请任何 TCC 权限。
  - 方案 A：`librime` 在 M0 暂驻 IMKit 进程，运行于 `@MainActor`，单键处理预算为 P95 `< 2ms`（本机实测亚毫秒级，P95 约 0.05ms）。
  - 通过 `TypingEngine` 协议解耦按键处理与 Rime 实现，未来可无缝外迁到 XPC 服务而不改调用方。
  - 启动 Safe Mode：若上一次启动在加载方案/词库时崩溃，下一次以最小方案启动并直通 ASCII，避免崩溃循环导致无法打字。
  - Safe Mode 的判定由 `BootGuard` 承担（`Sources/NoemaEngine/BootGuard.swift`）：先对 `<user_data_dir>/.noema-rime.lock` 取非阻塞 `flock`，拿不到即 `userDataDirLocked`，不读写哨兵也不打开 LevelDB；再读 `.noema-boot-guard`（`O_NOFOLLOW`，损坏、软链或非普通文件即 `bootGuardCorrupted`；锁文件被软链或目录占位同判 `bootGuardCorrupted`；`errno` 在 `open(2)` 返回后立即捕获），连续未完成启动达到阈值（默认 2）即 `bootCrashLoop`，否则以临时文件 + `fsync` + `rename(2)` 递增计数（写不进即 `userDataDirUnwritable`），加载成功后删除哨兵并 `fsync` 目录；只有持锁实例能删除哨兵（`disarm`/`clear`），未持锁实例返回 `false`。部署或建会话失败为 `engineInitFailed`。Safe Mode 下引擎零 `librime` 调用，所有按键 `handled: false`。
  - 进程内同一时刻只允许一个持有 `librime` 的 `RimeEngine`（第二个确定性抛错），`setup` 每进程只调一次：`librime` 是进程级单例，两个引擎会共享 deployer 与会话表。
  - 宿主进程从不调用 `librime` 的 deployer：部署一律交给 `noema-rime-deployer` 子进程（60 秒超时），在 `user_data_dir/.deploy-staging.<pid>.<uuid>` 中隔离编译，宿主复核后以两次 `rename(2)` 原子切换 `build/`（第二步失败即回滚；两步之间崩溃时，下次启动优先恢复通过校验、其次 mtime 最新的 `.build-old.*`，`fsync` 目录后才清理其余残留；恢复 `rename` 或读目录失败时保留全部残留并进入 Safe Mode）；子进程拒绝软链或与 `user_data_dir`、`shared_data_dir` 相同的 staging，以及含 `/`、`..`、NUL 的方案或词典名；子进程失败、崩溃、超时、找不到或校验不过时旧 `build/` 逐字节不变，引擎进入 `engineInitFailed`。
  - `build/.noema-deploy-manifest.json`（`DeployManifest`）记录输入清单（`shared_data_dir` 下全部文件递归 + `user_data_dir` 顶层 `*.custom.yaml`，含大小与 SHA256）、输出清单与方案引用的词典（`translator`、`reverse_lookup` 与带 tag 的 `script_translator`/`table_translator`）。输入无法完整盘点即失败而非跳过：`*.custom.yaml` 必须本身是普通文件（软链、目录、FIFO 一律拒绝，绝不跟随到 `user_data_dir` 之外），`shared_data_dir` 内软链只能指向普通文件。`build/` 仅当清单（≤ 16 MiB）列出非空的 `default.yaml`、方案与每个词典的 `.table.bin`、`.prism.bin`，且与 `build/` 实时盘点逐项全等（无未登记文件或软链）时可信；`deployIfNeeded` 在不可信或输入清单与当前不全等时重新部署（新增、修改、删除、改名都会改变清单），`neverDeploy` 直接进入 Safe Mode。
  - `KeyHandlingResult` 中 `handled` 与 `committedText` 相互独立：壳先上屏 `committedText`，再在 `handled == false` 时把当前键直通客户端。`librime` 提交组字并拒绝当前键（如无 `punctuator` 时 `nihao` 后按 `,`）时，引擎如实返回 `handled: false`，绝不因为有提交而吞键。
  - 内置最小拼音方案 `Resources/rime-default/`（`script_translator`，原创小词表）作为 `shared_data_dir` 随包分发；完整词库仍走 [lexicon note](2026-11-23-lexicon-canonical-and-userdb-isolation.md) 的下载与部署流程。
  - 密码框：`IsSecureEventInputEnabled()` 为真时立即直通并隐藏所有浮窗。
  - IMKit 壳分两层：`NoemaIMEShell` 库（`InputSessionCoordinator`、`NSEventKeyBridge`、`TextInputClient`/`CandidatePresenting` 接缝）不依赖引擎实现，可在测试中直接驱动真实 `RimeEngine`；`NoemaIME` 可执行文件只剩 `NoemaInputController`（逐个转发 IMKit 回调）、`EngineHost`（进程内唯一 `RimeEngine`）与 `main.swift`。`EngineHost.boot()` 立即返回：`RimeEngine.start` 在主 actor 上加锁、布防哨兵，把不调用 `librime` 的 `prepareBuild`（清单校验与 `noema-rime-deployer` 子进程）放到全局队列，完成后回到主 actor 做 `initialize` 与建会话；就绪前按键一律直通，`SIGTERM` 照常处理。`shutdown()` 在启动中先经 `DeployCancellation` 向部署子进程发 `SIGTERM`（宽限后 `SIGKILL`）再取消任务，被取消的启动解除哨兵（取消不是崩溃）、释放锁与 claim、抛出 `engineUnavailable("boot cancelled")`，`build/` 不变。两者都受 `check-imports.sh` 零 TCC 扫描。
  - 多个 `IMKInputController` 共享一个引擎：同一时刻只有一个会话令牌拥有组字；迟到的 `deactivate(A)` 在 `activate(B)` 之后到达时被忽略；换主时清掉旧客户端的 marked text 并 `clearComposition()`，绝不 `resetSession()`（会重置 `ascii_mode`）。按键顺序：安全输入 → 换主 → 无引擎/Safe Mode → 空闲 ASCII → `processKey`，结果先上屏 `committedText` 再按 `handled` 返回。安全输入下 `commitComposition` 与切到 ASCII 模式只丢弃组字（清除壳放上的 marked text），绝不 `insertText`；`deactivateServer:` 不取客户端代理即释放组字，代理失效也不会留下旧主。
  - `recognizedEvents` 只声明 keyDown：鼠标事件留给 IMKit，点击 marked text 之外时由 IMKit 调 `commitComposition:`。
  - `main.swift` 先回答 `--version`/`--check-rime`/`--help`（不触碰 AppKit，`verify-bundle.sh` 可无头运行），未知 `--` 参数立即退出 2；否则先注册 `IMKServer`，再在 `applicationDidFinishLaunching` 中启动引擎，SIGTERM/SIGINT 时 `shutdown()` 释放锁。
  - `noema-cli install` 先把包复制到 `--dest` 内的 staging 并只校验这份副本（Info.plist 标识与 `CFBundleExecutable`、两个可执行文件、librime、`rime-default`、`codesign --verify --strict --deep`；包本身与三个嵌套代码逐个 `codesign -dvv`，未加 `--allow-adhoc` 时任一为 ad-hoc 或无 `Authority=` 即拒绝；锁文件位于用户临时目录而非共享 `/tmp`），在 per-dest `flock` 下快照旧进程（pid + 启动时间；读路径前后各取一次身份并排除僵尸，pid 列表填满缓冲区时扩容重取）后以两次 `rename(2)` 替换，拒绝软链与非 Noema 目标；仅默认目录才注册 TIS 并结束快照中的进程。未结束的旧进程（`--no-reload`，或 3 秒内未退出——此时 `install` 退出 1 且不报告"stopped"）写入待重载台账：用户临时目录下按规范化目标包路径 SHA256 命名的 JSON（uid、包路径、pid + 启动时间），只在同一把 per-dest `flock` 下读写，读取拒绝软链、非普通文件、他人所有或超过 64 KiB，写入经 `0600` 临时文件 + `fsync` + `rename(2)`；`reload` 结束台账与当前路径上的进程，未全部退出时保留剩余并退出 1，发信号前一律重验 pid、启动时间、uid 与非僵尸。`noema-cli repl` 默认使用退出即删的临时 `user_data_dir`。
  - 任何热路径超时或异常一律 `return false` 直通 ASCII，永不吞键。
- **`Noema.app`（伴生 Agent，LaunchAgent 常驻）**：集中持有 Accessibility / Microphone / Speech Recognition 等 TCC 授权，承载 Settings、Clipboard、Voice、AI HUD 等 UI 与后台能力。
- **`noema-rime-deployer`（子进程）**：执行方案与词库编译，与输入热路径完全隔离（详见 [lexicon note](2026-11-23-lexicon-canonical-and-userdb-isolation.md)）。
- **`NoemaIPC`（异步 IPC）**：基于 `XPCSession`，每次请求携带 `generationID`，过期响应直接丢弃；IMKit 侧对 Agent 的任何同步等待上限 20ms，超时即降级直通 ASCII，Agent 不可用时输入法仍能独立工作。
- **选区 `⌘C` 安全事务**：优先 AX 读取选区；回退 `⌘C` 时先记录 `NSPasteboard.changeCount`，模拟复制后若 `changeCount` 未变则立即中止，严禁读取旧剪贴板；读取完成后恢复原剪贴板内容。
- **剪贴板过滤**：跳过带 `org.nspasteboard.ConcealedType`、`TransientType`、`AutoGeneratedType` 标记的条目，以及来自密码管理器的来源 App。
- **异步 AI 建议**：AI 结果只能进入独立的 `✨` 建议槽位，严禁改写或重排 Rime 候选首位，保证肌肉记忆与低延迟。

## Alternatives considered

- **单进程，把所有能力都塞进 IMKit。** Rejected：网络、ASR、模型推理与 AX 遍历会把不可控的延迟和崩溃面带入按键热路径；TCC 授权绑定在输入法 bundle 上，每次重签名或重装都可能漂移；输入法崩溃会影响所有 App 的输入。
- **M0 即把 `librime` 拆成独立 RimeEngine XPC Service。** 暂缓（not now）：M0 的首要风险是把基本输入跑通，额外的 XPC 往返与生命周期管理会增加延迟预算与调试成本，而 `librime` 本身在进程内实测亚毫秒级，已在单键 P95 `< 2ms` 预算之内。通过 `TypingEngine` 协议保留外迁接口。重启外迁的条件：实测 Rime 导致 IMKit 进程崩溃或单键 P95 超过 `2ms` 预算，或需要在多个前台进程间共享同一 Rime 会话。
- **崩溃计数放在 `UserDefaults` 或依赖 launchd 重启次数。** Rejected：`UserDefaults` 写入是异步合并的，崩溃前的递增可能丢失，计数永远到不了阈值；launchd 不管理 IMKit 进程的重启。哨兵与它保护的 `user_data_dir` 放在一起，`rename(2)` 保证崩溃后只见新旧两种记录之一。
- **在宿主进程内直接调用 `deployer_initialize` + `deploy()`。** Rejected：`librime` 在失败前就会覆写 `build/default.yaml` 等产物（实测：`default.yaml` 引用缺失方案时部署失败但旧 `build/` 已被改写），破坏最后可用的构建；编译的内存与耗时也落在输入法进程里。
- **部署时间戳文件 + 输入 mtime 比较。** Rejected：删除或改名的输入不在枚举结果中，撤销 `*.custom.yaml` 后旧配置持续生效；同一时钟刻度内的修改不可见；只检查暂存 YAML 而不检查编译词典，删掉 `.table.bin` 后仍"正常"启动却无候选。内容哈希清单把这三类问题一并消除，代价是每次启动对输入与输出各做一遍 SHA256。
- **有提交即报告 `handled: true`。** Rejected：`librime` 的 `DirectCommit` 在提交组字的同时拒绝当前键，要求宿主把它交给客户端；改成已处理会吞掉标点等按键。
- **以 `build/` 内已暂存 YAML 的修改时间判断是否需要重新部署。** Rejected：只改动非 YAML 输入（如 `lua/*.lua`）时 `librime` 不会重写暂存的 YAML，比较基准永远旧于输入，每次启动都会重新部署；部署成功后单独写入的时间戳文件只在真正部署后前移。
- **单写者锁用阻塞 `flock` 或 PID 文件。** Rejected：阻塞等待会卡住按键热路径；PID 文件在崩溃后残留，需要猜测进程是否存活，而 `flock` 在持有者退出（包括 `SIGKILL`）时由内核释放。
- **随包内置雾凇或万象作为默认方案。** Rejected：数十 MB 的词库违反大文件红线，并让 Safe Mode 之外的首次启动依赖重型部署；内置原创最小方案只保证"能打字"。
- **把会话协调逻辑直接写在 `NoemaIME` 可执行文件里。** Rejected：测试只能经由 IMKit 或 mock 的 `IMKServer` 触达它，违背"真实入口"测试原则；独立的 `NoemaIMEShell` 库让 `CRimeTests` 用真实 `RimeEngine` 驱动完整的按键与生命周期路径，壳本身仍受同一导入扫描。
- **`recognizedEvents` 同时声明鼠标与 flagsChanged 事件。** Rejected：接管鼠标事件后 IMKit 不再在点击 marked text 之外时调用 `commitComposition:`，组字会残留；Shift 切换中英暂不经 flagsChanged 实现。
- **失焦或换客户端时调用 `resetSession()`。** Rejected：会重置 `ascii_mode`，用户切到英文后每次换焦点都被切回中文；`clearComposition()` 只丢组字。
- **`install` 在替换之后再按目标路径查找旧进程。** Rejected：`rename(2)` 后旧进程的可执行文件已不在目标路径，查不到也就结束不了（负控：去掉替换前快照后 `installReloadStopsTheProcessOfTheReplacedBundle` 失败）。用 `pkill`/`killall` 按名字结束同样被拒：会误杀其他路径或其他用户的同名进程，且不防 pid 复用。
- **`EngineHost.boot()` 在主 actor 上同步运行 `RimeEngine(configuration:)`。** Rejected：部署时主线程阻塞最长 60 秒，IMKit 回调连"未就绪直通"都无法执行，主队列上的 `SIGTERM` 处理也被饿死（负控：把 `prepareBuild` 放回主 actor 后 `AsyncBootTests.deploymentDoesNotBlockTheMainActor` 的 50 ms 计时器延迟 2.1 秒）。同步初始化器只留给 `noema-cli repl` 与同步测试。
- **`reload` 只按目标路径查找进程，`install --no-reload` 丢弃替换前快照。** Rejected：旧包被改名删除后其进程不在目标路径，`reload` 报告 `stopped 0` 而旧进程继续持有 Rime 锁；超时同样丢失进程（负控：不写台账时 `installNoReloadFollowedByReloadStopsOldProcess` 失败）。
- **`install` 直接校验源包再复制。** Rejected：校验与复制之间源包可被替换（TOCTOU）；只校验 staging 副本，校验的就是安装的。
- **`repl` 默认使用真实 `~/Library/Application Support/Noema/rime`。** Rejected：会与正在运行的输入法争夺单写者锁并写入真实 userdb；需要时显式传 `--user-dir`。
- **在 IMKit 与 Agent 之间用 `CGEventTap` 监听全局按键。** Rejected：需要 Input Monitoring/Accessibility 权限，违背 IMKit 零 TCC 红线；全局按键监听是高敏感能力，与 IMKit 的事件流重复且存在顺序竞争；在安全输入模式下行为不可预测，存在泄露密码的风险。

## Acceptance criteria

- `NoemaIME` 目标的链接依赖与源码中不出现网络、AVFoundation/Speech、剪贴板监听或 AX 相关 API；其 `Info.plist` 不声明任何 TCC 用途字符串。
- 在 Agent 未运行或 IPC 人为延迟 >20ms 时，按键仍能输出（直通 ASCII 或 Rime 本地结果），无吞键。
- `IsSecureEventInputEnabled()` 为真时，所有按键直通且浮窗隐藏，引擎不接收按键，安全输入框不收到任何 marked text，上一客户端残留的 marked text 被清除（`InputSessionCoordinatorTests.secureInputPassesThroughWithoutTouchingTheSecureClient`，负控：去掉安全输入判断即失败）。
- `InputSessionCoordinator` 在真实 `RimeEngine` 上：全拼提交、半选汉字的 UTF-16 光标、Esc/退格取消、无 `punctuator` 时 `,` 上屏"你好"并返回 `false`、ASCII 模式与 Caps Lock 直通、Safe Mode 与无引擎降级、乱序 `activate(B)`/`deactivate(A)` 不影响 B、失焦保留 `ascii_mode`、安全输入下未激活的新会话零调用且 `commitComposition`/ASCII 切换不上屏、无提交时仍清 marked text、`commitComposition` 与 `hidePalettes`（`Tests/CRimeTests/InputSessionCoordinatorTests.swift`）；`NSEventKeyBridge` 用真实 `NSEvent` 测试，非 keyDown 事件在读取按键属性前即被拒绝。
- `noema-cli install` 拒绝软链、非 Noema 目标、签名被篡改的包、删除 `rime-default` 后重签的包与未加 `--allow-adhoc` 的 ad-hoc 包，且不改动已安装的包；升级后目录中不留 staging 或旧包；`--reload` 结束替换前的旧进程；`--no-reload` 后的 `reload` 经台账结束旧进程，再次 `reload` 为 0；忽略 `SIGTERM` 的旧进程让 `install --reload` 与 `reload` 都退出 1 且不报告已结束（负控：去掉台账写入或超时退出码即失败）；`reload` 只结束指定包路径的进程；`repl` 退出后删除临时目录，锁被占用时以 `userDataDirLocked` 直通（`Tests/CRimeTests/NoemaCLITests.swift`）。`NoemaIME --bogus` 立即退出 2。
- `⌘C` 回退事务在 `changeCount` 未变时返回中止结果，不返回剪贴板旧内容（负控测试覆盖）。
- AI 建议到达后，候选首位与到达前一致；建议只出现在 `✨` 槽位。
- 带过期 `generationID` 的 IPC 响应被丢弃。
- 单键处理 P95 `< 2ms`：真实 `librime` 上 500 个混合按键的基准测试（`singleKeyLatencyP95`）。
- 部署失败（`default.yaml` 引用缺失方案、找不到 `noema-rime-deployer`）时旧 `build/` 所有文件逐字节不变；删除 `build/*.table.bin` 后 `deployIfNeeded` 自动重建、`neverDeploy` 进入 Safe Mode；删除 `*.custom.yaml` 或 `shared_data_dir` 子目录文件触发重新部署并真实生效；软链或目录形式的 `*.custom.yaml`、`shared_data_dir` 内软链目录均进入 Safe Mode 且不拷贝外部文件；`build/` 内未登记文件或软链触发重建；损坏且字典序靠前的 `.build-old.*` 不会盖过有效备份；ACL 拒绝恢复 `rename` 时两种策略都保留全部 `.build-old.*`，权限恢复后 `neverDeploy` 仍能还原；无 `punctuator` 方案中 `nihao` 后按 `,` 返回 `handled: false` 与 `committedText == "你好"`（`Tests/CRimeTests/RimeEngineTests.swift`）。
- 预置连续失败计数达到阈值、损坏哨兵、外部持有锁、只读目录、部署失败五种情况下，`RimeEngine` 进入对应 Safe Mode 原因且所有按键 `handled: false`；`recoverFromSafeMode()` 在条件解除后恢复输入（`Tests/CRimeTests/RimeEngineTests.swift`）。

## Risks

- `librime` 暂驻 IMKit 进程，Rime 崩溃仍会拖垮输入法；依赖 Safe Mode 与后续外迁兜底。
- 每次启动对全部输入与输出做 SHA256：内置方案约毫秒级，百兆级外部词库可能增加数百毫秒启动时间；每次部署都在空 staging 中全量编译，不复用旧产物。
- 清单只按 `translator/dictionary` 要求 `<dict>.table.bin` 与 `<dict>.prism.bin`；另设 `translator/prism` 或多词典的方案需扩展 `requiredDictionaries`。
- 多进程增加签名、打包与调试复杂度，需要稳定的签名身份避免 TCC 授权漂移。
- 20ms 降级阈值可能在低负载机器上过于保守，需要实测调整。
- 进程在 `SIGTERM` 宽限期内来不及收尾时部署子进程被 `SIGKILL`，其 staging 目录留到下次启动的 `recoverInterruptedDeployments` 清理。
- Caps Lock 开启时，librime 在组字中途拒绝字母键，壳把键交给客户端而组字保持打开；该交互需在接入候选窗后实机确认。
- 剪贴板来源过滤依赖 App 自觉标记，未标记的敏感内容仍可能被记录。
