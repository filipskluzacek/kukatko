import AppKit
import Carbon.HIToolbox

/// Global shortcuts via Carbon – works without any permission.
final class HotkeyCenter {
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var installed = false

    func register(id: UInt32, keyCode: UInt32, modifiers: NSEvent.ModifierFlags, action: @escaping () -> Void) {
        installHandlerIfNeeded()
        handlers[id] = action
        var carbonMods: UInt32 = 0
        if modifiers.contains(.command) { carbonMods |= UInt32(cmdKey) }
        if modifiers.contains(.option) { carbonMods |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbonMods |= UInt32(controlKey) }
        if modifiers.contains(.shift) { carbonMods |= UInt32(shiftKey) }
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x4B554B41), id: id) // KUKA
        if RegisterEventHotKey(keyCode, carbonMods, hkID, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            refs.append(ref)
        }
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            let id = hk.id
            DispatchQueue.main.async { center.handlers[id]?() }
            return noErr
        }, 1, &spec, me, nil)
    }
}

/// Interactive region capture using the system's own crosshair (same as ⇧⌘4).
enum ScreenRegion {
    static func capture(_ completion: @escaping (NSImage?) -> Void) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kukatko-\(UUID().uuidString).png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-i", "-x", "-o", url.path]
        p.terminationHandler = { _ in
            let img = NSImage(contentsOf: url)
            try? FileManager.default.removeItem(at: url)
            DispatchQueue.main.async { completion(img) }
        }
        do { try p.run() } catch { completion(nil) }
    }
}
