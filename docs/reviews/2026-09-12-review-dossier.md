# Review dossier — agent-loop preparation, targeted AX, App Intents

Prepared for an external review pass. Everything below landed in a single commit.

- **Commit under review:** `1d3dcec` — "macos: agent-loop preparation, targeted AX, and App Intent execution"
- **Baseline (spec's "current behaviour" revision):** `257d869` (pi-bridge / streaming js engine)
- **Full changeset:** `git diff 257d869..HEAD` → 23 files, **+1598 / −82**
- **Raw diff for line-by-line review:** [`2026-09-12-changeset.diff`](./2026-09-12-changeset.diff) (in this folder)
- **Status:** builds clean; `swift test` = **221 passed, 0 failed, 7 skipped** (the 7 are live-desktop suites gated behind env flags).

Two agents worked this concurrently on the same package. This document says who did
what, why, and where to look hardest. Where a section is another agent's work I did
not author, it is marked **[not authored here — verify]**.

---

## 0. TL;DR for the reviewer

Two independent features share the macOS desktop service:

- **Workstream A — Targeted AX + snapshot-free actions + cursor speed** (authored here).
  A native, no-screenshot control lookup (`cua.query`) whose results feed the
  existing element actions, and a JavaScript action path that performs **no automatic
  before/after AX snapshot or screenshot**. Plus a cursor-animation speed knob.
- **Workstream B — Agent-loop preparation + App Intent execution** (other agent).
  Virtual-display preparation, non-activating window observation, streamed
  statement-progress reporting, and running App Intents via Shortcuts (`run_intent`).

They meet at one shared type (`TargetedAX.WindowContext`) and one shared function
(the streaming statement scanner in `JavaScriptToolRuntime`). Both meeting points had
integration bugs during development; both are resolved and covered by tests now.

**Highest-value things to scrutinise** (details in §4):
1. The streaming statement scanner's if/else/try-catch "hold" heuristic (naive, not a real JS parser).
2. The targeted-search **off-screen geometry pruning** — correctness vs. missing real controls.
3. `run_intent`'s Shortcuts-signing/execution path and its security posture.
4. The "no automatic snapshot" guarantee actually holding below the JS wrapper.
5. Element-reference lifetime / index stability across a background snapshot.

---

## 1. Workstream A — Targeted AX lookup + snapshot-free actions  *(authored here)*

Implements `docs/product-specs/targeted-ax-speculative-execution.md`.

### 1a. `cua.query(app, { text?, role?, exact?, limit?, max_nodes?, window_id? })`
Returns matching controls, each with an `index` the **existing** element actions accept
(`cua.click(app, { element_index })`, `setValue`, `scroll`, `secondaryAction`). No full
snapshot, no screenshot, no model-facing output.

- **Native path:** tries the app's `AXUIElementsForSearchPredicate` first. Measured
  finding: this is **unsupported on the current macOS across every app tried**
  (returns `parameterizedAttributeUnsupported`), so the fallback below is the real path.
- **Fallback (the hot path):** a bounded breadth-first walk of the window subtree that
  - **interleaves matching and stops at `limit`** (does not collect the whole tree then filter),
  - reads role/title/description/value/identifier/position/size in **one**
    `AXUIElementCopyMultipleAttributeValues` IPC call per node,
  - **prunes off-screen subtrees by geometry** against the *root window's own AX frame*
    (captured in the same pass, so it can't skew when a window moves; this macOS leaves
    `AXVisibleChildren` empty so geometry is the only lever),
  - caps at `max_nodes` (default 500); on cap-with-zero-matches it throws a clear error,
    otherwise returns what it found.
- **Where:** `AccessibilitySnapshot.swift` → `enum TargetedAX`, `SnapshotBuilder.resolveTargetWindow`,
  `SnapshotBuilder.targetedSearch`, `WindowCapture.resolveMetadata`, and the pure matcher
  `targetedRecordMatches` / `targetedRoleEquals` (unit-tested in `TargetedAXTests.swift`).
- **Latency measured live** (best of 3, Calculator/Finder/Safari/System Settings/Notes/TextEdit):
  ~15–56 ms, down from ~100–966 ms for the old getState path.

### 1b. Snapshot-free action path
Actions invoked **from JavaScript** (js runtime, `stream`, `pi-bridge`) perform no
automatic snapshot. Direct CLI/MCP action calls are unchanged and still return the
after-action snapshot.

- `ComputerUseService.withJavaScriptExecution { … }` wraps every JS-originated tool call
  (set in the dispatcher's `toolCaller`), flipping `javaScriptExecutionActive`.
- `actionResult(for:)` returns a compact `"ok"` in that mode instead of
  `refreshSnapshot(...)`.
- `currentSnapshot(for:)` in that mode resolves only the window context (no tree, no
  screenshot) when nothing is cached, so a missing snapshot never forces a capture.
- `snapshotForAction(app:elementIndex:)` resolves a *queried* index to that control's own
  lite window snapshot; the existing `click`/`scroll`/`setValue`/`performSecondaryAction`
  internals then run unchanged against it.
- **Queried indexes** are handed out from a monotonic counter starting at `1_000_000`
  (`targetedElements` registry, FIFO-capped at 5000), so they never collide with snapshot
  tree indexes and a background snapshot cannot repoint a saved index.
- **Verified live:** `9 × 8 = 72` driven entirely through queried indexes with **zero**
  full snapshots / screenshots during the burst (measured with a temporary counter that
  was then removed).

### 1c. Cursor animation speed  *(SoftwareCursorOverlay.swift)*
The software-cursor overlay animates **synchronously on the calling thread**, so its
glide + click-pulse time is added to every click. Added `motionDurationScale`
(default **0.15** ≈ 6× faster than the modeled macOS cursor;
`OPEN_COMPUTER_USE_CURSOR_DURATION_SCALE` overrides; `0` = instant snap) applied to the
move glide, the click pulse, and the inter-pulse pause. Kept **synchronous** by request.
Measured click latency by scale: 1.0 ≈ 330 ms · 0.3 ≈ 213 ms · **0.15 ≈ 192 ms** · 0 ≈ 172 ms
(the ~172 ms floor is the tuned AX input-settle, not the cursor).

---

## 2. Workstream B — Agent-loop preparation + App Intents  *(other agent — [not authored here — verify])*

New dispatcher tools: `prepare_agent_display`, `prepare_app`, `observe_app`,
`agent_app_catalog`, `run_intent`.

- **`AgentPreparation.swift`** (new) — prepare the virtual display; resolve an app
  *without activating it*, launch if needed, poll up to 3 s for its window, park it on the
  agent display, optionally open a fresh window (`super+n`) and bind that as the prepared
  action context; read-only `observe_app` of a specific window id; app catalog + default
  browser. Builds on Workstream A's `resolveTargetWindow(windowID:)` / lite snapshot.
- **`AppIntentExecution.swift`** (new) — `run_intent` runs an App Intent by
  `<bundle id>.<intent name>`. There is no unentitled API to invoke an App Intent
  directly (the private LinkServices executor rejects non-validated bundles), so it
  generates a one-action Shortcut, signs it with `shortcuts sign`, and opens it for the
  user to add once; subsequent runs use `shortcuts run`. **Review focus:** shells out to
  the `shortcuts` CLI, writes temp workflow files, 120 s deadline, first-run requires
  human "Add Shortcut". Check the signing/exec path and failure modes.
- **`AppDiscovery.swift`** — `resolve`/`launchIfPossible`/`openApplication` gained an
  `activate:` flag (default true) so the agent loop can launch apps without stealing
  foreground. Threads `configuration.activates`.
- **`AgentDisplay.swift`** — `prepare()` / `displayID` surfaced for `prepare_agent_display`.
- **Streamed statement progress** — `JavaScriptToolRuntime.streamObserver` emits
  `started`/`done` per statement (with byte offsets); `PiBridgeServer` forwards them as
  `done`/progress frames. `StreamCell` gained an `id`.
- **`SnapshotBuilder.build(windowID:)`** — build a snapshot for a specific window id
  (used by `observe_app`).

---

## 3. Cross-cutting fix — streaming statement scanner  *(other agent wrote it; fixed here)*

The other agent's exec-plan item "do not execute incomplete if/else or try/catch blocks"
shipped **buggy**: `executeNewlyComplete` executed an `if (…) {…}` block *before* its
`else` streamed in, and a trailing `// comment` defeated its `}` check so the branch split
anyway (their own test `PiBridgeServerTests.testIfAndTryBodiesWaitForTheirContinuation`
failed 3 assertions).

**Rewritten here** (`JavaScriptToolRuntime.swift`) as `nextRunnableUnitEnd` + small pure
helpers (`blockAcceptsContinuation` keyed on the unit's *leading* keyword `if`/`try`/`do`,
`startsWithContinuation`, `isPartialContinuation`) and `evaluateStreamStatement`. A unit
that opens with `if`/`try`/`do` is held until its continuation, unrelated following code,
or the end of the stream shows it is closed. Robust to trailing comments and braceless
`if…else`.

**Review focus:** this is still a *naive* line-scanner, not a real JS parser (documented
`ponytail:` caveat in `nextStatementEnd`). It does not distinguish a regex literal from
division and does not re-enter string parsing inside `${}`. Edge inputs could mis-split.
Covered by `PiBridgeServerTests` + `JavaScriptToolRuntimeTests` stream cases.

---

## 4. Review-focus checklist (what a careful reviewer should probe)

1. **Scanner heuristic** (§3): feed pathological streams — regex literals, template
   `${}` with braces/strings, `do…while`, nested `try/catch/finally`, minified one-liners.
   The fallback on truly broken syntax is: run it on final feed and surface the JS error.
2. **Geometry pruning** (§1a): could a *real, actionable* control be pruned because its AX
   frame reports off-window (odd apps, transformed/zoomed views, popovers that are separate
   AX windows)? Unknown-frame nodes are intentionally kept.
3. **Index/reference lifetime** (§1b): confirm a queried index survives an intervening
   `get_app_state` and is never reused; confirm the FIFO cap (5000) can't drop a
   still-referenced index mid-task.
4. **No-automatic-snapshot guarantee** (§1b): verify below the JS wrapper (not just output)
   that a burst does zero `SnapshotBuilder.build` / screenshot captures. Confirm the
   direct CLI/MCP path is unaffected.
5. **`run_intent` security** (§2): shelling to `shortcuts`, temp files, signing, and the
   human-in-the-loop first add. Any injection surface in the generated workflow?
6. **Non-activating launch** (§2): `activate:false` correctness across bundle-id vs
   name resolution; ensure `AppSafetyPolicy` blocks still apply.
7. **Cursor** (§1c): default 0.15 vs the tuned input-settle floor; confirm nothing depends
   on the previous glide duration.

---

## 5. File-by-file (all 23)

| File | Owner | What changed |
|---|---|---|
| `…/AccessibilitySnapshot.swift` (+396) | A | `TargetedAX` types, `resolveTargetWindow`, `targetedSearch` (batched scan, geometry prune, early-stop), `WindowCapture.resolveMetadata`, pure matchers; `SnapshotBuilder.build(windowID:)` |
| `…/ComputerUseService.swift` (+223) | A + B | A: `query`, `snapshotForAction`, `actionResult`, `currentSnapshot` JS-mode, `liteSnapshot`, `targetedElements`, `withJavaScriptExecution`. B: prepared-window binding hooks |
| `…/ComputerUseToolDispatcher.swift` (+72) | A + B | A: `query` tool + JS-execution wrapper on `toolCaller`. B: `prepare_agent_display`/`prepare_app`/`observe_app`/`agent_app_catalog`/`run_intent` cases |
| `…/JavaScriptToolRuntime.swift` (+123) | A + B | A: `cua.query` banner, **scanner rewrite/fix**. B: `streamObserver`, `StreamCell.id`, original (buggy) scanner |
| `…/SoftwareCursorOverlay.swift` (+17) | A | `motionDurationScale` cursor-speed knob |
| `…/ToolDefinitions.swift` (+31) | A | `query` discrete tool def + `js` tool description update |
| `…/AgentPreparation.swift` (+87, new) | B | prepare display / prepare app / observe / catalog |
| `…/AppIntentExecution.swift` (+113, new) | B | `run_intent` via Shortcuts signing/exec |
| `…/AppDiscovery.swift` (+13) | B | `activate:` flag on resolve/launch/open |
| `…/AgentDisplay.swift` (+8) | B | `prepare()` / `displayID` |
| `…/PiBridgeServer.swift` (+45) | B | statement-progress frames via `streamObserver` |
| `Tests/…/TargetedAXTests.swift` (+50, new) | A | pure matcher tests |
| `Tests/…/JavaScriptToolRuntimeTests.swift` (+35) | A | `query` wiring + queried-index→click; (other stream tests) |
| `Tests/…/OpenComputerUseKitTests.swift` (+3) | A | discrete tool count 9→10 (+`query`) |
| `Tests/…/PiBridgeServerTests.swift` (+37) | B | streamed-progress + if/else-hold tests (the ones the fix makes pass) |
| `docs/product-specs/targeted-ax-speculative-execution.md` (+207) | user + A | spec (user-authored) + "Implemented" section |
| `docs/product-specs/index.md` (+6) | A | spec index entry |
| `docs/references/js-code-tool.md` (+24) | A | `cua.query` + no-auto-snapshot docs |
| `docs/references/js-stream-protocol.md` (+41) | B | progress-frame protocol docs |
| `…/references/cua-api.md` (+23) | B | cua API doc updates |
| `docs/histories/2026-09/20260912-0150-targeted-ax-…md` (+64, new) | A | history record |
| `docs/histories/…/20260912-0310-agent-loop-integration.md` (+32, new) | B | history record |
| `docs/exec-plans/completed/20260912-agent-loop-integration.md` (+30, new) | B | exec plan |

*(Owner: A = targeted-AX/cursor authored in this session; B = agent-loop/App-Intent by the other agent. Line counts are the diff stat.)*

---

## 6. Build & test

```
# from repo root (root Package.swift drives the OpenComputerUseKit package)
swift build
swift test
```

Current: **build clean; 221 tests pass, 0 fail, 7 skipped** (live suites gated by
`OPEN_COMPUTER_USE_RUN_*` env flags; they need Accessibility + Screen Recording granted
to the test binary and real apps). The targeted-AX + cursor behaviour was additionally
verified live against Calculator/Finder/Safari/System Settings/Notes/TextEdit.

To review the exact code, open [`2026-09-12-changeset.diff`](./2026-09-12-changeset.diff)
or run `git show 1d3dcec`.
