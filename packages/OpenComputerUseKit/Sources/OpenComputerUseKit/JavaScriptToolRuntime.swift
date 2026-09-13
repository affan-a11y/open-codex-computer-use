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
        let id: String
        init(id: String) { self.id = id }
        var source = ""
        /// UTF-16 offset in `source` up to which statements have run.
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
        streamCells[id] = StreamCell(id: id)
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

    /// Run every statement the parser reports as complete and no longer extendable.
    /// On the final feed, whatever trails the last complete statement runs as-is so
    /// JavaScriptCore surfaces its syntax error.
    private func executeNewlyComplete(_ cell: StreamCell, isFinal: Bool) {
        let source = cell.source
        let base = cell.executed
        let remainder = String(source[String.Index(utf16Offset: base, in: source)...])
        let scan = StreamStatementParser.shared.scan(remainder, isFinal: isFinal)
        for end in scan.ends where !cell.failed {
            evaluateStreamStatement(cell, through: base + end)
        }
        let total = source.utf16.count
        if isFinal, !cell.failed, cell.executed < total, !scan.restIsBlank {
            evaluateStreamStatement(cell, through: total)
        }
    }

    private func evaluateStreamStatement(_ cell: StreamCell, through end: Int) {
        let source = cell.source
        let startIndex = String.Index(utf16Offset: cell.executed, in: source)
        let endIndex = String.Index(utf16Offset: end, in: source)
        let statement = String(source[startIndex..<endIndex])
        cell.executed = end
        let event: [String: Any] = [
            "cell": cell.id, "index": cell.completed, "text": statement,
            "start": source.utf8.distance(from: source.startIndex, to: startIndex),
            "end": source.utf8.distance(from: source.startIndex, to: endIndex),
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

        // A pause inside a statement, for cua.waitFor: the UI needs a beat after a
        // key press or click before its new controls exist. Capped well under the
        // 30 s a streamed statement may run.
        let sleepBlock: @convention(block) (Double) -> Void = { milliseconds in
            Thread.sleep(forTimeInterval: max(0, min(milliseconds, 10_000)) / 1000)
        }
        ctx.setObject(sleepBlock, forKeyedSubscript: "__ocuSleep" as NSString)

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
      },
      sleep: function (ms) { __ocuSleep(Number(ms) || 0); },
      // query, repeated until it matches or timeout_ms (default 5000) passes; [] on timeout.
      waitFor: function (app, criteria, opts) {
        var timeout = Math.min((opts && opts.timeout_ms) || 5000, 25000);
        var every = (opts && opts.interval_ms) || 250;
        var until = Date.now() + timeout;
        for (;;) {
          var found = this.query(app, criteria);
          if (found.length || Date.now() >= until) { return found; }
          __ocuSleep(Math.min(every, Math.max(0, until - Date.now())));
        }
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
