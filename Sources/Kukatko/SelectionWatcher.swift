import AppKit
import ApplicationServices

/// Watches mouse gestures in other apps and reads what got selected.
/// Primary path is the Accessibility API (no side effects); apps that don't expose
/// their selection get a quick ⌘C with the clipboard restored right after.
final class SelectionWatcher {
    var onSelection: ((Captured) -> Void)?
    var onDismissGesture: (() -> Void)?

    private var monitors: [Any] = []
    private var downPoint: NSPoint = .zero
    private var downTime: TimeInterval = 0
    private var downRoleBlocked = false
    private let queue = DispatchQueue(label: "kukatko.ax", qos: .userInitiated)
    private var enabledPIDs = Set<pid_t>()
    private var generation = 0

    /// Roles where a drag is never a text selection (window chrome, controls).
    private let chromeRoles: Set<String> = [
        "AXButton", "AXScrollBar", "AXSplitter", "AXToolbar", "AXSlider", "AXMenuBar", "AXMenuBarItem",
        "AXTabGroup", "AXDisclosureTriangle", "AXRadioButton", "AXCheckBox", "AXPopUpButton",
        "AXValueIndicator", "AXIncrementor", "AXDockItem", "AXImage", "AXWindow", "AXSheet",
    ]
    /// Apps where a drag means moving things, not selecting text.
    private let neverProbe: Set<String> = [
        "com.apple.finder", "com.apple.dock", "com.apple.systemuiserver", "com.apple.controlcenter",
        "com.figma.Desktop", "com.apple.Preview",
    ]

    func start() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.6)

        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] e in
            self?.mouseDown(e)
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] e in
            self?.mouseUp(e)
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .scrollWheel, .rightMouseDown], handler: { [weak self] _ in
            self?.generation += 1
            self?.onDismissGesture?()
        }) { monitors.append(m) }
    }

    // MARK: Gestures

    private func mouseDown(_ e: NSEvent) {
        generation += 1
        downPoint = NSEvent.mouseLocation
        downTime = ProcessInfo.processInfo.systemUptime
        onDismissGesture?()
        let p = downPoint
        queue.async { [weak self] in
            guard let self else { return }
            let role = self.role(at: p)
            DispatchQueue.main.async { self.downRoleBlocked = role.map { self.chromeRoles.contains($0) } ?? false }
        }
    }

    private func mouseUp(_ e: NSEvent) {
        guard Permissions.accessibilityGranted else { return }
        let up = NSEvent.mouseLocation
        let dragged = hypot(up.x - downPoint.x, up.y - downPoint.y) > 6
        let multiClick = e.clickCount >= 2
        guard dragged || multiClick else { return }
        guard !e.modifierFlags.contains(.command) else { return }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        if let id = app.bundleIdentifier, Settings.shared.excludedApps.contains(id) { return }

        let blocked = downRoleBlocked
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, gen == self.generation else { return }
            self.read(app: app, allowProbe: !blocked && !self.neverProbe.contains(app.bundleIdentifier ?? ""), fallbackPoint: up) { captured in
                guard gen == self.generation, let captured else { return }
                self.onSelection?(captured)
            }
        }
    }

    /// Used by the hotkey: read the selection right now, probing with ⌘C if needed (text or image).
    func captureNow(_ completion: @escaping (Captured?) -> Void) {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            completion(nil); return
        }
        read(app: app, allowProbe: true, allowImages: true, fallbackPoint: NSEvent.mouseLocation, completion: completion)
    }

    // MARK: Reading

    private func read(app: NSRunningApplication, allowProbe: Bool, allowImages: Bool = false,
                      fallbackPoint: NSPoint, completion: @escaping (Captured?) -> Void) {
        let pid = app.processIdentifier
        let firstTimeForApp = !enabledPIDs.contains(pid)
        if firstTimeForApp { enabledPIDs.insert(pid) }

        queue.async { [weak self] in
            guard let self else { return }
            if firstTimeForApp { self.enableWebAccessibility(pid: pid) }
            let ax = self.readAX(pid: pid)
            DispatchQueue.main.async {
                switch ax {
                case .secure:
                    completion(nil)
                case .text(let text, let rect, let context):
                    completion(Captured(content: .text(text), app: app, anchor: rect ?? NSRect(origin: fallbackPoint, size: .zero), context: context))
                case .emptyField:
                    completion(nil)
                case .unknown:
                    guard allowProbe else { completion(nil); return }
                    PasteboardProbe.copySelection(allowImages: allowImages) { content in
                        guard let content else { completion(nil); return }
                        completion(Captured(content: content, app: app, anchor: NSRect(origin: fallbackPoint, size: .zero), context: nil))
                    }
                }
            }
        }
    }

    private enum AXResult {
        case text(String, NSRect?, String?)
        case emptyField
        case secure
        case unknown
    }

    private func readAX(pid: pid_t) -> AXResult {
        let appEl = AXUIElementCreateApplication(pid)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused, CFGetTypeID(el) == AXUIElementGetTypeID() else { return .unknown }
        let element = el as! AXUIElement

        let role = stringAttr(element, kAXRoleAttribute)
        let subrole = stringAttr(element, kAXSubroleAttribute)
        if subrole == (kAXSecureTextFieldSubrole as String) { return .secure }

        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value)
        if err == .success, let s = value as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return .text(String(trimmed.prefix(12000)), selectionRect(element), surroundingText(element))
            }
            // Real text inputs report "" when nothing is selected – trust that.
            if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role ?? "") { return .emptyField }
        }
        return .unknown
    }

    private func selectionRect(_ el: AXUIElement) -> NSRect? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let range = rangeRef else { return nil }
        var boundsRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, range, &boundsRef) == .success,
              let b = boundsRef, CFGetTypeID(b) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(b as! AXValue, .cgRect, &rect), rect.width > 0 || rect.height > 0 else { return nil }
        return Self.cocoaRect(fromAX: rect)
    }

    private func surroundingText(_ el: AXUIElement) -> String? {
        var rangeRef: CFTypeRef?
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &valueRef) == .success,
              let full = valueRef as? String, let r = rangeRef, CFGetTypeID(r) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(r as! AXValue, .cfRange, &range) else { return nil }
        let ns = full as NSString
        guard ns.length > range.length + 20 else { return nil }
        let start = max(0, range.location - 400)
        let end = min(ns.length, range.location + range.length + 400)
        guard end > start else { return nil }
        return ns.substring(with: NSRange(location: start, length: end - start))
    }

    private func role(at p: NSPoint) -> String? {
        let ax = Self.axPoint(fromCocoa: p)
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(ax.x), Float(ax.y), &el) == .success,
              let el else { return nil }
        return stringAttr(el, kAXRoleAttribute)
    }

    /// Chromium and Electron only build their accessibility tree when asked.
    private func enableWebAccessibility(pid: pid_t) {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private func stringAttr(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    // MARK: Coordinates (AX = top-left of primary screen, Cocoa = bottom-left)

    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func cocoaRect(fromAX r: CGRect) -> NSRect {
        NSRect(x: r.origin.x, y: primaryHeight - r.origin.y - r.height, width: r.width, height: r.height)
    }

    static func axPoint(fromCocoa p: NSPoint) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }
}

// MARK: - ⌘C probe with clipboard restore

enum PasteboardProbe {
    static func copySelection(allowImages: Bool, completion: @escaping (Content?) -> Void) {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        let before = pb.changeCount
        ClipboardWatcher.suppressed = true

        postCommandC()

        var tries = 0
        func poll() {
            tries += 1
            if pb.changeCount != before {
                // Give the app a moment to finish writing all flavours.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                    var content = ClipboardWatcher.content(of: pb)
                    if !allowImages, case .image = content { content = nil }
                    restore(saved, to: pb)
                    ClipboardWatcher.acknowledge(pb.changeCount)
                    ClipboardWatcher.suppressed = false
                    completion(content)
                }
            } else if tries < 12 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.025, execute: poll)
            } else {
                ClipboardWatcher.suppressed = false
                completion(nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: poll)
    }

    private static func postCommandC() {
        let src = CGEventSource(stateID: .combinedSessionState)
        // Don't let physically held modifiers (e.g. ⌥ from the hotkey) leak into the ⌘C.
        src?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitSystemDefinedEvents], state: .eventSuppressionStateSuppressionInterval)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(KeyCode.c), keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(KeyCode.c), keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let d = item.data(forType: t) { dict[t] = d } }
            return dict
        }
    }

    private static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pb: NSPasteboard) {
        pb.clearContents()
        guard !items.isEmpty else { return }
        let objs: [NSPasteboardItem] = items.map { dict in
            let it = NSPasteboardItem()
            for (t, d) in dict { it.setData(d, forType: t) }
            return it
        }
        pb.writeObjects(objs)
    }
}
