# Agent Note: Pure CommandLineTools build with explicit SHA-1 signing, not Xcode.app or ad-hoc signing

Status: implemented

## Problem

开发与 CI 机器只安装了 CommandLineTools（Swift 6.3.3、macOS 26 SDK），没有 `Xcode.app`。因此 `xcodebuild`、`XCTest`、Interface Builder（`.xib`/`.storyboard`）与 Asset Catalog（`.xcassets`）都不可用。输入法与伴生 App 依赖 `librime` 及其插件，若链接 Homebrew 的动态库，产物会携带 `/opt/homebrew` 路径，换一台机器即无法加载，也无法通过公证。TCC 授权与签名身份绑定，若日常开发使用 ad-hoc 签名，每次重新构建都会使 Accessibility、Microphone 等授权失效，严重拖慢调试。

## Decision

- **目标平台**：macOS 26+，仅 arm64；SwiftPM 清单使用 `swift-tools-version: 6.2`，用 Swift 6.3.3 工具链构建，零 `Xcode.app` 依赖。
- **纯代码 UI 与资源**：不使用 `.xib`、`.storyboard`、`.xcassets`。`Resources/IME/generate-icons.swift` 只用 CoreGraphics、ImageIO、UniformTypeIdentifiers 在构建时绘制 `NoemaIME.iconset`（10 个标准尺寸）与 18×18pt 模板图 `menu-icon.pdf`，`/usr/bin/iconutil -c icns` 生成 `NoemaIME.icns`，仓库不入库任何图片二进制。
- **测试**：使用 Swift Testing（`import Testing`），由 `scripts/dev/test.sh` 以 `--disable-xctest` 加显式 `-F`/`-rpath` 封装 CLT 中 `Testing.framework` 与 `lib_TestingInterop.dylib` 的搜索路径；运行前要求 `vendor-out/librime/.lock-sha256` 等于当前 `vendor/librime.lock` 的 SHA256 并通过 `librime.sh --verify`，拒绝用过期产物跑绿测试。
- **librime 自包含单动态库**：`scripts/build/librime.sh` 按 `vendor/librime.lock` 中的精确 commit 与 Boost SHA256，用 cmake（`Unix Makefiles`、`CMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local`）从源码构建 `librime`、`librime-lua`、`librime-octagram`；Boost 仅用头文件，leveldb、marisa、OpenCC、yaml-cpp、spdlog 与 in-tree Lua 5.4 全部静态合并进唯一的 `librime.1.dylib`，`install_name` 固定为 `@rpath/librime.1.dylib`，运行时只依赖 `/usr/lib` 与 `/System/Library`。自检门禁校验 `otool -D`、`otool -L` 白名单（含 `..` 的路径与无结尾换行的末行同样受检）、无 `LC_RPATH`、仅 arm64；产物与 `.lock-sha256` 一致时幂等跳过。Boost 下载先在 `.part` 上校验 SHA256 再进入缓存；`--out` 拒绝 `/`、`..` 与非本脚本产物的非空目录；发布先把旧产物移到 `.old` 再换入 staging，失败或收到信号时回滚。
- **SwiftPM 链接**：`CRime` 链接 `-lrime`；debug 配置的 rpath 指向 `vendor-out/librime/lib`，release 配置只有 `@executable_path/../Frameworks`。`bundle.sh` 以 `--disable-local-rpath` 构建 release，去掉 SwiftPM 默认的 `@loader_path`。Noema 一律经 `noema_rime_get_api()`（`pthread_once` 包装）取 API 表，避开上游 `rime_get_api()` 冷启动的数据竞争。
- **打包**：`scripts/build/bundle.sh` 构建 `NoemaIME` 可执行目标（只链接 `NoemaCore`、`NoemaEngine`，提供 `--version` 与 `--check-rime`），在临时 staging 中组装 `NoemaIME.app`：`MacOS/NoemaIME`、`Frameworks/librime.1.dylib`、`Resources/{NoemaIME.icns,menu-icon.pdf,opencc/,rime-default/}`，`Info.plist` 由 `Resources/IME/Info.plist.in` 注入版本号并拒绝残留占位符；先 `xattr -cr`，签名后原子发布到 `<out>/NoemaIME.app`：发布临界区持有 `${TMPDIR:-/tmp}/noema-bundle-publish-<真实 out 路径 SHA256>.lock` 上的 `flock` 排他锁（进程死亡时内核自动释放，`<out>` 内不留锁文件），持锁后重新校验 `<out>` 与目标，把旧包移到 `.NoemaIME.app.old.<pid>`，再用 `os.rename` 换入 staging（`rename(2)` 遇到已存在目录直接失败，不会像 `mv` 那样嵌套出 `NoemaIME.app/NoemaIME.app`），失败时回滚，信号中断由 `trap` 回滚。`NoemaIME --version` 读 `Bundle.main` 的 `CFBundleShortVersionString`，未打包运行时回退到 `NoemaVersion.current`。
- **签名**：`bundle.sh --sign` 必填，只接受 40 位十六进制证书 SHA-1 或 `-`，拒绝证书名称（同名证书会使 `codesign -s <name>` 产生歧义）。由内到外逐层签名、从不使用 `--deep`：`librime.1.dylib` → `MacOS/NoemaIME`（带 `Resources/IME/NoemaIME.entitlements`，空字典，零 TCC 与零网络权限）→ `NoemaIME.app`（同一 entitlements）。证书签名加 `--options runtime --timestamp`。
- **ad-hoc 仅限 CI 校验**：Kiln `ci/bundle` 用 `--sign -` 只为验证组装与加载，不加 `--options runtime` 与 `--timestamp`：ad-hoc 签名没有 Team ID，Hardened Runtime 的库验证会让 dyld 拒载 `Frameworks/librime.1.dylib`（进程 `SIGABRT`，退出码 134）。日常开发与发布构建使用固定证书 SHA-1，CI 从不接触签名证书。
- **产物校验**：`scripts/build/verify-bundle.sh [--require-signed] [bundle]` 校验文件布局、全部 IMKit `Info.plist` 键与其引用的资源、零 `NS*UsageDescription` 与 `NSMainNibFile`、两个 Mach-O 仅 arm64 且通过 `librime.sh --check-linkage-stdin` 白名单、dylib 的 `@rpath` 安装名与零 `LC_RPATH`、可执行文件 rpath 恰为 `@executable_path/../Frameworks`、全包无 `/opt/homebrew` 字符串、逐层 `codesign --verify --strict`、可执行文件显式链接 `@rpath/librime.1.dylib`、bundle 与可执行文件实际签入的 entitlements 为空（`codesign -d --entitlements - --xml`）、`Info.plist` 引用的资源不得为绝对路径或经 `..` 逃出 `Contents/Resources`；`--require-signed` 另要求非 ad-hoc、Hardened Runtime、Authority 与 Team ID。最后真实执行 `Contents/MacOS/NoemaIME --version`（输出必须恰为 `NoemaIME <CFBundleShortVersionString>`）与 `--check-rime`，证明 dyld 从 bundle 解析 librime 且 7 个必选模块全部注册。

## Alternatives considered

- **依赖 `Xcode.app` / `xcodebuild` / `xcframework`。** Rejected：本机与 CI Runner 都没有也不打算安装 `Xcode.app`，引入后构建只能在部分机器上复现；数十 GB 的安装与版本漂移成本远高于纯 SwiftPM 方案。
- **直接链接 Homebrew 的动态 `librime`。** Rejected：产物携带 `/opt/homebrew` 绝对路径，在未安装 Homebrew 的机器上无法加载；Homebrew 升级会悄悄改变 ABI；动态库不在 bundle 内也无法通过 Hardened Runtime 与公证校验。
- **把 librime 及依赖合并为单个大静态库 `libnoema_rime.a`，直接静态链接进每个可执行文件。** Rejected：插件模块只通过 `__attribute__((constructor))` 自注册、没有被引用的符号，macOS `ld` 在 `-dead_strip` 下会静默丢弃 `lua`、`octagram` 模块，必须对每个目标加 `-force_load` 才能保住；输入法、伴生 App、`noema-rime-deployer` 各自链接一份会使体积成倍增加，并在同一进程加载多份副本时引发 ODR 冲突与多个 librime 单例。单动态库只链接一次、模块注册由 dylib 加载保证。
- **本地开发使用 `codesign -s -` ad-hoc 签名。** Rejected：ad-hoc 签名的代码身份随每次构建变化，导致 TCC 授权反复失效、需要手动重新授权；与发布签名路径不一致，掩盖签名顺序与 entitlements 问题。CI 的 ad-hoc 构建只做组装与加载校验，从不安装或授权。
- **ad-hoc 签名也加 `--options runtime`，让 CI 与发布签名参数一致。** Rejected：没有 Team ID 时库验证拒载嵌入的 `librime.1.dylib`，`--check-rime` 探针以 `SIGABRT` 失败；`verify-bundle.sh` 把 ad-hoc 加 runtime 标志视为错误。
- **用 `codesign --deep` 一次签整个 bundle。** Rejected：`--deep` 用同一组选项与 entitlements 签所有嵌套代码，掩盖签名顺序问题，Apple 也不推荐用于签名；`--deep` 只用于 `verify-bundle.sh` 的校验。
- **以证书名称（CN）选择签名身份，或给 `--sign` 一个默认值。** Rejected：钥匙串中重复或同名证书会让名称产生歧义；静默默认会让无意的 ad-hoc 构建混入发布路径。
- **在 `--out` 内用 `mkdir` 锁目录或锁文件串行化发布，再用 `mv` 换入。** Rejected：`mkdir` 锁在进程被 `SIGKILL` 后成为陈旧锁，锁文件会污染 `--out` 并干扰非空目录校验；`mv` 遇到已存在目录会静默把新包移入其中，嵌套出 `NoemaIME.app/NoemaIME.app` 并破坏外层签名。
- **入库 PNG/`.icns` 图标或使用 `.xcassets`。** Rejected：`.xcassets` 需要 `actool`（随 Xcode 提供）；二进制图片无法审阅差异，代码生成的图标可复现且零二进制。

## Consequences

- 仅安装 CommandLineTools 的机器即可构建、测试、打包并验证 `NoemaIME.app`；`scripts/governance/check-imports.sh` 机械拒绝 `.xcassets`、`.xib`、`.storyboard`、`.xcodeproj`、`.xcworkspace`、`import XCTest` 与 `xcodebuild` 调用（扫描 `Sources`、`Tests`、`Resources`、`scripts`、`.kiln` 与 `Package.swift`，跳过 Markdown 散文）；匹配前先做词法级剥注释（Swift 块注释可嵌套、字符串字面量保留），因此 Swift 6 访问级别 `import`、`@_spi` 等属性、`;` 拼接、跨行与反引号模块名都无法绕过（负控：引入任一项时检查失败，`import Carbon.HIToolbox` 仍放行）。
- `librime.sh` 门禁的负控：注入 `/opt/homebrew` 依赖或篡改 `BOOST_SHA256` 时脚本失败；`vendor-out/librime` 缺失或 `.lock-sha256` 与锁文件不符时 `test.sh` 与 `bundle.sh` 立即失败；末行无换行的 `/opt/homebrew` 依赖、`/usr/lib/../local/...` 路径穿越、`--out /` 均使脚本 exit 1。
- `bundle.sh` 的负控：`--sign` 传证书名称时 exit 1；`--version` 接受 SemVer 预发布与构建元数据（如 `1.2.3-rc.1+meta`）。4 个并发 `bundle.sh` 发布到同一 `--out` 时依次完成，不产生嵌套 `NoemaIME.app/NoemaIME.app`，`--out` 中除 `NoemaIME.app` 外无残留。`verify-bundle.sh` 的负控：ad-hoc 产物加 `--require-signed`、移除 `CFBundleIdentifier` 中的 `.inputmethod.`、注入 `NSMicrophoneUsageDescription`、签入 `com.apple.security.network.client`、`tsInputMethodIconFileKey` 指向 `../Info.plist`、篡改 `CFBundleShortVersionString` 后重签（`--version` 输出不符）均 exit 1；空字符串 bundle 路径 exit 2。
- CI 的 ad-hoc 包不可分发也不可安装为日常输入法；可分发产物只来自本地以证书 SHA-1 签名的构建，公证（`notarytool`）与 `spctl --assess` 属于发布流程。
- 无 Xcode 意味着没有 Instruments、Interface Builder 等工具，性能分析与 UI 调试成本更高。
- 自行用 cmake 构建 `librime` 及其依赖的维护成本较高，上游升级需要手动跟进；CMake 4.x 已移除 `FindBoost`，依赖 `CMAKE_POLICY_VERSION_MINIMUM=3.5` 回退到旧策略。
- in-tree Lua 的默认 `package.path` 仍内含 `/usr/local/share/lua/5.4` 等字符串（不是加载命令，`otool -L` 看不到）；librime-lua 会把 `user_data_dir/lua` 与 `shared_data_dir/lua` 前置，但 Lua 脚本 `require` 不存在的模块时仍可能探测这些路径。
- Swift Testing 的 `-F`/`-rpath` 封装依赖 CLT 内部目录结构，CLT 升级可能需要调整。
- 证书过期或轮换会导致 TCC 授权一次性失效。
