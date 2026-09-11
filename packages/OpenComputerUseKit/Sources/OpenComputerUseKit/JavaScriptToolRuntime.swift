#if canImport(JavaScriptCore)
import Foundation
import JavaScriptCore
import OpenComputerUseJavaScriptShim

/// A persistent JavaScriptCore runtime that exposes the Computer Use tools as a
/// synchronous `cua` API, so a model composes a multi-step flow (snapshot, find,
/// act, verify, loop, retry) in one `js` tool call instead of one tool call per
/// action. See docs/references/js-code-tool.md for the rationale.
///
/// The API is synchronous on purpose: every action runs in-process, so no
/// promises or top-level await are needed. Each `js` call runs in its own
/// function scope (via `new Function`), so `let`/`const` never collide across
/// calls; assign to `globalThis` for values that must survive to the next call.
/// Output is produced with `write(...)`; images with `emitImage(base64)`.
final class JavaScriptToolRuntime {
    typealias ToolCaller = (String, [String: Any]) throws -> ToolCallResult
    typealias ElementsProvider = (String) throws -> [[String: Any]]

    private let toolCaller: ToolCaller
    private let elementsProvider: ElementsProvider
    private var context: JSContext
    private var output = ""
    private var images: [Data] = []
    var streamObserver: (([String: Any]) -> Void)?
    private var streamCells: [String: StreamCell] = [:]

    /// One streamed call's record. `source` grows by prefix as the model's tool
    /// call streams; statements are executed the moment they complete, before the
    /// call finishes generating (speculative / streaming tool calling, modelled on
    /// pi_agent_rust's python_tool). Statements share one persistent scope like a
    /// REPL. Full speculation: mutating actions run as they stream, so a diverged
    /// or abandoned stream can leave real effects already applied — the divergence
    /// guard and `abandon` surface that, they cannot undo it.
    private final class StreamCell {
        var id = ""
        var source = ""
        var executed = 0
        var completed = 0
        var finished = false
        var failed = false
        var error: String?
    }

    init(
        toolCaller: @escaping ToolCaller,
        elementsProvider: @escaping ElementsProvider = { _ in [] }
    ) {
        self.toolCaller = toolCaller
        self.elementsProvider = elementsProvider
        self.context = JSContext()
        configure(context)
    }

    func reset() {
        let fresh = JSContext()!
        configure(fresh)
        context = fresh
    }

    func run(code: String, timeoutMs: Int) -> ToolCallResult {
        output = ""
        images = []

        let contextRef = UnsafeMutableRawPointer(context.jsGlobalContextRef)
        ocu_js_set_time_limit(contextRef, Double(max(1, timeoutMs)) / 1000.0)
        defer { ocu_js_clear_time_limit(contextRef) }

        context.exception = nil
        let runner = context.objectForKeyedSubscript("__ocuRun")
        let value = runner?.call(withArguments: [code])

        if let exception = context.exception {
            let message = exception.toString() ?? "JavaScript error"
            var text = output
            if !text.isEmpty { text += "\n" }
            text += "Error: " + message
            var content: [ToolResultContentItem] = [.text(text)]
            content.append(contentsOf: images.map { .pngImage($0) })
            return ToolCallResult(content: content, isError: true)
        }

        var text = output
        if let value, !value.isUndefined, !value.isNull {
            let repr = value.toString() ?? ""
            if !repr.isEmpty, repr != "undefined" {
                if !text.isEmpty { text += "\n" }
                text += repr
            }
        }

        var content: [ToolResultContentItem] = []
        if !text.isEmpty { content.append(.text(text)) }
        content.append(contentsOf: images.map { .pngImage($0) })
        if content.isEmpty { content.append(.text("(no output)")) }
        return ToolCallResult(content: content, isError: false)
    }

    // MARK: streaming / speculative execution

    /// Start a streamed cell; resets the current output sink. Cells share the one
    /// persistent scope, so run them one at a time in call order.
    func beginStream(id: String) {
        output = ""
        images = []
        streamCells[id] = StreamCell()
        streamCells[id]?.id = id
    }

    struct StreamProgress {
        let completed: Int
        let failed: Bool
        let error: String?
    }

    func streamProgress(id: String) -> StreamProgress {
        let cell = streamCells[id]
        return StreamProgress(completed: cell?.completed ?? 0,
            failed: cell?.failed ?? true, error: cell?.error)
    }

    /// Feed the growing `code` prefix; executes every statement that has newly
    /// completed since the last feed. The prefix must only grow. Returns how many
    /// statements have run and whether the cell has failed.
    @discardableResult
    func feedStream(id: String, source: String) -> StreamProgress {
        guard let cell = streamCells[id], !cell.finished, !cell.failed else {
            return streamProgress(id: id)
        }
        guard source.hasPrefix(cell.source) else {
            cell.failed = true
            cell.error = "source diverged; earlier statements may have run"
            return StreamProgress(completed: cell.completed, failed: true, error: cell.error)
        }
        cell.source = source
        executeNewlyComplete(cell, isFinal: false)
        return StreamProgress(completed: cell.completed, failed: cell.failed, error: cell.error)
    }

    /// The full source has arrived: run the trailing statement (if any) and return
    /// the cell's accumulated result.
    func finishStream(id: String, source: String? = nil) -> ToolCallResult {
        guard let cell = streamCells[id] else { return .text("(unknown cell)", isError: true) }
        if !cell.failed {
            if let source {
                if source.hasPrefix(cell.source) {
                    cell.source = source
                } else {
                    cell.failed = true
                    cell.error = "source diverged; earlier statements may have run"
                }
            }
            if !cell.failed {
                cell.finished = true
                executeNewlyComplete(cell, isFinal: true)
            }
        }
        return cellResult(cell)
    }

    /// The host will never deliver this call's final source (skipped/aborted). Any
    /// statements already run stay run; the result says how many.
    func abandonStream(id: String) -> ToolCallResult {
        guard let cell = streamCells[id] else { return .text("(unknown cell)", isError: true) }
        if !cell.finished {
            cell.failed = true
            if cell.error == nil {
                cell.error = "call abandoned after \(cell.completed) statement(s) had run"
            }
        }
        return cellResult(cell)
    }

    private func executeNewlyComplete(_ cell: StreamCell, isFinal: Bool) {
        let chars = Array(cell.source)
        while !cell.failed, cell.executed < chars.count {
            guard let end = nextRunnableUnitEnd(chars, from: cell.executed, isFinal: isFinal) else { break }
            let start = cell.executed
            cell.executed = end
            guard !String(chars[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            evaluateStreamStatement(chars, start: start, end: end, cell: cell)
        }
    }

    /// End index (exclusive) of the next complete top-level unit at `start` that is
    /// ready to run, or nil to wait for more input. An `if`/`try`/`do` block is held
    /// until its `else`/`catch`/`finally`/`while` continuation — or unrelated code,
    /// or the end of the stream — shows the unit is closed, so a half-streamed
    /// branch never runs on its own.
    private func nextRunnableUnitEnd(_ chars: [Character], from start: Int, isFinal: Bool) -> Int? {
        var candidate = start
        while let end = Self.nextStatementEnd(chars, from: candidate) {
            let unit = String(chars[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if unit.isEmpty { return end }                            // blank line: skip past it
            if !syntaxIsComplete(unit) { candidate = end; continue }   // statement spans more lines
            guard Self.blockAcceptsContinuation(unit) else {
                return end                                             // ordinary complete statement
            }
            let rest = Self.followingCode(String(chars[end...]))
            if rest.isEmpty { return isFinal ? end : nil }             // a continuation may still arrive
            if Self.startsWithContinuation(rest) { candidate = end; continue }  // fold it into this unit
            if !isFinal, Self.isPartialContinuation(rest) { return nil }        // keyword still streaming
            return end                                                 // unrelated code follows: block closed
        }
        return isFinal ? chars.count : nil
    }

    private func evaluateStreamStatement(_ chars: [Character], start: Int, end: Int, cell: StreamCell) {
        let statement = String(chars[start..<end])
        let event: [String: Any] = [
            "cell": cell.id, "index": cell.completed, "text": statement,
            "start": String(chars[..<start]).utf8.count, "end": String(chars[..<end]).utf8.count,
        ]
        streamObserver?(event.merging(["type": "started"]) { _, new in new })
        let contextRef = UnsafeMutableRawPointer(context.jsGlobalContextRef)
        ocu_js_set_time_limit(contextRef, 30.0)
        context.exception = nil
        context.evaluateScript(statement)
        ocu_js_clear_time_limit(contextRef)
        if let exception = context.exception {
            cell.failed = true
            cell.error = exception.toString() ?? "JavaScript error"
            return
        }
        cell.completed += 1
        streamObserver?(event.merging(["type": "done"]) { _, new in new })
    }

    private static let blockContinuationKeywords = ["else", "catch", "finally", "while"]

    /// True when a unit opens with `if`/`try`/`do` — the only forms JS may continue
    /// with a trailing else/catch/finally/while, so the only ones worth holding.
    private static func blockAcceptsContinuation(_ unit: String) -> Bool {
        switch String(unit.prefix { $0.isLetter }) {
        case "if", "try", "do": return true
        default: return false
        }
    }

    private static func startsWithContinuation(_ code: String) -> Bool {
        blockContinuationKeywords.contains { keyword in
            code.hasPrefix(keyword) && !isIdentifierCharacter(code.dropFirst(keyword.count).first)
        }
    }

    /// `code` is a nonempty strict prefix of a continuation keyword still streaming in.
    private static func isPartialContinuation(_ code: String) -> Bool {
        blockContinuationKeywords.contains { $0.count > code.count && $0.hasPrefix(code) }
    }

    private static func isIdentifierCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber || character == "_" || character == "$"
    }

    private static func followingCode(_ source: String) -> String {
        var rest = source.trimmingCharacters(in: .whitespacesAndNewlines)
        while rest.hasPrefix("//") || rest.hasPrefix("/*") {
            if rest.hasPrefix("//") {
                guard let newline = rest.firstIndex(of: "\n") else { return "" }
                rest = String(rest[rest.index(after: newline)...])
            } else {
                guard let end = rest.range(of: "*/") else { return "" }
                rest = String(rest[end.upperBound...])
            }
            rest = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return rest
    }

    private func syntaxIsComplete(_ source: String) -> Bool {
        let script = JSStringCreateWithUTF8CString(source)!
        defer { JSStringRelease(script) }
        return JSCheckScriptSyntax(context.jsGlobalContextRef, script, nil, 1, nil)
    }

    private func cellResult(_ cell: StreamCell) -> ToolCallResult {
        var text = output
        if cell.failed, let error = cell.error {
            if !text.isEmpty { text += "\n" }
            text += "Error: " + error
        }
        var content: [ToolResultContentItem] = []
        if !text.isEmpty { content.append(.text(text)) }
        content.append(contentsOf: images.map { .pngImage($0) })
        if content.isEmpty { content.append(.text("(no output)")) }
        return ToolCallResult(content: content, isError: cell.failed)
    }

    /// Index just past the next top-level statement boundary (`;` or newline at
    /// bracket depth 0, outside strings/templates/comments), or nil if the current
    /// prefix has no complete statement left.
    ///
    /// ponytail: naive scanner (does not re-enter string parsing inside `${}`, and
    /// does not distinguish a regex literal from division). Swap for a real JS
    /// parser (meriyah, as Codex bundles) if models hit the edges.
    static func nextStatementEnd(_ chars: [Character], from start: Int) -> Int? {
        var i = start
        var depth = 0
        while i < chars.count {
            let c = chars[i]
            if c == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
                continue
            }
            if c == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                i += 2
                while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i = min(i + 2, chars.count)
                continue
            }
            if c == "\"" || c == "'" {
                i += 1
                while i < chars.count {
                    if chars[i] == "\\" { i += 2; continue }
                    if chars[i] == c { i += 1; break }
                    i += 1
                }
                continue
            }
            if c == "`" {
                i += 1
                while i < chars.count {
                    if chars[i] == "\\" { i += 2; continue }
                    if chars[i] == "`" { i += 1; break }
                    if chars[i] == "$", i + 1 < chars.count, chars[i + 1] == "{" {
                        i += 2
                        var braces = 1
                        while i < chars.count, braces > 0 {
                            if chars[i] == "{" { braces += 1 }
                            else if chars[i] == "}" { braces -= 1 }
                            i += 1
                        }
                        continue
                    }
                    i += 1
                }
                continue
            }
            if c == "(" || c == "[" || c == "{" { depth += 1; i += 1; continue }
            if c == ")" || c == "]" || c == "}" { depth = max(0, depth - 1); i += 1; continue }
            if depth == 0, c == ";" || c == "\n" { return i + 1 }
            i += 1
        }
        return nil
    }

    private func configure(_ ctx: JSContext) {
        ctx.exceptionHandler = { context, exception in
            context?.exception = exception
        }

        let callBlock: @convention(block) (String, String) -> String = { [unowned self] tool, argsJSON in
            self.nativeCall(tool: tool, argsJSON: argsJSON)
        }
        ctx.setObject(callBlock, forKeyedSubscript: "__ocuCall" as NSString)

        let writeBlock: @convention(block) (String) -> Void = { [unowned self] text in
            self.output += text
        }
        ctx.setObject(writeBlock, forKeyedSubscript: "__ocuWrite" as NSString)

        let imageBlock: @convention(block) (String) -> Bool = { [unowned self] base64 in
            guard let data = Data(base64Encoded: base64) else { return false }
            self.images.append(data)
            return true
        }
        ctx.setObject(imageBlock, forKeyedSubscript: "__ocuEmitImage" as NSString)

        let elementsBlock: @convention(block) (String) -> String = { [unowned self] app in
            self.nativeElements(app: app)
        }
        ctx.setObject(elementsBlock, forKeyedSubscript: "__ocuElements" as NSString)

        // Generative UI: the agent emits polished component trees for important steps, and a
        // one-line status narration, streamed to TIDE_UI_FILE for the Tide app to render.
        let uiBlock: @convention(block) (String) -> Void = { json in
            let node = json.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? json
            Self.appendUIRaw(["kind": "ui", "node": node])
        }
        ctx.setObject(uiBlock, forKeyedSubscript: "__ocuUI" as NSString)

        let statusBlock: @convention(block) (String) -> Void = { text in
            Self.appendUIRaw(["kind": "status", "text": text])
        }
        ctx.setObject(statusBlock, forKeyedSubscript: "__ocuStatus" as NSString)

        ctx.evaluateScript(Self.banner)
    }

    private func nativeCall(tool: String, argsJSON: String) -> String {
        if tool == "js" || tool == "js_reset" {
            return Self.errorJSON("tool '\(tool)' cannot be called from inside js")
        }

        let arguments: [String: Any]
        if argsJSON.isEmpty {
            arguments = [:]
        } else if let data = argsJSON.data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            arguments = object
        } else {
            return Self.errorJSON("args for '\(tool)' must be a JSON object")
        }

        let result: ToolCallResult
        do {
            result = try toolCaller(tool, arguments)
        } catch let error as ComputerUseError {
            return Self.errorJSON(error.errorDescription ?? String(describing: error))
        } catch {
            return Self.errorJSON(String(describing: error))
        }

        var text = ""
        var encodedImages: [String] = []
        for item in result.content {
            let type = item.dictionary["type"] as? String
            if type == "text", let value = item.dictionary["text"] as? String {
                if !text.isEmpty { text += "\n" }
                text += value
            } else if type == "image", let value = item.dictionary["data"] as? String {
                encodedImages.append(value)
            }
        }

        let payload: [String: Any] = ["isError": result.isError, "text": text, "images": encodedImages]
        return Self.jsonString(payload)
    }

    private func nativeElements(app: String) -> String {
        let elements: [[String: Any]]
        do {
            elements = try elementsProvider(app)
        } catch let error as ComputerUseError {
            return Self.jsonString(["isError": true, "text": error.errorDescription ?? String(describing: error), "elements": [Any]()])
        } catch {
            return Self.jsonString(["isError": true, "text": String(describing: error), "elements": [Any]()])
        }
        return Self.jsonString(["isError": false, "text": "", "elements": elements])
    }

    private static func errorJSON(_ message: String) -> String {
        jsonString(["isError": true, "text": message, "images": [String]()])
    }

    private static func jsonString(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
            let text = String(data: data, encoding: .utf8) else {
            return "{\"isError\":true,\"text\":\"failed to encode result\",\"images\":[]}"
        }
        return text
    }

    private static func appendUIRaw(_ object: [String: Any]) {
        guard let path = ProcessInfo.processInfo.environment["TIDE_UI_FILE"],
            let data = try? JSONSerialization.data(withJSONObject: object),
            let line = (String(data: data, encoding: .utf8).map { $0 + "\n" })?.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: URL(fileURLWithPath: path))
        }
    }

    private static let banner = """
    globalThis.cua = {
      call: function (tool, args) {
        var raw = __ocuCall(tool, JSON.stringify(args || {}));
        var res = JSON.parse(raw);
        if (res.isError) { throw new Error(res.text || ('tool error: ' + tool)); }
        return res;
      },
      listApps: function () { return this.call('list_apps', {}).text; },
      getAppState: function (app, opts) { return this.call('get_app_state', Object.assign({ app: app }, opts || {})).text; },
      click: function (app, opts) { return this.call('click', Object.assign({ app: app }, opts || {})).text; },
      type: function (app, text, opts) { return this.call('type_text', Object.assign({ app: app, text: text }, opts || {})).text; },
      pressKey: function (app, key, opts) { return this.call('press_key', Object.assign({ app: app, key: key }, opts || {})).text; },
      scroll: function (app, direction, element_index, pages) { return this.call('scroll', { app: app, direction: direction, element_index: element_index, pages: (pages == null ? 1 : pages) }).text; },
      drag: function (app, fromX, fromY, toX, toY) { return this.call('drag', { app: app, from_x: fromX, from_y: fromY, to_x: toX, to_y: toY }).text; },
      setValue: function (app, element_index, value) { return this.call('set_value', { app: app, element_index: element_index, value: value }).text; },
      secondaryAction: function (app, element_index, action) { return this.call('perform_secondary_action', { app: app, element_index: element_index, action: action }).text; },
      screenshot: function (app, opts) { var r = this.call('get_app_state', Object.assign({ app: app }, opts || {})); if (r.images && r.images.length) { __ocuEmitImage(r.images[0]); } return r.text; },
      getState: function (app, opts) {
        var text = this.call('get_app_state', Object.assign({ app: app }, opts || {})).text;
        var res = JSON.parse(__ocuElements(app));
        if (res.isError) { throw new Error(res.text || ('elements failed: ' + app)); }
        return { text: text, elements: res.elements };
      },
      elements: function (app, opts) { return this.getState(app, opts).elements; },
      find: function (app, predicate, opts) {
        var els = this.elements(app, opts);
        for (var i = 0; i < els.length; i++) { if (predicate(els[i])) { return els[i]; } }
        return null;
      },
      findAll: function (app, predicate, opts) { return this.elements(app, opts).filter(predicate); },
      // Targeted native AX lookup: no snapshot, no screenshot. Returns matching
      // controls, each with an `index` usable by the actions above (click,
      // setValue, scroll, secondaryAction). Requires text and/or role.
      // criteria: { text?, role?, exact?, limit?, max_nodes?, window_id? }
      query: function (app, criteria) {
        return JSON.parse(this.call('query', Object.assign({ app: app }, criteria || {})).text);
      }
    };
    globalThis.write = function (value) { __ocuWrite(typeof value === 'string' ? value : JSON.stringify(value, null, 2)); };
    globalThis.emitImage = function (base64) { return __ocuEmitImage(String(base64)); };
    globalThis.console = {
      log: function () { __ocuWrite(Array.prototype.slice.call(arguments).map(function (x) { return typeof x === 'string' ? x : JSON.stringify(x); }).join(' ') + '\\n'); }
    };
    globalThis.console.error = globalThis.console.log;
    globalThis.console.warn = globalThis.console.log;
    globalThis.ui = function (node) { __ocuUI(JSON.stringify(node)); };
    globalThis.status = function (text) { __ocuStatus(String(text)); };
    globalThis.cua.ui = globalThis.ui;
    globalThis.cua.status = globalThis.status;
    globalThis.__ocuRun = function (src) { return (new Function(src))(); };
    """
}
#endif
