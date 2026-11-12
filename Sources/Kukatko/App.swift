import AppKit
import SwiftUI
import ServiceManagement

@main
enum KukatkoMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static private(set) var shared: AppDelegate!

    private var statusItem: NSStatusItem!
    let selection = SelectionWatcher()
    let clipboard = ClipboardWatcher()
    let hotkeys = HotkeyCenter()
    let pill = PillController()
    let result = ResultController()
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        Settings.shared.registerDefaults()
        buildStatusItem()

        NSApp.servicesProvider = ServiceProvider()
        NSUpdateDynamicServices()

        selection.onSelection = { [weak self] captured in
            guard Settings.shared.pillOnSelection else { return }
            self?.pill.show(for: captured)
        }
        selection.onDismissGesture = { [weak self] in self?.pill.hide() }
        selection.start()

        clipboard.onImage = { [weak self] image in
            guard Settings.shared.pillOnImageCopy else { return }
            self?.pill.show(for: Captured(content: .image(image), app: NSWorkspace.shared.frontmostApplication, anchor: nil, context: nil))
        }
        clipboard.start()

        hotkeys.register(id: 1, keyCode: KeyCode.e, modifiers: [.command, .option]) { [weak self] in
            self?.captureSelectionNow()
        }
        hotkeys.register(id: 2, keyCode: KeyCode.r, modifiers: [.command, .option]) { [weak self] in
            self?.captureScreenRegion()
        }

        // Diagnostics: Kukatko --stav  → prints permission/key state and quits.
        if CommandLine.arguments.contains("--stav") {
            let line = "zpristupneni=\(Permissions.accessibilityGranted) klic=\(Settings.shared.geminiKey != nil) sluzba=\(Settings.shared.backend.rawValue)\n"
            print(line, terminator: "")
            try? line.write(toFile: NSTemporaryDirectory() + "kukatko-stav.txt", atomically: true, encoding: .utf8)
            exit(0)
        }

        // Test hook: Kukatko --ukazka "text" [short|long|images]  /  --ukazka-obrazek /cesta.png [mode]
        let args = CommandLine.arguments
        if let i = args.firstIndex(where: { $0 == "--ukazka" || $0 == "--ukazka-obrazek" }), i + 1 < args.count {
            let mode = (i + 2 < args.count ? ResultMode(rawValue: args[i + 2]) : nil) ?? .short
            let content: Content? = args[i] == "--ukazka"
                ? .text(args[i + 1])
                : NSImage(contentsOfFile: args[i + 1]).map { .image($0) }
            if let content {
                let screen = NSScreen.main!.visibleFrame
                let anchor = NSRect(x: screen.midX - 230, y: screen.midY + 260, width: 120, height: 18)
                result.open(Captured(content: content, app: nil, anchor: anchor, context: nil), mode: mode)
                result.pin()
                pill.show(for: Captured(content: content, app: nil, anchor: NSRect(x: anchor.minX, y: anchor.maxY + 70, width: 120, height: 18), context: nil), force: true)
            }
            // --snimek <složka> <sekundy>: snapshot our own windows to PNG (no screen-recording permission needed).
            if let s = args.firstIndex(of: "--snimek"), s + 2 < args.count, let delay = Double(args[s + 2]) {
                let dir = URL(fileURLWithPath: args[s + 1])
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    for (n, w) in NSApp.windows.enumerated() {
                        guard w.isVisible else { continue }
                        guard let v = w.contentView,
                              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
                        v.cacheDisplay(in: v.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("okno-\(n).png"))
                    }
                    NSApp.terminate(nil)
                }
            }
            return
        }

        if !Permissions.accessibilityGranted || (Settings.shared.backend == .gemini && Settings.shared.geminiKey == nil) {
            showOnboarding()
        }
    }

    // MARK: Status bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "text.magnifyingglass", accessibilityDescription: "Kukátko")
            img?.isTemplate = true
            button.image = img
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let a = NSMenuItem(title: "Vysvětlit označené", action: #selector(menuCapture), keyEquivalent: "e")
        a.keyEquivalentModifierMask = [.command, .option]
        a.target = self
        menu.addItem(a)
        let b = NSMenuItem(title: "Vybrat oblast obrazovky…", action: #selector(menuRegion), keyEquivalent: "r")
        b.keyEquivalentModifierMask = [.command, .option]
        b.target = self
        menu.addItem(b)
        let c = NSMenuItem(title: "Vysvětlit obsah schránky", action: #selector(menuClipboard), keyEquivalent: "")
        c.target = self
        menu.addItem(c)
        menu.addItem(.separator())

        let t1 = NSMenuItem(title: "Lišta po označení textu", action: #selector(togglePillSelection), keyEquivalent: "")
        t1.state = Settings.shared.pillOnSelection ? .on : .off
        t1.target = self
        menu.addItem(t1)
        let t2 = NSMenuItem(title: "Lišta po zkopírování obrázku", action: #selector(togglePillImage), keyEquivalent: "")
        t2.state = Settings.shared.pillOnImageCopy ? .on : .off
        t2.target = self
        menu.addItem(t2)
        menu.addItem(.separator())

        if !Permissions.accessibilityGranted || (Settings.shared.backend == .gemini && Settings.shared.geminiKey == nil) {
            let p = NSMenuItem(title: "⚠︎ Dokončit nastavení…", action: #selector(menuOnboarding), keyEquivalent: "")
            p.target = self
            menu.addItem(p)
        }
        let s = NSMenuItem(title: "Nastavení…", action: #selector(showSettings), keyEquivalent: ",")
        s.target = self
        menu.addItem(s)
        let q = NSMenuItem(title: "Ukončit Kukátko", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(q)
    }

    @objc private func menuCapture() {
        // Menu steals focus from nothing (accessory app), the previous app stays frontmost.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.captureSelectionNow() }
    }
    @objc private func menuRegion() { captureScreenRegion() }
    @objc private func menuClipboard() {
        if let content = ClipboardWatcher.currentContent() {
            result.open(Captured(content: content, app: nil, anchor: nil, context: nil), mode: .short)
        } else {
            NSSound.beep()
        }
    }
    @objc private func togglePillSelection() { Settings.shared.pillOnSelection.toggle() }
    @objc private func togglePillImage() { Settings.shared.pillOnImageCopy.toggle() }
    @objc private func menuOnboarding() { showOnboarding() }

    // MARK: Actions

    func captureSelectionNow() {
        selection.captureNow { [weak self] captured in
            guard let self else { return }
            if let captured {
                self.pill.show(for: captured, force: true)
            } else if let content = ClipboardWatcher.currentContent(), case .image = content {
                self.pill.show(for: Captured(content: content, app: nil, anchor: nil, context: nil), force: true)
            } else {
                NSSound.beep()
            }
        }
    }

    func captureScreenRegion() {
        pill.hide()
        ScreenRegion.capture { [weak self] image in
            guard let self, let image else { return }
            self.result.open(Captured(content: .image(image), app: nil, anchor: nil, context: nil), mode: .short)
        }
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Kukátko – nastavení"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            settingsWindow = w
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Vítá vás Kukátko"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: OnboardingView(close: { [weak w] in w?.close() }))
            w.center()
            onboardingWindow = w
        }
        NSApp.activate()
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Services menu ("plugin" in every app's right-click → Služby)

final class ServiceProvider: NSObject {
    @objc func explainShort(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handle(pboard, mode: .short)
    }
    @objc func explainLong(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handle(pboard, mode: .long)
    }
    @objc func findImage(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handle(pboard, mode: .images)
    }

    private func handle(_ pboard: NSPasteboard, mode: ResultMode) {
        guard let content = ClipboardWatcher.content(of: pboard) else { return }
        let captured = Captured(content: content, app: NSWorkspace.shared.frontmostApplication, anchor: nil, context: nil)
        DispatchQueue.main.async {
            AppDelegate.shared.result.open(captured, mode: mode)
        }
    }
}
