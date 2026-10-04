import AppKit

/// What's playing system-wide (Spotify, YouTube in any browser, Music, …), fed by the perl helper.
struct NowPlaying: Equatable {
    var title = ""
    var artist = ""
    var album = ""
    var bundleID = ""
    var duration: Double = 0
    var elapsed: Double = 0
    var sampledAt = Date()
    var playing = false

    var isEmpty: Bool { title.isEmpty }

    /// Browsers report YouTube & co.; they get a 16:9 artwork frame and ±10 s skips.
    var isVideo: Bool { NowPlaying.browsers.contains(bundleID) }

    func position(at date: Date = Date()) -> Double {
        let value = playing ? elapsed + date.timeIntervalSince(sampledAt) : elapsed
        return duration > 0 ? min(max(value, 0), duration) : max(value, 0)
    }

    static let browsers: Set<String> = [
        "com.apple.Safari", "app.zen-browser.zen", "org.mozilla.firefox", "com.google.Chrome",
        "company.thebrowser.Browser", "company.thebrowser.dia", "com.brave.Browser", "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi", "com.kagi.kagimacOS", "ai.perplexity.comet", "com.openai.atlas",
    ]
}

@MainActor
final class MediaController: ObservableObject {
    @Published private(set) var now = NowPlaying()
    @Published private(set) var artwork: NSImage?
    @Published private(set) var tint = Color.white
    /// Bumped on real track changes (not on pause/seek) so the notch can peek.
    @Published private(set) var trackChange = 0
    /// The browser is playing a YouTube video we found the tab for.
    @Published private(set) var isYouTube = false

    private var remoteArt: NSImage?
    private var seeded = false
    private var thumbnail: (title: String, image: NSImage)?
    private var lookupTitle = ""
    private let lookupQueue = DispatchQueue(label: "nook.youtube", qos: .utility)

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var restarts = 0

    init() { start() }

    func send(_ command: String) {
        try? input?.write(contentsOf: Data((command + "\n").utf8))
    }

    func toggle() {
        // Optimistic: flip immediately so the button feels instant; the helper confirms right after.
        now.elapsed = now.position()
        now.sampledAt = Date()
        now.playing.toggle()
        send("toggle")
    }

    func next() { now.isVideo ? seek(to: now.position() + 10) : send("next") }
    func previous() { now.isVideo ? seek(to: now.position() - 10) : send("prev") }

    func seek(to seconds: Double) {
        let target = max(0, now.duration > 0 ? min(seconds, now.duration) : seconds)
        now.elapsed = target
        now.sampledAt = Date()
        send("seek \(target)")
    }

    func openSource() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: now.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    // MARK: Helper process

    private func start() {
        guard let script = Bundle.main.path(forResource: "stream", ofType: "pl"),
              let library = Bundle.main.path(forResource: "NookMedia", ofType: "dylib") else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [script, library]
        let stdout = Pipe(), stdin = Pipe()
        process.standardOutput = stdout
        process.standardInput = stdin
        process.standardError = FileHandle.nullDevice
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.consume(data) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.restartLater() }
        }
        do {
            try process.run()
            self.process = process
            input = stdin.fileHandleForWriting
        } catch {
            restartLater()
        }
    }

    private func restartLater() {
        process = nil
        input = nil
        restarts += 1
        guard restarts < 20 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(min(restarts * 2, 30))) { [weak self] in self?.start() }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] { apply(json) }
        }
    }

    private func apply(_ json: [String: Any]) {
        var next = NowPlaying()
        next.title = json["title"] as? String ?? ""
        next.artist = json["artist"] as? String ?? ""
        next.album = json["album"] as? String ?? ""
        next.bundleID = json["bundle"] as? String ?? ""
        next.duration = (json["duration"] as? NSNumber)?.doubleValue ?? 0
        next.elapsed = (json["elapsed"] as? NSNumber)?.doubleValue ?? 0
        next.sampledAt = (json["ts"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } ?? Date()
        let rate = (json["rate"] as? NSNumber)?.doubleValue ?? 0
        next.playing = ((json["playing"] as? NSNumber)?.boolValue ?? false) && (rate > 0 || json["rate"] == nil)

        let trackChanged = next.title != now.title || next.artist != now.artist
        if let encoded = json["art"] as? String, let data = Data(base64Encoded: encoded), let image = NSImage(data: data) {
            remoteArt = image
        } else if json["hasArt"] == nil {
            remoteArt = nil
        }
        if next != now { now = next }
        if next.isVideo && !next.title.isEmpty && next.title != lookupTitle {
            lookupTitle = next.title
            findVideo(title: next.title, browser: next.bundleID, attempt: 0)
        }
        if thumbnail?.title != next.title && isYouTube { isYouTube = false }
        updateArtwork()
        // The first update after launch is what was already playing, not a change.
        if trackChanged && !next.isEmpty && next.playing && seeded { trackChange += 1 }
        seeded = true
    }

    /// Browser artwork when it sends some, otherwise the YouTube thumbnail for this video.
    private func updateArtwork() {
        let image = remoteArt ?? (thumbnail?.title == now.title ? thumbnail?.image : nil)
        guard image !== artwork else { return }
        artwork = image
        tint = image?.vibrantTint ?? .white
    }

    /// A video's page can take a moment to reach the browser's history (or tabs) under its final
    /// title, so it's retried quickly at first, then backing off, for about a minute.
    private static let retryDelays: [Double] = [0.4, 0.8, 1.2, 2, 3, 5, 8, 12, 15, 15]

    private func findVideo(title: String, browser: String, attempt: Int) {
        lookupQueue.async { [weak self] in
            let id = YouTube.videoID(title: title, browser: browser)
            Task { @MainActor in
                guard let self, self.now.title == title else { return }
                if let id {
                    guard let image = await YouTube.thumbnail(id), self.now.title == title else { return }
                    self.thumbnail = (title, image)
                    self.isYouTube = true
                    self.updateArtwork()
                } else if attempt < Self.retryDelays.count {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryDelays[attempt]) { [weak self] in
                        guard let self, self.now.title == title else { return }
                        self.findVideo(title: title, browser: browser, attempt: attempt + 1)
                    }
                }
            }
        }
    }
}

import SwiftUI

extension NSImage {
    /// Average color of the artwork, lifted so it reads on black (Alcove-style tinted waveform).
    var vibrantTint: Color {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .white }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .white }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let color = NSColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        color.usingColorSpace(.deviceRGB)?.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return Color(hue: hue, saturation: min(saturation * 1.3, 0.85), brightness: max(brightness, 0.82))
    }
}
