# What we need from open-codex-computer-use

These are the requirements for the agent's JavaScript programs. They describe
what we want implemented.

Status: Implemented 2026-09-12 in `packages/OpenComputerUseKit`
(see "Implemented" at the end).

Date: 2026-09-12.

The idea:

The model writes a program that predicts several actions ahead. The program
should be able to find a control and use it without taking a full AX tree or
screenshot after every action.

For example, after opening Gmail, it should find Compose, press it and fill the
composer in the same execution. The model does not need to see each of those
intermediate screens.

1. Find controls directly through AX.

Add this JavaScript call:

```js
var matches = cua.query("Safari", {
    text: "Compose",
    role: "AXButton",
    limit: 2
});
```

How it should work:

i. `app` names the app or its bundle ID. Search the app window prepared for this
run. The query can also take `window_id` to name a particular window.

ii. `text` matches text in the control's title, description or value. Match
case-insensitive substrings. An optional `exact: true` asks for a complete text
match instead. `role` is optional and matches an exact AX role. Require at least
one of `text` or `role`.

iii. Return an array of matching controls. `limit` is the maximum number of
matches after applying the filters; default to 20. No match returns an empty
array. Multiple matches remain multiple matches for the program to choose from.

iv. Each match has an `index` usable by the existing element actions. Include
the role and available title, description, value, identifier, bounds and actions.
Do not return a full tree or screenshot.

v. Use native AX search when the app supports it. If it does not, search the
chosen window's AX nodes with a cap of 500 nodes by default, configurable as
`max_nodes`. Stop when enough matches are found. If the cap prevents finishing
the query, report that clearly instead of claiming there are no matches.
Do not build and render a full snapshot first.

vi. A query can find a control that appeared after an earlier action, even if
that control was not in the last full snapshot. It must not require
`getState()` first.

vii. Keep returned indexes tied to the same controls for this runtime. A
background snapshot must not reassign a saved index to a different control.
References are only for this run, not values to save in reusable programs.

viii. The results stay inside JavaScript. They reach the model only if the
program deliberately prints them. Native errors throw a short error.

For example:

```js
var matches = cua.query("Safari", {
    text: "Compose",
    role: "AXButton",
    limit: 2
});

if (matches.length !== 1) {
    throw new Error("Expected one Compose button; found " + matches.length);
}

cua.click("Safari", { element_index: matches[0].index });
```

This is an example of the API, not a tested Gmail selector.

2. Actions should not automatically take another observation.

This applies to actions called from JavaScript, including through `stream`
and `pi-bridge`:

- `cua.click`
- `cua.type`
- `cua.pressKey`
- `cua.setValue`
- `cua.scroll`
- `cua.drag`
- `cua.secondaryAction`

How they should work:

i. Run the action and return normally, or throw the native error.

ii. Do not refresh the full AX tree or capture a screenshot before or after
each action. Taking a snapshot and then discarding its output still costs time.

iii. Keep the app/window information needed to direct input separately from the
full snapshot. A missing full snapshot must not force a capture when the target
has already been prepared.

iv. Keep background input and the agent display working. Use the intended app
window without bringing it to the foreground.

v. Do not add an automatic check or wait after every action. The program can
write its own targeted query, wait or failure handling when needed.

vi. Run statements in order. If an error is not caught, stop the later
statements. Keep track of what already ran. Do not replay it automatically.

vii. Return only short status or error information. A successful action call
means the action was performed or input was sent; it does not by itself prove
that the user's whole task is complete.

These rules apply to JavaScript execution. The existing full observation APIs
remain available when explicitly called. Changing the separate, directly called
CLI/MCP action responses is outside this requirement.

3. Let the calling agent harness decide when to observe.

The agent harness prepares the AX tree and app shot for the model's turns.
It can also read them in the background and reuse a capture for several filters.

The running program does not wait for a full observation between speculative
actions. A targeted query for a control is separate from preparing a full
observation for the model.

Hyperopia belongs to the calling agent harness. It runs in the background and
mutates stored history whenever a compaction result is ready. Execution and the
next model request never wait for it. An in-flight request keeps the context
already sent to the provider.

What needs changing in the current code:

At revision `257d869b79920c17e8541b4a06fdbae093c99b9a`:

i. [`cua.find()`](../../packages/OpenComputerUseKit/Sources/OpenComputerUseKit/JavaScriptToolRuntime.swift)
calls `elements()`, which calls `getState()`, so it takes a new snapshot before
filtering. The new `query()` must avoid that path.

ii. [The action methods](../../packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift)
call `refreshSnapshot()` after acting. Some also capture when no cached
snapshot exists. The JavaScript action path must stop requiring those captures.

iii. The service has coordinate AX hit testing, but not the targeted native
search described above.
[macos-harness's query](https://github.com/browser-use/macos-harness/blob/main/src/macos_harness/controls.py)
is a reference for the required behavior.

How to check it when implemented:

1. Find a control that appeared after an action, then use it without taking a
full snapshot or screenshot in between.
2. After preparing a window, run several JavaScript actions and confirm that
they cause zero automatic full snapshots or screenshots.
3. Check the native calls, not only the output. Empty output does not prove
that a snapshot was skipped.
4. Check no matches, multiple matches, a search cap, an unsupported native
search and a native action error.
5. Confirm a background capture does not change what a saved control index
means.
6. Explicitly request a full observation and confirm it shows the current app.
7. Compare execution time and capture counts with the old path using designated
test targets. Do not assume a speedup before measuring it.

The existing JavaScript and streaming behavior is described in
[the JavaScript tool](../references/js-code-tool.md) and
[the streaming protocol](../references/js-stream-protocol.md).

## Implemented

Shipped 2026-09-12.

1. Lookup — `cua.query(app, { text?, role?, exact?, limit?, max_nodes?, window_id? })`
   returns matching controls, each with an `index` the existing element actions
   accept: `cua.click(app, { element_index: r[0].index })`, `setValue`, `scroll`,
   `secondaryAction`. It requires `text` and/or `role`, uses the app's native
   `AXUIElementsForSearchPredicate`, and falls back to a bounded child traversal
   (`max_nodes`, default 500). No full snapshot or screenshot. When the traversal
   cap stops the search before it finishes, `query` reports that instead of
   returning an empty list. Indexes are assigned above the snapshot range and are
   never reissued, so a background snapshot never repoints a saved index.
   Backed by `SnapshotBuilder.resolveTargetWindow` (read-only window resolution,
   no activation/raise/capture) and `SnapshotBuilder.targetedSearch`.

2. Snapshot-free actions — under JavaScript execution (js runtime, `stream`,
   `pi-bridge`), the action path performs no automatic before/after snapshot:
   `ComputerUseService.withJavaScriptExecution` sets the mode, `actionResult`
   returns a compact status instead of an after-action capture, and
   `currentSnapshot` resolves only the window context (no tree/screenshot) when no
   snapshot is cached. Background input and virtual-display targeting are
   unchanged. Direct CLI/MCP action calls are outside JavaScript execution and
   keep their snapshot responses.

Key files: `AccessibilitySnapshot.swift` (`TargetedAX`, `SnapshotBuilder`
targeted extension, `WindowCapture.resolveMetadata`), `ComputerUseService.swift`
(registry, `query`, `snapshotForAction`, `actionResult`), `ComputerUseToolDispatcher.swift`
(`query` tool, JavaScript-execution wrapper), `JavaScriptToolRuntime.swift`
(`cua.query`), `ToolDefinitions.swift`.
