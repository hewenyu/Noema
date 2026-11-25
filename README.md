# Noema

Noema 是一个自用的原生中文输入法，基于 `librime`，由轻量的 IMKit 输入法壳与伴生 Agent App 组成。

- 目标平台：macOS 26+，Apple Silicon（arm64）。
- 当前状态：SwiftPM 多模块骨架（`NoemaCore`、`NoemaEngine`、`NoemaIMEShell`、`NoemaText`、`NoemaIPC`、`noema-cli`、`NoemaIME`、`noema-rime-deployer`），链接从源码构建的自包含 `librime.1.dylib`（含 `librime-lua`、`librime-octagram`）。`NoemaEngine` 的 `RimeEngine` 通过 `TypingEngine` 协议提供无界面的拼音输入（内置最小方案 `Resources/rime-default`、崩溃循环 Safe Mode、单写者目录锁），方案编译只在 `noema-rime-deployer` 子进程的隔离 staging 目录中进行，经 `DeployManifest`（输入与产物 SHA256 清单）校验后原子切换 `build/`，失败时旧 `build/` 不变；均由真实 librime 集成测试覆盖。`NoemaIME.app` 已是可用的 IMKit 薄壳：`NoemaInputController` 把按键交给 `RimeEngine`，以预编辑（marked text）显示拼音、上屏提交文本；安全输入、Safe Mode、ASCII 模式、引擎启动中（部署在主线程之外进行）与引擎不认的键一律直通，绝不吞键。候选窗尚未接入（Issue #6），也尚无伴生 App。`noema-cli install|reload|repl` 负责安装、重载与命令行试打。
- 架构地图：[docs/architecture.md](docs/architecture.md)。

## 构建与测试

只需 CommandLineTools（Swift 6.2+、macOS 26 SDK）、CMake 与网络，不需要 `Xcode.app`：

```sh
scripts/dev/doctor.sh           # 检查工具链、Swift Testing 与 librime 状态
scripts/build/librime.sh        # 按 vendor/librime.lock 构建 vendor-out/librime（首次约 5 分钟，之后幂等跳过）
scripts/dev/test.sh             # 运行全部 Swift Testing 测试（含真实 librime 集成测试）；librime 产物过期时拒跑
swift build && .build/debug/noema-cli check-rime   # 打印 librime 版本与模块注册状态
.build/debug/noema-cli repl                        # 在临时目录里用真实引擎试打（如输入 nihao<space>，:help 查看命令）
scripts/governance/check.sh     # 文档词数预算、决策笔记格式、Markdown 链接与导入边界
```

## 打包与签名

```sh
security find-identity -v -p codesigning            # 查看证书 SHA-1
scripts/build/bundle.sh --sign <40 位 SHA-1>        # 组装并以 Hardened Runtime 签名 dist/NoemaIME.app
scripts/build/verify-bundle.sh --require-signed     # 校验布局、Info.plist、链接、签名，并真实运行 --check-rime
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
