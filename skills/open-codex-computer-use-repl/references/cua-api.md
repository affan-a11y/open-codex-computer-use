# `cua` API reference

All calls are synchronous. Set `cua.app = "<bundle id>"` once and leave the app out
of every call; a call may still name an app first (a bundle id or app name) to act
elsewhere for that one call. Actions throw an `Error` on a tool failure.

## Finding controls

### `cua.within = { text?, role? } | null`
Where every criteria looks until it is set again: inside the first container of the
window that the scope names, and nowhere else. `null` (the start) is the whole
window. A window has layers — the app's own controls, its content, a sheet or dialog
on top — and a label alone cannot say which layer is meant: a browser's address
field is "Address and search bar", so "the field named Search" is the browser's
unless the page is named. Say where, as tightly as you know:

```
cua.within = { role: "AXWebArea" };      // the page, not the browser around it
cua.within = { role: "AXSheet" };        // the sheet on top of a Mac window
cua.within = { text: "Save as" };        // a dialog, a group or a table, by its own label
cua.within = { role: "AXToolbar" };      // also AXOutline (a sidebar), AXTable, AXPopover, AXMenu
cua.within = null;                       // the app's own controls again
cua.click({ text: "OK", within: { role: "AXSheet" } });   // for one call; it wins over cua.within
```

- Set it at the top of every part: it outlives the turn, and a part run on its own
  must not inherit another part's container.
- When a click opens a sheet, a dialog, a popover or a picker, scope the lines that
  work in it to it, and set the scope back when it closes.
- A role alone takes the first such container; give its text too when a window has
  several (two tables, several groups).
- Inside a container a search is short and a miss is loud: `query` answers `[]` and
  an action throws. The substring retry never leaves the container.
- A container that is not on screen matches nothing: `waitFor` waits for it like for
  any control.

### `cua.query(criteria) -> Element[]`
Find controls through AX, with no snapshot or image. `criteria`: `text` (the
whole label, case-insensitive: a title, a description, the grey hint an empty field
shows, or a value — except what is typed into a field, which is its content and not
its name; a box with no label of its own is named by the text it holds;
retried as a substring when nothing matches whole, such records carrying
`match: "contains"`; `exact: false` asks for a substring), `role` (the `AX` prefix
optional), `within` (above), `limit` (default 20), `max_nodes` (default 5000),
`window_id`. Supply text or role. Each element:

```
{
  index: number,        // pass as element_index, or pass the element itself
  role: string,         // e.g. "AXButton", "AXTextField"
  subrole?: string,     // the kind of its role: "AXCloseButton", "AXSearchField", "AXOutlineRow"
  title?: string,       // its name; a row or cell with no name of its own gets the words inside it, a field its identifier
  value?: string,       // current value/text
  help?: string,        // its tooltip, when that is not already the title
  state?: string[],     // what holds now, of: "selected", "expanded", "focused", "disabled"
  in?: string,          // the nearest named thing around it: "outline sidebar", "dialog Save as"
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

### `cua.validate(fact)`
Say what must be true on the screen after the step just written, in one short
sentence: `cua.validate("The chart shows the 1 hour timeframe")`. It never waits: a
checker reads the window and judges the fact in the background while the program
goes on. A fact found false is judged once more on a newer read; false again, the
next `cua` call (or the program's end) throws an error that names the fact. Use it
where a control cannot tell you: after a step whose result is a state of the
screen, not a control to wait for. One fact a call, nothing that only holds for a
moment.

### `cua.sleep(ms)`
Pause the program up to 10 s.

## Acting

A control argument is criteria (`{ text, role, exact?, within?, timeout_ms? }`), an element
from a query, or an index. Criteria are waited for (default 3000 ms); among the
visible matches the action takes the control it can act on — `click` a button,
link, row or menu item over a caption, `setValue` a field over its label — unless
`role` says which; none there throws `no control matching …`.

### `cua.click({ text? | role? | element_index? | x?, y?, click_method? }) -> string`
### `cua.type(text, { key_method? }) -> string` — keys go wherever the keyboard focus is and add to what is there; to fill a field, `setValue` it by name.
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
