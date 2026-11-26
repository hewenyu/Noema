# Agent Note: Shell-owned v-mode with a pure reducer and OpenCC emoji candidates, not a Rime Lua v-mode or an emoji translator

Status: implemented

## Problem

M2（Issue #9）要求微信输入法同款的 `v` 模式：空闲时敲 `v` 弹出 3×3 快捷菜单（计算、剪贴板、常用语、语音输入、符号、翻译、改写、日期时间、设置），`v1+2` 直接算式上屏，`v` 加字母仍能原样输入英文，`lv`、`nv` 仍是 绿、女；同时在匹配的词后给出 Emoji 候选。约束：IME 保持薄壳与零 TCC（AGENTS.md 规则 1），剪贴板、语音、翻译、改写属于伴生 Agent（M3/M4），安全输入下一个按键、一个 IPC 帧都不能泄露；万象与雾凇自带 `recognizer/patterns/v`（`^v.*$` 一类），会在 Rime 内部抢走 `v` 开头的输入；Emoji 不能进入学习库，也不能改变首选。

## Decision

- **状态机**：`NoemaCore.VModeReducer` 是纯函数 `reduce(state, input, context) -> (state, effect)`，无计时器、无 I/O、无 AppKit。状态 `idle | composing | vMenu | vSub`，效果 `passToRime | passThroughToClient | consumeOnly | commitText | dispatchAgent`。安全输入、Safe Mode、ASCII 模式一律回到 `idle` 并直通；Rime 已在组字时 `v` 交给 Rime（`lv` 出 绿）；只有无修饰（Fn 除外）的小写 `v` 开菜单，Shift、Caps Lock 与快捷键组合不开。菜单里 `1` 先挂起（`v1` 后接运算符即 `1+…`，接数字或 `(` 则重新开始，`v13+4` 得 7），`0`、`(`、`=` 直接进计算器，`3/5/8` 进常用语、符号、日期时间子模式，`2/4/6/7/9` 派发 Agent 动作，`vv` 上屏 `v`，其他可打印 ASCII 进入原样输入（`vim` 回车上屏 `vim`）。菜单是两列网格：左右逐格、上下跨行，最后一行单格时从倒数第二行向下落到它。Esc 与菜单里的退格只清除，不上屏；子模式的退格清空后回到菜单。
- **离线工具**：`NoemaText` 提供 `CalculatorEvaluator`（UTF-8 递归下降，`Decimal` 运算，`+ - * / % ^`、括号、一元负号、全角与 `× ÷ −` 归一化，长度 128、深度 32、指数 1000 上限，非整数指数才退回 `Double`；结果保留 10 位小数，≥ 1e21 用 `%.10g`），`DateTimeTemplates`（时钟与时区由壳注入，公历分量，不随用户区域变化），`SymbolPalette`（5 类内置符号，字母过滤），`SnippetStore`（`~/Library/Application Support/Noema/snippets.json`，版本 1；读取 `O_NOFOLLOW|O_NONBLOCK`、仅常规文件、1 MiB 上限，任何问题回退 12 条默认常用语；保存拒绝符号链接，0600 `O_EXCL|O_NOFOLLOW` 临时文件、fsync、rename、目录 fsync）。`check-imports.sh` 禁用 `NSExpression`。
- **壳**：`InputSessionCoordinator` 在 Rime 未组字时先问 reducer，按效果设置整段选中的标记文本（禁用内联预编辑的客户端只在面板显示）、隐藏候选面板、递增 `vModeGenerationID` 后调用 `VModePresenting.updateVMode`。失焦、控制器关闭、`commitComposition`（点击外部）、`hidePalettes`、切到 ASCII、安全输入都清掉 `v` 并隐藏面板。面板点击走 `selectVModeItem(at:expectedGenerationID:)`，代数不符即忽略。`dispatchAgent` 只回调 `onQuickAction`，`EngineHost` 交给 `CompositionIPCReporter.requestQuickAction`；安全输入下 reporter、`sendFireAndForget`、`send` 三道闸都不发。
- **面板**：`CandidatePanelController` 同时实现 `CandidatePresenting` 与 `VModePresenting`，同一个非激活 `NSPanel`、同一套光标定位与背板，`PanelContentHost` 只显示其一，两者永不重叠。`VModeLayoutEngine` 用候选窗的 CoreText 字体排出两列等宽胶囊网格或“标题 + 页码 + 提示 + 分隔线 + 行”列表，过宽截断、过高在视口内滚动；`VModePanelView` 的点击绑定布局代数。
- **Agent**：IPC 追加 `ime.quickActionRequested(sessionEpoch, action)`（不合并，按连接 epoch 校验）与 `AgentSettingsSnapshot.emojiCandidatesEnabled`（缺省解码为 true）。`.settings` 打开设置窗口，`.clipboard` 打开剪贴板历史面板（[剪贴板笔记](../architecture/2026-11-26-clipboard-history-and-panel.md)）；其他动作在 M3/M4 前显示不可成为 key/main、忽略鼠标、2 秒消失的 HUD“语音输入将在 M3 推出”。设置 › 快速操作列出 `v1`…`v9` 与 Emoji 开关，存入 UserDefaults 并推送给 IME。
- **Emoji**：内置方案用 librime 自带的 `simplifier@emoji_suggestion` 读 OpenCC 文本词典 `opencc/noema_emoji.{json,txt}`（283 个词，原创映射），开关 `emoji_suggestion` 默认开、`tips: none`；librime 的 `ConvertWord` 第一项等于原词时保留原候选，所以 Emoji 永远排在匹配词之后。`RimeEngine.setOption` 记住覆盖值，在每次开会话与切换方案时重放。学习只记含汉字的上屏，Emoji 从不入库。为 Emoji 词新增的 `哈哈`、`咖啡`、`猫咪`、`点赞`、`足球` 同时补了单字 哈、咖、咪、赞、足，否则 `ha` 变成没有单字的完整音节，`niha` 的预编辑会退化成 `niha`。
- **上游 `v` 识别器**：`noema-rime-deployer` 每次部署都暂存补丁，把 `recognizer/patterns/v` 与 `v_mode` 置为空字符串 `""`（不写 YAML null `~`，避免 librime 的 `__include` 将用户自定义 `recognizer/patterns/v` 覆盖回来；librime 忽略空模式，且补丁键按字典序晚于用户对 `recognizer`、`recognizer/patterns` 的键）；用户自己的 `custom.yaml` 照旧经 `__include` 原样包含、从不改写。部署后若编译结果仍有非空的这两个模式则失败。`speller/alphabet` 不动，`lv`、`nv` 照常。`DeployManifest.schemaPatches`（版本 1 追加字段）记录 `noema.recognizer-v-disabled.v1`；`prepareBuild` 与暂存校验都要求清单含全部 `SchemaPatch.requiredPatchIDs`，PR #21 时代的构建会重新部署一次。

## Alternatives considered

- **在 Rime 里用 Lua 处理器 / `recognizer` 实现 v 模式**（雾凇、万象的做法）。Rejected：每个方案集都要各自维护 Lua，三套方案行为不一；Rime 的候选菜单只有一列文本，画不出两列网格与标题；派发 Agent 动作需要 Lua 访问 IPC，违反薄壳；按键语义只能用真实 librime 测，不能像纯 reducer 那样逐边单测。
- **保留上游 `v` 识别器，只在壳里抢先拦截 `v`**。Rejected：壳只在按键经过协调器且 Rime 未组字时拦截；`noema-cli repl`、直接驱动 `RimeEngine` 的测试与任何不经 reducer 的路径仍会进入上游另一套 v 模式，同一输入因入口不同而行为不一；关掉上游模式后，Rime 在任何入口都只把 `v` 当拼写。
- **改 `speller/alphabet` 去掉 `v`**。Rejected：`lv`、`nv`（绿、女）依赖 `v` 拼 ü，删掉会破坏全拼。
- **用 `NSExpression` 计算**。Rejected：它接受函数调用与键路径（`FUNCTION(...)`），对输入法输入是代码执行面；`Double` 精度让 `0.1+0.2` 出 `0.30000000000000004`。
- **独立的 Emoji 翻译器（`table_translator@emoji`）或 Lua 过滤器**。Rejected：翻译器按权重与其他候选混排，可能顶掉首选（违反规则 7 的精神）；Lua 过滤器要求方案启用 Lua。OpenCC 简化器是 librime 内置组件，顺序固定在原词之后，开关即 librime 选项。
- **第二个独立面板显示 v 菜单**。Rejected：两个面板会同时出现或互相遮挡，需要两套光标定位与外观同步；复用同一个 `NSPanel` 保证互斥且零闪烁。
- **Agent 未就绪时在 IME 里弹“即将推出”提示**。Rejected：IME 不应显示自己的窗口，HUD 属于 Agent；Agent 不在时动作静默丢弃，按键路径不等待。

## Consequences

- 验收：`v1+2` 空格上屏 `3`，`v=2+3` 下箭头回车上屏 `2+3=5`，`v8` 选中上屏日期，`vim` 回车上屏 `vim`，`vv` 上屏 `v`，`lv`/`nv` 出 绿/女；`v2`/`v9` 经真实匿名 libxpc 到达 Agent（`lastQuickAction`），Agent 死亡时按键不阻塞；安全输入中途开启时下一键直通、`v` 被清、面板隐藏、零 IPC 帧；陈旧代数的点击被忽略；`nihao` 首选 你好、第二个 👋，关闭开关后无 Emoji 且新会话保持，👋 上屏不写 `learning.sqlite`；带 `v`、`v_mode`、`keepme` 模式的上游方案部署后只剩 `keepme` 与用户补丁的模式，用户文件字节不变；缺 `schemaPatches` 的旧构建重部署一次后复用。
- 测试：`NoemaCoreTests`（reducer 全部边、计算器、日期、符号、常用语文件安全）、`NoemaEngineTests`（补丁文本、清单追加字段）、`NoemaIPCTests`（线格式、epoch、reporter、Toast）、`NoemaUITests`（网格几何、截断、滚动、代数绑定点击）、`CRimeTests.VModeAndEmojiTests`（真实 librime、部署器、面板控制器、IPC）。负控：去掉 v 补丁（部署器自检失败进 Safe Mode；再去掉自检则编译结果断言失败）、去掉 `carriesRequiredSchemaPatches` 检查、去掉协调器或 reporter 的安全输入判断、在 `NoemaText` 写 `NSExpression`、从包里删 `noema_emoji.json`，对应检查均失败。
- Emoji 开关只作用于声明了 `emoji_suggestion` 的方案（内置方案）；万象、雾凇、薄荷自带的 Emoji 开关与词典保持各自行为。
- 风险：上游方案若用别的键名实现 v 模式（不在 `disabledRecognizerKeys` 中）仍会与壳的 v 模式并存，届时追加新的补丁 ID；`requiredPatchIDs` 只能追加，已发布 ID 不改。常用语文件由用户编辑，格式错误时静默回退默认值，没有错误提示（M3 设置页再补）。
