# `cua` API reference

All calls are synchronous. `app` is an app name or bundle identifier. Actions
throw an `Error` on a tool failure; catch it where failure is expected.

## Reading state

### `cua.getState(app, opts?) -> { text, elements }`
Reads the app's key window once and returns both the accessibility tree text and
the structured `elements`. Request this full observation when needed; targeted
queries and JavaScript actions do not require it. `opts` accepts the same
fields as the underlying state read (`text_limit`, `max_tree_nodes`,
`max_tree_depth`).

### `cua.elements(app, opts?) -> Element[]`
Just the structured elements. Each element:

```
{
  index: number,        // pass as element_index to actions
  role: string,         // e.g. "AXButton", "AXTextField"
  title?: string,       // visible label
  value?: string,       // current value/text
  identifier?: string,
  bounds?: { x, y, w, h },
  actions?: string[]    // secondary action names
}
```

### `cua.query(app, criteria) -> Element[]`
Find controls directly through AX, without a full snapshot or image.
`criteria` accepts `text`, `role`, `exact`, `limit` (default 20), `max_nodes`
(default 500), and `window_id`. Supply text or role. Matches stay in JavaScript;
pass a match's index to an action. Query indexes stay attached to the same
control across later snapshots. Re-query when that control no longer exists.

### `cua.waitFor(app, criteria, { timeout_ms?, interval_ms? }) -> Element[]`
`cua.query`, repeated until it matches or `timeout_ms` (default 5000, at most
25000) passes; returns `[]` on timeout instead of throwing. Use it after a key
press or click that changes the screen, before the next query.

### `cua.sleep(ms)`
Pause the program up to 10 s.

JavaScript actions return a short status or throw. They do not automatically
capture the tree or image. Several predicted actions can run in one program.

### `cua.find(app, predicate, opts?) -> Element | null`
First element for which `predicate(element)` is true.

### `cua.findAll(app, predicate, opts?) -> Element[]`
Every matching element.

### `cua.getAppState(app, opts?) -> string`
The tree text only (no structured elements).

### `cua.screenshot(app, opts?) -> string`
Returns the tree text and emits the window screenshot into the result.

## Acting

### `cua.click(app, { element_index?, x?, y?, click_method? }) -> string`
Click an element by index (preferred) or by screenshot pixel coordinates.
`click_method` is usually omitted (auto).

### `cua.type(app, text, { key_method? }) -> string`
Type literal text into the focused element.

### `cua.pressKey(app, key, { key_method? }) -> string`
Press a key or chord using xdotool syntax, e.g. `"Return"`, `"super+c"`, `"Tab"`.

### `cua.scroll(app, direction, element_index, pages?) -> string`
Scroll an element up/down/left/right by `pages` (default 1).

### `cua.drag(app, from_x, from_y, to_x, to_y) -> string`
Drag between two screenshot pixel coordinates.

### `cua.setValue(app, element_index, value) -> string`
Set a settable element's value directly — preferred for editable fields. An
empty string clears the field.

### `cua.secondaryAction(app, element_index, action) -> string`
Invoke a secondary accessibility action named in an element's `actions`.

### `cua.listApps() -> string`
Running and recently used apps.

### `cua.call(tool, args) -> { text, images }`
Low-level escape hatch that calls any underlying action by name. Returns text and
any base64 images. Refuses `js` (no re-entry).

### `cua.call("run_intent", { bundle_id, action_id, parameters?, input? }) -> string`
Runs an App Intent by identity and returns its result to the next statement.
`bundle_id` and `action_id` are the inventory's fields; `parameters` are the
intent's own parameter keys; `input` is the Shortcut Input text.

The reply is JSON. `{"installed": true, "output": ...}` is the intent's result.
`{"installed": false, ...}` means macOS needs the generated shortcut added once:
prepare Shortcuts, click Add Shortcut, then call `run_intent` again. Adding is
per action and permanent — later runs go straight through.

## Output helpers

- `write(value)` — append to the result; objects are JSON-stringified.
- `console.log(...)` — same, with a trailing newline.
- `emitImage(base64)` — attach an image to the result.

## Runtime notes

- Synchronous; no `await`. Each call is its own scope; use `globalThis` to
  persist across calls, or `reset: true` to clear.
- Default timeout 30000 ms; raise `timeout_ms` for longer flows.
- macOS only (JavaScriptCore). Requires Accessibility and Screen Recording
  permissions, same as the underlying actions.
