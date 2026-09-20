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
/// Output is produced with `write(...)`; a picture a tool took goes out as an image block.
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
        /// The `try` blocks the stream is currently inside, outermost first.
        var frames: [TryFrame] = []
    }

    /// One open `try`, held while its body streams: the body's statements run
    /// before the catch is written, so a throw waits here for the handler that
    /// has not arrived yet.
    private final class TryFrame {
        /// UTF-16 offset where the `try` statement begins.
        let start: Int
        init(start: Int) { self.start = start }
        var error: JSValue?
        /// False while a section is skipped: the rest of a thrown-in body, or a
        /// catch with nothing to catch.
        var active = true
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
            content.append(contentsOf: images.map { .jpegImage($0) })
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
        content.append(contentsOf: images.map { .jpegImage($0) })
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
        let scan = StreamStatementParser.shared.scan(remainder, isFinal: isFinal, open: cell.frames.count)
        for op in scan.ops where !cell.failed {
            apply(op, to: cell, through: base + op.end)
        }
        let total = source.utf16.count
        if isFinal, !cell.failed, cell.executed < total, !scan.restIsBlank {
            evaluateStreamStatement(cell, through: total)
        }
    }

    /// One piece of the stream. A statement runs only where no enclosing section
    /// is being skipped; the try's own edges keep its semantics without it.
    private func apply(_ op: StreamStatementParser.Op, to cell: StreamCell, through end: Int) {
        switch op.kind {
        case .run:
            if cell.frames.allSatisfy({ $0.active }) {
                evaluateStreamStatement(cell, through: end)
            } else {
                cell.executed = end
            }
        case .openTry:
            cell.frames.append(TryFrame(start: cell.executed))
            cell.executed = end
        case .startCatch:
            cell.executed = end
            guard let frame = cell.frames.last else { return }
            guard let error = frame.error else {
                frame.active = false  // nothing was thrown: the handler is skipped
                return
            }
            frame.error = nil
            frame.active = true
            // The binding is a global: each statement is evaluated on its own, so a
            // block-scoped `catch (error)` would not reach the next one.
            if !op.name.isEmpty {
                context.setObject(error, forKeyedSubscript: op.name as NSString)
            }
        case .startFinally:
            cell.executed = end
            cell.frames.last?.active = true
        case .close:
            cell.executed = end
            guard let frame = cell.frames.popLast() else { return }
            if let error = frame.error {
                raise(error, in: cell)
            } else if cell.frames.allSatisfy({ $0.active }) {
                completed(cell, from: frame.start, through: end)
            }
        }
    }

    /// A thrown value the innermost open `try` will handle; with none, the cell fails.
    private func raise(_ error: JSValue, in cell: StreamCell) {
        guard let frame = cell.frames.last else {
            cell.failed = true
            cell.error = error.toString() ?? "JavaScript error"
            return
        }
        frame.error = error
        frame.active = false
    }

    /// A `try` statement that ran to its end counts as one completed statement, so
    /// the host sees the whole block run, not only the pieces inside it.
    private func completed(_ cell: StreamCell, from start: Int, through end: Int) {
        let event = statementEvent(cell, from: start, through: end)
        streamObserver?(event.merging(["type": "started"]) { _, new in new })
        cell.completed += 1
        streamObserver?(event.merging(["type": "done"]) { _, new in new })
    }

    /// A statement's identity on the wire: its text and its byte range in the source.
    private func statementEvent(_ cell: StreamCell, from start: Int, through end: Int) -> [String: Any] {
        let source = cell.source
        let startIndex = String.Index(utf16Offset: start, in: source)
        let endIndex = String.Index(utf16Offset: end, in: source)
        return [
            "cell": cell.id, "index": cell.completed, "text": String(source[startIndex..<endIndex]),
            "start": source.utf8.distance(from: source.startIndex, to: startIndex),
            "end": source.utf8.distance(from: source.startIndex, to: endIndex),
        ]
    }

    private func evaluateStreamStatement(_ cell: StreamCell, through end: Int) {
        let source = cell.source
        let statement = String(source[String.Index(utf16Offset: cell.executed, in: source)..<String.Index(utf16Offset: end, in: source)])
        let event = statementEvent(cell, from: cell.executed, through: end)
        cell.executed = end
        streamObserver?(event.merging(["type": "started"]) { _, new in new })
        let contextRef = UnsafeMutableRawPointer(context.jsGlobalContextRef)
        ocu_js_set_time_limit(contextRef, 30.0)
        context.exception = nil
        context.evaluateScript(statement)
        ocu_js_clear_time_limit(contextRef)
        if let exception = context.exception {
            raise(exception, in: cell)
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
        content.append(contentsOf: images.map { .jpegImage($0) })
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
        // A picture never reaches JavaScript: it goes to the model as an image frame, so
        // write() cannot put it into the text output (which pi cuts at 100k characters).
        (res.images || []).forEach(function (i) { __ocuEmitImage(i); });
        return { text: res.text };
      },
      // The app a call acts in when it names none: set cua.app once, then leave it out.
      app: null,
      // Every call took the app first; it still may. A first argument that is not an app
      // (an object, a number, a key, text alone) means the call is on cua.app.
      _app: function (candidate) {
        if (typeof candidate === 'string' && candidate) { return candidate; }
        if (this.app) { return this.app; }
        throw new Error('no app: set cua.app = "<bundle id>" or pass the app first');
      },
      _split: function (args, isApp) {
        // (app, rest...) or (rest...): the caller says which first argument is an app
        var list = Array.prototype.slice.call(args);
        if (list.length && isApp(list)) { return { app: this._app(list[0]), rest: list.slice(1) }; }
        return { app: this._app(null), rest: list };
      },
      _byRole: function (list) { return typeof list[0] === 'string'; },
      _byShape: function (list) { return typeof list[0] === 'string' && list.length > 1 && typeof list[1] !== 'object'; },
      _byPair: function (list) { return typeof list[0] === 'string' && list.length > 1; },
      listApps: function () { return this.call('list_apps', {}).text; },
      getAppState: function () { var a = this._split(arguments, this._byRole); return this.call('get_app_state', Object.assign({ app: a.app }, a.rest[0] || {})).text; },
      screenshot: function () { return this.getAppState.apply(this, arguments); },
      // click({ text? , role?, element_index?, x?, y? }): a control named by criteria is
      // waited for (timeout_ms, default 3000) and clicked; none there is an error.
      click: function () {
        var a = this._split(arguments, this._byRole), opts = a.rest[0] || {};
        var t = this._target(a.app, opts, this._pressable);
        return this.call('click', Object.assign({ app: a.app }, t)).text;
      },
      // Roles an action prefers among the controls a label names: the button over its
      // caption, the field over its label. Anything else only when none of these match.
      _pressable: /button|link|menu|check|radio|tab|row|cell|popup|disclosure|image|toolbar|outline/i,
      _editable: /textfield|textarea|combobox|searchfield|text field|text area/i,
      type: function () { var a = this._split(arguments, this._byPair); return this.call('type_text', Object.assign({ app: a.app, text: a.rest[0] }, a.rest[1] || {})).text; },
      pressKey: function () { var a = this._split(arguments, this._byPair); return this.call('press_key', Object.assign({ app: a.app, key: a.rest[0] }, a.rest[1] || {})).text; },
      press: function () { return this.pressKey.apply(this, arguments); },
      scroll: function () {
        var a = this._split(arguments, function (l) { return typeof l[0] === 'string' && !/^(up|down|left|right)$/.test(l[0]); });
        var r = a.rest;
        return this.call('scroll', { app: a.app, direction: r[0], element_index: this._index(a.app, r[1]), pages: (r[2] == null ? 1 : r[2]) }).text;
      },
      drag: function () { var a = this._split(arguments, this._byRole), r = a.rest; return this.call('drag', { app: a.app, from_x: r[0], from_y: r[1], to_x: r[2], to_y: r[3] }).text; },
      setValue: function () { var a = this._split(arguments, this._byPair), r = a.rest; return this.call('set_value', { app: a.app, element_index: this._index(a.app, r[0], this._editable), value: r[1] }).text; },
      secondaryAction: function () { var a = this._split(arguments, this._byPair), r = a.rest; return this.call('perform_secondary_action', { app: a.app, element_index: this._index(a.app, r[0], this._pressable), action: r[1] }).text; },
      getState: function () {
        var a = this._split(arguments, this._byRole);
        var text = this.call('get_app_state', Object.assign({ app: a.app }, a.rest[0] || {})).text;
        var res = JSON.parse(__ocuElements(a.app));
        if (res.isError) { throw new Error(res.text || ('elements failed: ' + a.app)); }
        return { text: text, elements: res.elements };
      },
      elements: function () { return this.getState.apply(this, arguments).elements; },
      find: function () {
        var a = this._split(arguments, this._byRole), predicate = a.rest[0];
        var els = this.elements(a.app, a.rest[1]);
        for (var i = 0; i < els.length; i++) { if (predicate(els[i])) { return els[i]; } }
        return null;
      },
      findAll: function () { var a = this._split(arguments, this._byRole); return this.elements(a.app, a.rest[1]).filter(a.rest[0]); },
      // Targeted native AX lookup: no snapshot, no screenshot. Returns matching
      // controls, each with an `index` usable by the actions above.
      // criteria: { text?, role?, exact?, limit?, max_nodes?, window_id? }
      // Text names the whole label unless exact: false; a whole-label miss is retried as a
      // substring by the harness ("To" must not match "Photos").
      _criteria: function (criteria) {
        var c = Object.assign({}, criteria || {});
        if (c.text && c.exact == null) { c.exact = true; }
        // cua.within says where every criteria looks until it is set again; a criteria's own wins.
        if (c.within === undefined && this.within) { c.within = this.within; }
        if (!c.within) { delete c.within; }
        return c;
      },
      query: function () {
        var a = this._split(arguments, this._byRole);
        return JSON.parse(this.call('query', Object.assign({ app: a.app }, this._criteria(a.rest[0]))).text);
      },
      sleep: function (ms) { __ocuSleep(Number(ms) || 0); },
      // A control given as criteria is waited for; an index or a record is used as is.
      _index: function (app, control, prefer) {
        if (control && typeof control === 'object') {
          if (control.index != null) { return control.index; }
          return this._target(app, control, prefer).element_index;
        }
        return control;
      },
      _target: function (app, opts, prefer) {
        if (opts.element_index != null || opts.x != null) { return opts; }
        if (opts.index != null) { return Object.assign({}, opts, { element_index: opts.index, index: undefined }); }
        if (!opts.text && !opts.role) { return opts; }
        var criteria = { text: opts.text, role: opts.role, exact: opts.exact, limit: opts.limit, max_nodes: opts.max_nodes, window_id: opts.window_id, within: opts.within };
        var found = this.waitFor(app, criteria, { timeout_ms: opts.timeout_ms != null ? opts.timeout_ms : 3000 });
        var visible = found.filter(function (e) { return e.bounds && e.bounds.w > 0 && e.bounds.h > 0; });
        var hit = null;
        if (prefer && !opts.role) { hit = visible.filter(function (e) { return prefer.test(e.role || ''); })[0] || null; }
        // A press takes a field last: a search field holds the text typed into it, and the
        // result it finds carries the same name.
        if (!hit && prefer === this._pressable) { var field = this._editable; hit = visible.filter(function (e) { return !field.test(e.role || ''); })[0] || null; }
        if (!hit) { hit = visible[0] || null; }
        if (!hit) { throw new Error('no control matching ' + JSON.stringify(criteria) + ' in ' + app); }
        var rest = Object.assign({}, opts);
        delete rest.text; delete rest.role; delete rest.exact; delete rest.limit; delete rest.max_nodes; delete rest.window_id; delete rest.timeout_ms; delete rest.within;
        rest.element_index = hit.index;
        return rest;
      },
      // query, repeated until it matches; [] once the screen has settled without it (the
      // search saw the same nodes for 0.7 s, checked from 1.5 s on) or when timeout_ms
      // (default 5000, 0 queries once) passes. A miss costs seconds, not the whole budget.
      // No query starts past the deadline: one more could reach the statement's 30 s limit.
      waitFor: function () {
        var a = this._split(arguments, this._byRole), criteria = a.rest[0] || {}, opts = a.rest[1];
        var timeout = Math.min(opts && opts.timeout_ms != null ? Number(opts.timeout_ms) : 5000, 25000);
        var every = (opts && opts.interval_ms) || 250;
        var start = Date.now(), until = start + timeout;
        var probe = Object.assign({ app: a.app, probe: true }, this._criteria(criteria));
        var seen = null, since = start;
        var res = JSON.parse(this.call('query', probe).text);
        while (!res.records.length && Date.now() < until) {
          if (res.digest !== seen) { seen = res.digest; since = Date.now(); }
          else if (res.digest && Date.now() - since >= 700 && Date.now() - start >= 1500) { return []; }
          __ocuSleep(Math.min(every, until - Date.now()));
          if (Date.now() >= until) { return []; }
          res = JSON.parse(this.call('query', probe).text);
        }
        return res.records;
      },
      // any([criteria, ...], opts): the first candidate present, polled like waitFor; its
      // records carry `which`, the candidate's position. [] when none came.
      any: function () {
        var a = this._split(arguments, this._byRole), candidates = a.rest[0] || [], opts = a.rest[1];
        var timeout = Math.min(opts && opts.timeout_ms != null ? Number(opts.timeout_ms) : 5000, 25000);
        var start = Date.now(), until = start + timeout, seen = null, since = start;
        for (;;) {
          var digest = null;
          for (var i = 0; i < candidates.length; i++) {
            var res = JSON.parse(this.call('query', Object.assign({ app: a.app, probe: true }, this._criteria(candidates[i]))).text);
            if (res.records.length) { return res.records.map(function (r) { r.which = i; return r; }); }
            if (i === 0) { digest = res.digest; }
          }
          if (digest !== seen) { seen = digest; since = Date.now(); }
          else if (digest && Date.now() - since >= 700 && Date.now() - start >= 1500) { return []; }
          if (Date.now() + 250 >= until) { return []; }
          __ocuSleep(250);
        }
      },
      // Where criteria look: a container's criteria ({role: "AXWebArea"}, {role: "AXSheet"},
      // {text: "Save as"}), or null for the whole window. Set once, like cua.app.
      within: null,
      // Learned intents the host defined for this run: run("name", input) runs one.
      intents: {},
      run: function (name, input) {
        var f = this.intents[name];
        if (!f) { throw new Error('no learned intent named ' + name); }
        return f(input || {});
      }
    };
    globalThis.write = function (value) { __ocuWrite(typeof value === 'string' ? value : JSON.stringify(value, null, 2)); };
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
