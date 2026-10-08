import AppKit

/// What's playing system-wide (Spotify, YouTube in any browser, Music, …), fed by the perl helper.
struct NowPlaying: Equatable {
    var title = ""
    var artist = ""
    var bundleID = ""
    var duration: Double = 0
    var elapsed: Double = 0
    var sampledAt = Date()
    var playing = false

    var isEmpty: Bool { title.isEmpty }

    /// Which track this is. The same title from another player or artist is a different one.
    struct Key: Equatable {
        var bundleID = "", title = "", artist = ""
    }

    var key: Key { Key(bundleID: bundleID, title: title, artist: artist) }

    /// Browsers report YouTube & co.; they get a 16:9 artwork frame and ±10 s skips.
    var isVideo: Bool { NowPlaying.browsers.contains(bundleID) }

    func position(at date: Date = Date()) -> Double {
        let value = playing ? elapsed + date.timeIntervalSince(sampledAt) : elapsed
        return duration > 0 ? min(max(value, 0), duration) : max(value, 0)
    }

    /// Every installed app that can open web pages, plus the common ones in case they're installed later.
    static let browsers: Set<String> = {
        let installed = URL(string: "https://example.com").map { NSWorkspace.shared.urlsForApplications(toOpen: $0) } ?? []
        return Set(installed.compactMap { Bundle(url: $0)?.bundleIdentifier }).union([
            "com.apple.Safari", "app.zen-browser.zen", "org.mozilla.firefox", "com.google.Chrome",
            "company.thebrowser.Browser", "company.thebrowser.dia", "com.brave.Browser", "com.microsoft.edgemac",
            "com.vivaldi.Vivaldi", "com.kagi.kagimacOS", "ai.perplexity.comet", "com.openai.atlas", "net.imput.helium",
            "org.chromium.Chromium", "com.operasoftware.Opera",
        ])
    }()
}

@MainActor
final class MediaController: ObservableObject {
    @Published private(set) var now = NowPlaying()
    @Published private(set) var artwork: NSImage?
    @Published private(set) var tint = Color.white
    /// Bumped on real track changes (not on pause/seek) so the notch can peek.
    @Published private(set) var trackChange = 0
    /// The web page a browser is playing from, once its tab is found.
    @Published private(set) var site: Site?

    struct Site {
        let key: NowPlaying.Key
        let name: String
        let icon: NSImage?
        let isYouTube: Bool
    }

    var isYouTube: Bool { site?.isYouTube == true }
    /// Websites often send no artist; the site's name stands in.
    var subtitle: String { now.artist.isEmpty ? site?.name ?? "" : now.artist }

    private var remoteArt: NSImage?
    private var seeded = false
    private var thumbnail: (key: NowPlaying.Key, image: NSImage)?
    private var lookupKey: NowPlaying.Key?
    private var lookupTask: Task<Void, Never>?
    /// Tab lookups run AppleScript and file reads, one at a time, off the main thread.
    private let lookupQueue = DispatchQueue(label: "nook.webpage", qos: .utility)

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var restarts = 0

    init() { start() }

    /// What the helper understands, one per line on its stdin.
    private enum Command {
        case toggle, next, previous, seek(Double)

        var line: String {
            switch self {
            case .toggle: "toggle"
            case .next: "next"
            case .previous: "prev"
            case .seek(let seconds): "seek \(seconds)"
            }
        }
    }

    private func send(_ command: Command) {
        try? input?.write(contentsOf: Data((command.line + "\n").utf8))
    }

    // Controls update the UI optimistically so they feel instant. The helper always reports the
    // player's actual state shortly after a command, which corrects it if the player said no.
    func toggle() {
        now.elapsed = now.position()
        now.sampledAt = Date()
        now.playing.toggle()
        send(.toggle)
    }

    func next() { now.isVideo ? seek(to: now.position() + 10) : send(.next) }
    func previous() { now.isVideo ? seek(to: now.position() - 10) : send(.previous) }

    func seek(to seconds: Double) {
        let target = max(0, now.duration > 0 ? min(seconds, now.duration) : seconds)
        now.elapsed = target
        now.sampledAt = Date()
        send(.seek(target))
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
            if let snapshot = try? JSONDecoder().decode(Snapshot.self, from: line) { apply(snapshot) }
        }
    }

    /// One line from the helper (Helper/NookMedia.m). `art` is only sent when it changes; `hasArt`
    /// says the player still has some.
    private struct Snapshot: Decodable {
        var title: String?
        var artist: String?
        var bundle: String?
        var duration: Double?
        var elapsed: Double?
        var ts: Double?
        var rate: Double?
        var playing: Bool?
        var art: String?
        var hasArt: Bool?
    }

    private func apply(_ snapshot: Snapshot) {
        var next = NowPlaying()
        next.title = snapshot.title ?? ""
        next.artist = snapshot.artist ?? ""
        next.bundleID = snapshot.bundle ?? ""
        next.duration = snapshot.duration ?? 0
        next.elapsed = snapshot.elapsed ?? 0
        next.sampledAt = snapshot.ts.map(Date.init(timeIntervalSince1970:)) ?? Date()
        next.playing = (snapshot.playing ?? false) && (snapshot.rate.map { $0 > 0 } ?? true)

        let trackChanged = next.title != now.title || next.artist != now.artist
        if let encoded = snapshot.art, let data = Data(base64Encoded: encoded), let image = NSImage(data: data) {
            remoteArt = image
        } else if snapshot.hasArt == nil {
            remoteArt = nil
        }
        if next != now { now = next }
        if site?.key != next.key { site = nil }
        if next.isVideo && !next.title.isEmpty {
            if next.key != lookupKey { findPage(for: next.key) }
        } else {
            lookupTask?.cancel()
            lookupKey = nil
        }
        updateArtwork()
        // The first update after launch is what was already playing, not a change.
        if trackChanged && !next.isEmpty && next.playing && seeded { trackChange += 1 }
        seeded = true
    }

    /// Browser artwork when it sends some, otherwise the thumbnail of the page it's playing.
    private func updateArtwork() {
        let image = remoteArt ?? (thumbnail?.key == now.key ? thumbnail?.image : nil)
        guard image !== artwork else { return }
        artwork = image
        tint = image?.vibrantTint ?? .white
    }

    /// A page can take a moment to reach the browser's history (or tabs) under its final title,
    /// so it's retried quickly at first, then backing off, for about a minute.
    private static let retryDelays: [Double] = [0, 0.4, 0.8, 1.2, 2, 3, 5, 8, 12, 15, 15]

    /// Finds the page `track` plays from, then its preview. A newer track cancels this one,
    /// downloads included, so a late answer can never land on the wrong track.
    private func findPage(for track: NowPlaying.Key) {
        lookupTask?.cancel()
        lookupKey = track
        let queue = lookupQueue
        lookupTask = Task { [weak self] in
            for delay in Self.retryDelays {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                let page = await withCheckedContinuation { done in
                    queue.async { done.resume(returning: WebPage.url(title: track.title, artist: track.artist, browser: track.bundleID)) }
                }
                guard !Task.isCancelled else { return }
                guard let page else { continue }
                let preview = await WebPage.preview(page)
                guard !Task.isCancelled, let self, self.now.key == track else { return }
                if let image = preview.image { self.thumbnail = (track, NSImage(cgImage: image, size: .zero)) }
                self.site = Site(key: track, name: preview.name, icon: preview.icon.map { NSImage(cgImage: $0, size: .zero) },
                                 isYouTube: preview.isYouTube)
                self.updateArtwork()
                return
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
