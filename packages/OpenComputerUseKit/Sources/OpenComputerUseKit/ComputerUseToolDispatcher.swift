import CoreGraphics
import Foundation

func normalizedElementIndexArgument(_ value: Any?) -> String? {
    if let string = value as? String {
        return string.isEmpty ? nil : string
    }

    if let integer = value as? Int {
        return String(integer)
    }

    if let number = value as? NSNumber {
        if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
            return nil
        }

        return normalizedElementIndexNumber(number.doubleValue)
    }

    if let double = value as? Double {
        return normalizedElementIndexNumber(double)
    }

    return nil
}

private func normalizedElementIndexNumber(_ value: Double) -> String? {
    guard value.isFinite, value.rounded(.towardZero) == value else {
        return nil
    }

    guard value >= Double(Int.min), value <= Double(Int.max) else {
        return nil
    }

    return String(Int(value))
}

public final class ComputerUseToolDispatcher {
    private let service: ComputerUseService

    public init(service: ComputerUseService = ComputerUseService()) {
        self.service = service
    }

    #if canImport(JavaScriptCore)
    // Actions invoked from JavaScript run in JavaScript-execution mode, so the
    // action path performs no automatic before/after snapshot (Requirement 2 of
    // targeted-ax-speculative-execution.md). Explicit reads (get_app_state) and
    // query still capture / search as usual.
    private lazy var jsRuntime = JavaScriptToolRuntime(
        toolCaller: { [unowned self] name, arguments in
            try self.service.withJavaScriptExecution {
                try self.callTool(name: name, arguments: arguments)
            }
        },
        elementsProvider: { [unowned self] app in
            try self.service.structuredElements(app: app)
        }
    )
    #endif

    // When OPEN_COMPUTER_USE_DEFAULT_BACKGROUND=1, input defaults to SkyLight (no focus/pointer
    // steal) unless the caller specifies a method. Cross-Space/covered windows still use
    // window_placement=agent_display explicitly (see the occlusion note in get_app_state).
    private static var backgroundDefault: Bool {
        ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_DEFAULT_BACKGROUND"] == "1"
    }

    private func resolvedClickMethod(_ arguments: [String: Any]) throws -> ClickMethod {
        if let raw = optionalString("click_method", in: arguments) { return try parseClickMethod(raw) }
        return Self.backgroundDefault ? .skyClick : .auto
    }

    private func resolvedKeyMethod(_ arguments: [String: Any]) throws -> KeyMethod {
        if let raw = optionalString("key_method", in: arguments) { return try parseKeyMethod(raw) }
        return Self.backgroundDefault ? .skyKey : .auto
    }

    public func callTool(name: String, arguments: [String: Any]) throws -> ToolCallResult {
        Self.logStep(name: name, arguments: arguments)
        switch name {
        case "prepare_agent_display":
            return try AgentPreparation.display()
        case "agent_app_catalog":
            return try AgentPreparation.catalog()
        case "prepare_app":
            return try AgentPreparation.app(service: service, query: requireString("app", in: arguments),
                newWindow: arguments["new_window"] as? Bool ?? false)
        case "observe_app":
            guard let id = optionalDouble("window_id", in: arguments), id > 0 else {
                throw ComputerUseError.invalidArguments("observe_app requires window_id")
            }
            return try AgentPreparation.observe(query: requireString("app", in: arguments), windowID: CGWindowID(id))
        case "close_prepared_window":
            guard let id = optionalDouble("window_id", in: arguments), id > 0 else {
                throw ComputerUseError.invalidArguments("close_prepared_window requires window_id")
            }
            try AgentDisplay.shared.close(windowID: CGWindowID(id))
            return ToolCallResult(content: [.text("closed \(Int(id))")])
        case "run_intent":
            return try AppIntentExecution.run(
                bundleID: requireString("bundle_id", in: arguments),
                actionID: requireString("action_id", in: arguments),
                parameters: arguments["parameters"] as? [String: Any] ?? [:],
                input: optionalString("input", in: arguments)
            )
        case "list_apps":
            return service.listApps()
        case "get_app_state":
            return try service.getAppState(
                app: requireString("app", in: arguments),
                textLimit: try optionalTextLimit("text_limit", in: arguments) ?? .defaults,
                treeLimits: AccessibilityTreeLimits.defaults.replacing(
                    maxNodeCount: try optionalPositiveInt("max_tree_nodes", in: arguments),
                    maxDepth: try optionalPositiveInt("max_tree_depth", in: arguments)
                ),
                windowPlacement: try parseWindowPlacement(optionalString("window_placement", in: arguments))
            )
        case "click":
            return try service.click(
                app: requireString("app", in: arguments),
                elementIndex: optionalElementIndex(in: arguments),
                x: optionalDouble("x", in: arguments),
                y: optionalDouble("y", in: arguments),
                clickCount: Int(optionalDouble("click_count", in: arguments) ?? 1),
                mouseButton: optionalString("mouse_button", in: arguments) ?? "left",
                clickMethod: try resolvedClickMethod(arguments)
            )
        case "perform_secondary_action":
            return try service.performSecondaryAction(
                app: requireString("app", in: arguments),
                elementIndex: requireElementIndex(in: arguments),
                action: requireString("action", in: arguments)
            )
        case "scroll":
            return try service.scroll(
                app: requireString("app", in: arguments),
                direction: requireString("direction", in: arguments),
                elementIndex: requireElementIndex(in: arguments),
                pages: optionalDouble("pages", in: arguments) ?? 1
            )
        case "drag":
            return try service.drag(
                app: requireString("app", in: arguments),
                fromX: requireDouble("from_x", in: arguments),
                fromY: requireDouble("from_y", in: arguments),
                toX: requireDouble("to_x", in: arguments),
                toY: requireDouble("to_y", in: arguments)
            )
        case "type_text":
            return try service.typeText(
                app: requireString("app", in: arguments),
                text: requireString("text", in: arguments),
                keyMethod: try resolvedKeyMethod(arguments)
            )
        case "press_key":
            return try service.pressKey(
                app: requireString("app", in: arguments),
                key: requireString("key", in: arguments),
                keyMethod: try resolvedKeyMethod(arguments)
            )
        case "set_value":
            return try service.setValue(
                app: requireString("app", in: arguments),
                elementIndex: requireElementIndex(in: arguments),
                value: requireText("value", in: arguments)
            )
        case "query":
            let records = try service.query(
                app: requireString("app", in: arguments),
                text: optionalString("text", in: arguments),
                role: optionalString("role", in: arguments),
                exact: (arguments["exact"] as? Bool) ?? false,
                limit: try optionalPositiveInt("limit", in: arguments) ?? 20,
                maxNodes: try optionalPositiveInt("max_nodes", in: arguments) ?? 500,
                windowID: optionalDouble("window_id", in: arguments).map { CGWindowID($0) }
            )
            return jsonResult(records)
        case "js":
            #if canImport(JavaScriptCore)
            let code = try requireString("code", in: arguments)
            let timeoutMs = try optionalPositiveInt("timeout_ms", in: arguments) ?? 30000
            if (arguments["reset"] as? Bool) == true {
                jsRuntime.reset()
            }
            return jsRuntime.run(code: code, timeoutMs: timeoutMs)
            #else
            throw ComputerUseError.unsupportedTool("js")
            #endif
        default:
            throw ComputerUseError.unsupportedTool(name)
        }
    }

    private func jsonResult(_ object: Any) -> ToolCallResult {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]),
            let text = String(data: data, encoding: .utf8) else {
            return .text("[]")
        }
        return .text(text)
    }

    // Live agent feedback: append a human-readable line per real action to TIDE_STEPS_FILE
    // (set by the Tide app), which the app tails to show what the agent is doing right now.
    private static func logStep(name: String, arguments: [String: Any]) {
        guard name != "js",
            let path = ProcessInfo.processInfo.environment["TIDE_STEPS_FILE"],
            let line = stepDescription(name: name, arguments: arguments),
            let data = (line + "\n").data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    private static func stepDescription(name: String, arguments: [String: Any]) -> String? {
        let app = (arguments["app"] as? String).map { " · \($0)" } ?? ""
        switch name {
        case "list_apps": return "Looking at open apps"
        case "get_app_state": return "Reading the screen\(app)"
        case "click": return "Clicking\(app)"
        case "type_text":
            let text = (arguments["text"] as? String) ?? ""
            let clip = text.count > 32 ? String(text.prefix(32)) + "…" : text
            return "Typing “\(clip)”\(app)"
        case "press_key": return "Pressing \((arguments["key"] as? String) ?? "key")\(app)"
        case "scroll": return "Scrolling\(app)"
        case "drag": return "Dragging\(app)"
        case "set_value": return "Setting a field\(app)"
        case "perform_secondary_action": return "\((arguments["action"] as? String) ?? "Action")\(app)"
        case "query": return "Finding controls\(app)"
        default: return nil
        }
    }

    public func callToolAsResult(name: String, arguments: [String: Any]) -> ToolCallResult {
        do {
            return try callTool(name: name, arguments: arguments)
        } catch let error as ComputerUseError {
            return ToolCallResult.text(
                error.errorDescription ?? String(describing: error),
                isError: error.toolResultIsError
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            return ToolCallResult.text(message, isError: true)
        }
    }

    // MARK: streaming / speculative execution (feeder protocol backend)

    public struct StreamProgress {
        public let completed: Int
        public let failed: Bool
        public let error: String?
    }

    public var streamObserver: (([String: Any]) -> Void)? {
        get {
            #if canImport(JavaScriptCore)
            return jsRuntime.streamObserver
            #else
            return nil
            #endif
        }
        set {
            #if canImport(JavaScriptCore)
            jsRuntime.streamObserver = newValue
            #endif
        }
    }

    public func streamBegin(id: String) {
        #if canImport(JavaScriptCore)
        jsRuntime.beginStream(id: id)
        #endif
    }

    @discardableResult
    public func streamFeed(id: String, source: String) -> StreamProgress {
        #if canImport(JavaScriptCore)
        let progress = jsRuntime.feedStream(id: id, source: source)
        return StreamProgress(completed: progress.completed, failed: progress.failed, error: progress.error)
        #else
        return StreamProgress(completed: 0, failed: true, error: "js streaming is unavailable on this platform")
        #endif
    }

    public func streamProgress(id: String) -> StreamProgress {
        #if canImport(JavaScriptCore)
        let progress = jsRuntime.streamProgress(id: id)
        return StreamProgress(completed: progress.completed, failed: progress.failed, error: progress.error)
        #else
        return StreamProgress(completed: 0, failed: true, error: "js streaming is unavailable on this platform")
        #endif
    }

    public func streamFinish(id: String, source: String?) -> ToolCallResult {
        #if canImport(JavaScriptCore)
        return jsRuntime.finishStream(id: id, source: source)
        #else
        return ToolCallResult.text("js streaming is unavailable on this platform", isError: true)
        #endif
    }

    public func streamAbandon(id: String) -> ToolCallResult {
        #if canImport(JavaScriptCore)
        return jsRuntime.abandonStream(id: id)
        #else
        return ToolCallResult.text("js streaming is unavailable on this platform", isError: true)
        #endif
    }

    public func streamReset() {
        #if canImport(JavaScriptCore)
        jsRuntime.reset()
        #endif
    }

    private func requireString(_ key: String, in arguments: [String: Any]) throws -> String {
        guard let value = arguments[key] as? String, !value.isEmpty else {
            throw ComputerUseError.missingArgument(key)
        }

        return value
    }

    /// A string that may be empty: setting a field to "" is how it is cleared.
    private func requireText(_ key: String, in arguments: [String: Any]) throws -> String {
        guard let value = arguments[key] as? String else {
            throw ComputerUseError.missingArgument(key)
        }
        return value
    }

    private func optionalString(_ key: String, in arguments: [String: Any]) -> String? {
        arguments[key] as? String
    }

    private func optionalTextLimit(_ key: String, in arguments: [String: Any]) throws -> SnapshotTextLimit? {
        guard let value = arguments[key] else {
            return nil
        }

        if let string = value as? String {
            guard string.lowercased() == SnapshotTextLimit.maxKeyword else {
                throw ComputerUseError.invalidArguments("\(key) must be a positive integer or max")
            }
            return .max
        }

        let maxCount = try positiveInt(from: value, key: key, expectedDescription: "a positive integer or max")
        return SnapshotTextLimit(maxCount: maxCount)
    }

    private func requireElementIndex(in arguments: [String: Any]) throws -> String {
        guard let value = optionalElementIndex(in: arguments) else {
            throw ComputerUseError.missingArgument("element_index")
        }

        return value
    }

    private func optionalElementIndex(in arguments: [String: Any]) -> String? {
        normalizedElementIndexArgument(arguments["element_index"])
    }

    private func requireDouble(_ key: String, in arguments: [String: Any]) throws -> Double {
        guard let value = optionalDouble(key, in: arguments) else {
            throw ComputerUseError.missingArgument(key)
        }

        return value
    }

    private func optionalDouble(_ key: String, in arguments: [String: Any]) -> Double? {
        if let double = arguments[key] as? Double {
            return double
        }

        if let integer = arguments[key] as? Int {
            return Double(integer)
        }

        if let number = arguments[key] as? NSNumber {
            return number.doubleValue
        }

        return nil
    }

    private func optionalPositiveInt(_ key: String, in arguments: [String: Any]) throws -> Int? {
        guard let value = arguments[key] else {
            return nil
        }

        return try positiveInt(from: value, key: key, expectedDescription: "a positive integer")
    }

    private func positiveInt(from value: Any, key: String, expectedDescription: String) throws -> Int {
        if let integer = value as? Int {
            return try validatePositiveInt(integer, key: key, expectedDescription: expectedDescription)
        }

        if let double = value as? Double {
            return try validatePositiveWholeNumber(double, key: key, expectedDescription: expectedDescription)
        }

        if let number = value as? NSNumber {
            if CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() {
                throw ComputerUseError.invalidArguments("\(key) must be \(expectedDescription)")
            }
            return try validatePositiveWholeNumber(number.doubleValue, key: key, expectedDescription: expectedDescription)
        }

        throw ComputerUseError.invalidArguments("\(key) must be \(expectedDescription)")
    }

    private func validatePositiveWholeNumber(_ value: Double, key: String, expectedDescription: String) throws -> Int {
        guard value.isFinite, value.rounded(.towardZero) == value else {
            throw ComputerUseError.invalidArguments("\(key) must be \(expectedDescription)")
        }

        guard value >= Double(Int.min), value <= Double(Int.max) else {
            throw ComputerUseError.invalidArguments("\(key) is outside the supported integer range")
        }

        return try validatePositiveInt(Int(value), key: key, expectedDescription: expectedDescription)
    }

    private func validatePositiveInt(_ value: Int, key: String, expectedDescription: String) throws -> Int {
        guard value > 0 else {
            throw ComputerUseError.invalidArguments("\(key) must be \(expectedDescription)")
        }
        return value
    }
}

public struct OpenComputerUseCallSpec {
    public let tool: String
    public let arguments: [String: Any]

    public init(tool: String, arguments: [String: Any]) {
        self.tool = tool
        self.arguments = arguments
    }
}

public struct OpenComputerUseCallOutput {
    public let jsonObject: Any
    public let hasToolError: Bool

    public init(jsonObject: Any, hasToolError: Bool) {
        self.jsonObject = jsonObject
        self.hasToolError = hasToolError
    }

    public func jsonText() throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: jsonObject,
            options: [.prettyPrinted, .withoutEscapingSlashes]
        )
        guard let text = String(data: data, encoding: .utf8) else {
            throw ComputerUseError.message("Failed to encode call output as JSON.")
        }
        return text
    }
}

public typealias OpenComputerUseSleepHandler = (TimeInterval) -> Void

public func runOpenComputerUseCall(
    _ invocation: OpenComputerUseCallInvocation,
    service: ComputerUseService = ComputerUseService(),
    sleepHandler: OpenComputerUseSleepHandler = { Thread.sleep(forTimeInterval: $0) }
) throws -> OpenComputerUseCallOutput {
    let dispatcher = ComputerUseToolDispatcher(service: service)

    switch invocation {
    case let .single(toolName, argumentsJSON, argumentsFile):
        let arguments = try readOpenComputerUseToolArguments(
            json: argumentsJSON,
            file: argumentsFile
        )
        let result = dispatcher.callToolAsResult(name: toolName, arguments: arguments)
        return OpenComputerUseCallOutput(
            jsonObject: result.asDictionary,
            hasToolError: result.isError
        )

    case let .sequence(callsJSON, callsFile, interCallDelay):
        let calls = try readOpenComputerUseCallSequence(json: callsJSON, file: callsFile)
        var outputs: [[String: Any]] = []
        var hasToolError = false

        for (index, call) in calls.enumerated() {
            let result = dispatcher.callToolAsResult(name: call.tool, arguments: call.arguments)
            outputs.append([
                "tool": call.tool,
                "result": result.asDictionary,
            ])

            if result.isError {
                hasToolError = true
                break
            }

            if index < calls.count - 1, interCallDelay > 0 {
                sleepHandler(interCallDelay)
            }
        }

        return OpenComputerUseCallOutput(jsonObject: outputs, hasToolError: hasToolError)
    }
}

public func readOpenComputerUseToolArguments(
    json: String?,
    file: String?
) throws -> [String: Any] {
    guard let source = try readOpenComputerUseJSONSource(json: json, file: file) else {
        return [:]
    }

    let object = try decodeOpenComputerUseJSONObject(source)
    guard let arguments = object as? [String: Any] else {
        throw OpenComputerUseCLIError(message: "--args must be a JSON object", helpCommand: "call")
    }

    return arguments
}

public func readOpenComputerUseCallSequence(
    json: String?,
    file: String?
) throws -> [OpenComputerUseCallSpec] {
    guard let source = try readOpenComputerUseJSONSource(json: json, file: file) else {
        throw OpenComputerUseCLIError(message: "call sequence requires --calls or --calls-file", helpCommand: "call")
    }

    let object = try decodeOpenComputerUseJSONObject(source)
    guard let array = object as? [Any] else {
        throw OpenComputerUseCLIError(message: "--calls must be a JSON array", helpCommand: "call")
    }

    return try array.enumerated().map { index, item in
        guard let dictionary = item as? [String: Any] else {
            throw OpenComputerUseCLIError(
                message: "call sequence item #\(index + 1) must be a JSON object",
                helpCommand: "call"
            )
        }

        guard let tool = (dictionary["tool"] ?? dictionary["name"]) as? String, !tool.isEmpty else {
            throw OpenComputerUseCLIError(
                message: "call sequence item #\(index + 1) requires a non-empty tool",
                helpCommand: "call"
            )
        }

        let rawArguments = dictionary["args"] ?? dictionary["arguments"] ?? [:]
        guard let arguments = rawArguments as? [String: Any] else {
            throw OpenComputerUseCLIError(
                message: "call sequence item #\(index + 1) args must be a JSON object",
                helpCommand: "call"
            )
        }

        return OpenComputerUseCallSpec(tool: tool, arguments: arguments)
    }
}

private func readOpenComputerUseJSONSource(json: String?, file: String?) throws -> String? {
    if json != nil, file != nil {
        throw OpenComputerUseCLIError(message: "Use either inline JSON or a JSON file, not both", helpCommand: "call")
    }

    if let json {
        return json
    }

    guard let file else {
        return nil
    }

    do {
        return try String(contentsOfFile: file, encoding: .utf8)
    } catch {
        throw OpenComputerUseCLIError(
            message: "Unable to read JSON file \(file): \(error.localizedDescription)",
            helpCommand: "call"
        )
    }
}

private func decodeOpenComputerUseJSONObject(_ source: String) throws -> Any {
    guard let data = source.data(using: .utf8) else {
        throw OpenComputerUseCLIError(message: "JSON input must be UTF-8 text", helpCommand: "call")
    }

    do {
        return try JSONSerialization.jsonObject(with: data)
    } catch {
        throw OpenComputerUseCLIError(
            message: "Invalid JSON input: \(error.localizedDescription)",
            helpCommand: "call"
        )
    }
}
