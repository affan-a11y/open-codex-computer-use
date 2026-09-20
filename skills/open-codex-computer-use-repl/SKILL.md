---
name: open-codex-computer-use-repl
description: How to operate a macOS desktop through Open Computer Use's single `js` code tool — composing multi-step UI flows in JavaScript via the `cua` API (getState, find, click, type, verify) in one call instead of one tool call per action. Use whenever the only Computer Use tool exposed is `js`.
---

# Open Computer Use — the `js` REPL

## Overview

On macOS, Open Computer Use exposes exactly one tool: `js`. It runs JavaScript in
a persistent runtime where a `cua` object drives the desktop. You compose a whole
flow — read state, find an element, act, verify, loop, retry — in a single `js`
call, instead of one tool call per action. There is no `click` or `type` tool to
call directly; use `cua.click`, `cua.type`, and the rest from inside `js`.

The runtime is **synchronous**: no promises, no `await`. Every `cua` call returns
when the action has run. Print with `write(value)`; return values are not shown.

## Core workflow

1. Read state first, every turn, before acting — same rule as the underlying
   actions. Prefer structured elements over parsing text:

   ```js
   const { text, elements } = cua.getState("Notes");
   ```

2. Find the target element in code, then act by its index:

   ```js
   const btn = cua.find("Notes", e => e.role === "AXButton" && /new note/i.test(e.title || ""));
   if (!btn) { write("no New Note button\n" + text); }
   else { cua.click("Notes", { element_index: btn.index }); }
   ```

3. Verify by reading state again, in the same call, and branch on it:

   ```js
   cua.type("Notes", "Meeting notes");
   const after = cua.getState("Notes");
   write(after.elements.some(e => (e.value || "").includes("Meeting notes")) ? "typed" : "MISSING");
   ```

4. Loop and retry in code rather than across turns:

   ```js
   for (let i = 0; i < 3; i++) {
     const ok = cua.find("Mail", e => /sent/i.test(e.title || ""));
     if (ok) { write("sent"); break; }
     cua.pressKey("Mail", "super+Return");
   }
   ```

## Say where: scope

A window has layers: the app's own controls (a toolbar, a sidebar, a browser's
address field and tabs), the content inside them (a document, a page, a table), and
whatever is on top (a sheet, a dialog, a popover, a menu). The same label lives in
more than one layer — every browser has a "search" field of its own above a page
that has one too — and criteria name a label and a role, not a place. Name the
place, and name it as tightly as you know it:

```js
cua.app = "com.google.Chrome";
cua.within = null;                                   // the browser's own controls
cua.setValue({ role: "AXTextField", text: "Address and search bar" }, url);
cua.press("Return");
cua.within = { role: "AXWebArea" };                  // from here on: the page
cua.click({ text: "Indicators" });                   // a dialog opens in the page
cua.within = { text: "Indicators, metrics, and strategies" };   // from here on: that dialog
cua.setValue({ role: "AXTextField", text: "Search" }, "RSI");
cua.click({ text: "Relative Strength Index" });
cua.press("Escape");
cua.within = { role: "AXWebArea" };                  // the dialog is gone: back to the page
```

- The tightest container you can name wins: the dialog by its title once you have
  seen it, the sheet by its role, the page when you know nothing else, the whole
  window (`null`) only for the app's own controls.
- Start every part by setting `cua.within`. It persists across calls and turns, so
  a part that assumes the last one's container acts in the wrong place.
- A click that opens a container is followed by lines scoped to it; when it closes,
  set the scope back. `{ ..., within: {...} }` on one criteria scopes one call.
- A scope is matched by the container's own label or role. A role alone is the
  first such container: fine for a page, a sheet, a toolbar; add the text when the
  window holds several tables or groups.
- Scoping is also the fast path and the honest one: the search walks the container
  instead of the window, and a label that is not in it fails loudly instead of
  landing on a look-alike somewhere else.

Native apps work the same way: `{ role: "AXSheet" }` for a save sheet,
`{ role: "AXOutline" }` for a sidebar, `{ role: "AXToolbar" }`, `{ role: "AXTable" }`,
`{ role: "AXPopover" }`, or any group or dialog by its title.

## Output, persistence, timeouts

- `write(value)` appends to the result (objects are JSON-stringified);
  `console.log(...)` adds a newline. `cua.screenshot(app)` shows the window's
  picture to the model and returns the tree text.
- Each `js` call runs in its own scope, so `let`/`const` never collide across
  calls. Assign to `globalThis` to keep a value for the next call. Pass
  `reset: true` in the tool arguments to clear all `globalThis` bindings first.
- Default timeout is 30000 ms; raise `timeout_ms` for longer flows. A runaway
  script is terminated.

## Operating rules

- Treat the desktop as the user's real session. Do not open password managers or
  unrelated private apps unless the task requires it.
- Ask before sending, deleting, purchasing, approving, or uploading — anything
  externally visible.
- Always read state before using an `element_index`; never reuse an index from a
  previous call after the UI changed.
- Prefer `cua.setValue` and element-targeted actions; use coordinate `cua.click`
  / `cua.drag` only when the tree exposes no safer target.
- Catch tool errors where a failure is expected; each `cua` action throws on
  error. An uncaught throw ends the call and is returned as an error.

## The `cua` API

See [references/cua-api.md](references/cua-api.md) for the full surface. Summary:

```
cua.getState(app, opts?)    -> { text, elements }
cua.elements(app, opts?)    -> [{ index, role, title, value, identifier, bounds, actions }]
cua.find(app, e => ...)     -> first match or null
cua.findAll(app, e => ...)  -> all matches
cua.getAppState(app, opts?) -> tree text only
cua.screenshot(app, opts?)  -> tree text; emits the screenshot
cua.click(app, { element_index?, x?, y?, click_method? })
cua.type(app, text, { key_method? })
cua.pressKey(app, key, { key_method? })
cua.scroll(app, direction, element_index, pages?)
cua.drag(app, from_x, from_y, to_x, to_y)
cua.setValue(app, element_index, value)
cua.secondaryAction(app, element_index, action)
cua.listApps()
cua.call(tool, args)        -> { text }   // low-level escape hatch; its image goes to the model
```

## Feeder integration (agent builders)

To drive this runtime with speculative, per-line execution as the model streams the code, an agent runtime speaks the JSONL feeder protocol over `open-computer-use stream`. See [../../docs/references/js-stream-protocol.md](../../docs/references/js-stream-protocol.md). Standard MCP cannot stream partial tool arguments, so this path is for runtimes that own the model loop.
