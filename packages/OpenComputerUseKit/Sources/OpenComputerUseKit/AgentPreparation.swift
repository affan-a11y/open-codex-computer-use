import AppKit
import ApplicationServices
import Foundation

/// Preparation and independent observations for a host-owned agent loop.
/// These reads never change a saved query index or recover a different window.
enum AgentPreparation {
    static func display() throws -> ToolCallResult {
        let bounds = try AgentDisplay.shared.prepare()
        return try json(["version": 1, "display_id": AgentDisplay.shared.displayID,
                         "width": Int(bounds.width), "height": Int(bounds.height)])
    }

    static func app(service: ComputerUseService, query: String, newWindow: Bool) throws -> ToolCallResult {
        let app = try AppDiscovery.resolve(query, activate: false)
        if (try? SnapshotBuilder.resolveTargetWindow(for: app)) == nil {
            try AppDiscovery.launchIfPossible(query, activate: false)
        }
        var context = try awaitWindow(app: app)
        let originalID = context.windowID
        try park(service: service, query: query, context: context)
        if newWindow {
            _ = try service.withJavaScriptExecution {
                try service.pressKey(app: query, key: "super+n", keyMethod: .skyKey)
            }
            context = try awaitWindow(app: app, excluding: originalID)
            try park(service: service, query: query, context: context)
        }
        guard let id = context.windowID else {
            throw ComputerUseError.stateUnavailable("No window ID for \(query)")
        }
        return try json(["app": app.bundleIdentifier ?? app.name, "name": app.name, "window_id": id])
    }

    private static func park(service: ComputerUseService, query: String, context: TargetedAX.WindowContext) throws {
        let element: AXUIElement? = context.windowElement
        guard let id = context.windowID, let window = element else {
            throw ComputerUseError.stateUnavailable("No window ID for \(query)")
        }
        try AgentDisplay.shared.park(windowID: id, pid: context.app.pid, window: window)
        // Bounds changed when parked. Keep the action context in that display.
        let parked = try SnapshotBuilder.resolveTargetWindow(for: context.app, windowID: id)
        service.bindPreparedWindow(query: query, context: parked)
    }

    private static func awaitWindow(app: RunningAppDescriptor, excluding: CGWindowID? = nil) throws -> TargetedAX.WindowContext {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            if let context = try? SnapshotBuilder.resolveTargetWindow(for: app),
               let id = context.windowID, id != excluding { return context }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        throw ComputerUseError.stateUnavailable("The requested window did not open in \(app.name)")
    }

    static func observe(query: String, windowID: CGWindowID) throws -> ToolCallResult {
        guard let app = running(query) else { throw ComputerUseError.appNotFound(query) }
        if let bundle = app.bundleIdentifier, AppSafetyPolicy.isBlocked(bundleIdentifier: bundle) {
            throw AppSafetyPolicy.permissionDenied(bundleIdentifier: bundle)
        }
        let snapshot = try SnapshotBuilder.build(for: app, textLimit: .max,
            recoveryPolicy: .readOnly, windowID: windowID)
        var content = [ToolResultContentItem.text(snapshot.renderedText(style: .fullState))]
        if let png = snapshot.screenshotPNGData { content.append(.pngImage(png)) }
        return ToolCallResult(content: content)
    }

    static func catalog() throws -> ToolCallResult {
        let browserURL = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
        let browser = browserURL.flatMap { Bundle(url: $0)?.bundleIdentifier }
        let apps: [[String: Any]] = AppDiscovery.listCatalog().map {
            ["name": $0.name, "app": $0.bundleIdentifier, "running": $0.isRunning]
        }
        return try json(["agent_loop": 1, "apps": apps, "default_browser": browser as Any? ?? NSNull()])
    }

    private static func running(_ query: String) -> RunningAppDescriptor? {
        AppDiscovery.runningApps().first {
            $0.name.caseInsensitiveCompare(query) == .orderedSame ||
            $0.bundleIdentifier?.caseInsensitiveCompare(query) == .orderedSame
        }
    }

    private static func json(_ value: Any) throws -> ToolCallResult {
        .text(String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self))
    }
}
