## [2026-09-19 17:07] | Task: 量 click / key 耗时；软件光标不再阻塞工具调用，节奏自适应且落点准确

### 🤖 Execution Context
* **Agent ID**: `Claude Code`
* **Base Model**: `Claude Fable 5.1`
* **Runtime**: `Claude Code CLI / macOS 27.0 arm64`

### 📥 User Query
> Measure average click time and keyboard stroke times
> 假光标动画是不是会阻塞到动画结束？感觉一次 click 要 1.9s 左右。
> scale 能不能自适应：click 越密集越快，像人一样；不要阻塞，排队快速播放；动画要准确，只是节奏变快。
> 光标空闲时原地可爱地动一动，不要静止。（现场播放 5 种方案后选定：lazy sway，幅度再大一点。）

### 🛠 Changes Overview
**Scope:** `SoftwareCursorOverlay`、`ComputerUseService` / `MCPServer` 的光标调用点、基准 live test、基准文档。

**Key Actions:**
- **测量**: `BackgroundInputBenchmarkLiveTests` 的 `BENCH` 行加 `mean`；新增 `CursorAnimationLatencyLiveTests`（`OPEN_COMPUTER_USE_RUN_CURSOR_BENCH=1`），量光标动画耗时、突发节奏、落点误差、排队时调用方的阻塞时间。
- **不再阻塞**: `VisualCursorSupport.performOnMain`（`DispatchQueue.main.sync`）换成 `enqueue`：工具线程只排队不等待，主线程按顺序播放每个动作；动画内部会 pump run loop，重入到达的动作进 `pending` 排队。turn-ended 的 reset 也走同一队列，保证排在动画之后。一次性 CLI 在主线程上没有 run loop 可排空，仍然内联播放。
- **自适应节奏**: `adaptiveCursorTempo`（纯函数）按距上一个动作结束的空闲时间缩放时长：连续动作逐次变快直到下限，空闲 2 s 恢复原速。下限 `OPEN_COMPUTER_USE_CURSOR_BURST_FLOOR`（默认 0.15，设 1 关闭）。
- **落点准确**: 绘制的光标尖端经 visual-dynamics 弹簧跟随路径，弹簧原先走墙上时钟，快速滑动时严重滞后。现在弹簧走与动画同步加速的时钟（`dynamicsTime` / `paceDynamics`），快动画等于完整动画的快放。
- **空闲动画**: 原先 ±0.09 rad 的摆动看起来像静止。改为 "lazy sway"：尖端仍钉在最后一次 click 的位置，指针绕尖端摆动，峰值 0.30 rad（约 17°），叠加一个慢的第二谐波让摆动不完全重复。候选方案（float / tail wag / hop）是带字幕现场播放给用户选的，未选中的原型已删除。

### 🧠 Design Intent (Why)
*光标只是给人看的，不该让工具调用等它。排队而不是丢弃，保证每个动作都按原路径播放；积压自然表现为“间隔为 0”，由自适应节奏追上。加速只改时间轴不改路径，所以需要把弹簧也放到同一条时间轴上，否则越快越不准。*

### ✅ Verification
- 50 轮基准（未 pin，默认参数，macOS 27.0 26A428）：`sky_click` 返回 mean 80.7 ms，`sky_key` `type_text` 返回 mean 27.9 ms，均 50/50，前台不变。
- 改动前光标动画每次 click 同步阻塞：scale 1 为 1602.6 ms，默认 0.15 为 248.9 ms。已安装的 npm 包内 app 二进制构建于 2026-09-09，不含 `CURSOR_DURATION_SCALE`（2026-09-12 引入），即按 scale 1 运行，对应用户观察到的约 1.9 s。
- 改动后：工具线程排入 10 次 click 共阻塞 0.06 ms；光标 922 ms 后全部播完（scale 0.15），顺序正确。
- 突发节奏（scale 0.15）：`moveCursor` 241 → 136 → 81 → 54 → 35 ms，空闲 2.2 s 后回到 224 ms。
- 落点误差（pulse 开始时尖端到目标的距离）：改时钟前突发时 320–376 pt，改后最大 0.1 pt（scale 0.15）/ 0.2 pt（scale 1）。
- `swift test` 245 tests 0 failures（9 个 live test 默认跳过）；`OpenComputerUseSmokeSuite --cursor-idle-only` 通过（真实 MCP 运行时，click 后光标进入 idle）。
- 空闲动画：`testVisualCursorIdlePoseKeepsTipAnchoredAndOnlyRotates` 不改动仍通过；改后 `--cursor-idle-only` smoke 通过（尖端锚定 < 0.25 pt，旋转持续变化）。
