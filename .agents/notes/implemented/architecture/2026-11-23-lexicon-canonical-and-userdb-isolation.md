# Agent Note: Canonical SQLite learning store with isolated per-schema userdbs, not a shared LevelDB userdb

Status: implemented

## Problem

Noema 同时支持内置拼音与万象（Wanxiang）、雾凇（rime-ice）、薄荷（Mint）三套 Rime 方案。它们的码表编码、分词与用户词条格式并不相同，如果直接共享同一个 LevelDB `.userdb`，异构编码会互相污染用户词频，且 LevelDB 只允许单进程打开，多进程并发写会导致锁冲突甚至数据损坏。方案与词库的编译（`RimeDeploy`）耗时长、内存高，若在输入热路径或设置 App 中直接执行，会造成卡顿与半成品产物。外部词库与 `.gram` 语言模型动辄上百 MB，提交进 Git 会让仓库膨胀，并带来许可证与来源可追溯问题。

## Decision

- **一个根目录、一把锁、每套方案一个 librime `user_data_dir`**：根目录 `~/Library/Application Support/Noema/rime/` 持有 `BootGuard` 的 `.noema-rime.lock` 与哨兵、`learning.sqlite`、`active-schema-set.json`；每套方案（内置方案也是）在 `sets/<set>/` 拥有自己的 `build/`、`.userdb`、`lua/`、`noema_learned.tsv`，下载的方案源在 `schemas/<set>/`，`.gram` 在 `models/` 并以 `link(2)` 硬链接进方案目录，快照在 `snapshots/<set>/`。全部同卷，`rename(2)` 原子。
- **Canonical SQLite 是唯一真相源**：`learning.sqlite`（WAL、`synchronous=NORMAL`、`0600`、拒绝符号链接）以规范化的无调全拼为键记录词条、词频、时间与修订号（`NoemaLearning.LearningStore`）。键必须是每个汉字一个标准普通话音节（`TextNormalization.standardMandarinSyllables`，不含裸声母）：双拼方案的预编辑本就是全拼（`uijx` 显示 `shi jia`）；简拼的声母按系统汉字转拼音（`kCFStringTransformMandarinLatin`，`ü` 记作 `v`）补全（`n h` 记作 `nv hai`）；无法验证的拼写（`x y` 上屏 `你好`）不学习。`.userdb` 与 `noema_learned.tsv` 都是它的派生投影，可随时重建。
- **热路径零 SQLite**：`RimeEngine.recordCommits(to:isSecureInputEnabled:)` 只把含汉字的上屏（连同上屏前的原始输入与预编辑）放进 `LearningStoreWriter` 的有界内存队列；落盘在串行 `.utility` 队列上批量合并为一个事务。安全输入时不入队（壳层也已在引擎之前直通）。`EngineHost.shutdown()` 先 `flush()` 再关闭引擎。
- **两条投影路径**：切换方案时，在无会话的静默窗口里 `UserDBGuardian` 先用 `export_user_dict` 探测 `.userdb`（坏 `CURRENT`/`MANIFEST`/`.ldb`、符号链接、`lost/`、条目数远少于已投影数都算损坏或偏离），再按该 userdb 自己的水位增量 `import_user_dict`（`projection_watermarks` 以 `(schema_set, dict_name)` 为主键：同一方案集里各用独立 user dict 的方案互不覆盖水位，共用 user dict 的方案共用一个；发布前按方案集记录的旧水位表在读写打开时删除重建、`entries` 不动，下次切换保守地全量重投影；只读连接遇到旧表时视作没有水位）；损坏时隔离到 `.quarantine/`，用 SHA-256 校验过的快照恢复并重放其后修订，或从 SQLite 全量重建。同时导出 `noema_learned.tsv`，由 `lua_translator@*noema_learned`（`noema-rime-deployer` 经 `<schema>.custom.yaml` 的 `engine/translators/+` 序列追加，从不写 `rime.lua`，编译后的 `engine/translators` 缺少它即部署失败）读取，查找前去掉 `speller/delimiter` 字符（`ni'hao` 即 `nihao`），所以新学的词即使尚未投影也能出现在候选里。TSV 以全拼为键，故该翻译器只在能证明是全拼的方案上启用（有 `script_translator`、方案 ID 与 prism 不含双拼/形码/注音等标记、探测音节在 `speller/algebra` 之后仍是合法拼写）：按 librime 生成音节表拼写的方式，逐条用 librime-lua 的 `Projection` 在每个探测音节的拼写集合（无调形与带调形）上重放全部规则，`xform`/`xlit` 替换、`erase` 删除、`derive`/`fuzz`/`abbrev` 在原拼写旁追加，未知运算符即关闭。万象全拼把 `ni` 先 `xform` 成 `ni0`、再由后面的 `derive` 还原为 `ni`，故仍启用；双拼等方案上它不加载 TSV、不出候选（小鹤 `shui` 是 `sang shi`），学习词只经按方案拼写投影的 userdb 出现。
- **按词典拼写投影**：userdb 编码的每个音节须是该方案词典音节表里的音节才查得到。万象 v18.2.1 与导入万象词库的薄荷，词典编码是 NFC 带调拼音（`ní hào`、`nǚ hái`、`lüè`，轻声不标，j/q/x/y 后写 `u`），无调的 `ni hao` 能导入却永远查不到。`RimeEngine.userDictCodeFormat(schemaID:)` 读编译后的 `speller/algebra`：有规则含带调元音（`āáǎà…ǖǘǚǜ`，不含无调 `ü`）即 `.unicodeToned`，否则 `.toneless`（雾凇、内置方案、`double_pinyin_flypy`）。带调时 `TextNormalization.unicodeTonedPinyinKey` 按系统读音（`kCFStringTransformMandarinLatin`）给每个音节标调；用户所打音节与系统读音不符（多音字：`yin hang` 的 `行`，系统读 `xíng`）时取 `defaultTonedSyllable`：默认第一声，没有第一声读音的 76 个音节取其实际有的声调（`lan` → `lán`、`lve` → `lüè`、`zhei` → `zhèi`），每个结果都在万象 v18.2.1 的音节表里；万象各声调都 `derive` 到无调，故仍以用户所打拼写命中。水位与快照旁注记录投影所用拼写（`code_format`，此前的行视为 `toneless`）；拼写不同即全量重放（快照照常恢复以保留方案自身学到的词），已用无调编码投影过的万象 userdb 在下次切换时自动修复。
- **只有普通话拼音方案参与学习**：`RimeEngine.isMandarinPinyinSchema(schemaID:)` 读编译后的方案（打不开即为否）：`engine/translators` 须有不带标签的 `script_translator`、不得有不带标签的 `table_translator`（五笔、仓颉、笔画、郑码的主翻译器；全拼只用 `table_translator@custom_phrase` 这类带标签的），且方案 ID、`translator/dictionary`、`translator/prism` 不含 `wubi`、`cangjie`、`zhuyin`、`jyutping`、`cantonese` 等非普通话拼音标记。双拼（`double_pinyin_flypy`、小鹤）算普通话拼音：预编辑即全拼，userdb 也以全拼为键。结果缓存在引擎上（开会话与 librime 内切换方案时重算），经 `CommitObservation.isMandarinPinyinSchema` 进入 `LearningCommitEvent`，为否时 `normalized()` 直接返回 nil：五笔 98 的 `wo`（伙）、`shi`（椒）虽是合法音节也不入库。切换到这类方案时 `UserDBGuardian` 照常体检 userdb，但不带 `learning.sqlite`：既不把全拼词条投影进形码 userdb，也不为它写水位。`noema_learned.lua` 同样要求不带标签的 `script_translator` 且无不带标签的 `table_translator`，并检查 `translator/dictionary`。
- **切换不打断输入**：Agent 经 XPC 发 `agent.switchSchemaSet`（受 `sessionEpoch` 与单调 `generationID` 的 `GenerationGate` 约束）；`SchemaSetSwitcher` 在组字中把请求挂起并回报 `pendingIdle`，空闲后回报 `compiling`，在主线程之外准备与部署目标方案，构建就绪时若又在组字则再次等待空闲，最后在主线程上做短暂的静默切换并回报 `ready`；失败回报 `failed`，原方案与目标的旧 `build/` 都不变。启动时读取 `active-schema-set.json`，目标未安装则回退内置方案。
- **单一写者**：只有持有根锁的进程（`NoemaIME`，或 IME 未运行时的 `noema-cli lexicon switch`）读写 `sets/` 与 `learning.sqlite`。Agent 只用 `.readOnly` 连接读取统计（`LexiconInventory`），下载、校验与安全解压（`NoemaLexiconAdmin`）只写 `schemas/` 与 `models/`；`check-imports.sh` 禁止任何 IME 可达的目标导入 `NoemaLexiconAdmin` 或网络 API。
- **离线编译与原子切换**：`noema-rime-deployer` 子进程在 `sets/<set>/.deploy-staging.<pid>.<uuid>/`（持有 `.deploy.lock`）编译，`DeployManifest` 复核 `requiredPrisms` 等产物后用 `renamex_np(RENAME_SWAP)` 替换 `build/`；进程模型见 [process model note](../../proposed/architecture/2026-11-23-process-model-and-permissions.md)。
- **外部资产只登记不入库**：`vendor/dictionaries.lock.json` 登记来源 URL、版本、许可证、大小与 SHA256，随 `Noema.app` 打包；下载后校验哈希，绝不提交百兆级二进制。
- **合规**：禁止逆向或调用第三方输入法的私有/非官方语音接口，语音能力只使用 Apple 官方框架或明确授权的服务。

## Alternatives considered

- **三套方案直连同一个 LevelDB `.userdb`，或共用一个平铺的 `user_data_dir`。** Rejected：编码与分词异构导致词频互相污染且无法回滚；平铺目录里各方案的 `build/`、`*.custom.yaml` 与 userdb 互相覆盖，切换即重编译，LevelDB 单进程锁也让并发访问有损坏风险。
- **用 librime 的 `backup_user_dict`/`restore_user_dict` 做快照与恢复。** Rejected：它们写进工作目录，对已损坏的 userdb 也报告成功，无法作为健康探测；`export_user_dict` 返回 -1 才是可靠的信号，快照另存 SHA-256 旁注文件。
- **覆盖或合并用户的 `rime.lua` 来挂载学习词翻译器。** Rejected：会破坏下载方案自带的 Lua 脚本，升级时冲突；`lua_translator@*noema_learned` 加 `lua/noema_learned.lua` 是独立模块，只经 `custom.yaml` 补丁追加。
- **以原始输入或预编辑原样为键（仅当二者字母一致时取预编辑）。** Rejected：双拼的原始按键（`uijx`）与简拼声母（`n h`、`shi j`）会被当作全拼写入，拆散词频并污染其他方案的 userdb 与 TSV；逐音节对照标准音节表与系统读音后，无法验证的上屏宁可不学。
- **用 `"engine/translators/@after last"` 追加学习词翻译器。** Rejected：用户补丁里已有同名键时插入的是重复键，librime 只保留其中一个，学习词翻译器被静默丢弃而部署仍成功；`engine/translators/+` 与用户的 `@after last` 并存，已有 `+` 序列则并入其中，部署器再核对编译结果。
- **凭编码是否拼成合法普通话音节判断能否学习，不看方案类型。** Rejected：五笔 98 的 `wo`（伙）、`shi`（椒），粤拼的 `si` 都是合法普通话音节，会以错误读音写入 SQLite，再投影成全拼方案的首选；只有方案的主翻译器与名称能区分形码、粤拼与普通话拼音。
- **每个方案集只记一个投影水位（`schema_set` 主键）。** Rejected：同一方案集里两个方案各有 user dict 时，先切到的那个把水位推到最新，另一个随后读到同一水位、`entriesSince` 为空，新词永远投影不进它的 userdb；按 `(schema_set, dict_name)` 记水位后，共用 user dict 的方案仍共用一个。
- **所有方案的 userdb 都导入无调 `pinyin_norm`。** Rejected：万象与薄荷的词典编码带调，`ni hao` 能导入、水位也前进，却不在音节表里而永远查不到（Codex #4709690149 在真实万象 v18.2.1 上复现）。
- **多音字回退一律标第一声。** Rejected：万象 v18.2.1 里 63 个标准音节没有第一声读音（`lan`、`ren`、`shui`、`lve`），`lüē` 之类的编码同样查不到；按系统读音推出的例外表只多 76 个条目。
- **只按 `speller/algebra` 中的 `xform`/`xlit`/`erase` 重放探测音节。** Rejected：万象把无调 `ni` 先变为 `ni0`、靠后面的 `derive` 才还原，略过 `derive` 会误判为非全拼，Lua 翻译器在全拼万象上自行关闭。
- **读编译后的词典表判断编码是否带调。** Rejected：`build/*.table.bin` 是 librime 私有格式，没有 API；拼写运算必须处理带调元音才能输入带调词典，规则文本即可靠信号。
- **在 `@MainActor` 上同步写 SQLite。** Rejected：WAL 提交与 `fsync` 偶发数毫秒，会突破按键 P95 < 2 ms 的预算；有界队列只做内存追加，丢弃溢出事件而不阻塞输入。
- **在设置 App 内直接调用 `RimeDeploy` 或打开 `learning.sqlite` 读写。** Rejected：Agent 会与输入法同时打开用户数据，破坏单一写者；编译中途失败会留下半成品 `build/`，长时间编译阻塞 UI。
- **组字中立即切换方案。** Rejected：销毁会话会丢掉用户正在输入的预编辑；挂起到空闲边界的代价只是切换晚几百毫秒。
- **把词库与 `.gram` 直接提交到 Git 或 Git LFS。** Rejected：百兆级二进制使仓库与 CI 缓存膨胀，PUBLIC 仓上的 LFS 带宽配额也有限；来源与许可证难以追溯。manifest + SHA256 既可复现又可审计。

## Consequences

- `CRimeTests` 的 `LexiconAndLearningTests` 在真实 librime、真实 deployer 子进程与真实 SQLite 上验证：三套夹具方案（其一 `translator/prism` 不同于 `translator/dictionary`）热切换、userdb 物理隔离、二次切换不重编译；跨方案学习分别经 userdb 投影与 Lua 翻译器两条路径生效；组字中的切换请求经真实 IPC 回报 `pendingIdle` 并在空闲后 `ready`；损坏 `CURRENT`、`MANIFEST`、`.ldb` 均被探测、隔离并恢复；部署失败时 `build/` 字节不变；双拼（`double_pinyin_flypy` 拼写运算）与简拼（`abbrev`）上屏以全拼入库并经 userdb 在全拼方案中出现；用户补丁已含 `@after last` 时学习词翻译器仍在，补丁覆盖掉它时部署器退出 1；`ni'hao` 命中 TSV 词；任意命名的小鹤双拼与 `double_pinyin_flypy` 上 Lua 翻译器不以 `shui` 出 `水`、`uv` 仍经 userdb 出现，带 `derive`/`abbrev`/`erase` 的全拼方案仍出 TSV 词；部分选字后改写剩余输入（`你好shi jian`）以改后的拼写入库，无法验证时不学；`wubi98_mint`、同构但名称中性的 `mint_shape`（只靠翻译器判断拦下）与用不带标签 `script_translator` 的 `jyutping_fixture`（只靠名称判断拦下）上屏 `伙`、`椒` 都不入库，预存的 `霓昊` 不投影进其 userdb、不写水位，`mint_shape` 上 Lua 翻译器关闭，雾凇 `wo` 的首选仍是 `我`；带调的万象形夹具（万象 v18.2.1 的全拼与小鹤双拼规则原文、`ní hào` 编码）在无 Lua 时经 userdb 让 `霓昊`、`霓女`、`昊行`（`hào hāng`）、`略昊`、`重昊` 出现在第一页，损坏后从 SQLite 重建依然如此，先以无调编码投影过的 userdb 在方案改为带调后全量重放；同一词典在全拼规则下 Lua 翻译器启用并以 `nihao`、`ni'hao` 出 TSV 词，在小鹤规则下关闭；同一方案集的 `schema_a`、`schema_b` 各自收到新词 `时见`，共用 `dict_a` 的 `schema_a_alias` 共用其水位；第二写者被拒；安全输入零写入；开启学习后 500 键 P95 < 2 ms。负控（去掉导出探测、去掉安全输入判断、去掉空闲等待、让方案分类恒为真、去掉 `normalized()` 的方案判断、去掉翻译器或名称判断、还原 Lua 的旧翻译器判断、Lua 重放略过 `derive`、Lua 恒启用、编码格式恒为无调、水位或快照忽略编码格式、不迁移 `code_format` 列、把水位退回按方案集共用、注入 `import Network`/`import NoemaLexiconAdmin`、删掉包内 `noema_learned.lua` 或 `dictionaries.lock.json`）都会让对应检查失败。
- 投影只在切换方案时发生：当前方案自己的 userdb 照常学习，其他方案在下次切换时经投影与重新导出的 `noema_learned.tsv`（启动与切换时导出）获得这些词。方案特有的词条属性（如万象的辅助码）不进入 SQLite，投影存在映射损失。
- 无调全拼规范化会丢失声调信息，部分同音词消歧依赖方案自身；投影进带调词典时多音字可能落在别的声调上（`银行` 记作 `yín hāng`），仍以用户所打拼写出现。简拼补全依赖系统读音：多音字的声母若与系统读音不符（`y h` 上屏 `银行`，系统读 `yin xing`）则不学习；完整输入的全拼按用户所打记录（`yin hang`）。
- 学习前去掉上屏文本首尾的标点、符号与空白（`nihao,` 上屏 `你好，`，只学 `你好`）；部分选字后的整句上屏沿用最近一次纯拼音预编辑的音节切分，但仅当原始输入未变；选字后改写过剩余输入则改用原始输入对照系统读音。`noema_learned.tsv` 与 levers 导入文件跳过含控制字符、以 `#` 开头或拼音非 `a`–`z` 的条目，即使 SQLite 被绕过写入也注入不了额外行。
- 启动时 `active-schema-set.json` 指向的外部方案若部署或初始化失败（含崩溃循环），`EngineHost` 只回退一次内置方案并把它记为当前方案，用户不会困在 Safe Mode 里无法切回。
- 风险：锁定在 lockfile 中的外部方案包自带的 Lua 脚本运行在 `NoemaIME` 内，可使用 `librime-lua` 的 `io`/`os`；目前只靠 SHA-256 固定来源缓解，日后如有需要可沙箱化或剥除 `io`/`os`。
- 首次以方案集布局启动时，内置方案在 `sets/builtin/` 重新部署，根目录下旧的平铺 `build/` 与 userdb 不再使用，也不自动迁移。
- 上游词库更新需要手动更新 `dictionaries.lock.json` 与哈希；万象的 `.gram`（约 390 MB）只登记，不随方案自动下载。
- `rename(2)`、`link(2)` 与 `RENAME_SWAP` 仅在同一卷内原子，`schemas/`、`models/`、`sets/` 必须与根目录同卷。
