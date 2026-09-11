## [2026-09-12 01:50] | Task: 实现 targeted AX lookup 与 no-snapshot 动作

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `claude-opus-4-8`
* **Runtime**: `Claude Code CLI`

### 📥 User Query
> 按 `docs/product-specs/targeted-ax-speculative-execution.md` 实现两项能力：
> (1) 定向 AX 查找，直接把匹配控件返回给 JavaScript；(2) 动作执行不再在每步前后
> 自动抓全量快照/截图。目标是让流式 JS 程序在首个动作后连续执行多步预测，而不必
> 每步都回模型或抓全树。

### 🛠 Changes Overview
**Scope:** `packages/OpenComputerUseKit`

**Key Actions:**
- **Targeted lookup**: 新增 `TargetedAX` + `SnapshotBuilder` 扩展。`resolveTargetWindow`
  只读解析当前目标窗口（不激活、不抬升、不截图）；`targetedSearch` 先用应用原生
  `AXUIElementsForSearchPredicate`，不支持时退回**有界**子树遍历（上限 5000 节点，
  非全量快照），返回带实时 `AXUIElement` 引用与窗口内相对 frame 的紧凑记录。
- **No-snapshot actions**: `ComputerUseService` 增加 ref 表与 `activeTargetedSnapshot`
  模式。动作方法结尾统一走新的 `actionResult(...)`——targeted 模式下直接返回 `ok`，
  完全跳过 `refreshSnapshot`；`currentSnapshot` 在该模式下返回不含树/截图的 lite
  snapshot，从而**复用**既有 click/type/scroll/setValue/secondary 内部逻辑与后台
  输入（sky_click/sky_key）、虚拟显示定向，无需重写。
- **API 暴露**: 新增调度工具 `query` 与统一的 `act`（op=click/set_value/scroll/
  secondary/type/press_key）；JS `cua` 增加 `cua.query(app, criteria)` 与 `cua.fast.*`。
  refs 稳定、与快照数字索引解耦，跨调用有效直到再次 query。
- **Docs/Tests**: 更新 spec 状态、`js-code-tool.md`、`js` 工具说明与 discrete 定义；
  新增 `TargetedAXTests`（纯匹配逻辑）与 JS 接线测试（query/fast.click/fast.type）。

### 🧠 Design Intent (Why)
规范要求“查找不等于每步验证”“动作派发不得因快照缓存为空而隐式抓全树/截图”。
选择新增独立路径而非改默认路径：既满足既有调用者兼容，又能在 JS 层下方直接验证
“零自动快照/截图”。lite snapshot 让新路径复用全部经过调优的动作内部实现，是最小且
低风险的接缝；有界遍历作为原生搜索不支持时的显式退路，绝不退化为隐藏的全量快照。

### 🚀 Follow-up (perf + integration, same session)
- **Native search unsupported on this macOS**: `AXUIElementsForSearchPredicate` returns
  `parameterizedAttributeUnsupported` on every app tried, so the bounded traversal is
  the real path. Made it fast: interleave matching with the walk and stop at `limit`;
  read role/title/description/value/identifier/position/size in one
  `AXUIElementCopyMultipleAttributeValues` call per node; prune off-screen subtrees by
  geometry against the root window's own AX frame (this macOS leaves AXVisibleChildren
  empty). Result: query dropped from 100–966ms to 15–56ms across Calculator/Finder/
  Safari/System Settings/Notes/TextEdit, verified live; `9×8=72` driven end-to-end.
- **Cursor latency**: the software-cursor overlay animates synchronously on the calling
  thread. Added `SoftwareCursorOverlay.motionDurationScale` (default 0.3 ≈ 3x faster,
  `OPEN_COMPUTER_USE_CURSOR_DURATION_SCALE`) applied to the move glide and click pulse;
  click latency ~320ms → ~210ms, still synchronous and visible.
- **Integration**: reconciled `TargetedAX.WindowContext.windowElement` to optional for a
  concurrent agent's window-preparation work; `targetedSearch` guards it.

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AccessibilitySnapshot.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseToolDispatcher.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/JavaScriptToolRuntime.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ToolDefinitions.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/TargetedAXTests.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/JavaScriptToolRuntimeTests.swift`
- `docs/product-specs/targeted-ax-speculative-execution.md`
- `docs/references/js-code-tool.md`
