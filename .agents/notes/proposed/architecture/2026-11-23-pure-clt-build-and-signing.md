# Agent Note: Pure CommandLineTools build with explicit SHA-1 signing, not Xcode.app or ad-hoc signing

Status: proposed

## Problem

开发与 CI 机器只安装了 CommandLineTools（Swift 6.3.3、macOS 26 SDK），没有 `Xcode.app`。因此 `xcodebuild`、`XCTest`、Interface Builder（`.xib`/`.storyboard`）与 Asset Catalog（`.xcassets`）都不可用。输入法与伴生 App 依赖 `librime` 及其插件，若链接 Homebrew 的动态库，产物会携带 `/opt/homebrew` 路径，换一台机器即无法加载，也无法通过公证。TCC 授权与签名身份绑定，若日常开发使用 ad-hoc 签名，每次重新构建都会使 Accessibility、Microphone 等授权失效，严重拖慢调试。

## Proposal

- **目标平台**：macOS 26+，仅 arm64；SwiftPM 清单使用 `swift-tools-version: 6.2`，用 Swift 6.3.3 工具链构建，零 `Xcode.app` 依赖。
- **纯代码 UI**：100% 纯代码 SwiftUI/AppKit，不使用 `.xib`、`.storyboard`、`.xcassets`；应用图标通过 `iconutil` 从 `.iconset` 生成 `.icns`。
- **测试**：使用 Swift Testing（`import Testing`），通过显式 `-F`/`-rpath` 封装 CLT 中 Testing.framework 的搜索路径，替代不可用的 `XCTest`。
- **librime 静态合并**：用 cmake 从源码构建 `librime`、`librime-lua`、`librime-octagram` 及其依赖，静态合并进产物，消除对 `/opt/homebrew` 的运行时依赖；打包后用 `otool -L` 校验产物中零 `/opt/homebrew` 路径。
- **签名**：显式按证书 SHA-1 选择签名身份，由内到外（嵌入的 framework/helper → 子进程 `noema-rime-deployer` → App bundle）逐层签名，启用 Hardened Runtime；发布产物使用 `notarytool` 公证并 staple。
- **禁止 ad-hoc 签名用于日常开发**：开发构建同样使用固定的证书 SHA-1，保证 TCC 授权在重建后不漂移。

## Alternatives considered

- **依赖 `Xcode.app` / `xcodebuild` / `xcframework`。** Rejected：本机与 CI Runner 都没有也不打算安装 `Xcode.app`，引入后构建只能在部分机器上复现；数十 GB 的安装与版本漂移成本远高于纯 SwiftPM 方案。
- **直接链接 Homebrew 的动态 `librime`。** Rejected：产物携带 `/opt/homebrew` 绝对路径，在未安装 Homebrew 的机器上无法加载；Homebrew 升级会悄悄改变 ABI；动态库不在 bundle 内也无法通过 Hardened Runtime 与公证校验。
- **本地开发使用 `codesign -s -` ad-hoc 签名。** Rejected：ad-hoc 签名的代码身份随每次构建变化，导致 TCC 授权反复失效、需要手动重新授权；与发布签名路径不一致，掩盖签名顺序与 entitlements 问题。

## Acceptance criteria

- 在仅安装 CommandLineTools 的机器上，`swift build` 与 Swift Testing 测试全部通过。
- 仓库中不存在 `.xcassets`、`.xib`、`.storyboard`、`.xcodeproj`，构建脚本不调用 `xcodebuild`，测试不 `import XCTest`（负控：引入任一项时检查失败）。
- 对打包产物中每个 Mach-O 运行 `otool -L`，输出中不出现 `/opt/homebrew`。
- `codesign --verify --deep --strict` 通过，`codesign -d` 显示 Hardened Runtime 标志与预期证书；发布产物 `spctl --assess` 通过。

## Risks

- 无 Xcode 意味着没有 Instruments、Interface Builder 等工具，性能分析与 UI 调试成本更高。
- 自行用 cmake 构建 `librime` 及其依赖（boost、leveldb、marisa、opencc、yaml-cpp、lua 等）的维护成本较高，上游升级需要手动跟进。
- Swift Testing 的 `-F`/`-rpath` 封装依赖 CLT 内部目录结构，CLT 升级可能需要调整。
- 证书过期或轮换会导致 TCC 授权一次性失效。
