import Foundation

public struct ToolDefinition: @unchecked Sendable {
    public let name: String
    public let description: String
    public let annotations: [String: Any]
    public let inputSchema: [String: Any]

    public init(name: String, description: String, annotations: [String: Any], inputSchema: [String: Any]) {
        self.name = name
        self.description = description
        self.annotations = annotations
        self.inputSchema = inputSchema
    }

    public var asDictionary: [String: Any] {
        var dictionary: [String: Any] = [
            "name": name,
            "description": description,
            "inputSchema": inputSchema,
        ]

        if !annotations.isEmpty {
            dictionary["annotations"] = annotations
        }

        return dictionary
    }
}

public enum ToolDefinitions {
    /// The action definitions the `cua` API mirrors. These are NOT advertised
    /// over MCP; they are reached from inside `js`. Kept for schema validation
    /// and documentation.
    public static let discrete: [ToolDefinition] = [
        ToolDefinition(
            name: "click",
            description: "Click an element by index or pixel coordinates from screenshot. This tool is part of plugin `Computer Use`.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "element_index": stringProperty(description: "Element index to click"),
                    "x": numberProperty(description: "X coordinate in screenshot pixel coordinates"),
                    "y": numberProperty(description: "Y coordinate in screenshot pixel coordinates"),
                    "click_count": integerProperty(description: "Number of clicks. Defaults to 1"),
                    "mouse_button": stringProperty(
                        description: "Mouse button to click. Defaults to left.",
                        enumValues: ["left", "right", "middle"]
                    ),
                    "click_method": stringProperty(
                        description: "Click implementation: auto (default), accessibility, app_post, sky_click, or global. Accessibility requires element_index. app_post sends a public event directly to the target app. sky_click uses the macOS SkyLight background window path. Global may move the system pointer and requires OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1.",
                        enumValues: ClickMethod.allCases.map(\.rawValue)
                    ),
                ],
                required: ["app"]
            )
        ),
        ToolDefinition(
            name: "drag",
            description: "Drag from one point to another using pixel coordinates. This tool is part of plugin `Computer Use`.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "from_x": numberProperty(description: "Start X coordinate"),
                    "from_y": numberProperty(description: "Start Y coordinate"),
                    "to_x": numberProperty(description: "End X coordinate"),
                    "to_y": numberProperty(description: "End Y coordinate"),
                ],
                required: ["app", "from_x", "from_y", "to_x", "to_y"]
            )
        ),
        ToolDefinition(
            name: "get_app_state",
            description: "Start an app use session if needed, then get the state of the app's key window and return a screenshot and accessibility tree. This must be called once per assistant turn before interacting with the app. This tool is part of plugin `Computer Use`.",
            annotations: readOnlyAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "text_limit": textLimitProperty(description: "Maximum text characters to return. Use \"max\" for full text. Defaults to 500."),
                    "max_tree_nodes": positiveIntegerProperty(description: "Maximum accessibility tree nodes to render. Defaults to 1200."),
                    "max_tree_depth": positiveIntegerProperty(description: "Maximum accessibility tree depth to render. Defaults to 64."),
                    "window_placement": stringProperty(
                        description: "keep (default) leaves the window where it is. agent_display (macOS) parks the app's window on an invisible display owned by the agent so a covered or other-Space window renders, exposes its full tree and accepts input without touching the user's Space, focus or pointer; the window disappears from the user's desktop until restore or process exit. restore puts it back.",
                        enumValues: WindowPlacement.allCases.map(\.rawValue)
                    ),
                ],
                required: ["app"]
            )
        ),
        ToolDefinition(
            name: "list_apps",
            description: "List the apps on this computer. Returns the set of apps that are currently running, as well as any that have been used in the last 14 days, including details on usage frequency. This tool is part of plugin `Computer Use`.",
            annotations: readOnlyAnnotations(),
            inputSchema: objectSchema(properties: [:], required: [])
        ),
        ToolDefinition(
            name: "perform_secondary_action",
            description: "Invoke a secondary accessibility action exposed by an element. This tool is part of plugin `Computer Use`.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "element_index": stringProperty(description: "Element identifier"),
                    "action": stringProperty(description: "Secondary accessibility action name"),
                ],
                required: ["app", "element_index", "action"]
            )
        ),
        ToolDefinition(
            name: "press_key",
            description: "Press a key or key-combination on the keyboard, including modifier and navigation keys.\n  - This supports xdotool's `key` syntax.\n  - Examples: \"a\", \"Return\", \"Tab\", \"super+c\", \"Up\", \"KP_0\" (for the numpad 0 key). This tool is part of plugin `Computer Use`.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "key": stringProperty(description: "Key or key combination to press"),
                    "key_method": keyMethodProperty(),
                ],
                required: ["app", "key"]
            )
        ),
        ToolDefinition(
            name: "scroll",
            description: "Scroll an element in a direction by a number of pages. This tool is part of plugin `Computer Use`.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "direction": stringProperty(description: "Scroll direction: up, down, left, or right"),
                    "element_index": stringProperty(description: "Element identifier"),
                    "pages": numberProperty(description: "Number of pages to scroll. Fractional values are supported. Defaults to 1"),
                ],
                required: ["app", "element_index", "direction"]
            )
        ),
        ToolDefinition(
            name: "set_value",
            description: "Set the value of a settable accessibility element. This tool is part of plugin `Computer Use`.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "element_index": stringProperty(description: "Element identifier"),
                    "value": stringProperty(description: "Value to assign"),
                ],
                required: ["app", "element_index", "value"]
            )
        ),
        ToolDefinition(
            name: "type_text",
            description: "Type literal text using keyboard input. This tool is part of plugin `Computer Use`.",
            annotations: defaultAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "text": stringProperty(description: "Literal text to type"),
                    "key_method": keyMethodProperty(),
                ],
                required: ["app", "text"]
            )
        ),
        ToolDefinition(
            name: "query",
            description: "Targeted accessibility lookup: find controls in the app's chosen window using native AX search, with no full snapshot or screenshot. Returns matching controls, each with an `index` usable by the element actions (click, set_value, scroll, perform_secondary_action). Requires text and/or role. This tool is part of plugin `Computer Use`.",
            annotations: readOnlyAnnotations(),
            inputSchema: objectSchema(
                properties: [
                    "app": stringProperty(description: "App name or bundle identifier"),
                    "text": stringProperty(description: "Match text in the control's title, description or value. Case-insensitive substring unless exact is true."),
                    "role": stringProperty(description: "Match this accessibility role (the AX prefix is optional, e.g. button or AXButton)"),
                    "exact": [
                        "type": "boolean",
                        "description": "Require a complete text match instead of a substring. Defaults to false.",
                    ],
                    "limit": positiveIntegerProperty(description: "Maximum matches to return. Defaults to 20."),
                    "max_nodes": positiveIntegerProperty(description: "Node cap for the fallback traversal when the app has no native search. Defaults to 500."),
                    "window_id": numberProperty(description: "Search this specific window (CGWindowID) instead of the app's current window."),
                ],
                required: ["app"]
            )
        ),
    ]

    /// The only tool advertised over MCP. Every action is reachable from inside
    /// `js` through the `cua` API (see docs/references/js-code-tool.md).
    public static let all: [ToolDefinition] = [jsTool]

    private static let jsTool = ToolDefinition(
        name: "js",
        description: jsToolDescription,
        annotations: defaultAnnotations(),
        inputSchema: objectSchema(
            properties: [
                "code": stringProperty(description: "JavaScript to run against the initialized `cua` runtime."),
                "timeout_ms": positiveIntegerProperty(description: "Execution timeout in milliseconds. Defaults to 30000."),
                "reset": [
                    "type": "boolean",
                    "description": "Clear all persisted globalThis bindings before running.",
                ],
                "title": stringProperty(description: "Short user-facing description of what the code does."),
            ],
            required: ["code"]
        )
    )
}

private let jsToolDescription = """
The one Computer Use tool. Run JavaScript that drives the desktop through the \
`cua` API, so a whole flow (read state, find an element, act, verify, loop, retry) \
happens in one call instead of one call per action. Get the current state every \
turn before acting, exactly as with the underlying actions.

Runtime: synchronous (no promises, no await) because actions run in-process. \
Print results with write(value); objects are JSON-stringified. console.log works. \
Return values are NOT auto-printed, so \
use write. Each call runs in its own scope, so let/const never collide across \
calls; assign to globalThis to keep a value for the next call. Pass reset:true to \
clear all globalThis bindings first. Default timeout 30000 ms; raise timeout_ms \
for longer flows.

State and elements (prefer these; act by element index):
  cua.getState(app, opts?)   -> { text, elements }   // tree text + structured elements
  cua.elements(app, opts?)   -> [{ index, role, title, value, identifier, bounds, actions }]
  cua.find(app, e => ...)    -> first matching element, or null
  cua.findAll(app, e => ...) -> all matching elements
  cua.getAppState(app, opts?)-> tree text only
  cua.screenshot(app, opts?) -> tree text, and emits the screenshot image

Actions (each throws on a tool error; catch with try/catch):
  cua.click(app, { element_index?, x?, y?, click_method? })
  cua.type(app, text, { key_method? })
  cua.pressKey(app, key, { key_method? })
  cua.scroll(app, direction, element_index, pages?)
  cua.drag(app, from_x, from_y, to_x, to_y)
  cua.setValue(app, element_index, value)
  cua.secondaryAction(app, element_index, action)
  cua.listApps()
  cua.call(tool, args)       // low-level escape hatch: returns { text }; any image the tool took is shown to the model

Speculative path: predict several steps per call. query() finds controls with a \
native AX search and NO snapshot or screenshot, returning an `index` you pass to \
the ordinary actions. Under js, actions do not auto-capture state, so a burst \
runs without a snapshot between steps; call getState/getAppState only when you \
must read a result back.
  cua.query(app, { text?, role?, exact?, limit?, max_nodes?, window_id? })
    -> [{ index, role, title, value, identifier, bounds, actions }]  // title falls back to the AX description
    // requires text and/or role; then e.g. cua.click(app, { element_index: r[0].index })
  cua.waitFor(app, criteria, { timeout_ms?, interval_ms? })
    -> the same matches, polled until found or timeout (default 5000 ms); [] on timeout
An index stays tied to its control for this runtime; re-query after the UI \
changes rather than reusing a stale index.

Example:
  const send = cua.find("Slack", e => e.role === "AXButton" && /send/i.test(e.title || ""));
  if (send) { cua.click("Slack", { element_index: send.index }); }
  else { write("no send button; state:\\n" + cua.getAppState("Slack")); }

This tool is part of plugin `Computer Use`.
"""

private func objectSchema(properties: [String: Any], required: [String]) -> [String: Any] {
    var schema: [String: Any] = [
        "type": "object",
        "properties": properties,
        "additionalProperties": false,
    ]

    if !required.isEmpty {
        schema["required"] = required
    }

    return schema
}

private func defaultAnnotations() -> [String: Any] {
    [
        "destructiveHint": false,
        "openWorldHint": false,
    ]
}

private func readOnlyAnnotations() -> [String: Any] {
    [
        "destructiveHint": false,
        "idempotentHint": true,
        "openWorldHint": false,
        "readOnlyHint": true,
    ]
}

private func keyMethodProperty() -> [String: Any] {
    stringProperty(
        description: "Keyboard delivery: auto (default) or sky_key. sky_key posts authenticated keyboard events through the macOS SkyLight background-window path to the current target window without changing foreground focus. Requires a current on-screen target window from get_app_state.",
        enumValues: KeyMethod.allCases.map(\.rawValue)
    )
}

private func stringProperty(description: String, enumValues: [String]? = nil) -> [String: Any] {
    var property: [String: Any] = [
        "type": "string",
        "description": description,
    ]

    if let enumValues {
        property["enum"] = enumValues
    }

    return property
}

private func integerProperty(description: String) -> [String: Any] {
    [
        "type": "integer",
        "description": description,
    ]
}

private func positiveIntegerProperty(description: String) -> [String: Any] {
    [
        "type": "integer",
        "minimum": 1,
        "description": description,
    ]
}

private func textLimitProperty(description: String) -> [String: Any] {
    [
        "anyOf": [
            [
                "type": "integer",
                "minimum": 1,
            ],
            [
                "type": "string",
                "enum": [SnapshotTextLimit.maxKeyword],
            ],
        ],
        "description": description,
    ]
}

private func numberProperty(description: String) -> [String: Any] {
    [
        "type": "number",
        "description": description,
    ]
}
