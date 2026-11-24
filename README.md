# Noema

Noema 是一个自用的原生中文输入法，基于 `librime`，由轻量的 IMKit 输入法壳与伴生 Agent App 组成。

- 目标平台：macOS 26+，Apple Silicon（arm64）。
- 当前状态：SwiftPM 多模块骨架（`NoemaCore`、`NoemaEngine`、`NoemaText`、`NoemaIPC`、`noema-cli`），链接从源码构建的自包含 `librime.1.dylib`（含 `librime-lua`、`librime-octagram`）；尚无输入法与伴生 App。

## 构建与测试

只需 CommandLineTools（Swift 6.2+、macOS 26 SDK）、CMake 与网络，不需要 `Xcode.app`：

```sh
scripts/dev/doctor.sh           # 检查工具链、Swift Testing 与 librime 状态
scripts/build/librime.sh        # 按 vendor/librime.lock 构建 vendor-out/librime（首次约 5 分钟，之后幂等跳过）
scripts/dev/test.sh             # 运行全部 Swift Testing 测试（含真实 librime 集成测试）；librime 产物过期时拒跑
swift build && .build/debug/noema-cli check-rime   # 打印 librime 版本与模块注册状态
```

## 贡献与治理

- [AGENTS.md](AGENTS.md)：所有贡献者与 AI 代理必须遵守的常驻规则。
- [.agents/notes/README.md](.agents/notes/README.md)：决策笔记（Agent Notes）的格式、目录与检索方法。
