#if canImport(JavaScriptCore)
import XCTest
@testable import OpenComputerUseKit

final class JavaScriptToolRuntimeTests: XCTestCase {
    private func runtime(
        _ caller: @escaping JavaScriptToolRuntime.ToolCaller = { _, _ in .text("ok") },
        elements: @escaping JavaScriptToolRuntime.ElementsProvider = { _ in [] }
    ) -> JavaScriptToolRuntime {
        JavaScriptToolRuntime(toolCaller: caller, elementsProvider: elements)
    }

    private func sampleElements() -> [[String: Any]] {
        [
            ["index": 0, "role": "AXButton", "title": "Send", "bounds": ["x": 1.0, "y": 2.0, "w": 3.0, "h": 4.0]],
            ["index": 1, "role": "AXTextField", "title": "Message", "value": "hi"],
            ["index": 2, "role": "AXButton", "title": "Cancel"],
        ]
    }

    func testWriteProducesText() {
        let result = runtime().run(code: "write(\"hello\"); write(\" world\");", timeoutMs: 5000)
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.primaryText, "hello world")
    }

    func testConsoleLog() {
        let result = runtime().run(code: "console.log(\"a\", 1);", timeoutMs: 5000)
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.primaryText, "a 1\n")
    }

    func testCuaCallReachesTheToolCaller() {
        var seen: (String, [String: Any])?
        let rt = runtime { tool, args in
            seen = (tool, args)
            return .text("APP LIST")
        }
        let result = rt.run(code: "write(cua.listApps());", timeoutMs: 5000)
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.primaryText, "APP LIST")
        XCTAssertEqual(seen?.0, "list_apps")
    }

    func testCuaForwardsArguments() {
        var seen: [String: Any]?
        let rt = runtime { tool, args in
            if tool == "click" { seen = args }
            return .text("clicked")
        }
        _ = rt.run(code: "cua.click(\"Notes\", { element_index: \"7\" });", timeoutMs: 5000)
        XCTAssertEqual(seen?["app"] as? String, "Notes")
        XCTAssertEqual(seen?["element_index"] as? String, "7")
    }

    func testQueryParsesRecordsAndPassesCriteria() {
        var seen: [String: Any]?
        let rt = runtime { tool, args in
            if tool == "query" {
                seen = args
                return .text("[{\"index\":1000001,\"role\":\"AXButton\",\"title\":\"New Note\"}]")
            }
            return .text("")
        }
        let result = rt.run(
            code: "const r = cua.query(\"Notes\", { text: \"note\", role: \"AXButton\" }); write(r[0].index + \"|\" + r.length);",
            timeoutMs: 5000
        )
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.primaryText, "1000001|1")
        XCTAssertEqual(seen?["app"] as? String, "Notes")
        XCTAssertEqual(seen?["role"] as? String, "AXButton")
        XCTAssertEqual(seen?["text"] as? String, "note")
    }

    func testQueriedIndexFlowsIntoExistingClick() {
        var clickArgs: [String: Any]?
        let rt = runtime { tool, args in
            if tool == "query" { return .text("[{\"index\":1000002,\"role\":\"AXButton\"}]") }
            if tool == "click" { clickArgs = args }
            return .text("ok")
        }
        _ = rt.run(
            code: "const r = cua.query(\"Notes\", { role: \"AXButton\" }); cua.click(\"Notes\", { element_index: r[0].index });",
            timeoutMs: 5000
        )
        XCTAssertEqual(clickArgs?["app"] as? String, "Notes")
        XCTAssertEqual(clickArgs?["element_index"] as? Int, 1000002)
    }

    func testToolErrorBecomesAThrownError() {
        let rt = runtime { _, _ in .text("no such window", isError: true) }
        let result = rt.run(code: "cua.click(\"Ghost\");", timeoutMs: 5000)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.primaryText?.contains("no such window") ?? false)
    }

    func testCatchableToolError() {
        let rt = runtime { _, _ in .text("boom", isError: true) }
        let result = rt.run(
            code: "try { cua.click(\"X\"); } catch (e) { write(\"caught: \" + e.message); }",
            timeoutMs: 5000
        )
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.primaryText, "caught: boom")
    }

    func testRecursionGuardRejectsJs() {
        let result = runtime().run(code: "cua.call(\"js\", { code: \"1\" });", timeoutMs: 5000)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.primaryText?.contains("cannot be called from inside js") ?? false)
    }

    func testGlobalThisPersistsAcrossCalls() {
        let rt = runtime()
        _ = rt.run(code: "globalThis.counter = 41;", timeoutMs: 5000)
        let result = rt.run(code: "write(String(globalThis.counter + 1));", timeoutMs: 5000)
        XCTAssertEqual(result.primaryText, "42")
    }

    func testResetClearsBindings() {
        let rt = runtime()
        _ = rt.run(code: "globalThis.keep = 1;", timeoutMs: 5000)
        rt.reset()
        let result = rt.run(code: "write(String(globalThis.keep));", timeoutMs: 5000)
        XCTAssertEqual(result.primaryText, "undefined")
    }

    func testLetDoesNotCollideAcrossCalls() {
        let rt = runtime()
        _ = rt.run(code: "let x = 1; write(String(x));", timeoutMs: 5000)
        let result = rt.run(code: "let x = 2; write(String(x));", timeoutMs: 5000)
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.primaryText, "2")
    }

    func testTimeoutTerminatesRunawayScript() {
        let result = runtime().run(code: "while (true) {}", timeoutMs: 300)
        XCTAssertTrue(result.isError)
    }

    func testGetStateReturnsTextAndElements() {
        let rt = runtime({ _, _ in .text("TREE") }, elements: { _ in self.sampleElements() })
        let result = rt.run(
            code: "const s = cua.getState(\"X\"); write(s.text + \"|\" + s.elements.length);",
            timeoutMs: 5000
        )
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.primaryText, "TREE|3")
    }

    func testFindMatchesByPredicate() {
        let rt = runtime({ _, _ in .text("TREE") }, elements: { _ in self.sampleElements() })
        let result = rt.run(
            code: "const b = cua.find(\"X\", e => e.role === \"AXButton\" && /send/i.test(e.title || \"\")); write(String(b.index));",
            timeoutMs: 5000
        )
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.primaryText, "0")
    }

    func testFindAllFiltersElements() {
        let rt = runtime({ _, _ in .text("TREE") }, elements: { _ in self.sampleElements() })
        let result = rt.run(
            code: "write(String(cua.findAll(\"X\", e => e.role === \"AXButton\").length));",
            timeoutMs: 5000
        )
        XCTAssertEqual(result.primaryText, "2")
    }

    func testElementsErrorPropagates() {
        let rt = runtime({ _, _ in .text("TREE") }, elements: { _ in throw ComputerUseError.appNotFound("Ghost") })
        let result = rt.run(code: "cua.elements(\"Ghost\");", timeoutMs: 5000)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.primaryText?.contains("Ghost") ?? false)
    }

    // MARK: streaming / speculative execution

    func testStreamRunsStatementsAsPrefixGrows() {
        var calls: [String] = []
        let rt = runtime { tool, args in
            if tool == "type_text" { calls.append(args["text"] as? String ?? "") }
            return .text("ok")
        }
        rt.beginStream(id: "c1")
        rt.feedStream(id: "c1", source: "cua.type(\"X\", \"a\");\n")
        XCTAssertEqual(calls, ["a"])  // ran before the call finished
        rt.feedStream(id: "c1", source: "cua.type(\"X\", \"a\");\ncua.type(\"X\", \"b\");\n")
        XCTAssertEqual(calls, ["a", "b"])
        let result = rt.finishStream(id: "c1")
        XCTAssertFalse(result.isError)
    }

    func testStreamFinalTrailingStatementRuns() {
        let rt = runtime()
        rt.beginStream(id: "c1")
        rt.feedStream(id: "c1", source: "write(\"x\")")  // no terminator yet
        let result = rt.finishStream(id: "c1")
        XCTAssertEqual(result.primaryText, "x")
    }

    func testStreamSharedScopeAcrossStatements() {
        let rt = runtime()
        rt.beginStream(id: "c1")
        rt.feedStream(id: "c1", source: "globalThis.n = 5;\n")
        let result = rt.finishStream(id: "c1", source: "globalThis.n = 5;\nwrite(String(globalThis.n + 1));\n")
        XCTAssertEqual(result.primaryText, "6")
    }

    func testStreamDivergenceFailsAfterEffects() {
        var calls = 0
        let rt = runtime { tool, _ in
            if tool == "type_text" { calls += 1 }
            return .text("ok")
        }
        rt.beginStream(id: "c1")
        rt.feedStream(id: "c1", source: "cua.type(\"X\", \"a\");\n")
        XCTAssertEqual(calls, 1)
        rt.feedStream(id: "c1", source: "cua.type(\"X\", \"b\");\n")  // not a prefix of prior
        let result = rt.finishStream(id: "c1")
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.primaryText?.contains("diverged") ?? false)
        XCTAssertEqual(calls, 1)  // the already-run effect stays run
    }

    func testStreamAbandonReportsStatementsRun() {
        let rt = runtime()
        rt.beginStream(id: "c1")
        rt.feedStream(id: "c1", source: "write(\"a\");\n")
        let result = rt.abandonStream(id: "c1")
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.primaryText?.contains("abandoned after 1") ?? false)
    }

    func testStreamStatementErrorStopsRemaining() {
        var typed = 0
        let rt = runtime { tool, _ in
            if tool == "type_text" { typed += 1 }
            return .text("ok")
        }
        rt.beginStream(id: "c1")
        // second statement throws; a later feed must not run more
        rt.feedStream(id: "c1", source: "cua.type(\"X\",\"a\");\nthrow new Error(\"boom\");\n")
        rt.feedStream(id: "c1", source: "cua.type(\"X\",\"a\");\nthrow new Error(\"boom\");\ncua.type(\"X\",\"c\");\n")
        let result = rt.finishStream(id: "c1")
        XCTAssertTrue(result.isError)
        XCTAssertEqual(typed, 1)
    }

    func testStreamSemicolonClosesCompoundStatementPromptly() {
        let rt = runtime()
        rt.beginStream(id: "c1")
        XCTAssertEqual(rt.feedStream(id: "c1", source: "if (true) { globalThis.p = 1 };\n").completed, 1)
        XCTAssertEqual(rt.feedStream(id: "c1", source: "if (true) { globalThis.p = 1 };\ndo { globalThis.p += 1 } while (globalThis.p < 3);\n").completed, 2)
        XCTAssertEqual(rt.finishStream(id: "c1", source: "if (true) { globalThis.p = 1 };\ndo { globalThis.p += 1 } while (globalThis.p < 3);\nwrite(globalThis.p);").primaryText, "3")
    }

    func testStreamBracelessIfWaitsForElse() {
        let rt = runtime()
        rt.beginStream(id: "c1")
        XCTAssertEqual(rt.feedStream(id: "c1", source: "if (false) globalThis.q = 1;\n").completed, 0)
        XCTAssertEqual(rt.feedStream(id: "c1", source: "if (false) globalThis.q = 1;\nelse globalThis.q = 2;\n").completed, 1)
        let result = rt.finishStream(id: "c1", source: "if (false) globalThis.q = 1;\nelse globalThis.q = 2;\nwrite(globalThis.q);")
        XCTAssertEqual(result.primaryText, "2")
    }

    func testStreamWhileIsNotFoldedIntoAnIf() {
        let rt = runtime()
        rt.beginStream(id: "c1")
        let source = "if (true) { globalThis.w = 1; }\nwhile (globalThis.w < 3) { globalThis.w += 1; }\n"
        XCTAssertEqual(rt.feedStream(id: "c1", source: source).completed, 2)
    }

    func testStreamCommentOnlyLinesAreNotStatements() {
        let rt = runtime()
        rt.beginStream(id: "c1")
        XCTAssertEqual(rt.feedStream(id: "c1", source: "// plan\n/* multi\nline */\nwrite('a');\n").completed, 1)
    }

    func testStreamMultiLineStatementRunsOnceComplete() {
        var seen: [String: Any]?
        let rt = runtime { tool, args in
            if tool == "query" { seen = args }
            return .text("[]")
        }
        rt.beginStream(id: "c1")
        XCTAssertEqual(rt.feedStream(id: "c1", source: "cua.query(\"Notes\", {\n  text: \"a;b\",\n").completed, 0)
        XCTAssertEqual(rt.feedStream(id: "c1", source: "cua.query(\"Notes\", {\n  text: \"a;b\",\n  role: \"AXButton\"\n});\n").completed, 1)
        XCTAssertEqual(seen?["text"] as? String, "a;b")
    }

    func testStreamContinuationLinesStayOneStatement() {
        let rt = runtime()
        rt.beginStream(id: "c1")
        XCTAssertEqual(rt.feedStream(id: "c1", source: "globalThis.v = 8\n").completed, 0)  // next token unknown yet
        XCTAssertEqual(rt.feedStream(id: "c1", source: "globalThis.v = 8\n  / 2\n  / 2\nglobalThis.s = [1, 2]\n  .map(function (n) { return n * 2 })\n  .join('|')\nglobalThis.t = 1\n").completed, 2)
        let result = rt.finishStream(id: "c1", source: "globalThis.v = 8\n  / 2\n  / 2\nglobalThis.s = [1, 2]\n  .map(function (n) { return n * 2 })\n  .join('|')\nglobalThis.t = 1\nwrite(globalThis.v + ' ' + globalThis.s + ' ' + globalThis.t);")
        XCTAssertEqual(result.primaryText, "2 2|4 1")
    }

    func testStreamRegexAndTemplateLiteralsAreOpaque() {
        let rt = runtime()
        rt.beginStream(id: "c1")
        let source = "globalThis.r = /[;}]\\/{/.test('};/{') ? 'y' : 'n';\nglobalThis.u = `a${ '}' + `${ '{' }` };`;\nglobalThis.q = 4 / 2 / 1;\n"
        XCTAssertEqual(rt.feedStream(id: "c1", source: source).completed, 3)
        XCTAssertEqual(rt.finishStream(id: "c1", source: source + "write(globalThis.r + globalThis.u + globalThis.q);").primaryText, "ya}{;2")
    }

    func testStreamHoldsPartialContinuationKeyword() {
        let rt = runtime()
        rt.beginStream(id: "c1")
        XCTAssertEqual(rt.feedStream(id: "c1", source: "globalThis.k = 0;\nif (true) { globalThis.k = 1; }\nel").completed, 1)
        XCTAssertEqual(rt.feedStream(id: "c1", source: "globalThis.k = 0;\nif (true) { globalThis.k = 1; }\nelsewhere = 2;\n").completed, 3)
        XCTAssertEqual(rt.finishStream(id: "c1", source: "globalThis.k = 0;\nif (true) { globalThis.k = 1; }\nelsewhere = 2;\nwrite(globalThis.k + elsewhere);").primaryText, "3")
    }

    func testStreamRunsCompleteStatementBeforeBrokenLiteral() {
        let rt = runtime()
        rt.beginStream(id: "c1")
        XCTAssertEqual(rt.feedStream(id: "c1", source: "globalThis.a = 1;\nglobalThis.b = \"unterminated").completed, 1)
        let result = rt.finishStream(id: "c1")
        XCTAssertTrue(result.isError)
        XCTAssertEqual(rt.run(code: "write(globalThis.a);", timeoutMs: 5000).primaryText, "1")
    }

    func testStreamFollowsJavaScriptSemicolonInsertion() {
        let rt = runtime()
        rt.beginStream(id: "c1")
        let source = "globalThis.f = function (s) { return /a;b/.test(s) }\nglobalThis.c = 1\nglobalThis.c\n++globalThis.c\n"
        XCTAssertEqual(rt.feedStream(id: "c1", source: source).completed, 3)  // `++` after a newline starts a new statement
        XCTAssertEqual(rt.finishStream(id: "c1", source: source + "write(globalThis.f('xa;by') + ' ' + globalThis.c);").primaryText, "true 2")
    }

    func testStreamNonASCIISourceOffsets() {
        var events: [[String: Any]] = []
        let rt = runtime()
        rt.streamObserver = { events.append($0) }
        rt.beginStream(id: "c1")
        let source = "globalThis.e = '😀é';\nwrite(globalThis.e);\n"
        XCTAssertEqual(rt.feedStream(id: "c1", source: source).completed, 2)
        let done = events.filter { $0["type"] as? String == "done" }
        XCTAssertEqual(done.count, 2)
        XCTAssertEqual(done.last?["start"] as? Int, "globalThis.e = '😀é';".utf8.count)  // byte offset in the cell source
        XCTAssertEqual(done.last?["end"] as? Int, source.utf8.count - 1)  // node ends at `;`, before the newline
        XCTAssertEqual(rt.finishStream(id: "c1").primaryText, "😀é")
    }

    func testScreenshotRoundTripsImage() {
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])
        let rt = runtime { _, _ in
            ToolCallResult(content: [.text("tree text"), .jpegImage(bytes)])
        }
        let result = rt.run(code: "write(cua.screenshot(\"X\"));", timeoutMs: 5000)
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.primaryText, "tree text")
        let imageItems = result.content.filter { $0.dictionary["type"] as? String == "image" }
        XCTAssertEqual(imageItems.count, 1)
        XCTAssertEqual(imageItems.first?.dictionary["data"] as? String, bytes.base64EncodedString())
    }
}
#endif
