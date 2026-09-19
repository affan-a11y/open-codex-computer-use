import AppKit
import XCTest
@testable import OpenComputerUseKit

/// Times the visual-cursor phases that wrap every click (`moveCursor` before
/// the click, `pulseClick` after it): how long they play, how the pacing adapts
/// in a burst, how close the drawn tip lands, and that a tool thread queueing
/// them does not wait. Compare speeds with
/// `OPEN_COMPUTER_USE_CURSOR_DURATION_SCALE` (1 = original animation).
final class CursorAnimationLatencyLiveTests: XCTestCase {
    /// A tool thread queues a burst of clicks; it must not wait for the animation,
    /// and the queue must play every action in order.
    @MainActor
    func testQueuedCursorActionsDoNotBlockTheCaller() throws {
        guard ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_RUN_CURSOR_BENCH"] == "1" else {
            throw XCTSkip("set OPEN_COMPUTER_USE_RUN_CURSOR_BENCH=1")
        }
        _ = NSApplication.shared
        let clicks = 10
        let frame = try XCTUnwrap(NSScreen.main?.frame)
        let points = [CGPoint(x: frame.midX - 300, y: frame.midY - 150), CGPoint(x: frame.midX + 300, y: frame.midY + 150)]
        nonisolated(unsafe) var played: [Int] = []
        nonisolated(unsafe) var callerBlockedMs = 0.0
        let drained = expectation(description: "queue drained")

        let start = TimingLog.now()
        Thread.detachNewThread {
            let callerStart = TimingLog.now()
            for click in 0..<clicks {
                let point = points[click % 2]
                VisualCursorSupport.enqueue { SoftwareCursorOverlay.moveCursor(to: point, in: nil) }
                VisualCursorSupport.enqueue {
                    SoftwareCursorOverlay.pulseClick(at: point, clickCount: 1, mouseButton: .left, in: nil)
                    played.append(click)
                }
            }
            callerBlockedMs = (TimingLog.now() - callerStart) * 1000
            VisualCursorSupport.enqueue { drained.fulfill() }
        }
        wait(for: [drained], timeout: 30)
        let drainMs = (TimingLog.now() - start) * 1000
        SoftwareCursorOverlay.reset()

        print(String(format: "BENCH queued %d clicks: caller blocked %.2f ms, cursor caught up after %.0f ms (scale=%.2f)", clicks, callerBlockedMs, drainMs, SoftwareCursorOverlay.motionDurationScale))
        XCTAssertEqual(played, Array(0..<clicks), "every queued action plays, in order")
        XCTAssertLessThan(callerBlockedMs, 20, "the caller must not wait for the animation")
    }

    @MainActor
    func testCursorMoveAndPulseBlockingTime() throws {
        guard ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_RUN_CURSOR_BENCH"] == "1" else {
            throw XCTSkip("set OPEN_COMPUTER_USE_RUN_CURSOR_BENCH=1")
        }
        _ = NSApplication.shared
        let cycles = Int(ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_BENCH_CYCLES"] ?? "") ?? 20
        let frame = try XCTUnwrap(NSScreen.main?.frame)
        let points = [CGPoint(x: frame.midX - 300, y: frame.midY - 150), CGPoint(x: frame.midX + 300, y: frame.midY + 150)]

        // Landing error: how far the drawn tip is from the target when the pulse
        // starts. Needs OPEN_COMPUTER_USE_VISUAL_CURSOR_OBSERVATION_FILE.
        func tipError(from point: CGPoint) -> Double? {
            guard let url = visualCursorObservationFileURL(environment: ProcessInfo.processInfo.environment),
                  let data = try? Data(contentsOf: url),
                  let tip = (try? JSONDecoder().decode(VisualCursorObservationSnapshot.self, from: data))?.tipPosition else { return nil }
            return Double(hypot(tip.x - point.x, tip.y - point.y))
        }

        var move: [Double] = [], pulse: [Double] = [], landing: [Double] = []
        for cycle in 0..<cycles {
            let point = points[cycle % 2]
            var start = TimingLog.now()
            SoftwareCursorOverlay.moveCursor(to: point, in: nil)
            move.append((TimingLog.now() - start) * 1000)
            if let error = tipError(from: point) { landing.append(error) }
            start = TimingLog.now()
            SoftwareCursorOverlay.pulseClick(at: point, clickCount: 1, mouseButton: .left, in: nil)
            pulse.append((TimingLog.now() - start) * 1000)
        }
        if !landing.isEmpty {
            print("BENCH landing error at pulse start per cycle (pt): " + landing.prefix(10).map { String(format: "%.1f", $0) }.joined(separator: " ") + String(format: " | max %.1f", landing.max() ?? .nan))
        }
        // Idle past the relaxed gap: the adaptive tempo should be back to full length.
        RunLoop.current.run(until: Date().addingTimeInterval(2.2))
        let idleStart = TimingLog.now()
        SoftwareCursorOverlay.moveCursor(to: points[cycles % 2], in: nil)
        let afterIdle = (TimingLog.now() - idleStart) * 1000
        SoftwareCursorOverlay.reset()

        print("BENCH burst moveCursor per cycle: " + move.prefix(8).map { String(format: "%.0f", $0) }.joined(separator: " ") + String(format: " ms | after 2.2 s idle: %.0f ms", afterIdle))
        func row(_ name: String, _ values: [Double]) -> String {
            String(format: "BENCH %-12@ n=%2d mean=%7.1fms min=%7.1fms max=%7.1fms", name, values.count, values.reduce(0, +) / Double(values.count), values.min() ?? .nan, values.max() ?? .nan)
        }
        print("BENCH cursor scale=\(SoftwareCursorOverlay.motionDurationScale) cycles=\(cycles)")
        print(row("moveCursor", move)); print(row("pulseClick", pulse))
        print(row("move+pulse", zip(move, pulse).map(+)))
        XCTAssertEqual(move.count, cycles)
    }
}
