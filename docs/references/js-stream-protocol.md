# JS streaming feeder protocol

A wire protocol that lets an agent runtime ("feeder") drive Open Computer Use's
`js` speculative streaming engine as the model's tool call streams, so
model-generation latency overlaps execution. This is the integration contract for
agent builders. It is deliberately small and language-agnostic.

## Why a separate protocol (not MCP)

Standard MCP delivers a whole `tools/call` as one request; an MCP server never
sees partial tool-call arguments. Streaming per-line execution therefore cannot
live behind MCP. It has to be driven by the component that owns the model's token
stream — the agent runtime. This protocol is how that runtime talks to the
engine. (The engine is the same one behind the MCP `js` tool; a feeder is just an
alternative front end that can stream into it.)

## Transport

- The feeder spawns `open-computer-use stream`. One process is one persistent
  runtime session (one JavaScript scope, shared across cells).
- Framing is newline-delimited JSON (JSONL), UTF-8, exactly one JSON object per
  line, in both directions. Requests on the process's stdin, responses on stdout.
  The server writes unbuffered; the feeder should too.
- It is synchronous request/response: one response line per request line, in
  order. There are no unsolicited frames in this version.

## Requests

Every request is a JSON object with an `op`. A cell is one streamed tool call.

| op | fields | meaning |
|---|---|---|
| `begin` | `cell` | Start a cell. Resets the output sink for that cell. |
| `feed` | `cell`, `source` | `source` is the **full code generated so far** (a growing prefix). The engine runs every statement that has newly completed since the last feed. |
| `finish` | `cell`, `source?` | The full source has arrived. Runs the trailing statement and returns the cell's result. `source` is optional; if given it must still be a prefix-extension. |
| `abandon` | `cell` | The host will never finish this call (skipped/aborted/stream cut). Returns the result; statements already run stay run. |
| `reset` | — | Clear the persistent `globalThis` scope and re-initialize the runtime. |

## Responses

| for | shape |
|---|---|
| `begin` | `{"op":"begin","cell":<id>,"ok":true}` |
| `feed` | `{"op":"feed","cell":<id>,"completed":<int>,"failed":<bool>,"error":<string|null>}` |
| `finish` | `{"op":"finish","cell":<id>,"result":{"content":[…],"isError":<bool>}}` |
| `abandon` | `{"op":"abandon","cell":<id>,"result":{…}}` |
| `reset` | `{"op":"reset","ok":true}` |
| bad request | `{"op":<op?>,"error":<string>}` |

`result` has the same shape as an MCP tool result (`content` is an array of
`{"type":"text","text":…}` and `{"type":"image","data":<base64>,"mimeType":"image/png"}`).
Hand it back to the model as the `js` tool's output.

## Compliance rules

1. **`source` is the full accumulated code, never a delta.** Extract the `code`
   field from the streaming tool-call arguments as they accumulate, and send what
   you have so far. The engine diffs against what it already ran.
2. **The prefix may only grow.** A `feed`/`finish` whose `source` is not a prefix
   of what already ran fails the cell (`"source diverged; earlier statements may
   have run"`). Never send a rewritten prefix.
3. **One cell at a time.** `begin` → `feed`* → (`finish` | `abandon`) before the
   next `begin`. Cells share one scope, so use `globalThis` for values that must
   survive a cell, and avoid re-declaring the same `let` in a later cell.
4. **On the model completing the call,** send `finish` with the final source and
   return its `result` to the model.
5. **On skip/abort/stream-cut,** send `abandon`; its `result` says how many
   statements had already run.

## Semantics

- **Fail-stop.** A statement that throws fails the cell; later statements and
  later feeds do not run. `completed` stops advancing and `failed` becomes true.
- **Shared REPL scope.** Statements run in one persistent scope via the engine's
  interpreter, so a `let` in one statement is visible to the next.
- **Idle/timeout.** Each statement is bounded (30 s); a runaway statement is
  terminated and fails the cell.

## Safety — read this before feeding mutations

The engine runs in **full speculation**: every statement, including mutating
actions (`cua.click`, `cua.type`, `cua.drag`, `cua.setValue`), runs during `feed`,
as it streams. The divergence guard and `abandon` **surface** a diverged or
abandoned stream; they cannot **undo** a click or keystroke already sent to the
real desktop.

A feeder that needs safety controls this itself, because it decides what to feed:
feed read-only prefixes eagerly (the slow accessibility reads — `cua.getState`,
`cua.elements`, `cua.find`, `cua.screenshot`), and **hold the prefix at the last
line before a mutating call until `finish`.** That captures the read latency while
never performing an irreversible action on an uncommitted stream. creator-agent
retired its own speculative path (decision D30) precisely because an abandoned
speculative mutation corrupts a persistent session.

## Example

```
→ {"op":"begin","cell":"t1"}
← {"op":"begin","cell":"t1","ok":true}
→ {"op":"feed","cell":"t1","source":"const b = cua.find(\"Notes\", e => e.role===\"AXButton\");\n"}
← {"op":"feed","cell":"t1","completed":1,"failed":false,"error":null}
→ {"op":"feed","cell":"t1","source":"const b = cua.find(\"Notes\", e => e.role===\"AXButton\");\nif (b) cua.click(\"Notes\", { element_index: b.index });\n"}
← {"op":"feed","cell":"t1","completed":2,"failed":false,"error":null}
→ {"op":"finish","cell":"t1"}
← {"op":"finish","cell":"t1","result":{"content":[{"type":"text","text":""}],"isError":false}}
```

## Versioning

This is version 1. Fields may be added; a compliant feeder ignores unknown
response fields. Multi-cell pipelining (a cell returning before its source is
complete so the model predicts the next call) is a possible future extension and
is not part of v1.


## Host preparation and observations

These calls are for a host that owns the model loop. They use `cua.call(name,
args)` in the persistent runtime. `agent_app_catalog` and `observe_app` can also
be called through the CLI in a separate process.

| Call | Arguments | Result |
| --- | --- | --- |
| `prepare_agent_display` | `{}` | JSON text with display ID and dimensions; creates the display before apps are selected |
| `agent_app_catalog` | `{}` | JSON text with known apps (`name`, `app`, `running`, `pid` when running, else null) and the default browser's bundle ID |
| `prepare_app` | `{app, new_window?: boolean}` | JSON text with app, name and window_id; launches in the background if necessary and parks the window |
| `observe_app` | `{app, window_id}` | The named window's AX tree and image; does not launch, activate, or substitute another window |
| `close_prepared_window` | `{window_id}` | Closes a parked window with its own close button and forgets it: `closed <id>` (also when the window was already gone), or `window <id> is still open` when a sheet holds it (it is then back on the user's screen, no longer parked). Errors when the window is not parked |
| `restore_prepared_window` | `{window_id}` | Puts a parked window back while the app keeps running, exactly as process exit would: a window `prepare_app` opened is closed (`closed <id>`, also when it was already gone), any other goes home (`restored <id>`, or `still open` as above); the window is no longer the app's default target. Errors when the window is not parked |

Keep the process that prepared the display alive for the run. Closing its
`pi-bridge` input restores parked windows. `new_window` presses the prepared
app's New Window menu item and waits for a different window; use it for a new
browser window. An app without that item (Command-N makes a note or an event
there) fails with `<app> has no New Window menu item` and nothing is pressed;
if no new window appears, it fails without repeating the command.

A window `prepare_app` opened, by Dock reopen or `new_window`, is the agent's:
restoring it closes it, since the user never had it. A window the user already
had, or one that appeared because the app was launched, is moved home and left
to the app (a host that launched the app for the run quits it).

Prepared windows remain the default target for that runtime's queries and
input. Observation processes keep separate snapshot indexes; their indexes are
for reading. Resolve an actionable reference with `cua.query` in the runtime.
A separate observation never changes what an existing query index addresses.

## Statement records on pi-bridge

`started` is emitted immediately before executing a statement, with its `cell`,
zero-based `index`, exact `text`, and UTF-8 byte offsets `start` and `end` in the
cell source. `done` carries the same fields after it returns successfully.
These events are emitted during feeds and during the final call. A terminal
failure includes the native error. Prior prints are delivered on failure and
abandonment as well as success. An attempted statement without `done` may have
partially acted; do not replay it automatically.

Statement boundaries come from a real JavaScript parser (acorn, vendored in
`Vendor/AcornJavaScript.swift`, run in its own JavaScriptCore context), so
strings, templates, regex literals, comments and semicolon insertion are handled
exactly as the engine does. A complete statement runs as soon as nothing that
has streamed in could still extend it: `if` waits for a possible `else`, `try`
for `finally`, and an expression without `;` waits until the next token has
fully arrived (`el` may still become `else`). A `;`-terminated statement or a
closed block runs at once. A complete statement followed by a broken literal
still runs. On the final feed everything complete runs, then any leftover
source is executed as-is so JavaScriptCore reports its syntax error.
