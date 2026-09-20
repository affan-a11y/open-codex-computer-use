import AppKit
import Foundation
import OpenComputerUseKit

/// Runs a stdio server's read loop (mcp, stream, pi-bridge) on its own thread and
/// keeps the main thread for the app, so the drawn cursor plays there while a
/// tool call carries on.
final class MCPAppRuntime: NSObject, NSApplicationDelegate {
    private let readLoop: () throws -> Void
    private var runtimeError: Error?
    private var turnEndedObserver: NSObjectProtocol?

    private init(readLoop: @escaping () throws -> Void) {
        self.readLoop = readLoop
    }

    @MainActor
    static func run(_ readLoop: @escaping () throws -> Void) throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        let delegate = MCPAppRuntime(readLoop: readLoop)
        application.delegate = delegate
        application.run()

        if let runtimeError = delegate.runtimeError {
            throw runtimeError
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        turnEndedObserver = DistributedNotificationCenter.default().addObserver(
            forName: openComputerUseTurnEndedNotificationName,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                resetOpenComputerUseVisualCursor()
            }
        }
        Thread.detachNewThreadSelector(#selector(processStandardIO), toTarget: self, with: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let turnEndedObserver {
            DistributedNotificationCenter.default().removeObserver(turnEndedObserver)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc
    private func processStandardIO() {
        do {
            try readLoop()
        } catch {
            runtimeError = error
        }

        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }
}
