import AppKit
import Security

/// Self-update from the GitHub repo: `vydani/aktualizace.json` says which version is current and where its zip is.
/// The new app is only installed if it is signed by the same certificate as the running one.
@MainActor
final class Updater {
    static let feed = URL(string: "https://raw.githubusercontent.com/filipskluzacek/kukatko/main/vydani/aktualizace.json")!

    struct Release { let version: String; let zip: URL; let notes: String }

    private(set) var available: Release?
    private(set) var busy = false
    private var timer: Timer?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.check(userInitiated: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check(userInitiated: false) }
        }
    }

    func check(userInitiated: Bool, installWithoutAsking: Bool = false) {
        Task {
            let release = await Self.fetch()
            guard let release, Self.isNewer(release.version, than: Self.currentVersion) else {
                available = nil
                if userInitiated {
                    alert("Máte nejnovější verzi", "Kukátko \(Self.currentVersion) je aktuální.", buttons: ["OK"])
                }
                return
            }
            available = release
            if installWithoutAsking { install(release); return }
            // Ask once per version unless the user asked explicitly; the menu keeps offering it.
            let key = "updateOffered-\(release.version)"
            if userInitiated || !UserDefaults.standard.bool(forKey: key) {
                UserDefaults.standard.set(true, forKey: key)
                offer(release)
            }
        }
    }

    func offer(_ r: Release) {
        let notes = r.notes.isEmpty ? "" : "\n\nCo je nového:\n\(r.notes)"
        let answer = alert("Je tu Kukátko \(r.version)", "Máte verzi \(Self.currentVersion). Aktualizace trvá pár vteřin, Kukátko se pak samo znovu spustí.\(notes)",
                           buttons: ["Aktualizovat", "Později"])
        if answer == .alertFirstButtonReturn { install(r) }
    }

    func installAvailable() { if let r = available { install(r) } }

    // MARK: Install

    private func install(_ r: Release) {
        guard !busy else { return }
        busy = true
        Task {
            do {
                let newApp = try await Self.download(r)
                try Self.verifySameSigner(newApp)
                try relaunch(replacingWith: newApp)
            } catch {
                busy = false
                alert("Aktualizace se nepovedla", error.localizedDescription, buttons: ["OK"])
            }
        }
    }

    private static func download(_ r: Release) async throws -> URL {
        var req = URLRequest(url: r.zip)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 60
        let (tmpZip, resp) = try await URLSession.shared.download(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("Stažení selhalo.") }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kukatko-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", tmpZip.path, dir.path]
        try unzip.run()
        unzip.waitUntilExit()
        let app = dir.appendingPathComponent("Kukatko.app")
        guard unzip.terminationStatus == 0, FileManager.default.fileExists(atPath: app.path) else {
            throw UpdateError("Stažený balíček je poškozený.")
        }
        return app
    }

    /// The downloaded app must satisfy the running app's own designated requirement (same identifier + certificate).
    private static func verifySameSigner(_ app: URL) throws {
        var selfCode: SecCode?
        var requirement: SecRequirement?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
              SecCodeCopyDesignatedRequirement(selfCode as! SecStaticCode, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            throw UpdateError("Nepodařilo se ověřit podpis aktualizace.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess else {
            throw UpdateError("Aktualizace není podepsaná stejně jako nainstalované Kukátko, proto ji neinstaluji.")
        }
    }

    /// A tiny shell script waits for us to quit, swaps the bundle in place and starts the new version.
    private func relaunch(replacingWith newApp: URL) throws {
        let current = Bundle.main.bundleURL
        let backup = current.deletingLastPathComponent().appendingPathComponent(".Kukatko-stara.app")
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(backup.path)"
        mv "\(current.path)" "\(backup.path)" && mv "\(newApp.path)" "\(current.path)" && rm -rf "\(backup.path)" || mv "\(backup.path)" "\(current.path)"
        xattr -dr com.apple.quarantine "\(current.path)" 2>/dev/null
        open "\(current.path)"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try p.run()
        NSApp.terminate(nil)
    }

    // MARK: Feed

    private static func fetch() async -> Release? {
        var req = URLRequest(url: feed)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = obj["verze"] as? String,
              let z = (obj["zip"] as? String).flatMap(URL.init(string:)) else { return nil }
        return Release(version: v, zip: z, notes: obj["novinky"] as? String ?? "")
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    @discardableResult
    private func alert(_ title: String, _ text: String, buttons: [String]) -> NSApplication.ModalResponse {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.icon = NSApp.applicationIconImage
        for b in buttons { a.addButton(withTitle: b) }
        return a.runModal()
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
