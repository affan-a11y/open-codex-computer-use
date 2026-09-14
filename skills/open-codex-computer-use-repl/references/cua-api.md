# `cua` API reference

All calls are synchronous. Set `cua.app = "<bundle id>"` once and leave the app out
of every call; a call may still name an app first (a bundle id or app name) to act
elsewhere for that one call. Actions throw an `Error` on a tool failure.

## Finding controls

### `cua.query(criteria) -> Element[]`
Find controls through AX, with no snapshot or image. `criteria`: `text`
(case-insensitive substring; a whole-label match with `exact: true`, retried as a
substring when nothing matches whole — such records carry `match: "contains"`),
`role` (the `AX` prefix optional), `limit` (default 20), `max_nodes` (default
1500), `window_id`. Supply text or role. Each element:

```
{
  index: number,        // pass as element_index, or pass the element itself
  role: string,         // e.g. "AXButton", "AXTextField"
  title?: string,       // visible label
  value?: string,       // current value/text
  identifier?: string,
  bounds?: { x, y, w, h },
  actions?: string[]    // secondary action names
}
```

An index stays tied to its control for this runtime; re-query when the control no
longer exists.

### `cua.waitFor(criteria, { timeout_ms?, interval_ms? }) -> Element[]`
`query`, repeated until it matches. Returns `[]` once the screen has settled
without a match (the same nodes for 0.7 s, checked from 1.5 s on) or when
`timeout_ms` (default 5000, at most 25000; 0 queries once) passes. Use it after a
key press or click that changes the screen.

### `cua.any([criteria, ...], { timeout_ms? }) -> Element[]`
The first candidate present, polled like `waitFor`. Records carry `which`, the
candidate's position. `[]` when none came. One call for "the Compose button, or
the New message item, or the Send field".

### `cua.sleep(ms)`
Pause the program up to 10 s.

## Acting

A control argument is criteria (`{ text, role, exact?, timeout_ms? }`), an element
from a query, or an index. Criteria are waited for (default 3000 ms) and the first
match with visible bounds is used; none there throws `no control matching …`.

### `cua.click({ text? | role? | element_index? | x?, y?, click_method? }) -> string`
### `cua.type(text, { key_method? }) -> string` — into the focused element.
### `cua.press(key)` / `cua.pressKey(key)` — xdotool syntax: `"Return"`, `"super+l"`.
### `cua.setValue(control, value) -> string` — preferred for editable fields; `""` clears.
### `cua.secondaryAction(control, action) -> string` — an action named in `actions`.
### `cua.scroll(direction, control, pages?) -> string`
### `cua.drag(from_x, from_y, to_x, to_y) -> string`
### `cua.run(name, input) -> any`
Runs a learned intent the host defined for this run by name (they are listed in
`<app_intents>`), with its `inputs`. Its result feeds the next statement.

### `cua.call(tool, args) -> { text }`
Any underlying action by name. Any image the tool took is shown to the model with
the cell's result, never to the program. Refuses `js`.

`cua.call("run_intent", { bundle_id, action_id, parameters?, input? })` runs an
App Intent from the inventory; the reply is JSON: `{"installed": true, "output":
…}` is its result, `{"installed": false, …}` means macOS needs the generated
shortcut added once (prepare Shortcuts, click Add Shortcut, call again).

`cua.call("restore_prepared_window", { window_id })` puts a parked window back
where the user had it (a window `prepare_app` opened is closed instead);
`close_prepared_window` takes the same argument and closes any parked window.
Both answer `closed <id>` when the window is gone and `still open` when a sheet
holds it.

## Reading state

### `cua.getState(opts?) -> { text, elements }` — the key window's tree text and elements.
### `cua.elements(opts?) -> Element[]`
### `cua.find(predicate, opts?) -> Element | null` / `cua.findAll(predicate, opts?)`
### `cua.getAppState(opts?) -> string` — the tree text only.
### `cua.listApps() -> string`

## Output helpers

- `write(value)` — append to the result; objects are JSON-stringified.
- `console.log(...)` — same, with a trailing newline.

## Runtime notes

- Synchronous; no `await`. Each call is its own scope; `globalThis` persists.
- A statement may run 30 s; `waitFor` and `any` keep under it.
- macOS only (JavaScriptCore). Requires Accessibility and Screen Recording.
