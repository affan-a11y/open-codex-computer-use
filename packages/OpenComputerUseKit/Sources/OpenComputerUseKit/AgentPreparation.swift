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
        // Opening a window may bring the app forward; focus goes back to where it was on every exit.
        defer {
            if let front, !SkyLightSPI.shared.restoreFrontProcess(front) {
                TimingLog.note("prepare_app could not restore the front process")
            }
        }
        let before = windowIDs(pid: app.pid)
        var opened = false
        let context: TargetedAX.WindowContext
        if newWindow && app.runningApplication.isFinishedLaunching {
            // The user's own windows stay where they are: only the window opened here is parked,
            // even when none of theirs is on this Space (the menu bar needs no window).
            try SkyKeyboardDispatcher.pressNewWindow(pid: app.pid, appName: app.name)
            opened = true
            context = try awaitWindow(app: app, excluding: visible?.windowID)
        } else {
            // A window in its own full-screen Space is the user's to keep: reopening would switch
            // them to that Space, and a full-screen window cannot be moved to the agent display.
            if inFullScreen(pid: app.pid, windowID: visible?.windowID) {
                throw ComputerUseError.stateUnavailable("\(app.name) is in full screen; it is left alone")
            }
            if visible == nil {
                if app.runningApplication.isFinishedLaunching {
                    // Running with no open window: the reopen a Dock click sends brings a closed window back.
                    try AppDiscovery.reopen(app)
                    opened = true
                } else {
                    try AppDiscovery.launchIfPossible(query, activate: false)
                }
            }
            context = try awaitWindow(app: app)
        }
        guard let id = context.windowID else {
            throw ComputerUseError.stateUnavailable("No window ID for \(query)")
        }
        try AgentDisplay.shared.park(windowID: id, pid: app.pid, window: context.windowElement)
        // A window the agent opened (Dock reopen or New Window) that did not exist before is closed
        // when restored; marked as soon as it is parked, so a failure below still ends with it closed.
        // Reopen can also un-minimize or raise a window the user already had; that one comes back
        // open, not re-minimized: they asked for work in it, and restore only moves frames. A window
        // that appeared because the app was launched is left to the app.
        if opened, !before.contains(id) { AgentDisplay.shared.closeWhenRestored(id) }
        // Bounds changed when parked. Keep the action context in that display.
        // A new window is focused before the app lists it; with the display off no park wait covers that.
        service.bindPreparedWindow(query: query, context: try awaitWindow(app: app, windowID: id))
        return try json(["app": app.bundleIdentifier ?? app.name, "name": app.name, "window_id": id])
    }

    /// The app's document-level windows on any Space, minimized or not.
    private static func windowIDs(pid: pid_t) -> [CGWindowID] {
        let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid, (info[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            return info[kCGWindowNumber as String] as? CGWindowID
        }
    }

    /// Whether `windowID`, or any window of the app when nil, sits in a full-screen Space.
    private static func inFullScreen(pid: pid_t, windowID: CGWindowID?) -> Bool {
        let fullScreen = SkyLightSPI.shared.fullScreenSpaces()
        guard !fullScreen.isEmpty else { return false }
        return windowIDs(pid: pid).contains { id in
            guard windowID == nil || windowID == id, let spaces = SkyLightSPI.shared.spaces(forWindow: id) else { return false }
            return spaces.contains(where: fullScreen.contains)
        }
    }

    private static func awaitWindow(app: RunningAppDescriptor, excluding: CGWindowID? = nil, windowID: CGWindowID? = nil) throws -> TargetedAX.WindowContext {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            if let context = try? SnapshotBuilder.resolveTargetWindow(for: app, windowID: windowID),
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
        if let data = snapshot.screenshotData { content.append(.jpegImage(data)) }
        return ToolCallResult(content: content)
    }

    static func catalog() throws -> ToolCallResult {
        let browserURL = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
        let browser = browserURL.flatMap { Bundle(url: $0)?.bundleIdentifier }
        let apps: [[String: Any]] = AppDiscovery.listCatalog().map {
            ["name": $0.name, "app": $0.bundleIdentifier, "running": $0.isRunning, "pid": $0.pid.map { Int($0) } as Any? ?? NSNull()]
        }
        return try json(["agent_loop": 1, "apps": apps, "default_browser": browser as Any? ?? NSNull()])
    }

    private static func json(_ value: Any) throws -> ToolCallResult {
        .text(String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self))
    }
}
