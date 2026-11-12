import AppKit
import SwiftUI

// MARK: - Controller (window)

@MainActor
final class ResultController: NSObject, NSWindowDelegate {
    private var panel: ResultPanel?
    private var model: ResultModel?
    private var outsideMonitor: Any?

    var isVisible: Bool { panel?.isVisible ?? false }
    var isPinned: Bool { model?.pinned ?? false }

    func open(_ c: Captured, mode: ResultMode) {
        model?.cancelAll()
        let m = ResultModel(captured: c, mode: mode)
        model = m

        let p = panel ?? ResultPanel()
        p.delegate = self
        panel = p
        p.contentView = NSHostingView(rootView: ResultView(model: m, close: { [weak self] in self?.close() }))

        let size = NSSize(width: 460, height: mode == .images ? 520 : (mode == .short ? 300 : 480))
        if !p.isVisible || !m.pinned {
            p.setFrame(Self.frame(for: size, anchor: c.anchor ?? NSRect(origin: NSEvent.mouseLocation, size: .zero)), display: true)
        }
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            p.animator().alphaValue = 1
        }
        m.start(mode)
        installOutsideMonitor()
    }

    func close() {
        model?.cancelAll()
        removeOutsideMonitor()
        guard let p = panel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            p.animator().alphaValue = 0
        }, completionHandler: { p.orderOut(nil) })
    }

    private func installOutsideMonitor() {
        removeOutsideMonitor()
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, let p = self.panel, p.isVisible, self.model?.pinned != true else { return }
            if !p.frame.contains(NSEvent.mouseLocation) { self.close() }
        }
    }

    private func removeOutsideMonitor() {
        if let m = outsideMonitor { NSEvent.removeMonitor(m) }
        outsideMonitor = nil
    }

    private static func frame(for size: NSSize, anchor: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) } ?? NSScreen.main!
        let vis = screen.visibleFrame
        var x = anchor.minX
        var y = anchor.minY - 12 - size.height             // below the selection
        if y < vis.minY { y = anchor.maxY + 12 }            // or above it
        if y + size.height > vis.maxY { y = vis.maxY - size.height - 8 }
        x = min(max(x, vis.minX + 8), vis.maxX - size.width - 8)
        y = max(y, vis.minY + 8)
        return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }
}

final class ResultPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                   styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        minSize = NSSize(width: 340, height: 220)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { standardWindowButton(b)?.isHidden = true }
        backgroundColor = .clear
    }
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { AppDelegate.shared.result.close() }
}

// MARK: - Model

struct AnswerState {
    var text = ""
    var loading = false
    var error: String?
    var started = false
}

struct Turn: Identifiable {
    let id = UUID()
    var question: String
    var answer = AnswerState()
}

@MainActor
final class ResultModel: ObservableObject {
    let captured: Captured
    @Published var mode: ResultMode
    @Published var answers: [ResultMode: AnswerState] = [:]
    @Published var followUps: [ResultMode: [Turn]] = [:]
    @Published var images: [ImageHit] = []
    @Published var imagesLoading = false
    @Published var imagesStarted = false
    @Published var imageQuery = ""
    @Published var preview: ImageHit?
    @Published var pinned = false
    @Published var input = ""

    private var tasks: [Task<Void, Never>] = []

    init(captured: Captured, mode: ResultMode) {
        self.captured = captured
        self._mode = Published(initialValue: mode)
    }

    func cancelAll() { tasks.forEach { $0.cancel() }; tasks.removeAll() }

    func start(_ m: ResultMode) {
        mode = m
        if m == .images {
            if !imagesStarted { startImages() }
        } else if answers[m]?.started != true {
            ask(mode: m)
        }
    }

    // Text answers

    private func ask(mode m: ResultMode) {
        answers[m] = AnswerState(loading: true, started: true)
        let msgs = [Prompts.firstQuestion(for: captured, mode: m)]
        let effort = m == .short ? "low" : "medium"
        run(msgs, effort: effort) { [weak self] update in
            guard let self else { return }
            update(&self.answers[m, default: AnswerState()])
        }
    }

    func retry() {
        if mode == .images { imagesStarted = false; startImages() } else { answers[mode] = nil; ask(mode: mode) }
    }

    func sendFollowUp() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        input = ""
        let m = mode == .images ? .short : mode
        if mode == .images { mode = m }
        var msgs = [Prompts.firstQuestion(for: captured, mode: m)]
        if let a = answers[m]?.text, !a.isEmpty { msgs.append(AIMessage(role: .assistant, text: a)) }
        for t in followUps[m] ?? [] where !t.answer.text.isEmpty {
            msgs.append(AIMessage(role: .user, text: t.question))
            msgs.append(AIMessage(role: .assistant, text: t.answer.text))
        }
        msgs.append(AIMessage(role: .user, text: q))
        var turn = Turn(question: q)
        turn.answer.loading = true
        turn.answer.started = true
        followUps[m, default: []].append(turn)
        let id = turn.id
        run(msgs, effort: "medium") { [weak self] update in
            guard let self, let i = self.followUps[m]?.firstIndex(where: { $0.id == id }) else { return }
            update(&self.followUps[m]![i].answer)
        }
    }

    private func run(_ msgs: [AIMessage], effort: String, apply: @escaping (( inout AnswerState) -> Void) -> Void) {
        let system = Prompts.system()
        let t = Task { [weak self] in
            do {
                for try await chunk in AIClient.stream(system: system, messages: msgs, effort: effort) {
                    if Task.isCancelled { return }
                    await MainActor.run { apply { $0.text += chunk } }
                }
                await MainActor.run { apply { $0.loading = false } }
            } catch {
                if Task.isCancelled { return }
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run { apply { $0.loading = false; $0.error = msg } }
            }
            _ = self
        }
        tasks.append(t)
    }

    // Images

    private func startImages() {
        imagesStarted = true
        imagesLoading = true
        images = []
        let c = captured
        // Short selections are searchable as-is, right away.
        if let t = c.content.text, t.split(whereSeparator: \.isWhitespace).count <= 5, t.count <= 60 {
            let q = t.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
            imageQuery = q
            search(q, slot: 0, finishLoading: false)
        }
        let t = Task { [weak self] in
            var queries: [String] = []
            do {
                let raw = try await AIClient.complete(system: Prompts.keywordsSystem, messages: [Prompts.keywordsQuestion(for: c)], effort: "low", json: true)
                if let s = raw.firstIndex(of: "{"), let e = raw.lastIndex(of: "}"),
                   let obj = try? JSONSerialization.jsonObject(with: Data(raw[s...e].utf8)) as? [String: String] {
                    queries = [obj["cs"], obj["en"]].compactMap { $0 }.filter { !$0.isEmpty }
                }
            } catch {}
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self else { return }
                if self.imageQuery.isEmpty, let first = queries.first { self.imageQuery = first }
                if queries.isEmpty && self.imageQuery.isEmpty, let t = c.content.text {
                    self.imageQuery = String(t.prefix(60))
                    queries = [self.imageQuery]
                }
                if queries.isEmpty { self.imagesLoading = false; return }
                // Skip a query identical to the direct one; keep the local-language query first.
                let fresh = queries.filter { $0.lowercased() != self.imageQuery.lowercased() || self.slots.isEmpty }
                if fresh.isEmpty { self.imagesLoading = false }
                for (i, q) in fresh.enumerated() { self.search(q, slot: i + 1, finishLoading: i == fresh.count - 1) }
            }
        }
        tasks.append(t)
    }

    func searchCustom() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        input = ""
        imageQuery = q
        imagesLoading = true
        slots = [:]
        images = []
        search(q, slot: 0, finishLoading: true)
    }

    /// Results per query, shown in slot order so the best (first) query stays on top.
    private var slots: [Int: [ImageHit]] = [:]

    private func search(_ q: String, slot: Int, finishLoading: Bool) {
        let lang = Settings.shared.language.lowercased().hasPrefix("angl") ? "en" : "cs"
        let t = Task { [weak self] in
            let hits = await ImageSearch.search(q, language: lang)
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self else { return }
                self.slots[slot] = hits
                var seen = Set<URL>()
                self.images = self.slots.keys.sorted().flatMap { self.slots[$0]! }.filter { seen.insert($0.full).inserted }
                if finishLoading { self.imagesLoading = false }
            }
        }
        tasks.append(t)
    }

    var currentAnswerText: String {
        var parts: [String] = []
        if let a = answers[mode]?.text { parts.append(a) }
        for t in followUps[mode] ?? [] { parts.append("**\(t.question)**\n\n\(t.answer.text)") }
        return parts.joined(separator: "\n\n")
    }
}

// MARK: - Views

struct ResultView: View {
    @ObservedObject var model: ResultModel
    let close: () -> Void
    @Namespace private var tabNS
    @FocusState private var inputFocused: Bool
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            header
            tabs.padding(.horizontal, 14).padding(.bottom, 8)
            Divider().opacity(0.5)
            ZStack {
                if model.mode == .images { ImagesView(model: model) } else { answerView }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider().opacity(0.5)
            footer
        }
        .background(.regularMaterial)
        .overlay(alignment: .center) {
            if let hit = model.preview { ImagePreview(hit: hit, close: { model.preview = nil }) }
        }
        .ignoresSafeArea()
    }

    // Header: where it came from + what was selected
    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            if let img = model.captured.content.image {
                Image(nsImage: img).resizable().scaledToFill()
                    .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 8))
            } else if let icon = model.captured.app?.icon {
                Image(nsImage: icon).resizable().frame(width: 22, height: 22).padding(.top, 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let t = model.captured.content.text {
                    Text(t).font(.system(size: 13, weight: .semibold)).lineLimit(2).truncationMode(.tail)
                } else {
                    Text("Obrázek").font(.system(size: 13, weight: .semibold))
                }
                if let name = model.captured.app?.localizedName {
                    Text(name).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            IconButton(symbol: model.pinned ? "pin.fill" : "pin", help: model.pinned ? "Odepnout" : "Připnout – nezavře se po kliknutí jinam") {
                model.pinned.toggle()
            }
            IconButton(symbol: "xmark", help: "Zavřít (Esc)", action: close)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(ResultMode.allCases) { m in
                Button { withAnimation(.snappy(duration: 0.25)) { model.start(m) } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: m.symbol).font(.system(size: 11, weight: .semibold))
                        Text(m == .images && model.captured.content.isImage ? "Podobné" : m.title)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .foregroundStyle(model.mode == m ? Color.primary : Color.secondary)
                    .background {
                        if model.mode == m {
                            Capsule().fill(Color.primary.opacity(0.09)).matchedGeometryEffect(id: "tab", in: tabNS)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private var answerView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    AnswerBlock(state: model.answers[model.mode] ?? AnswerState(loading: true), retry: model.retry)
                    ForEach(model.followUps[model.mode] ?? []) { turn in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(turn.question)
                                .font(.system(size: 12.5, weight: .semibold))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.12)))
                            AnswerBlock(state: turn.answer, retry: nil)
                        }
                        .id(turn.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.followUps[model.mode]?.count ?? 0) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: model.mode == .images ? "magnifyingglass" : "bubble.left")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            TextField(model.mode == .images ? "Hledat jiný obrázek…" : "Zeptat se dál…", text: $model.input)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($inputFocused)
                .onSubmit { model.mode == .images ? model.searchCustom() : model.sendFollowUp() }
            if model.mode == .images {
                let q = model.imageQuery.isEmpty ? (model.captured.content.text ?? "") : model.imageQuery
                IconButton(symbol: "globe", help: "Otevřít v Google Obrázcích") {
                    if model.captured.content.isImage, let img = model.captured.content.image {
                        ClipboardOut.copy(image: img)
                        NSWorkspace.shared.open(URL(string: "https://lens.google.com/")!)
                    } else {
                        NSWorkspace.shared.open(ImageSearch.googleImagesURL(q))
                    }
                }
            } else {
                IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Kopírovat odpověď") {
                    ClipboardOut.copy(text: model.currentAnswerText)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct AnswerBlock: View {
    let state: AnswerState
    let retry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !state.text.isEmpty {
                MarkdownView(text: state.text)
            }
            if state.loading && state.text.isEmpty {
                ThinkingDots()
            }
            if let err = state.error {
                VStack(alignment: .leading, spacing: 6) {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12.5)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if let retry { Button("Zkusit znovu", action: retry).controlSize(.small) }
                        Button("Nastavení…") { AppDelegate.shared.showSettings() }.controlSize(.small)
                    }
                }
            }
        }
    }
}

struct ThinkingDots: View {
    @State private var phase = 0.0
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle().fill(Color.secondary)
                        .frame(width: 6, height: 6)
                        .opacity(0.25 + 0.6 * max(0, sin(t * 3.2 - Double(i) * 0.7)))
                }
            }
        }
        .frame(height: 18)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(hover ? 0.09 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .onHover { hover = $0 }
    }
}

// MARK: - Images

struct ImagesView: View {
    @ObservedObject var model: ResultModel
    private let cols = [GridItem(.adaptive(minimum: 128, maximum: 220), spacing: 8)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !model.imageQuery.isEmpty {
                    Text("Hledám: \(model.imageQuery)").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                if model.images.isEmpty && model.imagesLoading {
                    HStack { ThinkingDots(); Text("Hledám obrázky…").font(.system(size: 12.5)).foregroundStyle(.secondary) }
                } else if model.images.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Nic jsem nenašel.").font(.system(size: 13, weight: .medium))
                        Text("Zkuste dole napsat jiný dotaz, nebo otevřít Google Obrázky (ikona glóbu).")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                LazyVGrid(columns: cols, spacing: 8) {
                    ForEach(model.images) { hit in
                        ImageCell(hit: hit) { model.preview = hit }
                    }
                }
                if model.imagesLoading && !model.images.isEmpty {
                    HStack { Spacer(); ThinkingDots(); Spacer() }
                }
            }
            .padding(14)
        }
    }
}

struct ImageCell: View {
    let hit: ImageHit
    let open: () -> Void
    @State private var hover = false

    var body: some View {
        AsyncImage(url: hit.thumb, transaction: Transaction(animation: .easeOut(duration: 0.35))) { phase in
            switch phase {
            case .success(let img): img.resizable().scaledToFill()
            case .failure: Color.primary.opacity(0.05).overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
            default: Color.primary.opacity(0.05)
            }
        }
        .frame(height: 110)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay(alignment: .bottomLeading) {
            if hover {
                Text(hit.source)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .onDrag { NSItemProvider(object: hit.full as NSURL) }
        .contextMenu { ImageActions(hit: hit) }
        .help(hit.title)
    }
}

struct ImageActions: View {
    let hit: ImageHit
    var body: some View {
        Button("Kopírovat obrázek") { Task { await ClipboardOut.copy(remote: hit.full) } }
        Button("Uložit do Stažených") { Task { await ClipboardOut.saveToDownloads(hit.full) } }
        if let page = hit.page { Button("Otevřít zdroj") { NSWorkspace.shared.open(page) } }
        Button("Otevřít obrázek v prohlížeči") { NSWorkspace.shared.open(hit.full) }
    }
}

struct ImagePreview: View {
    let hit: ImageHit
    let close: () -> Void
    @State private var status: String?

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                IconButton(symbol: "chevron.left", help: "Zpět", action: close)
                Text(hit.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Spacer()
            }
            AsyncImage(url: hit.full, transaction: Transaction(animation: .easeOut(duration: 0.35))) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFit()
                default:
                    AsyncImage(url: hit.thumb) { $0.resizable().scaledToFit() } placeholder: { ThinkingDots() }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrag { NSItemProvider(object: hit.full as NSURL) }
            Text("\(hit.source)\(hit.width > 0 ? " · \(hit.width)×\(hit.height)" : "")")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Kopírovat") { Task { status = await ClipboardOut.copy(remote: hit.full) ? "Zkopírováno" : "Nepodařilo se stáhnout" } }
                Button("Uložit") { Task { status = await ClipboardOut.saveToDownloads(hit.full) ? "Uloženo do Stažených" : "Nepodařilo se uložit" } }
                if let page = hit.page { Button("Zdroj") { NSWorkspace.shared.open(page) } }
                if let status { Text(status).font(.system(size: 11.5)).foregroundStyle(.secondary) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .transition(.opacity)
    }
}

// MARK: - Clipboard out

enum ClipboardOut {
    static func copy(text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: .kukatkoOwn)
        pb.writeObjects([item])
    }

    static func copy(image: NSImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        if let tiff = image.tiffRepresentation {
            item.setData(tiff, forType: .tiff)
            if let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) { item.setData(png, forType: .png) }
        }
        item.setData(Data(), forType: .kukatkoOwn)
        pb.writeObjects([item])
    }

    @discardableResult
    static func copy(remote url: URL) async -> Bool {
        guard let data = await download(url), let img = NSImage(data: data) else { return false }
        await MainActor.run { copy(image: img) }
        return true
    }

    @discardableResult
    static func saveToDownloads(_ url: URL) async -> Bool {
        guard let data = await download(url) else { return false }
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        if name.isEmpty || !name.contains(".") { name = "obrazek-\(Int(Date().timeIntervalSince1970)).jpg" }
        var dest = dir.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\((name as NSString).deletingPathExtension) \(n).\((name as NSString).pathExtension)")
            n += 1
        }
        do { try data.write(to: dest); NSWorkspace.shared.activateFileViewerSelecting([dest]); return true } catch { return false }
    }

    private static func download(_ url: URL) async -> Data? {
        var req = URLRequest(url: url)
        req.setValue("Kukatko/1.0 (macOS image lookup)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}
