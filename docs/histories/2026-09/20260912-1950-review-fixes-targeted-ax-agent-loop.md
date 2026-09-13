## [2026-09-12 19:50] | Task: Review fixes for commit 1d3dcec (targeted AX, agent-loop prep, run_intent)

### 🤖 Execution Context
* **Agent ID**: `claude-code`
* **Base Model**: `claude-fable-5-1`
* **Runtime**: `Claude Code CLI`

### 📥 User Query
> Review commit 1d3dcec skeptically (streaming statement scanner, targeted-search
> geometry pruning, run_intent security, no-auto-snapshot guarantee, element
> registry lifetime, non-activating launch, Swift footguns) and fix what is wrong.
> Focus on performance, accuracy, correctness, low memory overhead. No big comments.

### 🛠 Changes Overview
**Scope:** `packages/OpenComputerUseKit`

- **Scanner** (`JavaScriptToolRuntime.swift`): continuations are keyed per opener
  (`if`→else, `try`→catch/finally, `do`→while) so a standalone `while` loop is no
  longer folded into a preceding `if`; a unit ending in `};` (or a `do…while(…);`)
  is closed immediately, which makes the documented "semicolon finishes promptly"
  rule true; comment-only units emit no statement events; each cell memoizes the
  largest prefix already known to be syntactically incomplete so re-feeds of a long
  block do not re-parse every line prefix; `JSStringCreate` no longer force-unwrapped.
  Follow-up: the hand-written scanner was replaced by a real parser. acorn 8.18.0
  (MIT) is vendored verbatim as a Swift string (`Vendor/AcornJavaScript.swift`)
  and driven statement-by-statement in its own JSContext
  (`StreamStatementParser.swift`). A statement runs once nothing streamed so far
  can extend it (`if`→`else`, `try`→`finally`, unterminated expression→next
  token); a broken literal after a complete statement no longer blocks it. Cell
  offsets are UTF-16; emitted `start`/`end` stay UTF-8 bytes.
- **Targeted search** (`AccessibilitySnapshot.swift`): geometry pruning skipped
  zero-size frames because `CGRect.intersects` is false for empty rects, so 0×0
  wrapper groups (common in web/Electron trees) dropped every real control beneath
  them; now unknown *or* empty frames are kept. The duplicated window-metadata
  resolver was folded into `WindowCapture.resolve(capture:)`.
- **run_intent** (`AppIntentExecution.swift`): model-supplied `bundle_id`/`action_id`
  became a temp-file name unvalidated (`../x` escaped the temp dir). Now a dotted
  identifier with non-empty `[A-Za-z0-9_-]` segments is required; the unsigned
  workflow and the `--input-path` file are removed after use; the deadline timer
  only terminates a still-running child. The action is always
  `<bundle_id>.<action_id>` and `is.workflow.*` is refused, so the model cannot
  generate a built-in Shortcuts action (shell script, etc.) for the user to add.
- **Queried-element actions** re-read the window bounds and element frame at
  action time (`SnapshotBuilder.currentGeometry`), so a click on a queried index
  lands correctly even if the window moved after the query.
- **Query/JS actions** resolve apps with `activate: false` so a read-only lookup
  never steals foreground when the app has to launch.
- **Tidy**: `observe_app` parses `window_id` like `query`; cursor speed scale is read
  once; `AgentPreparation` reuses `AppDiscovery.resolvedRunningApp`; docs no longer
  promise a `description` field the record does not carry.

### 🧠 Design Intent (Why)
Boundaries now come from the same grammar the engine uses; the only heuristic
left is "could the next, still-streaming token become a continuation keyword". Pruning must be conservative:
a missed control is worse than visiting a few off-screen nodes. `run_intent`'s trust
boundary is the human "Add Shortcut" click, so everything before it must not touch
the filesystem with untrusted names.

### 📁 Files Modified
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/JavaScriptToolRuntime.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/StreamStatementParser.swift` (new)
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/Vendor/AcornJavaScript.swift` (new, vendored)
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AccessibilitySnapshot.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AppIntentExecution.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AgentPreparation.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/AppDiscovery.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseToolDispatcher.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/SoftwareCursorOverlay.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ToolDefinitions.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/JavaScriptToolRuntimeTests.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/AppIntentExecutionTests.swift`
- `docs/references/js-code-tool.md`
- `docs/references/js-stream-protocol.md`
