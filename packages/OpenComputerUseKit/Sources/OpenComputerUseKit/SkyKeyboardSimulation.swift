import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct SkyKeyboardTarget {
    let windowID: CGWindowID
    let pid: pid_t
}

/// A `cmd`-chord expressed the way AppKit menus advertise their key
/// equivalents: `AXMenuItemCmdChar` plus the `AXMenuItemCmdModifiers` bitmask
/// (1 = shift, 2 = option, 4 = control; 8 marks a non-command equivalent).
struct SkyMenuKeyEquivalent: Equatable, Sendable {
    let character: String
    let modifiers: Int
}

/// Menu-bar key equivalents (`cmd+a`, `cmd+c`, `cmd+t`, ...) are dispatched by
/// AppKit through `NSMenu`, which only fires for the active app. A background
/// target instead needs the menu item invoked directly, which is exactly what
/// the user's keypress would have triggered. Only single-character keys with
/// a command modifier map to a menu equivalent; everything else (arrows,
/// return, plain characters, non-command chords) is delivered as key events.
func skyMenuKeyEquivalent(for parsed: ParsedKeyPress) -> SkyMenuKeyEquivalent? {
    guard parsed.modifiers.contains(where: { $0.flag == .maskCommand }),
          parsed.displayValue.count == 1
    else {
        return nil
    }

    var modifiers = 0
    for modifier in parsed.modifiers {
        switch modifier.flag {
        case .maskShift:
            modifiers |= 1
        case .maskAlternate:
            modifiers |= 2
        case .maskControl:
            modifiers |= 4
        default:
            break
        }
    }
    return SkyMenuKeyEquivalent(character: parsed.displayValue.uppercased(), modifiers: modifiers)
}

func skyMenuItemMatches(cmdChar: String?, cmdModifiers: Int?, enabled: Bool?, equivalent: SkyMenuKeyEquivalent) -> Bool {
    guard let cmdChar, enabled != false else {
        return false
    }
    return cmdChar.uppercased() == equivalent.character && (cmdModifiers ?? 0) == equivalent.modifiers
}

/// Owner check for keyboard targets. Unlike `sky_click`, the window does not
/// need to be on-screen: keyboard delivery is process-addressed, so a window on
/// another Space or hidden app is a valid target as long as it still exists
/// and belongs to the snapshot's process.
func skyKeyWindowMatchesTarget(
    windowInfo: [[String: Any]],
    windowID: CGWindowID,
    pid: pid_t
) -> Bool {
    windowInfo.contains { info in
        guard
            let number = info[kCGWindowNumber as String] as? NSNumber,
            number.uint32Value == windowID,
            let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber
        else {
            return false
        }

        return ownerPID.int32Value == pid
    }
}

/// `sky_key`: deliver keyboard input to a background window without changing
/// the real foreground app.
///
/// Keyboard events posted to a pid reach any AppKit window, but Chromium and
/// Electron only insert text while their NSWindow is key (page focus is driven
/// by `OnWindowIsKeyChanged`). The recipe therefore reuses the `sky_click`
/// target-only synthetic-active state, then posts yabai's key-window record
/// pair so the target app makes the window key internally, waits for it to
/// take effect, delivers the ordinary `CGEvent.postToPid` keyboard events (or
/// presses the matching menu item for command chords), and releases the
/// synthetic state again. The real frontmost app keeps its active, key and
/// first-responder state throughout; the target is never raised and the
/// pointer never moves.
enum SkyKeyboardDispatcher {
    private static let dispatchLock = NSLock()
    /// The activation record, the key-window records, the key events and the
    /// deactivation record all travel the target's single event queue, so the
    /// app handles them in order: no timing gap is needed between them. Both
    /// settles therefore default to 0 and exist only as calibration knobs
    /// (OPEN_COMPUTER_USE_SKY_KEY_SETTLE_MS / OPEN_COMPUTER_USE_SKY_KEY_RELEASE_MS)
    /// for a target that turns out to process input asynchronously.
    static let keyWindowFallbackSettle: TimeInterval = settle("OPEN_COMPUTER_USE_SKY_KEY_SETTLE_MS")
    static let releaseSettle: TimeInterval = settle("OPEN_COMPUTER_USE_SKY_KEY_RELEASE_MS")

    private static func settle(_ variable: String) -> TimeInterval {
        guard let raw = ProcessInfo.processInfo.environment[variable], let ms = Double(raw) else { return 0 }
        return max(0, ms) / 1000
    }

    static func typeText(
        target: SkyKeyboardTarget,
        text: String,
        spi: SkyLightSPI = .shared
    ) throws {
        try deliver(to: target, spi: spi) {
            try InputSimulation.typeText(text, pid: target.pid)
        }
    }

    static func pressKey(
        target: SkyKeyboardTarget,
        key: String,
        spi: SkyLightSPI = .shared
    ) throws {
        // Reject bad key specs before touching the target's focus state.
        let parsed = try KeyPressParser.parse(key)
        try deliver(to: target, spi: spi) {
            if let equivalent = skyMenuKeyEquivalent(for: parsed),
               let item = menuItem(matching: equivalent, pid: target.pid) {
                let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
                guard result == .success else {
                    throw ComputerUseError.message(
                        "sky_key could not press the menu item for '\(key)' (AXError \(result.rawValue))"
                    )
                }
                Thread.sleep(forTimeInterval: 0.1)
                return
            }

            try InputSimulation.pressKey(key, pid: target.pid)
        }
    }

    private static func deliver(
        to target: SkyKeyboardTarget,
        spi: SkyLightSPI,
        _ body: () throws -> Void
    ) throws {
        guard spi.capability.isAvailable else {
            throw ComputerUseError.message(
                "key_method 'sky_key' is unavailable: \(spi.capability.unavailableReason)"
            )
        }

        dispatchLock.lock()
        defer {
            dispatchLock.unlock()
        }

        try validate(target: target)

        if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.pid {
            try body()
            return
        }

        let start = TimingLog.now()
        let focusContext = try spi.beginSyntheticTargetFocus(
            targetPID: target.pid,
            targetWindowID: target.windowID
        )
        do {
            try spi.makeSyntheticTargetWindowKey(focusContext)
            TimingLog.log("sky_key.activate", since: start)
            let keyStart = TimingLog.now()
            waitForKeyWindow(target, spi: spi)
            TimingLog.log("sky_key.key_window", since: keyStart)
            let deliverStart = TimingLog.now()
            try body()
            TimingLog.log("sky_key.deliver", since: deliverStart)
            if releaseSettle > 0 {
                Thread.sleep(forTimeInterval: releaseSettle)
            }
        } catch {
            try? spi.endSyntheticTargetFocus(focusContext)
            throw error
        }
        try spi.endSyntheticTargetFocus(focusContext)
        TimingLog.log("sky_key.total", since: start)
    }

    private static func waitForKeyWindow(_ target: SkyKeyboardTarget, spi: SkyLightSPI) {
        if keyWindowFallbackSettle > 0 {
            Thread.sleep(forTimeInterval: keyWindowFallbackSettle)
        }
    }

    private static func validate(target: SkyKeyboardTarget) throws {
        // A hidden app (cmd+h) never makes its windows key, so keys would be
        // silently dropped. Fail closed instead of unhiding on the user's behalf.
        if NSRunningApplication(processIdentifier: target.pid)?.isHidden == true {
            throw ComputerUseError.stateUnavailable(
                "sky_key target app is hidden. Unhide it first; sky_key does not change window visibility."
            )
        }

        // `.optionAll`, not `.optionIncludingWindow`: the latter omits windows
        // that are off-screen (hidden app, minimized, or on another Space).
        let windowInfo = CGWindowListCopyWindowInfo(
            [.optionAll],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        guard skyKeyWindowMatchesTarget(
            windowInfo: windowInfo,
            windowID: target.windowID,
            pid: target.pid
        ) else {
            throw ComputerUseError.stateUnavailable(
                "sky_key target window no longer exists or is no longer owned by the target app. Run get_app_state again."
            )
        }
    }

    // MARK: - Menu-bar key equivalents

    /// Press the app's New Window menu item, with no window to address: an app whose windows are
    /// all on another Space still has a menu bar. Cmd-N alone would not do: in Notes, Reminders,
    /// Music and Calendar it makes a new note, reminder, playlist or event in the user's window.
    static func pressNewWindow(pid: pid_t, appName: String) throws {
        let cmdN = SkyMenuKeyEquivalent(character: "N", modifiers: 0)
        let item = menuItem(pid: pid) { item in
            // A leaf only: a submenu header called "New Window" (Terminal's profiles) would just drop open.
            guard (copyValue(item, kAXChildrenAttribute) as? [AXUIElement] ?? []).isEmpty, isEnabled(item),
                  let title = copyValue(item, kAXTitleAttribute) as? String else { return false }
            // The title is the only sign that the item makes a window and not a note or an event
            // (Notes, Calendar and Music put those on Cmd-N), so this is English only; elsewhere
            // it throws and the caller falls back to the app's existing window.
            // "New Finder Window": the Cmd-N item counts when it names a window.
            return title.hasPrefix("New Window") || (title.contains("Window") && hasKeyEquivalent(item, cmdN))
        }
        guard let item else {
            throw ComputerUseError.message("\(appName) has no New Window menu item")
        }
        let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
        guard result == .success else {
            throw ComputerUseError.message("could not press New Window in \(appName) (AXError \(result.rawValue))")
        }
    }

    private static func menuItem(matching equivalent: SkyMenuKeyEquivalent, pid: pid_t) -> AXUIElement? {
        menuItem(pid: pid) { isEnabled($0) && hasKeyEquivalent($0, equivalent) }
    }

    private static func isEnabled(_ item: AXUIElement) -> Bool {
        (copyValue(item, kAXEnabledAttribute) as? NSNumber)?.boolValue != false
    }

    private static func hasKeyEquivalent(_ item: AXUIElement, _ equivalent: SkyMenuKeyEquivalent) -> Bool {
        skyMenuItemMatches(
            cmdChar: copyValue(item, "AXMenuItemCmdChar") as? String,
            cmdModifiers: (copyValue(item, "AXMenuItemCmdModifiers") as? NSNumber)?.intValue,
            enabled: nil,
            equivalent: equivalent
        )
    }

    private static func menuItem(pid: pid_t, where matches: (AXUIElement) -> Bool) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        guard let menuBar = copyValue(application, kAXMenuBarAttribute) else {
            return nil
        }
        return firstMenuItem(in: menuBar as! AXUIElement, depth: 0, where: matches)
    }

    private static func firstMenuItem(in element: AXUIElement, depth: Int, where matches: (AXUIElement) -> Bool) -> AXUIElement? {
        guard depth < 6 else {
            return nil
        }

        for child in copyValue(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
            if copyValue(child, kAXRoleAttribute) as? String == kAXMenuItemRole as String, matches(child) {
                return child
            }

            if let nested = firstMenuItem(in: child, depth: depth + 1, where: matches) {
                return nested
            }
        }

        return nil
    }

    private static func copyValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }
}
