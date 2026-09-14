#if canImport(JavaScriptCore)
import XCTest
@testable import OpenComputerUseKit

final class PiBridgeServerTests: XCTestCase {
    private func decode(_ line: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
    }

    func testFinalSourceRunsAndReportsOutputThenTerminal() {
        let bridge = OpenComputerUsePiBridgeServer()
        let out = bridge.handle(line: #"{"op":"source","cell":"c1","source":"write(\"hi\");\n","final":true}"#)
        let frames = out.map(decode)
        XCTAssertEqual(frames.first(where: { $0["type"] as? String == "output" })?["text"] as? String, "hi")
        let terminal = frames.first(where: { $0["type"] as? String == "terminal" })
        XCTAssertEqual(terminal?["status"] as? String, "done")
    }

    func testStreamingReportsDonePerStatementThenFinishes() {
        let bridge = OpenComputerUsePiBridgeServer()
        let feed = bridge.handle(line: #"{"op":"source","cell":"c1","source":"globalThis.x = 1;\n","final":false}"#).map(decode)
        XCTAssertEqual(feed.first(where: { $0["type"] as? String == "done" })?["index"] as? Int, 0)

        let final = bridge.handle(line: #"{"op":"source","cell":"c1","source":"globalThis.x = 1;\nwrite(String(globalThis.x));\n","final":true}"#).map(decode)
        XCTAssertEqual(final.first(where: { $0["type"] as? String == "output" })?["text"] as? String, "1")
        XCTAssertEqual(final.first(where: { $0["type"] as? String == "terminal" })?["status"] as? String, "done")
    }

    func testDivergenceFailsCell() {
        let bridge = OpenComputerUsePiBridgeServer()
        _ = bridge.handle(line: #"{"op":"source","cell":"c1","source":"write(\"a\");\n","final":false}"#)
        let out = bridge.handle(line: #"{"op":"source","cell":"c1","source":"write(\"b\");\n","final":false}"#).map(decode)
        let terminal = out.first(where: { $0["type"] as? String == "terminal" })
        XCTAssertEqual(terminal?["status"] as? String, "failed")
        XCTAssertTrue((terminal?["error"] as? String ?? "").contains("diverged"))
    }

    func testAbandonEmitsFailedTerminal() {
        let bridge = OpenComputerUsePiBridgeServer()
        _ = bridge.handle(line: #"{"op":"source","cell":"c1","source":"globalThis.y = 2;\n","final":false}"#)
        let out = bridge.handle(line: #"{"op":"abandon","cell":"c1"}"#).map(decode)
        let terminal = out.first(where: { $0["type"] as? String == "terminal" })
        XCTAssertEqual(terminal?["status"] as? String, "failed")
        XCTAssertTrue((terminal?["error"] as? String ?? "").contains("abandoned"))
    }

    func testClosedCellIgnoresLateFrames() {
        let bridge = OpenComputerUsePiBridgeServer()
        _ = bridge.handle(line: #"{"op":"source","cell":"c1","source":"write(\"x\");\n","final":true}"#)
        XCTAssertTrue(bridge.handle(line: #"{"op":"source","cell":"c1","source":"write(\"x\");\nwrite(\"y\");\n","final":true}"#).isEmpty)
    }

    func testFinalFeedReportsAttemptedStatementAndKeepsEarlierEffect() throws {
        let bridge = OpenComputerUsePiBridgeServer()
        let source = "globalThis.sent = 1;\nthrow new Error('stop');\nglobalThis.sent = 2;"
        let request = try JSONSerialization.data(withJSONObject: [
            "op": "source", "cell": "failed", "source": source, "final": true,
        ])
        let frames = bridge.handle(line: String(decoding: request, as: UTF8.self)).map(decode)
        let started = frames.filter { $0["type"] as? String == "started" }
        XCTAssertEqual(started.count, 2)
        XCTAssertTrue((started.last?["text"] as? String ?? "").contains("throw new Error"))
        XCTAssertEqual(frames.filter { $0["type"] as? String == "done" }.count, 1)
        XCTAssertEqual(frames.last?["status"] as? String, "failed")
        let read = bridge.handle(line: #"{"op":"source","cell":"read","source":"write(globalThis.sent);","final":true}"#).map(decode)
        XCTAssertEqual(read.first { $0["type"] as? String == "output" }?["text"] as? String, "1")
    }

    /// An `if` body waits for a possible `else`; a `try` body runs as it streams and
    /// its `catch` is skipped when nothing threw. Either way the result is the same.
    func testIfWaitsForItsElseAndATryBodyRunsEarly() throws {
        for (head, tail, early) in [
            ("if (true) { globalThis.ran += 1; }\n// branch follows\n", "else { globalThis.ran += 10; };\n", 1),
            ("try { globalThis.ran += 1; }\n", "catch (e) { globalThis.ran += 10; };\n", 2),
        ] {
            let bridge = OpenComputerUsePiBridgeServer()
            func feed(_ source: String, final: Bool) throws -> [[String: Any]] {
                let data = try JSONSerialization.data(withJSONObject: [
                    "op": "source", "cell": "control", "source": source, "final": final,
                ])
                return bridge.handle(line: String(decoding: data, as: UTF8.self)).map(decode)
            }
            let prefix = "globalThis.ran = 0;\n" + head
            let opened = try feed(prefix, final: false)
            XCTAssertEqual(opened.filter { $0["type"] as? String == "done" }.count, early)
            let final = try feed(prefix + tail + "write(globalThis.ran);", final: true)
            XCTAssertEqual(final.first { $0["type"] as? String == "output" }?["text"] as? String, "1")
            XCTAssertEqual(final.last?["status"] as? String, "done")
        }
    }

    func testMalformedIgnored() {
        let bridge = OpenComputerUsePiBridgeServer()
        XCTAssertTrue(bridge.handle(line: "not json").isEmpty)
        XCTAssertTrue(bridge.handle(line: #"{"op":"nope"}"#).isEmpty)
    }
}
#endif
