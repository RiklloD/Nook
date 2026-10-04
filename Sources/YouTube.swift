import AppKit
import Compression

/// Finds which YouTube video a browser is playing, so the notch can show its thumbnail.
/// Browsers only report title + channel to macOS; the video ID comes from the matching page:
/// Zen/Firefox from their history (written the moment a video opens), then their session file
/// (saved only every ~15 s); Safari/Chromium from their tabs via AppleScript.
enum YouTube {
    static func videoID(title: String, browser bundleID: String) -> String? {
        let wanted = normalize(title)
        guard !wanted.isEmpty else { return nil }
        guard let folder = firefoxFamily[bundleID] else { return match(wanted, in: scriptedTabs(bundleID)) }
        return match(wanted, in: historyPages(folder)) ?? match(wanted, in: sessionTabs(folder))
    }

    private static func match(_ wanted: String, in pages: [Tab]) -> String? {
        let videos = pages.compactMap { page in id(from: page.url).map { (id: $0, title: normalize(page.title)) } }
        return (videos.first { $0.title == wanted }
            ?? videos.first { !$0.title.isEmpty && ($0.title.contains(wanted) || wanted.contains($0.title)) })?.id
    }

    @MainActor private static var thumbnails: [String: NSImage] = [:]

    @MainActor static func thumbnail(_ id: String) async -> NSImage? {
        if let cached = thumbnails[id] { return cached }
        // 320×180, ~15 KB: sharp enough for the notch, cheap to fetch. One retry for a flaky network.
        guard let url = URL(string: "https://i.ytimg.com/vi/\(id)/mqdefault.jpg") else { return nil }
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
            if let (data, response) = try? await URLSession.shared.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200, let image = NSImage(data: data) {
                if thumbnails.count > 30 { thumbnails.removeAll() }
                thumbnails[id] = image
                return image
            }
        }
        return nil
    }

    // MARK: Tabs

    private typealias Tab = (url: String, title: String)

    private static let firefoxFamily = [
        "app.zen-browser.zen": "zen",
        "org.mozilla.firefox": "Firefox",
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

    /// YouTube pages from the last few hours of history, newest first. The browser holds the
    /// database locked, so a copy (with its write-ahead log, ~20 ms) is read instead.
    private static func historyPages(_ folder: String) -> [Tab] {
        guard let wal = latest("places.sqlite-wal", in: folder) else { return [] }
        let source = String(wal.dropLast(4))
        let dir = "\(supportDir)/history"
        let copy = "\(dir)/places.sqlite"
        let manager = FileManager.default
        try? manager.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm"] { try? manager.removeItem(atPath: copy + suffix) }
        defer { for suffix in ["", "-wal", "-shm"] { try? manager.removeItem(atPath: copy + suffix) } }
        guard (try? manager.copyItem(atPath: source, toPath: copy)) != nil,
              (try? manager.copyItem(atPath: wal, toPath: copy + "-wal")) != nil else { return [] }
        let since = Int64((Date().timeIntervalSince1970 - 6 * 3600) * 1_000_000)
        return sqliteRows(copy, """
            SELECT url, title FROM moz_places
            WHERE last_visit_date > \(since) AND title IS NOT NULL
              AND (url LIKE 'https://www.youtube.com/%' OR url LIKE 'https://m.youtube.com/%' OR url LIKE 'https://youtu.be/%')
            ORDER BY last_visit_date DESC LIMIT 50
            """).compactMap { row in row["url"].map { ($0, row["title"] ?? "") } }
    }

    /// Reads the live session file (mozLz4: 8-byte magic, 4-byte size, raw LZ4 block).
    private static func sessionTabs(_ folder: String) -> [Tab] {
        guard let path = latest("sessionstore-backups/recovery.jsonlz4", in: folder),
              let data = FileManager.default.contents(atPath: path), data.count > 12,
              data.prefix(8) == Data("mozLz40\0".utf8) else { return [] }
        let size = Int(data[8]) | Int(data[9]) << 8 | Int(data[10]) << 16 | Int(data[11]) << 24
        guard size > 0, size < 200_000_000 else { return [] }
        var json = Data(count: size)
        let decoded = json.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { input in
                compression_decode_buffer(output.bindMemory(to: UInt8.self).baseAddress!, size,
                                          input.bindMemory(to: UInt8.self).baseAddress! + 12, data.count - 12,
                                          nil, COMPRESSION_LZ4_RAW)
            }
        }
        guard decoded > 0, let session = try? JSONSerialization.jsonObject(with: json.prefix(decoded)) as? [String: Any],
              let windows = session["windows"] as? [[String: Any]] else { return [] }
        return windows.flatMap { window in
            (window["tabs"] as? [[String: Any]] ?? []).compactMap { tab -> Tab? in
                let entries = tab["entries"] as? [[String: Any]] ?? []
                let index = (tab["index"] as? Int ?? entries.count) - 1
                guard entries.indices.contains(index), let url = entries[index]["url"] as? String else { return nil }
                return (url, entries[index]["title"] as? String ?? "")
            }
        }
    }

    /// Safari and Chromium browsers expose tabs to AppleScript (macOS asks permission once).
    private static func scriptedTabs(_ bundleID: String) -> [Tab] {
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

    // MARK: Matching

    static func id(from string: String) -> String? {
        guard let url = URLComponents(string: string), let host = url.host?.lowercased() else { return nil }
        if host.hasSuffix("youtu.be") { return url.path.split(separator: "/").first.map(String.init) }
        guard host.hasSuffix("youtube.com") else { return nil }
        if url.path == "/watch" { return url.queryItems?.first { $0.name == "v" }?.value }
        let parts = url.path.split(separator: "/")
        if parts.count >= 2, ["shorts", "live", "embed"].contains(parts[0]) { return String(parts[1]) }
        return nil
    }

    /// "(3) Some Title - YouTube" → "some title".
    private static func normalize(_ title: String) -> String {
        var value = title
        if let range = value.range(of: #"^\(\d+\)\s*"#, options: .regularExpression) { value.removeSubrange(range) }
        if value.hasSuffix(" - YouTube") { value.removeLast(10) }
        return value.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
