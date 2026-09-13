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
        let visible = try? SnapshotBuilder.resolveTargetWindow(for: app)
        let front = SkyLightSPI.shared.frontProcess()
        var reopened = false
        let context: TargetedAX.WindowContext
        if newWindow && app.runningApplication.isFinishedLaunching {
            // The user's own windows stay where they are: only the window opened here is parked,
            // even when none of theirs is on this Space (the menu bar needs no window).
            try SkyKeyboardDispatcher.pressMenuItem(key: "super+n", pid: app.pid)
            context = try awaitWindow(app: app, excluding: visible?.windowID)
        } else {
            if visible == nil {
                // A window in its own full-screen Space is the user's to keep: reopening would switch
                // them to that Space, and a full-screen window cannot be moved to the agent display.
                if inFullScreen(pid: app.pid) {
                    throw ComputerUseError.stateUnavailable("\(app.name) is in full screen on another desktop; it is left alone")
                }
                if app.runningApplication.isFinishedLaunching {
                    // Running with no open window: the reopen a Dock click sends brings a closed window back.
                    try AppDiscovery.reopen(app)
                    reopened = true
                } else {
                    try AppDiscovery.launchIfPossible(query, activate: false)
                }
            }
            context = try awaitWindow(app: app)
        }
        try park(service: service, query: query, context: context)
        // Opening a window may bring the app forward; focus goes back to where it was.
        if let front { SkyLightSPI.shared.restoreFrontProcess(front) }
        if reopened, let id = context.windowID { AgentDisplay.shared.closeWhenRestored(id) }
        guard let id = context.windowID else {
            throw ComputerUseError.stateUnavailable("No window ID for \(query)")
        }
        return try json(["app": app.bundleIdentifier ?? app.name, "name": app.name, "window_id": id])
    }

    private static func inFullScreen(pid: pid_t) -> Bool {
        let fullScreen = SkyLightSPI.shared.fullScreenSpaces()
        guard !fullScreen.isEmpty else { return false }
        let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid, (info[kCGWindowLayer as String] as? Int) == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID else { return false }
            return SkyLightSPI.shared.spaces(forWindow: id)?.contains(where: fullScreen.contains) ?? false
        }
    }

    private static func park(service: ComputerUseService, query: String, context: TargetedAX.WindowContext) throws {
        guard let id = context.windowID else {
            throw ComputerUseError.stateUnavailable("No window ID for \(query)")
        }
        try AgentDisplay.shared.park(windowID: id, pid: context.app.pid, window: context.windowElement)
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
        guard let app = AppDiscovery.resolvedRunningApp(in: AppDiscovery.runningApps(), matching: query) else {
            throw ComputerUseError.appNotFound(query)
        }
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

    private static func json(_ value: Any) throws -> ToolCallResult {
        .text(String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self))
    }
}
