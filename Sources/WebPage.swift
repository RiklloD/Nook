import AppKit
import Compression
import ImageIO

/// Finds the web page a browser is playing from, so the notch shows that site (its icon, the
/// video's thumbnail) instead of the browser's. Browsers only report title + artist to macOS;
/// the page is the tab with a matching title: Zen/Firefox from their session file (open tabs,
/// saved every ~15 s), then their history (written the moment a page opens); Safari/Chromium from
/// their tabs via AppleScript.
enum WebPage {
    static func url(title: String, artist: String, browser bundleID: String) -> URL? {
        let wanted = normalize(title), by = normalize(artist)
        guard !wanted.isEmpty else { return nil }
        guard let folder = firefoxFamily[bundleID] else { return match(wanted, by, in: pages(scriptedTabs(bundleID))) }
        // An open tab with the exact title is the answer; history covers a page opened since the
        // session file was last saved.
        let open = pages(sessionTabs(folder))
        return open.first { $0.title == wanted }?.url ?? match(wanted, by, in: open + pages(historyPages(folder)))
    }

    private typealias Page = (url: URL, title: String)

    private static func pages(_ tabs: [Tab]) -> [Page] {
        tabs.compactMap { tab in
            guard let url = URL(string: tab.url), ["http", "https"].contains(url.scheme ?? "") else { return nil }
            return (url, normalize(tab.title))
        }
    }

    /// Exact title first. Otherwise one title containing the other as whole words, then (not on
    /// YouTube, whose tabs are always titled after the video) a page titled after the artist, e.g.
    /// "Gotaga - Twitch". A loose match only counts when it points at a single page.
    private static func match(_ wanted: String, _ artist: String, in pages: [Page]) -> URL? {
        if let page = pages.first(where: { $0.title == wanted }) { return page.url }
        func only(_ found: [Page]) -> URL? { Set(found.map(\.url)).count == 1 ? found[0].url : nil }
        let overlapping = pages.filter { page in
            min(page.title.count, wanted.count) >= 4 && (containsWords(page.title, wanted) || containsWords(wanted, page.title))
        }
        if !overlapping.isEmpty { return only(overlapping) }
        guard artist.count >= 3 else { return nil }
        return only(pages.filter { containsWords($0.title, artist) && !isYouTube($0.url) })
    }

    /// `part` appears in `text` with no letter or digit glued on either side ("episode 1" isn't in
    /// "episode 10").
    private static func containsWords(_ text: String, _ part: String) -> Bool {
        var searchStart = text.startIndex
        while let found = text.range(of: part, range: searchStart..<text.endIndex) {
            let before = found.lowerBound > text.startIndex ? text[text.index(before: found.lowerBound)] : nil
            let after = found.upperBound < text.endIndex ? text[found.upperBound] : nil
            if !(before.map { $0.isLetter || $0.isNumber } ?? false), !(after.map { $0.isLetter || $0.isNumber } ?? false) { return true }
            searchStart = text.index(after: found.lowerBound)
        }
        return false
    }

    // MARK: Preview

    struct Preview: Sendable {
        var name: String
        var image: CGImage?
        var icon: CGImage?
        var isYouTube = false
    }

    /// The page's thumbnail (YouTube's own, Twitch's live frame, else its og:image) and site icon.
    /// Runs off the main thread; cancelling the task stops its downloads.
    static func preview(_ page: URL) async -> Preview {
        let host = page.host?.lowercased() ?? ""
        if let id = youTubeID(page) {
            return Preview(name: "YouTube", image: await image(URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg")), isYouTube: true)
        }
        let head = await head(of: page)
        let base = head?.url ?? page
        let metas = head.map { tags("meta", in: $0.html) } ?? []
        func meta(_ keys: String...) -> String? {
            keys.lazy.compactMap { key in
                metas.first { ($0["property"] ?? $0["name"])?.lowercased() == key }?["content"]
            }.first { !$0.isEmpty }.map(decodeEntities)
        }
        var preview = Preview(name: meta("og:site_name") ?? displayHost(host))
        if let live = twitchPreview(page) { preview.image = await image(live) }
        if preview.image == nil, let src = meta("og:image", "og:image:secure_url", "twitter:image", "twitter:image:src") {
            preview.image = await image(URL(string: src, relativeTo: base)?.absoluteURL)
        }
        preview.icon = await icon(host: host, links: head.map { tags("link", in: $0.html) } ?? [], base: base)
        return preview
    }

    private static let images = ImageCache(limit: 30)
    private static let icons = ImageCache(limit: 60)

    /// 640 px at most (thumbnails are drawn ≤ 112 pt wide); one retry for a flaky network.
    private static func image(_ url: URL?) async -> CGImage? {
        guard let url else { return nil }
        if let cached = await images[url.absoluteString] { return cached }
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
            guard !Task.isCancelled else { return nil }
            guard let fetched = await fetch(url, limit: 4 << 20, types: ["image/"]) else { continue }
            // Twitch answers an offline channel with a redirect to a placeholder frame.
            guard !fetched.url.absoluteString.contains("404_preview"),
                  let image = decode(fetched.data, maxPixels: 640), image.width >= 32 else { return nil }
            await images.store(image, for: url.absoluteString)
            return image
        }
        return nil
    }

    /// apple-touch-icon (crisp at any size), then the largest declared icon, then /favicon.ico.
    private static func icon(host: String, links: [[String: String]], base: URL) async -> CGImage? {
        if let cached = await icons[host] { return cached }
        func rels(_ link: [String: String]) -> [Substring] { link["rel"]?.lowercased().split(separator: " ") ?? [] }
        func size(_ link: [String: String]) -> Int {
            let sizes = link["sizes"]?.lowercased() ?? ""
            return sizes == "any" ? 0 : Int(sizes.split(separator: "x").first ?? "") ?? 1
        }
        let touch = links.filter { rels($0).contains { $0.hasPrefix("apple-touch-icon") } }
        let declared = links.filter { rels($0).contains("icon") }.sorted { size($0) > size($1) }
        var candidates = (touch + declared).compactMap { $0["href"] }.prefix(3).compactMap {
            URL(string: decodeEntities($0), relativeTo: base)?.absoluteURL
        }
        if let favicon = URL(string: "/favicon.ico", relativeTo: base)?.absoluteURL { candidates.append(favicon) }
        for url in candidates {
            // Favicons are often served without an image type.
            guard let fetched = await fetch(url, limit: 1 << 20, types: ["image/", "application/octet-stream", "text/plain"]),
                  let image = decode(fetched.data, maxPixels: 128) else { continue }
            await icons.store(image, for: host)
            return image
        }
        return nil
    }

    /// The page's <head> only: enough for its meta and link tags, without downloading the rest.
    private static func head(of page: URL) async -> (html: String, url: URL)? {
        guard let fetched = await fetch(page, limit: 1_500_000, types: ["text/html", "application/xhtml+xml"], until: { data in
            data.count >= 7 && String(decoding: data.suffix(7), as: UTF8.self).lowercased() == "</head>"
        }) else { return nil }
        return (String(decoding: fetched.data, as: UTF8.self), fetched.url)
    }

    /// Every preview request goes through here. A page's own metadata picks most of these URLs, so
    /// each one (and every redirect) must lead to a public http(s) host: never this Mac, the local
    /// network or link-local services, which Nook would otherwise reach outside the browser's
    /// protections. Bodies are read up to `limit` bytes. With `until`, reading stops once it returns
    /// true (or at the limit) and keeps what it has; without, an over-limit body is dropped.
    private static func fetch(_ url: URL, limit: Int, types: [String], until: ((Data) -> Bool)? = nil) async -> (data: Data, url: URL)? {
        guard isPublic(url) else {
            debugLog("preview: refused \(url.host ?? url.absoluteString)")
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue(types.first == "image/" ? "image/*" : "text/html", forHTTPHeaderField: "Accept")
        guard let (bytes, response) = try? await session.bytes(for: request, delegate: RedirectPolicy.shared),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.expectedContentLength <= Int64(limit) || until != nil,
              types.contains(where: { (http.mimeType ?? "application/octet-stream").lowercased().hasPrefix($0) }) else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                guard data.count < limit else {
                    if until == nil { return nil }
                    break
                }
                data.append(byte)
                if let until, byte == UInt8(ascii: ">"), until(data) { break }
            }
        } catch { return nil }
        return (data, response.url ?? url)
    }

    /// http(s), and every address the host resolves to is public. The check runs before connecting,
    /// so a host that changes its DNS answer in between could still slip through; this covers the
    /// pages and metadata Nook actually meets.
    static func isPublic(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host(percentEncoded: false)?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[].")),
              !host.isEmpty, host != "localhost", !host.hasSuffix(".localhost"), !host.hasSuffix(".local") else { return false }
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, list != nil else { return false }
        defer { freeaddrinfo(list) }
        var entry = list
        while let info = entry {
            guard let address = info.pointee.ai_addr, isPublic(address) else { return false }
            entry = info.pointee.ai_next
        }
        return true
    }

    private static func isPublic(_ address: UnsafeMutablePointer<sockaddr>) -> Bool {
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            return isPublic(ipv4: address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) })
        case AF_INET6:
            let b = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) } }
            let embedded = b[12..<16].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff { return isPublic(ipv4: embedded) } // ::ffff:a.b.c.d
            if b[0..<12] == [0, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0] { return isPublic(ipv4: embedded) } // NAT64
            if b[0..<15].allSatisfy({ $0 == 0 }) { return false } // :: and ::1
            if b[0] & 0xfe == 0xfc { return false } // fc00::/7 unique local
            if b[0] == 0xfe && b[1] & 0x80 == 0x80 { return false } // fe80::/10 link-local, fec0::/10 site-local
            return b[0] != 0xff // multicast
        default:
            return false
        }
    }

    private static func isPublic(ipv4 address: UInt32) -> Bool {
        let blocked: [(network: UInt32, bits: UInt32)] = [
            (0x0000_0000, 8), (0x0A00_0000, 8), (0x6440_0000, 10), (0x7F00_0000, 8), (0xA9FE_0000, 16),
            (0xAC10_0000, 12), (0xC000_0000, 24), (0xC0A8_0000, 16), (0xC612_0000, 15), (0xE000_0000, 3),
        ]
        return !blocked.contains { address >> (32 - $0.bits) == $0.network >> (32 - $0.bits) }
    }

    private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
        static let shared = RedirectPolicy()

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            request.url.map(WebPage.isPublic) == true ? request : nil
        }
    }

    /// No cookies or cache on disk; a Safari user agent, since some sites (X) only fill in the
    /// thumbnail for real browsers.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.timeoutIntervalForResource = 20
        config.httpAdditionalHeaders = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"]
        return URLSession(configuration: config)
    }()

    /// Downsampled while decoding, so a large image never sits in memory at full size.
    private static func decode(_ data: Data, maxPixels: Int) -> CGImage? {
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
               kCGImageSourceCreateThumbnailFromImageAlways: true,
               kCGImageSourceCreateThumbnailWithTransform: true,
               kCGImageSourceThumbnailMaxPixelSize: maxPixels,
           ] as CFDictionary) {
            return image
        }
        // Formats ImageIO can't read (SVG icons), drawn at the same size.
        var rect = CGRect(x: 0, y: 0, width: maxPixels, height: maxPixels)
        return NSImage(data: data)?.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private actor ImageCache {
        private var items: [String: CGImage] = [:]
        private let limit: Int

        init(limit: Int) { self.limit = limit }

        subscript(key: String) -> CGImage? { items[key] }

        func store(_ image: CGImage, for key: String) {
            if items.count >= limit { items.removeAll() }
            items[key] = image
        }
    }

    // MARK: HTML

    private static let attribute = try! NSRegularExpression(pattern: #"([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#)

    /// Attributes of every `<name …>` tag, keys lowercased.
    private static func tags(_ name: String, in html: String) -> [[String: String]] {
        guard let tag = try? NSRegularExpression(pattern: "<\(name)\\b[^>]*>", options: .caseInsensitive) else { return [] }
        let text = html as NSString
        return tag.matches(in: html, range: NSRange(location: 0, length: text.length)).map { match in
            let body = text.substring(with: match.range)
            var values: [String: String] = [:]
            for pair in attribute.matches(in: body, range: NSRange(location: 0, length: (body as NSString).length)) {
                let key = (body as NSString).substring(with: pair.range(at: 1)).lowercased()
                let value = (2...4).lazy.map { pair.range(at: $0) }.first { $0.location != NSNotFound }
                    .map { (body as NSString).substring(with: $0) } ?? ""
                if values[key] == nil { values[key] = value }
            }
            return values
        }
    }

    private static func decodeEntities(_ value: String) -> String {
        guard value.contains("&") else { return value }
        return [("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&#x2F;", "/"), ("&#47;", "/"), ("&amp;", "&")]
            .reduce(value) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    // MARK: Tabs

    private typealias Tab = (url: String, title: String)

    private static let firefoxFamily = [
        "app.zen-browser.zen": "zen",
        "org.mozilla.firefox": "Firefox",
        "org.mozilla.firefoxdeveloperedition": "Firefox",
        "org.mozilla.nightly": "Firefox",
        "org.mozilla.librewolf": "librewolf",
        "one.ablaze.floorp": "Floorp",
        "net.waterfox.waterfox": "Waterfox",
    ]

    /// The most recently written copy of `file` across the browser's profiles.
    private static func latest(_ file: String, in folder: String) -> String? {
        let profiles = "\(home)/Library/Application Support/\(folder)/Profiles"
        return ((try? FileManager.default.contentsOfDirectory(atPath: profiles)) ?? [])
            .map { "\(profiles)/\($0)/\(file)" }
            .compactMap { path -> (String, Date)? in
                guard let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { return nil }
                return (path, date)
            }
            .max { $0.1 < $1.1 }?.0
    }

    /// Web pages from the last few hours of history, newest first. The browser keeps places.sqlite
    /// exclusively locked, so it can't be queried (or backed up through SQLite) in place. Instead
    /// the database and its write-ahead log are copied into a private temporary folder, and the
    /// copy is only used if neither file changed while it was made; otherwise it's tried again.
    private static func historyPages(_ folder: String) -> [Tab] {
        guard let wal = latest("places.sqlite-wal", in: folder) else { return [] }
        let source = String(wal.dropLast(4))
        let manager = FileManager.default
        let dir = manager.temporaryDirectory.appendingPathComponent("nook-history-\(UUID().uuidString)").path
        guard (try? manager.createDirectory(atPath: dir, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])) != nil else { return [] }
        defer { try? manager.removeItem(atPath: dir) }
        let copy = "\(dir)/places.sqlite"
        func versions() -> [String] {
            [source, wal].map { path in
                let attributes = try? manager.attributesOfItem(atPath: path)
                return "\(attributes?[.size] ?? "-") \((attributes?[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0)"
            }
        }
        var consistent = false
        for _ in 0..<3 where !consistent {
            let before = versions()
            for suffix in ["", "-wal", "-shm"] { try? manager.removeItem(atPath: copy + suffix) }
            guard (try? manager.copyItem(atPath: source, toPath: copy)) != nil,
                  (try? manager.copyItem(atPath: wal, toPath: copy + "-wal")) != nil else { return [] }
            consistent = versions() == before
        }
        guard consistent else { return [] }
        let since = Int64((Date().timeIntervalSince1970 - 6 * 3600) * 1_000_000)
        return (sqliteQuery(copy, """
            SELECT url, title FROM moz_places
            WHERE last_visit_date > \(since) AND title IS NOT NULL AND title != ''
              AND (url LIKE 'https://%' OR url LIKE 'http://%')
            ORDER BY last_visit_date DESC LIMIT 300
            """) ?? []).compactMap { row in row["url"].map { ($0, row["title"] ?? "") } }
    }

    private struct Session: Decodable {
        struct Window: Decodable { var tabs: [SessionTab]? }
        struct SessionTab: Decodable {
            struct Entry: Decodable { var url: String?, title: String? }
            var entries: [Entry]?
            var index: Int?
        }
        var windows: [Window]
    }

    /// Reads the live session file (mozLz4: 8-byte magic, 4-byte size, raw LZ4 block).
    private static func sessionTabs(_ folder: String) -> [Tab] {
        guard let path = latest("sessionstore-backups/recovery.jsonlz4", in: folder),
              let data = FileManager.default.contents(atPath: path), data.count > 12,
              data.prefix(8) == Data("mozLz40\0".utf8) else { return [] }
        let size = Int(data[8]) | Int(data[9]) << 8 | Int(data[10]) << 16 | Int(data[11]) << 24
        guard size > 0, size < 64 << 20 else { return [] }
        var json = Data(count: size)
        let decoded = json.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { input in
                compression_decode_buffer(output.bindMemory(to: UInt8.self).baseAddress!, size,
                                          input.bindMemory(to: UInt8.self).baseAddress! + 12, data.count - 12,
                                          nil, COMPRESSION_LZ4_RAW)
            }
        }
        guard decoded > 0, let session = try? JSONDecoder().decode(Session.self, from: json.prefix(decoded)) else { return [] }
        return session.windows.flatMap { window in
            (window.tabs ?? []).compactMap { tab -> Tab? in
                let entries = tab.entries ?? []
                let index = (tab.index ?? entries.count) - 1
                guard entries.indices.contains(index), let url = entries[index].url else { return nil }
                return (url, entries[index].title ?? "")
            }
        }
    }

    /// Safari and Chromium browsers expose tabs to AppleScript (macOS asks permission once).
    private static func scriptedTabs(_ bundleID: String) -> [Tab] {
        // Bundle IDs are reverse-DNS; anything else is never put in a script.
        guard bundleID.range(of: #"^[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil else { return [] }
        let titleKey = bundleID == "com.apple.Safari" ? "name" : "title"
        let source = """
            set out to ""
            tell application id "\(bundleID)"
              repeat with w in windows
                repeat with t in tabs of w
                  set out to out & (URL of t) & tab & (\(titleKey) of t) & linefeed
                end repeat
              end repeat
            end tell
            return out
            """
        var error: NSDictionary?
        guard let output = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue else { return [] }
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
    }

    // MARK: Sites

    /// `host` is `domain` or one of its subdomains (not merely a name ending the same way).
    private static func isHost(_ url: URL, in domain: String) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host == domain || host.hasSuffix("." + domain)
    }

    private static func isYouTube(_ url: URL) -> Bool { isHost(url, in: "youtube.com") || isHost(url, in: "youtu.be") }

    static func youTubeID(_ url: URL) -> String? {
        guard isYouTube(url), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let parts = Array(url.pathComponents.dropFirst())
        let id: String?
        if isHost(url, in: "youtu.be") { id = parts.first }
        else if url.path == "/watch" { id = components.queryItems?.first { $0.name == "v" }?.value }
        else if parts.count >= 2, ["shorts", "live", "embed"].contains(parts[0]) { id = parts[1] }
        else { id = nil }
        return id.flatMap { $0.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil ? $0 : nil }
    }

    /// twitch.tv/<channel> → its live frame (og:image there is only the avatar).
    private static func twitchPreview(_ url: URL) -> URL? {
        guard isHost(url, in: "twitch.tv") else { return nil }
        let parts = url.pathComponents.dropFirst()
        guard parts.count == 1, let channel = parts.first?.lowercased(),
              channel.range(of: #"^[a-z0-9_]{2,25}$"#, options: .regularExpression) != nil,
              !["directory", "videos", "search", "downloads", "settings", "subscriptions", "inventory", "drops", "wallet"].contains(channel)
        else { return nil }
        return URL(string: "https://static-cdn.jtvnw.net/previews-ttv/live_user_\(channel)-640x360.jpg")
    }

    private static func displayHost(_ host: String) -> String {
        for prefix in ["www.", "m.", "mobile."] where host.hasPrefix(prefix) { return String(host.dropFirst(prefix.count)) }
        return host
    }

    /// "(3) Some Title - YouTube" → "some title".
    private static func normalize(_ title: String) -> String {
        var value = title
        if let range = value.range(of: #"^\(\d+\)\s*"#, options: .regularExpression) { value.removeSubrange(range) }
        if value.hasSuffix(" - YouTube") { value.removeLast(10) }
        return value.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
