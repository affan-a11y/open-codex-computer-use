import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OpenComputerUseVirtualDisplayShim

public enum WindowPlacement: String, CaseIterable, Sendable {
    case keep
    case agentDisplay = "agent_display"
    case restore
}

func parseWindowPlacement(_ rawValue: String?) throws -> WindowPlacement {
    let normalized = rawValue?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? WindowPlacement.keep.rawValue

    guard let placement = WindowPlacement(rawValue: normalized) else {
        let expected = WindowPlacement.allCases.map(\.rawValue).joined(separator: ", ")
        throw ComputerUseError.message(
            "Invalid window_placement '\(rawValue ?? "")'. Expected one of: \(expected)"
        )
    }

    return placement
}

/// Where a parked window goes on the agent display: inset from the top-left
/// corner, clamped so at least the top-left `minVisible` points stay inside the
/// display when the window is larger than it.
func agentDisplayPlacement(windowSize: CGSize, displayBounds: CGRect, inset: CGFloat = 40, minVisible: CGFloat = 200) -> CGPoint {
    let maxX = max(displayBounds.minX, displayBounds.maxX - max(windowSize.width, minVisible))
    let maxY = max(displayBounds.minY, displayBounds.maxY - max(windowSize.height, minVisible))
    return CGPoint(
        x: min(displayBounds.minX + inset, maxX),
        y: min(displayBounds.minY + inset, maxY)
    )
}

/// The agent's own display: a virtual display (the mechanism behind Screen
/// Sharing's headless sessions) that the user never sees. A window parked on it
/// is genuinely on screen for WindowServer, so its app renders it, exposes its
/// full accessibility tree and accepts input, while the user's Space, foreground
/// app and pointer are untouched. Parking moves the window's frame (AX
/// position, no activation); the original position is restored on `restore`
/// and at process exit, and the display is removed once nothing is parked.
final class AgentDisplay: @unchecked Sendable {
    static let shared = AgentDisplay()

    static let displaySize = CGSize(width: 1920, height: 1080)
    // Upper bounds for the polls; the observed values are far lower and are
    // logged with OPEN_COMPUTER_USE_DEBUG_TIMING=1.
    static let displaySettle: TimeInterval = 3.0
    static let moveSettle: TimeInterval = 2.0
    // Fallback sleep for display creation when the Space SPI is unavailable.
    static let displayFallbackSettle: TimeInterval = 0.5
    /// OPEN_COMPUTER_USE_AGENT_DISPLAY=off: no display is made and a prepared window is driven
    /// where it sits, on the person's own screen.
    static let off = ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_AGENT_DISPLAY"] == "off"
    /// OPEN_COMPUTER_USE_KEEP_OPENED_WINDOWS=1: a window the agent opened goes home at restore
    /// instead of being closed, so a person can see what was done in it.
    static let keepOpenedWindows = ProcessInfo.processInfo.environment["OPEN_COMPUTER_USE_KEEP_OPENED_WINDOWS"] == "1"

    struct ParkedWindow {
        let pid: pid_t
        let element: AXUIElement
        let originalPosition: CGPoint
    }

    private let lock = NSLock()
    private var handle: UnsafeMutableRawPointer?
    private(set) var displayID: CGDirectDisplayID = 0
    private(set) var displaySpaceIDs: Set<UInt64> = []
    private var parked: [CGWindowID: ParkedWindow] = [:]
    /// Windows the agent opened; restoring closes them again.
    private var reopened: Set<CGWindowID> = []
    private var exitHookInstalled = false

    var isSupported: Bool {
        ocu_virtual_display_is_supported() != 0
    }

    var displayBounds: CGRect? {
        displayID == 0 ? nil : CGDisplayBounds(displayID)
    }

    func isParked(windowID: CGWindowID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return parked[windowID] != nil
    }

    func parkedWindowIDs(pid: pid_t) -> [CGWindowID] {
        lock.lock()
        defer { lock.unlock() }
        return parked.filter { $0.value.pid == pid }.map(\.key)
    }

    func prepare() throws -> CGRect {
        lock.lock()
        defer { lock.unlock() }
        let bounds = try ensureDisplay()
        installExitHookIfNeeded()
        return bounds
    }

    /// Move `window` onto the agent display. Returns the display bounds.
    @discardableResult
    func park(windowID: CGWindowID, pid: pid_t, window: AXUIElement) throws -> CGRect {
        lock.lock()
        defer { lock.unlock() }

        let bounds = try ensureDisplay()
        if parked[windowID] != nil {
            return bounds
        }

        guard let position = axPoint(window, kAXPositionAttribute as String) else {
            throw ComputerUseError.stateUnavailable("window_placement 'agent_display' could not read the window position")
        }
        if Self.off {
            // Still recorded: restore closes a window the agent opened.
            parked[windowID] = ParkedWindow(pid: pid, element: window, originalPosition: position)
            installExitHookIfNeeded()
            return bounds
        }
        let size = axSize(window) ?? CGSize(width: 800, height: 600)
        let target = agentDisplayPlacement(windowSize: size, displayBounds: bounds)
        let start = TimingLog.now()
        try setAXPosition(window, target)
        parked[windowID] = ParkedWindow(pid: pid, element: window, originalPosition: position)
        installExitHookIfNeeded()
        waitForWindow(windowID, toLandOn: displaySpaceIDs, or: bounds)
        TimingLog.log("agent_display.park", since: start)
        return bounds
    }

    /// Wait until the window's frame sits inside the display and, when the
    /// Space SPI is available, WindowServer also reports it on one of the
    /// display's Spaces. Space membership alone precedes the frame update.
    private func waitForWindow(_ windowID: CGWindowID, toLandOn spaceIDs: Set<UInt64>, or bounds: CGRect) {
        let spi = SkyLightSPI.shared
        waitUntil(timeout: Self.moveSettle) {
            guard let frame = Self.windowFrame(windowID),
                  bounds.contains(CGPoint(x: frame.minX + 1, y: frame.minY + 1))
            else { return false }
            if !spaceIDs.isEmpty, let spaces = spi.spaces(forWindow: windowID) {
                return spaces.contains(where: spaceIDs.contains)
            }
            return true
        }
    }

    /// On-screen app windows and their frames, keyed by window ID.
    private static func onScreenWindows() -> [CGWindowID: (pid: pid_t, frame: CGRect)] {
        let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var windows: [CGWindowID: (pid: pid_t, frame: CGRect)] = [:]
        for info in infoList where (info[kCGWindowLayer as String] as? Int) == 0 {
            guard let number = info[kCGWindowNumber as String] as? NSNumber,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: dictionary) else { continue }
            windows[number.uint32Value] = (pid, frame)
        }
        return windows
    }

    /// macOS puts windows back on a display it has seen before, and the agent display always has
    /// the same identity: a window still on an earlier agent display when it went away (a run that
    /// ended without restoring) reappears on every new one, off the user's screen. Move each such
    /// window back to where the user had it. Moving it while the display exists also makes macOS
    /// forget it, so the next agent display leaves it alone.
    private func returnRestoredWindows(_ before: [CGWindowID: (pid: pid_t, frame: CGRect)], from bounds: CGRect) {
        for (windowID, window) in before where parked[windowID] == nil && !bounds.intersects(window.frame) {
            guard let frame = Self.windowFrame(windowID), bounds.intersects(frame) else { continue }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(window.pid), kAXWindowsAttribute as CFString, &value) == .success,
                  let element = (value as? [AXUIElement])?.first(where: { SkyLightSPI.shared.windowID(for: $0) == windowID })
            else { continue }
            try? setAXPosition(element, window.frame.origin)
        }
    }

    private static func windowFrame(_ windowID: CGWindowID) -> CGRect? {
        let infoList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in infoList {
            guard let number = info[kCGWindowNumber as String] as? NSNumber, number.uint32Value == windowID,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary) else { continue }
            return bounds
        }
        return nil
    }

    enum Restored { case home, closed, heldOpen }

    /// Put a parked window back where the user had it. A window the agent opened
    /// (`closeWhenRestored`), or any window when `close` is set, is closed with its own close
    /// button instead, so no other window of the app is touched (a menu's Close Window acts on
    /// whichever window is main). One that survives the press (a Save sheet holds it) goes home,
    /// no longer parked; one the app already took down counts as closed.
    @discardableResult
    func restore(windowID: CGWindowID, close: Bool = false) throws -> Restored {
        lock.lock()
        defer { lock.unlock() }
        let outcome = try restoreLocked(windowID, close: close)
        destroyDisplayIfIdle()
        return outcome
    }

    func restoreAll() {
        lock.lock()
        defer { lock.unlock() }
        for windowID in Array(parked.keys) {
            try? restoreLocked(windowID)
        }
        destroyDisplayIfIdle()
    }

    /// Close a window again when it is restored: the agent opened it, the user never had it.
    func closeWhenRestored(_ windowID: CGWindowID) {
        lock.lock()
        defer { lock.unlock() }
        reopened.insert(windowID)
    }

    /// The per-window step of `restore` and `restoreAll` (call with lock held). The window stays
    /// parked when the move fails, so the caller can retry or close it.
    private func restoreLocked(_ windowID: CGWindowID, close: Bool = false) throws -> Restored {
        guard let entry = parked[windowID] else {
            throw ComputerUseError.stateUnavailable("window \(windowID) is not parked on the agent display")
        }
        let start = TimingLog.now()
        var outcome = Restored.home
        if Self.windowFrame(windowID) == nil {
            TimingLog.note("agent_display.restore: window \(windowID) was already gone")
            outcome = .closed
        } else if (close || reopened.remove(windowID) != nil) && !Self.keepOpenedWindows {
            // The mark goes with the press: should the move below fail, a retry only moves, never presses twice.
            guard pressClose(entry.element) else {
                throw ComputerUseError.stateUnavailable("window \(windowID) has no close button to press")
            }
            // A page may answer the close with a dialog ("Leave site?"): the window is the
            // agent's own, so the dialog's default button is pressed as soon as it shows and the
            // close is waited for again. The host gives this process about a second to leave.
            waitUntil(timeout: Self.moveSettle) {
                Self.onScreenWindows()[windowID] == nil || self.focusedDialog(pid: entry.pid, other: entry.element) != nil
            }
            outcome = Self.onScreenWindows()[windowID] == nil ? .closed : .heldOpen
            if outcome == .heldOpen, pressDefaultButtonOfDialog(pid: entry.pid, other: entry.element) {
                outcome = waitUntil(timeout: Self.moveSettle) { Self.onScreenWindows()[windowID] == nil } != nil ? .closed : .heldOpen
            }
        }
        if outcome != .closed {
            try setAXPosition(entry.element, entry.originalPosition)
            waitUntil(timeout: Self.moveSettle) {
                guard let frame = Self.windowFrame(windowID) else { return false }
                return abs(frame.minX - entry.originalPosition.x) < 1 && abs(frame.minY - entry.originalPosition.y) < 1
            }
        }
        parked[windowID] = nil
        reopened.remove(windowID)
        TimingLog.log("agent_display.restore", since: start)
        return outcome
    }

    /// The app's focused window when it is a dialog or sheet other than `other`.
    private func focusedDialog(pid: pid_t, other: AXUIElement) -> AXUIElement? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused, !CFEqual(focused, other) else { return nil }
        let window = focused as! AXUIElement
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role)
        let isDialog = (subrole as? String) == (kAXDialogSubrole as String) || (role as? String) == (kAXSheetRole as String)
        return isDialog ? window : nil
    }

    /// Press the default button of the app's focused dialog, when there is one. False when
    /// there is no such dialog or button, or the press was refused.
    private func pressDefaultButtonOfDialog(pid: pid_t, other: AXUIElement) -> Bool {
        guard let dialog = focusedDialog(pid: pid, other: other) else { return false }
        var button: CFTypeRef?
        guard AXUIElementCopyAttributeValue(dialog, kAXDefaultButtonAttribute as CFString, &button) == .success, let button else {
            TimingLog.note("agent_display.restore: the dialog has no default button")
            return false
        }
        let pressed = AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        TimingLog.note("agent_display.restore: pressed the dialog's default button (\(pressed.rawValue))")
        return pressed == .success
    }

    /// Press a window's close button. False when it has none or the press was refused.
    private func pressClose(_ element: AXUIElement) -> Bool {
        var button: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &button) == .success, let button else {
            return false
        }
        return AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success
    }

    // MARK: - Display lifecycle (call with lock held)

    private func ensureDisplay() throws -> CGRect {
        if Self.off { return CGDisplayBounds(CGMainDisplayID()) }
        if displayID != 0, let bounds = displayBounds, !bounds.isEmpty {
            return bounds
        }
        guard isSupported else {
            throw ComputerUseError.message("window_placement 'agent_display' is unavailable: CGVirtualDisplay is not present on this macOS")
        }
        let spi = SkyLightSPI.shared
        let spacesBefore = Set((spi.managedDisplaySpaces() ?? [:]).values.flatMap { $0 })
        let frontBefore = spi.frontProcess()
        let windowsBefore = Self.onScreenWindows()
        let start = TimingLog.now()
        var newHandle: UnsafeMutableRawPointer?
        let id = ocu_virtual_display_create("Open Computer Use", UInt32(Self.displaySize.width), UInt32(Self.displaySize.height), 60, &newHandle)
        guard id != 0, let newHandle else {
            throw ComputerUseError.message("window_placement 'agent_display' could not create the agent display")
        }
        handle = newHandle
        displayID = id
        TimingLog.log("agent_display.create", since: start)

        // Ready means WindowServer reports the display's bounds and has given
        // it a Space; without the Space SPI, fall back to a fixed settle.
        var newSpaces: Set<UInt64> = []
        let ready = waitUntil(timeout: Self.displaySettle) {
            // Focus moves while the display comes up; give it back as soon as it does (see below).
            if let frontBefore { spi.restoreFrontProcess(frontBefore) }
            guard let bounds = self.displayBounds, !bounds.isEmpty else { return false }
            guard let displays = spi.managedDisplaySpaces() else { return true }
            newSpaces = Set(displays.values.flatMap { $0 }).subtracting(spacesBefore)
            return !newSpaces.isEmpty
        }
        if ready == nil, displayBounds?.isEmpty != false {
            destroyDisplay()
            throw ComputerUseError.message("window_placement 'agent_display' timed out waiting for the agent display")
        }
        if newSpaces.isEmpty {
            Thread.sleep(forTimeInterval: Self.displayFallbackSettle)
        }
        displaySpaceIDs = newSpaces
        // A new display hands activation to the last regular app. When the user is typing in an
        // accessory app (a menu-bar composer), that moves their keystrokes into the app behind.
        // The agent display must not move the user's focus: give it back.
        if let frontBefore, !spi.restoreFrontProcess(frontBefore) {
            TimingLog.note("agent_display.ready could not restore the front process")
        }
        returnRestoredWindows(windowsBefore, from: displayBounds ?? .zero)
        TimingLog.log("agent_display.ready", since: start)
        return displayBounds ?? .zero
    }

    private func destroyDisplayIfIdle() {
        if parked.isEmpty {
            destroyDisplay()
        }
    }

    /// Removing a display hands activation around like adding one did (see `ensureDisplay`), after
    /// WindowServer has processed the removal: give the front process back on every poll tick.
    private func destroyDisplay() {
        guard let handle else { return }
        let spi = SkyLightSPI.shared
        let frontBefore = spi.frontProcess()
        let id = displayID
        let start = TimingLog.now()
        ocu_virtual_display_destroy(handle)
        self.handle = nil
        displayID = 0
        displaySpaceIDs = []
        let gone = waitUntil(timeout: Self.displaySettle) {
            if let frontBefore { spi.restoreFrontProcess(frontBefore) }
            return CGDisplayBounds(id).isEmpty
        }
        if gone == nil {
            TimingLog.note("agent_display.destroy timed out waiting for the display to go")
        }
        if let frontBefore, !spi.restoreFrontProcess(frontBefore) {
            TimingLog.note("agent_display.destroy could not restore the front process")
        }
        TimingLog.log("agent_display.destroy", since: start)
    }

    private func installExitHookIfNeeded() {
        guard !exitHookInstalled else { return }
        exitHookInstalled = true
        atexit {
            AgentDisplay.shared.restoreAll()
        }
    }

    // MARK: - AX helpers

    private func axPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func axSize(_ element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success, let value else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    private func setAXPosition(_ element: AXUIElement, _ point: CGPoint) throws {
        var mutable = point
        guard let value = AXValueCreate(.cgPoint, &mutable) else {
            throw ComputerUseError.message("could not encode the window position")
        }
        let result = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        guard result == .success else {
            throw ComputerUseError.stateUnavailable("window_placement could not move the window (AXError \(result.rawValue))")
        }
    }
}
