# Agent Note: CoreText candidate panel on NSGlassEffectView with caret fault tolerance, not SwiftUI or per-keystroke resizing

Status: implemented

## Problem

M1 需要一个真正可用的候选窗（Issue #6）：每次按键都要在 2 ms 预算内刷新、不闪烁、不抢焦点，跟随亮暗色外观，并能在 Chrome、VS Code、Spotlight 等客户端里放在光标旁。IMKit 客户端报告的光标矩形并不可靠：Chrome/Electron 常返回 `.zero`，竖直光标宽度为 0，右到左文本给出负宽度，副屏坐标为负；同一应用的多个窗口光标互不相关。输入法进程必须保持零 TCC（AGENTS.md 规则 1），不能用 AX 读光标位置。

## Decision

- **模块**：新 `NoemaUI` 库（依赖 `NoemaCore`、`NoemaIMEShell`）实现 `CandidatePresenting`，受 `check-imports.sh` 同样的零 TCC 扫描；只用 `AppKit`、`CoreText`、`QuartzCore`、`CoreGraphics`，不用 `ApplicationServices`。
- **布局与绘制**：`CandidateLayoutEngine` 用 CoreText（`CTFontCreateUIFontForLanguage(.system, …, "zh-Hans")`，系统级联覆盖 Apple Color Emoji 与拉丁文）测量标签、候选、注释与浮动预编辑（`CTLineGetOffsetForStringIndex` 定位光标），产出纯值 `CandidatePanelLayout`（`Sendable`、`Hashable`，不含 `CTLine`/`CTFont`/`CGColor`），可无头测试。单行折叠时圆角为高度一半（胶囊）；展开为每行一个候选的列表，或有浮动预编辑时，圆角固定 14 pt。过宽时先丢注释，再按水位线截断候选并加"…"，截断按字素簇进行，不拆 ZWJ 表情。截断后重新测量整行：标签、内边距、间距与"…"本身不会缩小，`menu/page_size: 20` 这类大页即使全部截成"…"仍超出 `maxPanelWidth`，此时该页自动按展开列表布局（用未截断的测量值），并隐藏无法收起的展开按钮（Codex 审查 PR #19）。展开列表高于 `maxHeight`（控制器取目标屏 `visibleFrame` 高度减两倍 `screenMargin`，屏太矮时取整个可见高度）时，面板高度夹在 `maxHeight` 内，候选在 `candidatesViewport` 里按 `verticalScrollOffset` 纵向滚动；默认 `ensureHighlightVisible` 以最小滚动让高亮候选整行可见，方向键高亮不会离开视口；视口外的候选不可点击，CoreText 文本与高亮图层（`CALayer` 遮罩）都裁剪到视口，尾缘画 3 pt 滚动条（Codex 审查 PR #19：`page_size: 50` 时面板高 1506 pt，0 至 20 号候选落在 875 pt 可见区之上）。浮动预编辑超出面板宽度时在 `PreeditStripLayout.clipRect` 内水平滚动（`scrollOffset`）：光标在尾部留白之前不滚动，之后只滚到光标贴住留白、最多滚到文本末尾，因此光标条始终在 `clipRect` 内；文本与光标裁剪到 `clipRect` 绘制，不越出面板边缘。
- **视图**：`CandidatePanelView` 与其子视图全部 `isFlipped`，布局、高亮 `CAShapeLayer`、CoreText 绘制与点击命中共用自上而下坐标；每次 `CTLineDraw` 前围绕基线反转文本矩阵。蓝色胶囊高亮在文本视图下方的独立宿主视图里（图层自身的 sublayer 会盖住其 `draw(_:)` 内容），关闭隐式动画更新。点击按代次绑定：`mouseDown` 记下命中目标与当时布局的 `generationID`，`apply(_:)` 换到别的代次即取消这次按下，`mouseUp` 只在同一代次、同一目标上触发，并回报按下时的代次，所以在旧面板上按下、刷新后松开不会提交新候选。动态颜色只在 `effectiveAppearance.performAsCurrentDrawingAppearance` 内解析，`draw(_:)` 与 `viewDidChangeEffectiveAppearance()` 都会解析。滚轮在可滚动列表里先在页内滚动，到顶或到底后再累计触发 Rime 翻页；换页、展开/收起与 `hide()` 把滚动归零，同页只变高亮时保留。
- **零闪烁**：`WidthHysteresis` 把宽度向上量化到 32 pt 档位，同一组合与同一模式内只增不减，`hide()` 与模式切换时重置；展开按钮钉在量化宽度的尾部。控制器复用一个 `NSPanel`，只在隐藏 → 可见时 `orderFrontRegardless()`，frame 变化时才 `setFrame`，且先改 panel frame 再 `apply` 布局，子视图在 `layout()` 里取 `bounds`；图层修改都在关闭动作的 `CATransaction` 里，`animationBehavior = .none`。
- **窗口**：`NonActivatingCandidatePanel` 的 `canBecomeKey`/`canBecomeMain` 为 false，`.nonactivatingPanel`；层级为客户端窗口层级 + 1，至少 `.popUpMenu`，至多屏保层级，因此浮在 Spotlight/Raycast 之上。背景默认 `NSGlassEffectView`（无窗口阴影），`.visualEffect` 模式用 `NSVisualEffectView`（`.hudWindow`，有阴影）。
- **光标容错**：`CaretPositionResolver` 拒绝 `nil`、非有限值与恰为 `.zero` 的矩形，先 `standardized`，用至少 1×1 并外扩 2 pt 的探针判断是否在某块屏上，高度为 0 时补 `fallbackLineHeight`。有效矩形按 `uniqueClientIdentifier`（缺省时用会话令牌）缓存，最多 32 个、LRU 淘汰；当前矩形无效时用同一客户端的缓存，两者都没有才用 `NSEvent.mouseLocation`。默认放在光标下方，越过可见区底部时翻到上方，再夹到可见区内；水平夹取保证窄屏上 `lo <= hi`。查询锚定在标记文本下标 0，光标在预编辑内移动时窗口不动。`attributes(forCharacterIndex:lineHeightRectangle:)` 取标记文本内的相对下标；它返回 `.zero` 时，`DocumentCaretRange` 把相对下标换成文档下标（基于 `markedRange()`，无标记文本时用 `selectedRange()`）再调 `firstRect(forCharacterRange:actualRange:)`，两者都没有有效位置时返回 nil，不猜下标 0（文档第一行）。
- **会话协调**：`InputSessionCoordinator` 接受 `inlinePreeditDisabledBundleIDs`（`NoemaIME` 从 IME 包的 `InlinePreeditDisabledBundleIDs` 默认值读取）：这些客户端不收标记文本，由面板绘制预编辑。安全输入在同一会话下也会清掉没有标记文本的组合。面板点击经 `selectCandidate(at:expectedGenerationID:)`、滚动经 `changePage(backward:expectedGenerationID:)` 进入与按键相同的 `applyResult`，代次不符（面板已过期）或安全输入时什么都不做。`EngineHost` 只在 IMKit 首次使用协调器时创建面板，`--version`、`--check-rime` 与提前的 `shutdown()` 不会创建窗口。

## Alternatives considered

- **SwiftUI `NSHostingView` 候选窗。** Rejected：每次按键要经过 SwiftUI 的 diff、布局与隐式动画，难以控制在 2 ms 内，也难以保证不闪；文本测量不可在无窗口的测试里复现。CoreText 加 `CAShapeLayer` 让测量成为可单测的纯函数，绘制路径完全可控。
- **纯色或手绘半透明图层作为背景。** Rejected：与 macOS 26 的 Liquid Glass 系统外观不一致，亮暗色与壁纸取色都要自己模拟。`NSGlassEffectView` 是系统材质；`NSVisualEffectView` 保留为同一布局的后备。
- **每次按键按内容精确调整窗口宽度。** Rejected：连续输入 `nihaoshijie` 时宽度逐键抖动，按钮跟着跳；量化档位加单调增长让大多数按键不改 frame，`setFrame` 次数显著减少。
- **自下而上的坐标（不翻转视图），手工换算 y。** Rejected：布局、命中测试与图层路径要各自做 `height - y` 换算，容易错位一像素且难测；翻转视图只需在 `CTLineDraw` 周围局部反转文本矩阵，彩色表情也能正确绘制。
- **按 `bundleIdentifier` 缓存光标位置。** Rejected：Chrome、VS Code 的多个窗口共享一个 bundle ID，一个窗口的光标会把另一个窗口的候选窗放错位置。`uniqueClientIdentifier` 区分窗口与文档。
- **用 `screen.frame.intersects(caretRect)` 判断光标是否在屏上。** Rejected：CoreGraphics 把宽度为 0 的矩形视为空，合法的竖直光标会被判无效，候选窗退回鼠标位置；1×1 探针加 2 pt 容差在屏幕边缘也成立。
- **用 AX（`AXUIElement`）读取光标位置。** Rejected：需要辅助功能授权，违反零 TCC（规则 1），`check-imports.sh` 也会拒绝。
- **`firstRect` 回退直接用相对下标。** Rejected：`firstRect(forCharacterRange:)` 取文档下标，相对下标 0 指向文档第一行，长文档中候选窗会放到错误的行（Codex 审查 PR #19）。
- **超高列表只夹取面板原点、保留自然高度。** Rejected：`page_size: 50` 时 1506 pt 的面板超出 875 pt 可见区，默认高亮的 0 号候选在屏外，滚轮只会翻页，无法看到或点击 0 至 20 号候选（Codex 审查 PR #19）。
- **大页单行截断后不再复核宽度。** Rejected：`page_size: 20` 时 `contentWidth` 为 923 pt，而迟滞宽度夹在 720 pt，末个胶囊越过展开按钮与面板右缘，无法看到也无法点击（Codex 审查 PR #19）。
- **浮动预编辑过宽时截断或换行。** Rejected：截断会把光标所在部分藏起来，换行让面板高度逐键变化；在裁剪区内水平滚动保持高度不变且光标始终可见。
- **子视图用 `autoresizingMask` 跟随面板，并在 `apply` 里按 `panelSize` 直接设 frame。** Rejected：先设子视图 frame 再 `setFrame` 时，AppKit 把尺寸差再叠加一次，展开/收起后子视图变成 `(0, 276)`、`(352, 0)`（Codex 审查 PR #19）。
- **把高亮画在 `draw(_:)` 里。** Rejected：高亮随选择移动时整块重绘；独立 `CAShapeLayer` 只改路径，并可关闭隐式动画，避免从原点滑入的闪烁。

## Consequences

- `NoemaUITests` 用真实 CoreText 字体无头测试布局、迟滞与光标放置；`CRimeTests` 用真实 `RimeEngine` 测试面板点击、翻页、浮动预编辑、同会话安全输入，以及两种背景模式下展开/收起后各子视图与面板同尺寸。窗口、外观切换与各客户端的光标行为只能在真机上验证，见 [smoke checklist](../../../../docs/runbooks/smoke-checklist.md)。
- IMKit 只在有标记文本时因点击外部而调用 `commitComposition`；关闭内联预编辑的客户端里，点击外部可能保留组合，直到下一次按键或焦点变化。
- `NSGlassEffectView` 要求 macOS 26，与平台下限一致；`.visualEffect` 只在代码中切换，尚无用户设置。
- 展开列表只显示当前页（`page_size`）；超出屏高时页内滚动，翻页靠滚轮滚过页首/页尾或 `-`/`=` 键。
