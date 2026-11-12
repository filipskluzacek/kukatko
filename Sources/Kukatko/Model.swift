import AppKit
import ApplicationServices

enum Content {
    case text(String)
    case image(NSImage)

    var isImage: Bool { if case .image = self { return true } else { return false } }
    var text: String? { if case .text(let t) = self { return t } else { return nil } }
    var image: NSImage? { if case .image(let i) = self { return i } else { return nil } }
}

/// What the user marked, plus where it came from.
struct Captured {
    var content: Content
    var app: NSRunningApplication?
    /// Screen rect of the selection in Cocoa coordinates (bottom-left origin), if known.
    var anchor: NSRect?
    /// A bit of surrounding text, to disambiguate short selections.
    var context: String?
}

enum ResultMode: String, CaseIterable, Identifiable {
    case short, long, images
    var id: String { rawValue }
    var title: String {
        switch self {
        case .short: return "Krátce"
        case .long: return "Dlouze"
        case .images: return "Obrázky"
        }
    }
    var symbol: String {
        switch self {
        case .short: return "text.bubble"
        case .long: return "doc.text.magnifyingglass"
        case .images: return "photo.on.rectangle.angled"
        }
    }
}

enum AIModel: String, CaseIterable, Identifiable {
    case opus = "claude-opus-5-5"
    case sonnet = "claude-sonnet-5-5"
    case haiku = "claude-haiku-5-5"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .opus: return "Claude Opus 5.5 (nejchytřejší)"
        case .sonnet: return "Claude Sonnet 5.5 (vyvážený)"
        case .haiku: return "Claude Haiku 5.5 (nejrychlejší)"
        }
    }
}

enum Backend: String, CaseIterable, Identifiable {
    case gemini, cli, api
    var id: String { rawValue }
    var title: String {
        switch self {
        case .gemini: return "Google Gemini (cloud, zdarma)"
        case .cli: return "Claude Code (předplatné)"
        case .api: return "Claude API (platí se za použití)"
        }
    }
}

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

    func registerDefaults() {
        d.register(defaults: [
            "pillOnSelection": true,
            "pillOnImageCopy": true,
            "model": AIModel.opus.rawValue,
            "backend": Backend.gemini.rawValue,
            "language": "česky",
        ])
    }

    var pillOnSelection: Bool {
        get { d.bool(forKey: "pillOnSelection") }
        set { d.set(newValue, forKey: "pillOnSelection") }
    }
    var pillOnImageCopy: Bool {
        get { d.bool(forKey: "pillOnImageCopy") }
        set { d.set(newValue, forKey: "pillOnImageCopy") }
    }
    var model: AIModel {
        get { AIModel(rawValue: d.string(forKey: "model") ?? "") ?? .opus }
        set { d.set(newValue.rawValue, forKey: "model") }
    }
    var backend: Backend {
        get { Backend(rawValue: d.string(forKey: "backend") ?? "") ?? .gemini }
        set { d.set(newValue.rawValue, forKey: "backend") }
    }
    var language: String {
        get { d.string(forKey: "language") ?? "česky" }
        set { d.set(newValue, forKey: "language") }
    }
    var excludedApps: [String] {
        get { d.stringArray(forKey: "excludedApps") ?? [] }
        set { d.set(newValue, forKey: "excludedApps") }
    }

    var geminiKey: String? {
        get { SecretStore.read(account: "gemini-api-key") }
        set {
            if let v = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                SecretStore.write(v, account: "gemini-api-key")
            } else {
                SecretStore.delete(account: "gemini-api-key")
            }
        }
    }

    var apiKey: String? {
        get { SecretStore.read(account: "anthropic-api-key") }
        set {
            if let v = newValue?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                SecretStore.write(v, account: "anthropic-api-key")
            } else {
                SecretStore.delete(account: "anthropic-api-key")
            }
        }
    }
}

/// API keys live in a small file only this user can read (0600). The login keychain would ask
/// for access again after every app update, which is miserable for people installing new versions.
enum SecretStore {
    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kukatko", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        return dir.appendingPathComponent("klice.json")
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return [:] }
        return obj
    }

    private static func save(_ dict: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else { return }
        FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func read(account: String) -> String? { load()[account] }

    static func write(_ value: String, account: String) {
        var d = load(); d[account] = value; save(d)
    }

    static func delete(account: String) {
        var d = load(); d.removeValue(forKey: account); save(d)
    }
}

enum Permissions {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static func promptAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    static func openScreenRecordingSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}

enum KeyCode {
    static let c: UInt32 = 8
    static let e: UInt32 = 14
    static let r: UInt32 = 15
}

extension NSImage {
    /// JPEG/PNG data scaled so the long edge is at most `maxEdge` px – what the API accepts comfortably.
    func encodedForAI(maxEdge: CGFloat = 1568) -> (data: Data, mediaType: String)? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let scale = min(1, maxEdge / max(w, h))
        let tw = max(1, Int(w * scale)), th = max(1, Int(h * scale))
        guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: tw, height: th))
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let scaled = ctx.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: scaled)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return nil }
        return (data, "image/jpeg")
    }
}
