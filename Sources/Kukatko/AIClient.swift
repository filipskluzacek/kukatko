import AppKit

struct AIMessage {
    enum Role: String { case user, assistant }
    var role: Role
    var text: String
    var image: NSImage? = nil
}

enum AIError: LocalizedError {
    case noBackend
    case http(Int, String)
    case refused
    case cli(String)
    case message(String)
    case noGeminiKey

    var errorDescription: String? {
        switch self {
        case .noBackend:
            return "Chybí připojení k Claude. V Nastavení vložte API klíč, nebo se v Terminálu přihlaste příkazem „claude“."
        case .message(let msg):
            return msg
        case .noGeminiKey:
            return "Chybí klíč ke Google Gemini. V Nastavení klikněte na „Získat klíč zdarma“, zkopírujte ho a vložte."
        case .http(let code, let msg):
            if code == 401 { return "API klíč nefunguje (401). Zkontrolujte ho v Nastavení." }
            if code == 429 { return "Moc dotazů najednou (429). Zkuste to za chvilku." }
            if code == 529 || code == 503 { return "Claude je teď přetížený. Zkuste to znovu." }
            return "Chyba API \(code): \(msg)"
        case .refused:
            return "Claude tuhle odpověď odmítl."
        case .cli(let msg):
            if msg.localizedCaseInsensitiveContains("authenticate") || msg.localizedCaseInsensitiveContains("login") {
                return "Claude Code není přihlášený. Otevřete Terminál, spusťte „claude“ a přihlaste se (nebo vložte API klíč v Nastavení)."
            }
            return msg
        }
    }
}

enum AIClient {
    /// Streams answer text from the backend chosen in Settings (Gemini free tier by default).
    static func stream(system: String, messages: [AIMessage], effort: String, maxTokens: Int = 8000, json: Bool = false) -> AsyncThrowingStream<String, Error> {
        let s = Settings.shared
        switch s.backend {
        case .gemini:
            guard let key = s.geminiKey else { return failing(AIError.noGeminiKey) }
            return GeminiBackend.stream(key: key, model: s.geminiModel, system: system, messages: messages, json: json)
        case .cli:
            guard let cli = CLIBackend.executable else { return failing(AIError.noBackend) }
            return CLIBackend.stream(exe: cli, model: s.model, system: system, messages: messages, effort: effort)
        case .api:
            guard let key = s.apiKey else { return failing(AIError.noBackend) }
            return APIBackend.stream(key: key, model: s.model, system: system, messages: messages, effort: effort, maxTokens: maxTokens)
        }
    }

    /// Convenience: whole answer at once (for short helper calls like image keywords).
    static func complete(system: String, messages: [AIMessage], effort: String = "low", json: Bool = false) async throws -> String {
        var out = ""
        for try await chunk in stream(system: system, messages: messages, effort: effort, maxTokens: 1000, json: json) { out += chunk }
        return out
    }

    private static func failing(_ e: Error) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish(throwing: e) }
    }

    static func contentBlocks(_ m: AIMessage) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        if let img = m.image, let enc = img.encodedForAI() {
            blocks.append(["type": "image", "source": ["type": "base64", "media_type": enc.mediaType, "data": enc.data.base64EncodedString()]])
        }
        blocks.append(["type": "text", "text": m.text])
        return blocks
    }
}

// MARK: - Claude API (raw HTTP + SSE; Swift has no official SDK)

enum APIBackend {
    static func stream(key: String, model: AIModel, system: String, messages: [AIMessage], effort: String, maxTokens: Int) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
                    req.httpMethod = "POST"
                    req.timeoutInterval = 300
                    req.setValue("application/json", forHTTPHeaderField: "content-type")
                    req.setValue(key, forHTTPHeaderField: "x-api-key")
                    req.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")

                    var body: [String: Any] = [
                        "model": model.rawValue,
                        "max_tokens": maxTokens,
                        "stream": true,
                        "system": system,
                        "output_config": ["effort": effort],
                        "messages": messages.map { ["role": $0.role.rawValue, "content": AIClient.contentBlocks($0)] },
                    ]
                    // Server-side fallback on a safety decline (not offered for Haiku).
                    if model != .haiku {
                        req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
                        body["fallbacks"] = "default"
                    }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if status != 200 {
                        var raw = ""
                        for try await line in bytes.lines { raw += line; if raw.count > 2000 { break } }
                        let msg = (try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
                            .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? raw
                        throw AIError.http(status, msg)
                    }

                    var refused = false
                    var gotText = false
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                              let type = obj["type"] as? String else { continue }
                        switch type {
                        case "content_block_delta":
                            if let delta = obj["delta"] as? [String: Any],
                               delta["type"] as? String == "text_delta",
                               let text = delta["text"] as? String {
                                gotText = true
                                continuation.yield(text)
                            }
                        case "message_delta":
                            if let d = obj["delta"] as? [String: Any], d["stop_reason"] as? String == "refusal" { refused = true }
                        case "error":
                            let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? "neznámá chyba"
                            throw AIError.http(500, msg)
                        default: break
                        }
                    }
                    if refused && !gotText { throw AIError.refused }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Claude Code CLI (uses the user's subscription login)

enum CLIBackend {
    static var executable: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
            "\(home)/.claude/local/claude", "\(home)/.npm-global/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func stream(exe: String, model: AIModel, system: String, messages: [AIMessage], effort: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.currentDirectoryURL = FileManager.default.temporaryDirectory
            p.arguments = [
                "-p", "--input-format", "stream-json", "--output-format", "stream-json",
                "--include-partial-messages", "--verbose",
                "--model", model.rawValue, "--effort", effort,
                "--tools", "", "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
                "--setting-sources", "", "--disable-slash-commands", "--no-session-persistence",
                "--system-prompt", system,
            ]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
            env.removeValue(forKey: "ANTHROPIC_API_KEY")
            p.environment = env

            let input = Pipe(), output = Pipe(), errPipe = Pipe()
            p.standardInput = input
            p.standardOutput = output
            p.standardError = errPipe

            // The CLI takes one user turn; earlier turns go in as a transcript.
            let last = messages.last!
            var text = last.text
            if messages.count > 1 {
                let history = messages.dropLast().map { ($0.role == .user ? "Uživatel: " : "Ty: ") + $0.text }.joined(separator: "\n\n")
                text = "Dosavadní rozhovor:\n\(history)\n\nNová otázka: \(last.text)"
            }
            let image = messages.first(where: { $0.image != nil })?.image
            let msg: [String: Any] = ["type": "user", "message": ["role": "user", "content": AIClient.contentBlocks(AIMessage(role: .user, text: text, image: image))]]

            var buffer = Data()
            var gotText = false
            var resultError: String?
            output.fileHandleForReading.readabilityHandler = { h in
                let chunk = h.availableData
                if chunk.isEmpty { h.readabilityHandler = nil; return }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: buffer.startIndex..<nl)
                    buffer.removeSubrange(buffer.startIndex...nl)
                    guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    if obj["type"] as? String == "stream_event",
                       let ev = obj["event"] as? [String: Any], ev["type"] as? String == "content_block_delta",
                       let d = ev["delta"] as? [String: Any], d["type"] as? String == "text_delta",
                       let t = d["text"] as? String {
                        gotText = true
                        continuation.yield(t)
                    } else if obj["type"] as? String == "result" {
                        if obj["is_error"] as? Bool == true { resultError = obj["result"] as? String ?? "Claude Code selhal." }
                    }
                }
            }
            p.terminationHandler = { proc in
                output.fileHandleForReading.readabilityHandler = nil
                if let resultError, !gotText {
                    continuation.finish(throwing: AIError.cli(resultError))
                } else if proc.terminationStatus != 0 && !gotText {
                    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    continuation.finish(throwing: AIError.cli(err.isEmpty ? "Claude Code skončil s chybou \(proc.terminationStatus)." : err))
                } else {
                    continuation.finish()
                }
            }
            do {
                try p.run()
                let data = try JSONSerialization.data(withJSONObject: msg)
                input.fileHandleForWriting.write(data)
                input.fileHandleForWriting.write(Data([0x0A]))
                try? input.fileHandleForWriting.close()
            } catch {
                continuation.finish(throwing: AIError.cli("Nepodařilo se spustit Claude Code: \(error.localizedDescription)"))
            }
            continuation.onTermination = { _ in if p.isRunning { p.terminate() } }
        }
    }
}

// MARK: - Google Gemini (free tier with the user's own key)

enum GeminiBackend {
    static let keyPage = URL(string: "https://aistudio.google.com/apikey")!
    /// Tried in order when a model isn't available for the key.
    static let fallbacks = ["gemini-3.8-flash", "gemini-3.6-flash", "gemini-3.5-flash-lite", "gemini-2.5-flash"]

    static func stream(key: String, model: String, system: String, messages: [AIMessage], json: Bool) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var models = [model] + fallbacks.filter { $0 != model }
                var lastError: Error = AIError.message("Gemini neodpověděl.")
                while !models.isEmpty {
                    let m = models.removeFirst()
                    do {
                        try await run(key: key, model: m, system: system, messages: messages, json: json) { continuation.yield($0) }
                        if m != model { Settings.shared.geminiModel = m }
                        continuation.finish()
                        return
                    } catch GeminiError.modelUnavailable(let msg) {
                        lastError = AIError.message("Model \(m) není dostupný: \(msg)")
                        continue
                    } catch {
                        continuation.finish(throwing: error)
                        return
                    }
                }
                continuation.finish(throwing: lastError)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private enum GeminiError: Error { case modelUnavailable(String) }

    private static func run(key: String, model: String, system: String, messages: [AIMessage], json: Bool, yield: (String) -> Void) async throws {
        var c = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):streamGenerateContent")!
        c.queryItems = [.init(name: "alt", value: "sse")]
        var req = URLRequest(url: c.url!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")

        let contents: [[String: Any]] = messages.map { m in
            var parts: [[String: Any]] = []
            if let img = m.image, let enc = img.encodedForAI(maxEdge: 1536) {
                parts.append(["inline_data": ["mime_type": enc.mediaType, "data": enc.data.base64EncodedString()]])
            }
            parts.append(["text": m.text])
            return ["role": m.role == .user ? "user" : "model", "parts": parts]
        }
        var gen: [String: Any] = ["temperature": 0.4]
        if json { gen["responseMimeType"] = "application/json" }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": contents,
            "generationConfig": gen,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status != 200 {
            var raw = ""
            for try await line in bytes.lines { raw += line; if raw.count > 4000 { break } }
            let err = (try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])?["error"] as? [String: Any]
            let msg = err?["message"] as? String ?? raw
            let st = err?["status"] as? String ?? ""
            if status == 404 || (status == 400 && msg.lowercased().contains("model")) && !msg.contains("API key") {
                throw GeminiError.modelUnavailable(msg)
            }
            if status == 429 || st == "RESOURCE_EXHAUSTED" {
                throw AIError.message("Bezplatný limit Gemini je na chvíli vyčerpaný. Zkuste to za minutu, případně zítra.")
            }
            if status == 400 && msg.contains("API key") || status == 401 || status == 403 {
                throw AIError.message("Klíč ke Gemini nefunguje. Zkontrolujte ho v Nastavení (\(msg)).")
            }
            throw AIError.message("Gemini hlásí chybu \(status): \(msg)")
        }

        var got = false
        var blocked: String?
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { continue }
            if let fb = obj["promptFeedback"] as? [String: Any], let reason = fb["blockReason"] as? String { blocked = reason }
            guard let cand = (obj["candidates"] as? [[String: Any]])?.first else { continue }
            if let parts = (cand["content"] as? [String: Any])?["parts"] as? [[String: Any]] {
                for p in parts where p["thought"] as? Bool != true {
                    if let t = p["text"] as? String, !t.isEmpty { got = true; yield(t) }
                }
            }
            if let fr = cand["finishReason"] as? String, ["SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST"].contains(fr), !got { blocked = fr }
        }
        if !got, let blocked { throw AIError.message("Gemini odpověď zablokoval (\(blocked)).") }
    }
}
