# Agent Note: Canonical SQLite learning store with isolated per-schema userdbs, not a shared LevelDB userdb

Status: implemented

## Problem

Noema 同时支持内置拼音与万象（Wanxiang）、雾凇（rime-ice）、薄荷（Mint）三套 Rime 方案。它们的码表编码、分词与用户词条格式并不相同，如果直接共享同一个 LevelDB `.userdb`，异构编码会互相污染用户词频，且 LevelDB 只允许单进程打开，多进程并发写会导致锁冲突甚至数据损坏。方案与词库的编译（`RimeDeploy`）耗时长、内存高，若在输入热路径或设置 App 中直接执行，会造成卡顿与半成品产物。外部词库与 `.gram` 语言模型动辄上百 MB，提交进 Git 会让仓库膨胀，并带来许可证与来源可追溯问题。

## Decision

- **一个根目录、一把锁、每套方案一个 librime `user_data_dir`**：根目录 `~/Library/Application Support/Noema/rime/` 持有 `BootGuard` 的 `.noema-rime.lock` 与哨兵、`learning.sqlite`、`active-schema-set.json`；每套方案（内置方案也是）在 `sets/<set>/` 拥有自己的 `build/`、`.userdb`、`lua/`、`noema_learned.tsv`，下载的方案源在 `schemas/<set>/`，`.gram` 在 `models/` 并以 `link(2)` 硬链接进方案目录，快照在 `snapshots/<set>/`。全部同卷，`rename(2)` 原子。
- **Canonical SQLite 是唯一真相源**：`learning.sqlite`（WAL、`synchronous=NORMAL`、`0600`、拒绝符号链接）以规范化的无调全拼为键记录词条、词频、时间与修订号（`NoemaLearning.LearningStore`）。`.userdb` 与 `noema_learned.tsv` 都是它的派生投影，可随时重建。
- **热路径零 SQLite**：`RimeEngine.recordCommits(to:isSecureInputEnabled:)` 只把含汉字的上屏（连同上屏前的原始输入与预编辑）放进 `LearningStoreWriter` 的有界内存队列；落盘在串行 `.utility` 队列上批量合并为一个事务。安全输入时不入队（壳层也已在引擎之前直通）。`EngineHost.shutdown()` 先 `flush()` 再关闭引擎。
- **两条投影路径**：切换方案时，在无会话的静默窗口里 `UserDBGuardian` 先用 `export_user_dict` 探测 `.userdb`（坏 `CURRENT`/`MANIFEST`/`.ldb`、符号链接、`lost/`、条目数远少于已投影数都算损坏或偏离），再按水位增量 `import_user_dict`；损坏时隔离到 `.quarantine/`，用 SHA-256 校验过的快照恢复并重放其后修订，或从 SQLite 全量重建。同时导出 `noema_learned.tsv`，由 `lua_translator@*noema_learned`（`noema-rime-deployer` 经 `<schema>.custom.yaml` 追加，从不写 `rime.lua`）读取，所以新学的词即使尚未投影也能出现在候选里。
- **切换不打断输入**：Agent 经 XPC 发 `agent.switchSchemaSet`（受 `sessionEpoch` 与单调 `generationID` 的 `GenerationGate` 约束）；`SchemaSetSwitcher` 在组字中把请求挂起并回报 `pendingIdle`，空闲后回报 `compiling`，在主线程之外准备与部署目标方案，构建就绪时若又在组字则再次等待空闲，最后在主线程上做短暂的静默切换并回报 `ready`；失败回报 `failed`，原方案与目标的旧 `build/` 都不变。启动时读取 `active-schema-set.json`，目标未安装则回退内置方案。
- **单一写者**：只有持有根锁的进程（`NoemaIME`，或 IME 未运行时的 `noema-cli lexicon switch`）读写 `sets/` 与 `learning.sqlite`。Agent 只用 `.readOnly` 连接读取统计（`LexiconInventory`），下载、校验与安全解压（`NoemaLexiconAdmin`）只写 `schemas/` 与 `models/`；`check-imports.sh` 禁止任何 IME 可达的目标导入 `NoemaLexiconAdmin` 或网络 API。
- **离线编译与原子切换**：`noema-rime-deployer` 子进程在 `sets/<set>/.deploy-staging.<pid>.<uuid>/`（持有 `.deploy.lock`）编译，`DeployManifest` 复核 `requiredPrisms` 等产物后用 `renamex_np(RENAME_SWAP)` 替换 `build/`；进程模型见 [process model note](../../proposed/architecture/2026-11-23-process-model-and-permissions.md)。
- **外部资产只登记不入库**：`vendor/dictionaries.lock.json` 登记来源 URL、版本、许可证、大小与 SHA256，随 `Noema.app` 打包；下载后校验哈希，绝不提交百兆级二进制。
- **合规**：禁止逆向或调用第三方输入法的私有/非官方语音接口，语音能力只使用 Apple 官方框架或明确授权的服务。

## Alternatives considered

- **三套方案直连同一个 LevelDB `.userdb`，或共用一个平铺的 `user_data_dir`。** Rejected：编码与分词异构导致词频互相污染且无法回滚；平铺目录里各方案的 `build/`、`*.custom.yaml` 与 userdb 互相覆盖，切换即重编译，LevelDB 单进程锁也让并发访问有损坏风险。
- **用 librime 的 `backup_user_dict`/`restore_user_dict` 做快照与恢复。** Rejected：它们写进工作目录，对已损坏的 userdb 也报告成功，无法作为健康探测；`export_user_dict` 返回 -1 才是可靠的信号，快照另存 SHA-256 旁注文件。
- **覆盖或合并用户的 `rime.lua` 来挂载学习词翻译器。** Rejected：会破坏下载方案自带的 Lua 脚本，升级时冲突；`lua_translator@*noema_learned` 加 `lua/noema_learned.lua` 是独立模块，只经 `custom.yaml` 补丁追加。
- **在 `@MainActor` 上同步写 SQLite。** Rejected：WAL 提交与 `fsync` 偶发数毫秒，会突破按键 P95 < 2 ms 的预算；有界队列只做内存追加，丢弃溢出事件而不阻塞输入。
- **在设置 App 内直接调用 `RimeDeploy` 或打开 `learning.sqlite` 读写。** Rejected：Agent 会与输入法同时打开用户数据，破坏单一写者；编译中途失败会留下半成品 `build/`，长时间编译阻塞 UI。
- **组字中立即切换方案。** Rejected：销毁会话会丢掉用户正在输入的预编辑；挂起到空闲边界的代价只是切换晚几百毫秒。
- **把词库与 `.gram` 直接提交到 Git 或 Git LFS。** Rejected：百兆级二进制使仓库与 CI 缓存膨胀，PUBLIC 仓上的 LFS 带宽配额也有限；来源与许可证难以追溯。manifest + SHA256 既可复现又可审计。

## Consequences

- `CRimeTests` 的 `LexiconAndLearningTests` 在真实 librime、真实 deployer 子进程与真实 SQLite 上验证：三套夹具方案（其一 `translator/prism` 不同于 `translator/dictionary`）热切换、userdb 物理隔离、二次切换不重编译；跨方案学习分别经 userdb 投影与 Lua 翻译器两条路径生效；组字中的切换请求经真实 IPC 回报 `pendingIdle` 并在空闲后 `ready`；损坏 `CURRENT`、`MANIFEST`、`.ldb` 均被探测、隔离并恢复；部署失败时 `build/` 字节不变；第二写者被拒；安全输入零写入；开启学习后 500 键 P95 < 2 ms。负控（去掉导出探测、去掉安全输入判断、去掉空闲等待、注入 `import Network`/`import NoemaLexiconAdmin`、删掉包内 `noema_learned.lua` 或 `dictionaries.lock.json`）都会让对应检查失败。
- 投影只在切换方案时发生：当前方案自己的 userdb 照常学习，其他方案在下次切换时经投影与重新导出的 `noema_learned.tsv`（启动与切换时导出）获得这些词。方案特有的词条属性（如万象的辅助码）不进入 SQLite，投影存在映射损失。
- 无调全拼规范化会丢失声调信息，部分同音词消歧依赖方案自身。
- 首次以方案集布局启动时，内置方案在 `sets/builtin/` 重新部署，根目录下旧的平铺 `build/` 与 userdb 不再使用，也不自动迁移。
- 上游词库更新需要手动更新 `dictionaries.lock.json` 与哈希；万象的 `.gram`（约 390 MB）只登记，不随方案自动下载。
- `rename(2)`、`link(2)` 与 `RENAME_SWAP` 仅在同一卷内原子，`schemas/`、`models/`、`sets/` 必须与根目录同卷。
