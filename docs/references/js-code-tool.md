# The `js` tool — the single Computer Use interface

`js` is the only tool advertised over MCP. It runs JavaScript that drives the
desktop through a synchronous `cua` API, so a whole flow (read state, find an
element, act, verify, loop, retry) happens in one call instead of one call per
action. The underlying actions (click, type, get_app_state, ...) are not
advertised; they are reachable from inside `js` as `cua.*`, and still callable by
name through the CLI (`open-computer-use call click ...`) for debugging.

## Runtime

- **Engine:** JavaScriptCore, in-process in the MCP server. macOS only. On a
  build without JavaScriptCore the tool returns a stable unsupported error.
- **Synchronous by design:** actions run in-process, so there are no promises and
  no top-level await. `cua.click(...)` returns when the action has run.
- **Scope and persistence:** each call runs in its own function scope, so
  `let`/`const` never collide across calls. Assign to `globalThis` for a value
  that must survive to the next call. Pass `reset: true` to clear all `globalThis`
  bindings before running.
- **Output:** `write(value)` appends to the result text (objects are
  JSON-stringified); `console.log(...)` adds a trailing newline. `emitImage(base64)`
  attaches an image. Return values are not auto-printed; use `write`.
- **Timeout:** `timeout_ms` bounds execution (default 30000 ms). A runaway script
  is terminated through JavaScriptCore's execution time-limit, which the framework
  exports but declares only privately; the shim `OpenComputerUseJavaScriptShim`
  restates the prototype.

## The `cua` API

State and elements (prefer these; act by element index):

```
cua.getState(app, opts?)    -> { text, elements }
cua.elements(app, opts?)    -> [{ index, role, title, value, identifier, bounds, actions }]
cua.find(app, e => ...)     -> first matching element, or null
cua.findAll(app, e => ...)  -> all matching elements
cua.getAppState(app, opts?) -> tree text only
cua.screenshot(app, opts?)  -> tree text, and emits the screenshot
```

Actions (each throws on a tool error; catch with try/catch):

```
cua.click(app, { element_index?, x?, y?, click_method? })
cua.type(app, text, { key_method? })
cua.pressKey(app, key, { key_method? })
cua.scroll(app, direction, element_index, pages?)
cua.drag(app, from_x, from_y, to_x, to_y)
cua.setValue(app, element_index, value)
cua.secondaryAction(app, element_index, action)
cua.listApps()
cua.call(tool, args)        // low-level escape hatch: { text, images }
```

Targeted lookup (no snapshot or screenshot):

```
cua.query(app, { text?, role?, exact?, limit?, max_nodes?, window_id? })
  -> [{ index, role, title, value, identifier, bounds, actions }]   // title falls back to the AX description
```

`query` finds controls in the app's chosen window with the app's native AX search
(`AXUIElementsForSearchPredicate`), falling back to a bounded child traversal
(`max_nodes`, default 500) when the app has no native search. It requires `text`
and/or `role`; `text` matches title/description/value (case-insensitive substring,
or a full match with `exact: true`). Each result's `index` is passed straight to
the element actions (`cua.click(app, { element_index: r[0].index })`, `setValue`,
`scroll`, `secondaryAction`). An index stays tied to its control for the runtime;
re-query after the UI changes rather than reusing a stale one. If the traversal
cap stops the search early, `query` throws instead of reporting no matches.

Under `js` (and the `stream`/`pi-bridge` feeders), the actions above do **not**
automatically capture the AX tree or a screenshot before or after acting — a
burst of predicted steps runs with no snapshot in between. Read back explicitly
with `getState`/`getAppState`/`screenshot` when your logic needs the result. The
directly called CLI/MCP action responses are unchanged and still return the
after-action snapshot.

## Example

```
const send = cua.find("Slack", e => e.role === "AXButton" && /send/i.test(e.title || ""));
if (send) { cua.click("Slack", { element_index: send.index }); }
else { write("no send button; state:\n" + cua.getAppState("Slack")); }
```

## Safety

The runtime binds only the Computer Use actions; JavaScriptCore exposes nothing
else (no filesystem, no network). `cua.call` refuses `js`, so a script cannot
re-enter the runtime. The actions it can drive are exactly the ones the discrete
definitions describe (`ToolDefinitions.discrete`).

## Streaming / speculative execution (engine)

The feeder wire protocol is specified in [js-stream-protocol.md](js-stream-protocol.md) and served by `open-computer-use stream`.

The runtime can execute a call's statements **as the model streams the `code`**,
before the call finishes generating, so model-generation latency overlaps
execution latency. This is modelled on `pi_agent_rust`'s `python_tool`
("statements execute while the call still streams"). It is a host-agnostic engine
on the runtime; a feeder that owns the model's token stream drives it. Standard
MCP delivers a whole `tools/call`, so this cannot run over the MCP path — the
feeder must be an agent runtime that sees partial tool-call arguments.

Feed API (one cell = one streamed call; run cells one at a time, in call order):

```
beginStream(id)                 // start a cell; resets the output sink
feedStream(id, sourcePrefix)    // execute every statement newly completed since the last feed
finishStream(id, source?)       // run the trailing statement; return the cell's result
abandonStream(id)               // host will never finish this call; report statements already run
```

Invariants (from `python_tool.rs`):
- **Append-only.** The prefix may only grow. If a feed's source is not a prefix
  of what already ran, the cell fails with "source diverged; earlier statements
  may have run."
- **Shared REPL scope.** Statements in a cell run in one persistent scope
  (via `evaluateScript`), so a `let` in one statement is visible to the next.
  Scope persists across cells; use `globalThis` and avoid re-declaring the same
  `let` in a later cell.
- **Fail-stop.** A statement that throws fails the cell; later statements and
  later feeds do not run.
- **Abandon** records how many statements had already run.

**Safety ceiling — read this.** This engine runs in **full speculation**: every
statement, including mutating actions (`click`, `type`, `drag`, `setValue`), runs
as it streams. The divergence guard and `abandon` **surface** a diverged or
abandoned stream; they cannot **undo** an action already taken on the real
desktop. creator-agent retired its own speculative path (decision D30) for exactly
this reason: an abandoned speculative mutation corrupts a persistent session. If
that risk is unacceptable for a deployment, gate mutations to run only after the
call commits (execute side-effect-free ops — `getState`/`elements`/`find`/
`screenshot`/pure JS — while streaming, defer the rest); the engine's cell model
supports adding that gate.
