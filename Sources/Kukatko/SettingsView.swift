import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @State private var geminiKey = Settings.shared.geminiKey ?? ""
    @State private var geminiSaved = Settings.shared.geminiKey != nil
    @State private var apiKey = Settings.shared.apiKey ?? ""
    @State private var keySaved = Settings.shared.apiKey != nil
    @State private var model = Settings.shared.model
    @State private var backend = Settings.shared.backend
    @State private var language = Settings.shared.language
    @State private var pillSelection = Settings.shared.pillOnSelection
    @State private var pillImage = Settings.shared.pillOnImageCopy
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var axGranted = Permissions.accessibilityGranted
    @State private var testResult: String?
    @State private var testing = false

    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    private var claudeModelPicker: some View {
        Picker("Model", selection: $model) {
            ForEach(AIModel.allCases) { Text($0.title).tag($0) }
        }
        .onChange(of: model) { _, v in Settings.shared.model = v }
    }

    var body: some View {
        Form {
            Section("Umělá inteligence") {
                Picker("Služba", selection: $backend) {
                    ForEach(Backend.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: backend) { _, v in Settings.shared.backend = v; testResult = nil }

                switch backend {
                case .gemini:
                    GeminiKeyField(key: $geminiKey, saved: $geminiSaved)
                    Text("Bezplatná úroveň Google AI Studia: stačí účet Google, platební karta není potřeba. Google smí dotazy z bezplatné úrovně použít ke zlepšování svých služeb, proto do Kukátka neposílejte citlivé údaje.")
                        .font(.caption).foregroundStyle(.secondary)
                case .cli:
                    Text(CLIBackend.executable == nil
                         ? "Claude Code na tomto Macu není nainstalovaný."
                         : "Použije Claude Code přihlášený v Terminálu (příkaz „claude“). Počítá se do limitů předplatného, ne za tokeny.")
                        .font(.caption).foregroundStyle(.secondary)
                    claudeModelPicker
                case .api:
                    HStack {
                        SecureField("API klíč (sk-ant-…)", text: $apiKey)
                        Button(keySaved ? "Uloženo" : "Uložit") {
                            Settings.shared.apiKey = apiKey
                            keySaved = Settings.shared.apiKey != nil
                        }
                        .disabled(keySaved && apiKey == (Settings.shared.apiKey ?? ""))
                    }
                    .onChange(of: apiKey) { _, _ in keySaved = false }
                    Text("Nejchytřejší, ale každý dotaz se platí.")
                        .font(.caption).foregroundStyle(.secondary)
                    claudeModelPicker
                }

                HStack {
                    Button(testing ? "Zkouším…" : "Vyzkoušet") { test() }.disabled(testing)
                    if let testResult { Text(testResult).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
                }
            }

            Section("Odpovědi") {
                Picker("Jazyk", selection: $language) {
                    Text("Česky").tag("česky")
                    Text("Slovensky").tag("slovensky")
                    Text("Anglicky").tag("anglicky")
                    Text("Německy").tag("německy")
                }
                .onChange(of: language) { _, v in Settings.shared.language = v }
            }

            Section("Kdy se nabídne") {
                Toggle("Po označení textu myší", isOn: $pillSelection)
                    .onChange(of: pillSelection) { _, v in Settings.shared.pillOnSelection = v }
                Toggle("Po zkopírování obrázku", isOn: $pillImage)
                    .onChange(of: pillImage) { _, v in Settings.shared.pillOnImageCopy = v }
                LabeledContent("Označené (i obrázek)") { Text("⌥⌘E").monospaced() }
                LabeledContent("Oblast obrazovky") { Text("⌥⌘R").monospaced() }
                LabeledContent("Kdekoli") { Text("pravé tlačítko → Služby → Kukátko").foregroundStyle(.secondary) }
            }

            Section("Systém") {
                LabeledContent("Zpřístupnění") {
                    if axGranted {
                        Label("Povoleno", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Povolit…") { Permissions.promptAccessibility(); Permissions.openAccessibilitySettings() }
                    }
                }
                if !axGranted {
                    Text("Když je Kukátko v seznamu zapnuté, a stejně to nejde: vyberte ho, odeberte tlačítkem − a přidejte znovu.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Spouštět po přihlášení", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in
                        do { if v { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 620)
        .onReceive(timer) { _ in axGranted = Permissions.accessibilityGranted }
    }

    private func test() {
        testing = true
        testResult = nil
        Task {
            do {
                let start = Date()
                let out = try await AIClient.complete(system: "Odpověz jedním slovem.", messages: [AIMessage(role: .user, text: "Řekni ahoj.")])
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                await MainActor.run { testResult = "Funguje (\(ms) ms): \(out.prefix(40))"; testing = false }
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run { testResult = msg; testing = false }
            }
        }
    }
}

/// Paste field + "get a free key" link, shared by Settings and onboarding.
struct GeminiKeyField: View {
    @Binding var key: String
    @Binding var saved: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecureField("Klíč Gemini (AIza…)", text: $key)
                    .textFieldStyle(.roundedBorder)
                Button(saved ? "Uloženo" : "Uložit") {
                    Settings.shared.geminiKey = key
                    saved = Settings.shared.geminiKey != nil
                }
                .disabled(saved && key == (Settings.shared.geminiKey ?? ""))
            }
            .onChange(of: key) { _, _ in saved = false }
            Button("Získat klíč zdarma ↗") { NSWorkspace.shared.open(GeminiBackend.keyPage) }
                .buttonStyle(.link)
                .font(.callout)
        }
    }
}

struct OnboardingView: View {
    let close: () -> Void
    @State private var granted = Permissions.accessibilityGranted
    @State private var key = Settings.shared.geminiKey ?? ""
    @State private var keySaved = Settings.shared.geminiKey != nil
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 28, weight: .semibold))
                    .frame(width: 52, height: 52)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Kukátko").font(.system(size: 22, weight: .bold))
                    Text("Označte cokoli, kdekoli. Kukátko to vysvětlí.").foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Step(n: 1, text: "Označte text myší v jakékoli aplikaci – vedle se objeví lišta **Krátce · Dlouze · Proč · Obrázek**.")
                Step(n: 2, text: "Zkopírujte obrázek (nebo ⌃⇧⌘4) – lišta se nabídne taky.")
                Step(n: 3, text: "**⌥⌘E** vysvětlí, co je zrovna označené, **⌥⌘R** vybranou oblast obrazovky.")
            }
            Divider()

            Text("1. Klíč ke Google Gemini").font(.headline)
            if keySaved {
                Label("Klíč je uložený.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Text("Zdarma a bez platební karty: klikněte na odkaz, přihlaste se účtem Google, dejte **Create API key**, klíč zkopírujte a vložte sem.")
                    .fixedSize(horizontal: false, vertical: true)
                GeminiKeyField(key: $key, saved: $keySaved)
            }

            Text("2. Povolení Zpřístupnění").font(.headline)
            if granted {
                Label("Zpřístupnění je povolené.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Text("Aby Kukátko vidělo, co máte označené, zapněte ho v Nastavení systému → Soukromí a zabezpečení → Zpřístupnění. Když tam už je a nefunguje, odeberte ho tlačítkem − a přidejte znovu.")
                    .fixedSize(horizontal: false, vertical: true)
                Button("Otevřít Nastavení systému") {
                    Permissions.promptAccessibility()
                    Permissions.openAccessibilitySettings()
                }
            }

            HStack {
                Spacer()
                Button(granted && keySaved ? "Hotovo" : "Později", action: close)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(26)
        .frame(width: 480)
        .onReceive(timer) { _ in granted = Permissions.accessibilityGranted }
    }

    private struct Step: View {
        let n: Int
        let text: LocalizedStringKey
        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(n)").font(.system(size: 12, weight: .bold)).frame(width: 20, height: 20)
                    .background(Circle().fill(Color.accentColor.opacity(0.15)))
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
