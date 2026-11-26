# Noema

Noema 是一个自用的原生中文输入法，基于 `librime`，由轻量的 IMKit 输入法壳与伴生 Agent App 组成。

- 目标平台：macOS 26+，Apple Silicon（arm64）。
- 当前状态：SwiftPM 多模块骨架（`NoemaCore`、`NoemaEngine`、`NoemaIMEShell`、`NoemaUI`、`NoemaText`、`NoemaLearning`、`NoemaLexiconAdmin`、`NoemaIPC`、`NoemaAgentCore`、`noema-cli`、`NoemaIME`、`NoemaAgent`、`noema-rime-deployer`），链接从源码构建的自包含 `librime.1.dylib`（含 `librime-lua`、`librime-octagram`）。`NoemaEngine` 的 `RimeEngine` 通过 `TypingEngine` 协议提供无界面的拼音输入（内置最小方案 `Resources/rime-default`、崩溃循环 Safe Mode、单写者目录锁），方案编译只在 `noema-rime-deployer` 子进程的隔离 staging 目录中进行，经 `DeployManifest`（输入与产物 SHA256 清单）校验后原子切换 `build/`，失败时旧 `build/` 不变；均由真实 librime 集成测试覆盖。`NoemaIME.app` 已是可用的 IMKit 薄壳：`NoemaInputController` 把按键交给 `RimeEngine`，以预编辑（marked text）显示拼音、上屏提交文本；安全输入、Safe Mode、ASCII 模式、引擎启动中（部署在主线程之外进行）与引擎不认的键一律直通，绝不吞键。候选窗（`NoemaUI`）用 CoreText 排版、`NSGlassEffectView` 作背景，不抢焦点、不闪烁，跟随亮暗色，在光标旁放置（光标位置无效时用同一窗口上次的有效位置），支持点击选词、展开与滚轮翻页；可按应用关闭内联预编辑，改由候选窗绘制。伴生 App `Noema.app`（`dev.noema.agent`）是菜单栏常驻的 LaunchAgent（`SMAppService.agent`），提供设置窗口（基础设置、快速操作、词库、其他）；IME 经 `NoemaIPC`（`XPCSession` + 双层签名身份校验 + `generationID`）只向它发送不含文本的组合元数据，即发即弃，Agent 退出或被冒充时打字不受影响，安全输入期间不发任何消息。内置拼音与万象、雾凇、薄荷各自在 `sets/<方案>/` 拥有独立的 `build/` 与 `.userdb`（旧版平铺在根目录的 userdb 与 `*.custom.yaml` 首次启动时迁入 `sets/builtin/`，其词条并入 `learning.sqlite`；内置方案以 `uniquifier` 去掉 userdb 与学习词翻译器的重复候选），共享学习统一写入 Canonical SQLite `learning.sqlite`（上屏在主线程外异步落盘，安全输入时不记录；双拼与简拼上屏一律以全拼为键，五笔、粤拼等非普通话拼音方案以及拼音方案内的反查与识别器输入（薄荷 `Uw` 五笔反查）的上屏不学习；外部方案缺少的标准 OpenCC 配置（如 `s2t.json`）由包内 `Resources/opencc` 补足，方案自带的 `opencc/` 文件优先），启动与切换方案时（均在主线程之外）经 `UserDBGuardian` 按各 userdb 自己的水位、以目标词典的编码拼写（万象、薄荷为带调的 `ní hào`）投影进目标 userdb（形码等方案只体检不投影；损坏时隔离并从校验过的快照或 SQLite 恢复），并由 `noema_learned.lua` 在全拼方案上读取导出的 `noema_learned.tsv`（双拼等方案只经 userdb）。设置的"词库"页只读展示当前方案、已安装 `*.dict.yaml` 与学习库统计，按 `dictionaries.lock.json`（SHA256 校验）下载安装方案，并经 XPC 请求切换；输入法在组字中会等到本次输入结束再切换，编译在后台进行，失败时保留原 `build/`；启动时外部方案若无法加载，则回退内置方案。`noema-cli install|reload|repl|lexicon` 负责安装、重载、命令行试打与离线查看/校验/切换方案（输入法运行时拒绝切换）。
- 架构地图：[docs/architecture.md](docs/architecture.md)；真机冒烟清单：[docs/runbooks/smoke-checklist.md](docs/runbooks/smoke-checklist.md)。

## 构建与测试

只需 CommandLineTools（Swift 6.2+、macOS 26 SDK）、CMake 与网络，不需要 `Xcode.app`：

```sh
scripts/dev/doctor.sh           # 检查工具链、Swift Testing 与 librime 状态
scripts/build/librime.sh        # 按 vendor/librime.lock 构建 vendor-out/librime（首次约 5 分钟，之后幂等跳过）
scripts/dev/test.sh             # 运行全部 Swift Testing 测试（含真实 librime 集成测试）；librime 产物过期时拒跑
swift build && .build/debug/noema-cli check-rime   # 打印 librime 版本与模块注册状态
.build/debug/noema-cli repl                        # 在临时目录里用真实引擎试打（如输入 nihao<space>，:help 查看命令）
.build/debug/noema-cli lexicon list                # 列出 lockfile、当前方案、已安装词典大小与学习库统计（verify 校验，switch <方案> 离线切换）
scripts/governance/check.sh     # 文档词数预算、决策笔记格式、Markdown 链接与导入边界
```

## 打包与签名

```sh
security find-identity -v -p codesigning            # 查看证书 SHA-1
scripts/build/bundle.sh --sign <40 位 SHA-1>        # 组装并以 Hardened Runtime 签名 dist/NoemaIME.app 与 dist/Noema.app（--target ime|agent 只构建其一）
scripts/build/verify-bundle.sh --require-signed     # 校验两个包的布局、Info.plist、LaunchAgent、链接、签名，并真实运行 --version 与 --check-rime
```

安装到 `~/Library/Input Methods` 并让系统重新加载：

```sh
.build/debug/noema-cli install                      # 先在暂存副本上校验 Info.plist、可执行文件与签名，再以 RENAME_SWAP 原子替换；被中断的安装下次自动恢复
.build/debug/noema-cli install --allow-adhoc        # 本机开发：接受 ad-hoc 签名的包
.build/debug/noema-cli reload                       # 结束本用户该路径下（含 install --no-reload 留下）的 NoemaIME 进程，系统下次使用时重启；超时退出 1
```

首次安装后在"系统设置 > 键盘 > 输入法"中添加 Noema。`--dest` 指向其他目录时默认不注册、不重载。

`--sign` 必填，只接受证书 SHA-1 或 `-`（ad-hoc，仅供 CI 校验，不加 Hardened Runtime，不可分发）。Kiln CI（`.kiln/workflows/ci.yml`）运行治理检查、librime 构建、测试与 ad-hoc 打包校验，不接触签名证书。

## 贡献与治理

- [AGENTS.md](AGENTS.md)：所有贡献者与 AI 代理必须遵守的常驻规则。
- [.agents/notes/README.md](.agents/notes/README.md)：决策笔记（Agent Notes）的格式、目录与检索方法。
