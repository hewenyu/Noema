# Agent Note: Canonical SQLite learning store with isolated per-schema userdbs, not a shared LevelDB userdb

Status: proposed

## Problem

Noema 计划同时支持万象（Wanxiang）、雾凇（rime-ice）、薄荷（Mint）三套 Rime 方案。它们的码表编码、分词与用户词条格式并不相同，如果直接共享同一个 LevelDB `.userdb`，异构编码会互相污染用户词频，且 LevelDB 只允许单进程打开，多进程并发写会导致锁冲突甚至数据损坏。与此同时，方案与词库的编译（`RimeDeploy`）耗时长、内存高，若在输入热路径或设置 App 中直接执行，会造成卡顿与半成品产物。外部词库与 `.gram` 语言模型动辄上百 MB，提交进 Git 会让仓库膨胀，并带来许可证与来源可追溯问题。

## Proposal

- **Canonical SQLite 学习库为唯一真相源**：`learning.sqlite`，启用 WAL 模式，以规范化的无调全拼作为键记录用户学习（词条、词频、时间）。各方案的 `.userdb` 只是由它投影出来的派生数据，可随时重建。
- **每套方案物理隔离 `.userdb`**：万象、雾凇、薄荷各自拥有独立的 `.userdb` 目录，禁止直连共享同一 LevelDB；跨方案共享词频统一经 Canonical SQLite 投影。
- **单一写者红线**：仅单一 Rime 宿主进程（M0 为 `NoemaIME`）打开并读写 `user_data_dir`；Agent 与其它进程只能通过 IPC 请求变更或读取 SQLite。
- **离线编译与原子切换**：`noema-rime-deployer` 作为独立子进程，在 `staging/` 目录完成方案与词库编译和校验，成功后通过 `rename(2)` 原子替换 `build/`；失败则保留旧 `build/` 不变。宿主进程在切换后重新加载。M0 已落地：staging 为 `user_data_dir/.deploy-staging.<pid>.<uuid>`（同卷），子进程只复制顶层 `*.custom.yaml`、不碰 `.userdb` 与锁，产物附带 `DeployManifest`（输入与输出 SHA256 清单），宿主复核后切换，详见 [process model note](2026-11-23-process-model-and-permissions.md)。
- **外部资产只登记不入库**：外部词库与 `.gram` 文件只在 `dictionaries.lock.json` 中登记来源 URL、版本、许可证与 SHA256，下载后校验哈希；绝不把百兆级二进制提交进 Git。
- **合规**：禁止逆向或调用第三方输入法的私有/非官方语音接口，语音能力只使用 Apple 官方框架或明确授权的服务。

## Alternatives considered

- **三套方案直连同一个 LevelDB `.userdb`。** Rejected：编码与分词异构导致词频互相污染且无法回滚；LevelDB 单进程锁使多方案或多进程并发访问时出现锁冲突与损坏风险。
- **在设置 App 内直接调用 `RimeDeploy`。** Rejected：设置 App 会与输入法宿主同时打开 `user_data_dir`，破坏单一写者；编译过程中途失败会留下半成品 `build/`，导致输入法加载失败；长时间编译阻塞 UI。
- **把词库与 `.gram` 直接提交到 Git 或 Git LFS。** Rejected：百兆级二进制使仓库与 CI 缓存膨胀，PUBLIC 仓上的 LFS 带宽配额也有限；来源与许可证难以追溯。manifest + SHA256 既可复现又可审计。

## Acceptance criteria

- `learning.sqlite` 以 WAL 模式打开，删除任一方案的 `.userdb` 后可由 SQLite 完整重建该方案的用户词频。
- 同一时刻只有 Rime 宿主进程持有 `user_data_dir` 的 LevelDB 锁（负控：第二进程尝试打开时被拒绝并报错）。
- `noema-rime-deployer` 编译失败时 `build/` 内容与哈希保持不变；成功时切换为单次 `rename(2)`。
- 仓库中不存在超过约定大小阈值的二进制词库或模型文件；`dictionaries.lock.json` 中每个条目都有 SHA256，哈希不匹配时拒绝加载。

## Risks

- SQLite 到各 `.userdb` 的投影可能存在延迟或映射损失（例如方案特有的词条属性）。
- 无调全拼规范化会丢失声调信息，部分同音词消歧依赖方案自身。
- 上游词库更新需要手动更新 manifest 与哈希，存在维护成本。
- `rename(2)` 仅在同一文件系统卷内原子，`staging/` 与 `build/` 必须位于同一卷。
