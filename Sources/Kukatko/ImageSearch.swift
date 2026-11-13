import Foundation

struct ImageHit: Identifiable, Hashable {
    let id: String
    let thumb: URL
    let full: URL
    let page: URL?
    let title: String
    let source: String
    let width: Int
    let height: Int
}

/// Keyless image sources: the whole web via DuckDuckGo Images, then Wikipedia and Wikimedia Commons as extras.
enum ImageSearch {
    private static let ua = "Kukatko/1.0 (macOS image lookup)"

    /// Each source separately, in display order, so results can appear as soon as one answers.
    static func sources(_ query: String, language: String = "cs") -> [() async -> [ImageHit]] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var list: [() async -> [ImageHit]] = [{ await web(q, lang: language) }]
        list.append { await wikipedia(q, lang: language) }
        if language != "en" { list.append { await wikipedia(q, lang: "en") } }
        list.append { await commons(q) }
        return list
    }

    static func search(_ query: String, language: String = "cs") async -> [ImageHit] {
        var all: [ImageHit] = []
        for src in sources(query, language: language) { all += await src() }
        var seen = Set<String>()
        return all.filter { seen.insert($0.full.absoluteString).inserted }
    }

    private static func get(_ url: URL) async -> [String: Any]? {
        var req = URLRequest(url: url)
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 8
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func wikipedia(_ q: String, lang: String) async -> [ImageHit] {
        var c = URLComponents(string: "https://\(lang).wikipedia.org/w/api.php")!
        c.queryItems = [
            .init(name: "action", value: "query"), .init(name: "format", value: "json"),
            .init(name: "generator", value: "search"), .init(name: "gsrsearch", value: q),
            .init(name: "gsrlimit", value: "6"), .init(name: "prop", value: "pageimages|info"),
            .init(name: "piprop", value: "thumbnail|original"), .init(name: "pithumbsize", value: "500"),
            .init(name: "inprop", value: "url"),
        ]
        guard let json = await get(c.url!),
              let pages = (json["query"] as? [String: Any])?["pages"] as? [String: Any] else { return [] }
        let sorted = pages.values.compactMap { $0 as? [String: Any] }
            .sorted { ($0["index"] as? Int ?? 99) < ($1["index"] as? Int ?? 99) }
        return sorted.compactMap { p in
            guard let thumb = (p["thumbnail"] as? [String: Any])?["source"] as? String,
                  let orig = p["original"] as? [String: Any], let full = orig["source"] as? String,
                  let tu = URL(string: thumb), let fu = URL(string: full) else { return nil }
            return ImageHit(id: "w\(lang)-\(full)", thumb: tu, full: fu,
                            page: (p["fullurl"] as? String).flatMap(URL.init(string:)),
                            title: p["title"] as? String ?? q, source: "Wikipedie \(lang.uppercased())",
                            width: orig["width"] as? Int ?? 0, height: orig["height"] as? Int ?? 0)
        }
    }

    private static func commons(_ q: String) async -> [ImageHit] {
        var c = URLComponents(string: "https://commons.wikimedia.org/w/api.php")!
        c.queryItems = [
            .init(name: "action", value: "query"), .init(name: "format", value: "json"),
            .init(name: "generator", value: "search"), .init(name: "gsrsearch", value: "\(q) filetype:bitmap"),
            .init(name: "gsrnamespace", value: "6"), .init(name: "gsrlimit", value: "18"),
            .init(name: "prop", value: "imageinfo"), .init(name: "iiprop", value: "url|size"),
            .init(name: "iiurlwidth", value: "500"),
        ]
        guard let json = await get(c.url!),
              let pages = (json["query"] as? [String: Any])?["pages"] as? [String: Any] else { return [] }
        let sorted = pages.values.compactMap { $0 as? [String: Any] }
            .sorted { ($0["index"] as? Int ?? 99) < ($1["index"] as? Int ?? 99) }
        return sorted.compactMap { p in
            guard let info = (p["imageinfo"] as? [[String: Any]])?.first,
                  let thumb = info["thumburl"] as? String, let full = info["url"] as? String,
                  let tu = URL(string: thumb), let fu = URL(string: full) else { return nil }
            let title = (p["title"] as? String ?? "").replacingOccurrences(of: "File:", with: "")
            return ImageHit(id: "c-\(full)", thumb: tu, full: fu,
                            page: (info["descriptionurl"] as? String).flatMap(URL.init(string:)),
                            title: (title as NSString).deletingPathExtension, source: "Wikimedia Commons",
                            width: info["width"] as? Int ?? 0, height: info["height"] as? Int ?? 0)
        }
    }

    private static let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// Web-wide image search through DuckDuckGo Images (results come from Bing's index). No key needed:
    /// the search page hands out a per-query token (vqd) that the JSON endpoint requires.
    private static func web(_ q: String, lang: String) async -> [ImageHit] {
        var page = URLComponents(string: "https://duckduckgo.com/")!
        page.queryItems = [.init(name: "q", value: q), .init(name: "iax", value: "images"), .init(name: "ia", value: "images")]
        var r1 = URLRequest(url: page.url!)
        r1.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        r1.timeoutInterval = 8
        guard let (html, _) = try? await URLSession.shared.data(for: r1),
              let text = String(data: html, encoding: .utf8),
              let re = try? NSRegularExpression(pattern: #"vqd=["']?([0-9-]+)"#),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return [] }
        let vqd = String(text[r])

        var api = URLComponents(string: "https://duckduckgo.com/i.js")!
        api.queryItems = [
            .init(name: "l", value: lang == "en" ? "us-en" : "cz-cs"), .init(name: "o", value: "json"),
            .init(name: "q", value: q), .init(name: "vqd", value: vqd),
            .init(name: "f", value: ",,,,,"), .init(name: "p", value: "1"),
        ]
        var r2 = URLRequest(url: api.url!)
        r2.setValue(browserUA, forHTTPHeaderField: "User-Agent")
        r2.setValue("https://duckduckgo.com/", forHTTPHeaderField: "Referer")
        r2.timeoutInterval = 8
        guard let (data, resp) = try? await URLSession.shared.data(for: r2),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]] else { return [] }
        return results.prefix(60).compactMap { r in
            guard let full = (r["image"] as? String).flatMap(URL.init(string:)),
                  let thumb = (r["thumbnail"] as? String).flatMap(URL.init(string:)) else { return nil }
            let pageURL = (r["url"] as? String).flatMap(URL.init(string:))
            let host = pageURL?.host?.replacingOccurrences(of: "www.", with: "") ?? "web"
            return ImageHit(id: "d-\(full.absoluteString)", thumb: thumb, full: full, page: pageURL,
                            title: r["title"] as? String ?? q, source: host,
                            width: r["width"] as? Int ?? 0, height: r["height"] as? Int ?? 0)
        }
    }

    static func googleImagesURL(_ q: String) -> URL {
        var c = URLComponents(string: "https://www.google.com/search")!
        c.queryItems = [.init(name: "tbm", value: "isch"), .init(name: "q", value: q)]
        return c.url!
    }
}
