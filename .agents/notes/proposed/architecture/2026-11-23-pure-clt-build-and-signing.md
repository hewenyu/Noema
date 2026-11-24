# Agent Note: Pure CommandLineTools build with explicit SHA-1 signing, not Xcode.app or ad-hoc signing

Status: proposed

## Problem

开发与 CI 机器只安装了 CommandLineTools（Swift 6.3.3、macOS 26 SDK），没有 `Xcode.app`。因此 `xcodebuild`、`XCTest`、Interface Builder（`.xib`/`.storyboard`）与 Asset Catalog（`.xcassets`）都不可用。输入法与伴生 App 依赖 `librime` 及其插件，若链接 Homebrew 的动态库，产物会携带 `/opt/homebrew` 路径，换一台机器即无法加载，也无法通过公证。TCC 授权与签名身份绑定，若日常开发使用 ad-hoc 签名，每次重新构建都会使 Accessibility、Microphone 等授权失效，严重拖慢调试。

## Proposal

- **目标平台**：macOS 26+，仅 arm64；SwiftPM 清单使用 `swift-tools-version: 6.2`，用 Swift 6.3.3 工具链构建，零 `Xcode.app` 依赖。
- **纯代码 UI**：100% 纯代码 SwiftUI/AppKit，不使用 `.xib`、`.storyboard`、`.xcassets`；应用图标通过 `iconutil` 从 `.iconset` 生成 `.icns`。
- **测试**：使用 Swift Testing（`import Testing`），由 `scripts/dev/test.sh` 以 `--disable-xctest` 加显式 `-F`/`-rpath` 封装 CLT 中 `Testing.framework` 与 `lib_TestingInterop.dylib` 的搜索路径，替代不可用的 `XCTest`。
- **librime 自包含单动态库**：`scripts/build/librime.sh` 按 `vendor/librime.lock` 中的精确 commit 与 Boost SHA256，用 cmake（`Unix Makefiles`、`CMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local`）从源码构建 `librime`、`librime-lua`、`librime-octagram`；Boost 仅用头文件，leveldb、marisa、OpenCC、yaml-cpp、spdlog 与 in-tree Lua 5.4 全部静态合并进唯一的 `librime.1.dylib`，`install_name` 固定为 `@rpath/librime.1.dylib`，运行时只依赖 `/usr/lib` 与 `/System/Library`。脚本末尾的自检门禁校验 `otool -D`、`otool -L` 白名单、无 `LC_RPATH`、仅 arm64；产物与 `.lock-sha256` 一致时幂等跳过。
- **SwiftPM 链接**：`CRime` 以相对路径包含 `vendor-out/librime/include/rime_api.h`，链接 `-lrime`；debug 配置的 rpath 指向 `vendor-out/librime/lib`，release 配置只有 `@executable_path/../Frameworks`，发布产物不含开发机绝对路径。打包时将 `librime.1.dylib` 放入 bundle 的 `Contents/Frameworks/` 并按 SHA-1 重签；构建脚本留下的 ad-hoc 签名仅用于本地加载。
- **签名**：显式按证书 SHA-1 选择签名身份，由内到外（嵌入的 framework/helper → 子进程 `noema-rime-deployer` → App bundle）逐层签名，启用 Hardened Runtime；发布产物使用 `notarytool` 公证并 staple。
- **禁止 ad-hoc 签名用于日常开发**：开发构建同样使用固定的证书 SHA-1，保证 TCC 授权在重建后不漂移。

## Alternatives considered

- **依赖 `Xcode.app` / `xcodebuild` / `xcframework`。** Rejected：本机与 CI Runner 都没有也不打算安装 `Xcode.app`，引入后构建只能在部分机器上复现；数十 GB 的安装与版本漂移成本远高于纯 SwiftPM 方案。
- **直接链接 Homebrew 的动态 `librime`。** Rejected：产物携带 `/opt/homebrew` 绝对路径，在未安装 Homebrew 的机器上无法加载；Homebrew 升级会悄悄改变 ABI；动态库不在 bundle 内也无法通过 Hardened Runtime 与公证校验。
- **把 librime 及依赖合并为单个大静态库 `libnoema_rime.a`，直接静态链接进每个可执行文件。** Rejected：插件模块只通过 `__attribute__((constructor))` 自注册、没有被引用的符号，macOS `ld` 在 `-dead_strip` 下会静默丢弃 `lua`、`octagram` 模块，必须对每个目标加 `-force_load` 才能保住；输入法、伴生 App、`noema-rime-deployer` 各自链接一份会使体积成倍增加，并在同一进程加载多份副本时引发 ODR 冲突与多个 librime 单例。单动态库只链接一次、模块注册由 dylib 加载保证。
- **本地开发使用 `codesign -s -` ad-hoc 签名。** Rejected：ad-hoc 签名的代码身份随每次构建变化，导致 TCC 授权反复失效、需要手动重新授权；与发布签名路径不一致，掩盖签名顺序与 entitlements 问题。

## Acceptance criteria

- 在仅安装 CommandLineTools 的机器上，`swift build` 与 Swift Testing 测试全部通过。
- 仓库中不存在 `.xcassets`、`.xib`、`.storyboard`、`.xcodeproj`，构建脚本不调用 `xcodebuild`，测试不 `import XCTest`（负控：引入任一项时检查失败）。
- 对打包产物中每个 Mach-O 运行 `otool -L`，输出中不出现 `/opt/homebrew`。
- `scripts/build/librime.sh` 的自检门禁要求 `otool -D` 精确为 `@rpath/librime.1.dylib`、`otool -L` 仅含白名单路径；`CRimeTests` 在真实 librime 中确认 `lua`、`octagram`、`grammar` 模块已注册，并用内联 schema 经 Lua 与表翻译器真实上屏（负控：注入 `/opt/homebrew` 依赖或篡改 `BOOST_SHA256` 时脚本失败，`vendor-out/librime` 缺失时 `test.sh` 立即失败）。
- release 构建的可执行文件 `LC_RPATH` 不含 `/Users/` 等开发机绝对路径。
- `codesign --verify --deep --strict` 通过，`codesign -d` 显示 Hardened Runtime 标志与预期证书；发布产物 `spctl --assess` 通过。

## Risks

- 无 Xcode 意味着没有 Instruments、Interface Builder 等工具，性能分析与 UI 调试成本更高。
- 自行用 cmake 构建 `librime` 及其依赖（boost、leveldb、marisa、opencc、yaml-cpp、lua 等）的维护成本较高，上游升级需要手动跟进；CMake 4.x 已移除 `FindBoost`，当前依赖 `CMAKE_POLICY_VERSION_MINIMUM=3.5` 回退到旧策略。
- in-tree Lua 的默认 `package.path` 仍内含 `/usr/local/share/lua/5.4` 等字符串（不是加载命令，`otool -L` 看不到）；librime-lua 会把 `user_data_dir/lua` 与 `shared_data_dir/lua` 前置，但 Lua 脚本 `require` 不存在的模块时仍可能探测这些路径。
- Swift Testing 的 `-F`/`-rpath` 封装依赖 CLT 内部目录结构，CLT 升级可能需要调整。
- 证书过期或轮换会导致 TCC 授权一次性失效。
