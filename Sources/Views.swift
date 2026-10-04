import AppKit
import SwiftUI

struct NotchRoot: View {
    @EnvironmentObject var model: NotchModel

    var body: some View {
        NotchBody(media: model.media, agents: model.agents)
            .frame(width: NotchWindowController.canvas.width, height: NotchWindowController.canvas.height, alignment: .top)
    }
}

/// Observes media and agents directly so their updates re-lay out the notch, and nothing else.
private struct NotchBody: View {
    @EnvironmentObject var model: NotchModel
    @ObservedObject var media: MediaController
    @ObservedObject var agents: AgentStore

    var body: some View {
        let size = model.size
        let shape = NotchShape(ear: model.earRadius, bottom: model.bottomRadius)
        // Each layer is laid out at the size it's heading to and the morphing shape uncovers it,
        // so nothing inside re-flows (and jitters) on every frame of the spring.
        ZStack(alignment: .top) {
            if model.phase == .open {
                OpenLayer(media: media, agents: agents, pager: model.pager)
                    .transition(.notchContent)
            } else {
                closedLayer
                    .frame(width: size.width, height: size.height, alignment: .top)
                    .transition(.notchContent)
            }
        }
        .frame(width: size.width + model.earRadius * 2, height: size.height, alignment: .top)
        .clipShape(shape)
        // The shadow is cast by the plain black shape, not the whole view tree, which would have
        // to be re-rendered offscreen every frame.
        .background {
            shape.fill(.black)
                .shadow(color: .black.opacity(model.phase == .open ? 0.45 : 0), radius: 10, y: 4)
        }
        .contentShape(shape)
        .onTapGesture { model.tap() }
        .contextMenu { SettingsMenu(model: model) }
        .animation(Motion.wings, value: model.activity.kind)
    }

    private var closedLayer: some View {
        VStack(spacing: 0) {
            ClosedWings(media: media, agents: agents)
                .frame(height: model.notch.height)
            if model.phase == .peek {
                Group {
                    if case .agent(let thread) = model.peek {
                        AgentPeek(thread: thread)
                    } else {
                        TrackPeek(media: media)
                    }
                }
                .transition(.notchContent)
            }
        }
    }
}

/// Fades, unblurs and grows content in from the top edge, the way the Dynamic Island fills in.
private struct Reveal: ViewModifier {
    var shown: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(shown ? 1 : 0.9, anchor: .top)
            .blur(radius: shown ? 0 : 6)
            .opacity(shown ? 1 : 0)
    }
}

extension AnyTransition {
    static let notchContent = AnyTransition.asymmetric(
        insertion: .modifier(active: Reveal(shown: false), identity: Reveal(shown: true)).animation(Motion.reveal),
        removal: .modifier(active: Reveal(shown: false), identity: Reveal(shown: true)).animation(Motion.hide))
}

private struct OpenLayer: View {
    @EnvironmentObject var model: NotchModel
    @ObservedObject var media: MediaController
    @ObservedObject var agents: AgentStore
    let pager: Pager

    var body: some View {
        VStack(spacing: 0) {
            OpenHeader(media: media, agents: agents, pager: pager)
                .frame(height: model.notch.height)
            Pages(pager: pager, media: media, agents: agents)
        }
        .frame(width: NotchModel.openSize.width, height: model.notch.height + NotchModel.openSize.height, alignment: .top)
    }
}

/// Both tabs side by side, sliding with the fingers. The page that's off screen only exists
/// while the pager moves.
private struct Pages: View {
    @ObservedObject var pager: Pager
    let media: MediaController
    let agents: AgentStore

    var body: some View {
        HStack(alignment: .top, spacing: Pager.gap) {
            page(0) { MediaPanel(media: media) }
            page(1) { AgentsPanel(agents: agents) }
        }
        .frame(width: Pager.width, alignment: .leading)
        .offset(x: -pager.position * Pager.stride)
    }

    private func page<Content: View>(_ index: Int, @ViewBuilder _ content: () -> Content) -> some View {
        let distance = min(abs(pager.position - CGFloat(index)), 1)
        return Group {
            if pager.moving || pager.page == index { content() } else { Color.clear }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .frame(width: Pager.width, height: NotchModel.openSize.height, alignment: .top)
        .opacity(1 - distance * 0.6)
    }
}

// MARK: - Closed: live activity wings around the camera

private struct ClosedWings: View {
    @EnvironmentObject var model: NotchModel
    @ObservedObject var media: MediaController
    @ObservedObject var agents: AgentStore

    var body: some View {
        HStack(spacing: 0) {
            leading
                .frame(width: model.hasWings ? model.wing : 0)
            Spacer(minLength: model.notch.width)
            trailing
                .frame(width: model.hasWings ? model.wing : 0)
        }
        .frame(height: model.notch.height)
    }

    @ViewBuilder private var leading: some View {
        switch model.activity {
        case _ where isAgentPeek:
            Color.clear // the peek card below already shows the app icon
        case .needsYou(let thread, _), .finished(let thread, _), .unread(let thread, _), .working(let thread, _):
            AppIcon(bundleID: thread.bundleID, size: 18)
                .id(thread.bundleID)
                .transition(.scale(0.5).combined(with: .opacity))
        case .playing:
            Group {
                if media.isYouTube {
                    YouTubeLogo(height: 13)
                } else {
                    Artwork(image: media.artwork, bundleID: media.now.bundleID, size: 18, radius: 5)
                }
            }
            .transition(.scale(0.5).combined(with: .opacity))
        case .idle:
            Color.clear
        }
    }

    @ViewBuilder private var trailing: some View {
        switch model.activity {
        case .needsYou(_, let count):
            Badge(count: count, color: .orange, symbol: "exclamationmark")
                .transition(.scale(0.3).combined(with: .opacity))
        case .finished(_, let failed), .unread(_, let failed):
            Image(systemName: failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(failed ? .red : .green)
                .transition(.scale(0.3).combined(with: .opacity))
        case .playing:
            Equalizer(color: media.tint, playing: true)
                .frame(width: 14, height: 11)
                .transition(.opacity)
        case .working(_, let count):
            Thinking(size: 15)
                .overlay(alignment: .bottomTrailing) {
                    if count > 1 {
                        Text("\(count)").font(.system(size: 7, weight: .bold, design: .rounded)).foregroundStyle(.white)
                            .padding(1.5).background(Circle().fill(.black))
                            .offset(x: 5, y: 4)
                    }
                }
            .transition(.opacity)
        case .idle:
            Color.clear
        }
    }

    private var isAgentPeek: Bool {
        if case .agent = model.peek { return true }
        return false
    }
}

private struct Badge: View {
    let count: Int
    let color: Color
    let symbol: String

    var body: some View {
        ZStack {
            Pulse(color: color).frame(width: 18, height: 18)
            Circle().fill(color).frame(width: 13, height: 13)
            if count > 1 {
                Text("\(count)").font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(.black)
            } else {
                Image(systemName: symbol).font(.system(size: 7, weight: .heavy)).foregroundStyle(.black)
            }
        }
    }
}

// MARK: - Peeks

private struct TrackPeek: View {
    @ObservedObject var media: MediaController

    var body: some View {
        HStack(spacing: 6) {
            if media.isYouTube { YouTubeLogo(height: 10) }
            Text(media.now.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            if !media.now.artist.isEmpty {
                Text(media.now.artist).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .frame(height: 20)
    }
}

private struct AgentPeek: View {
    let thread: AgentThread

    var body: some View {
        HStack(spacing: 8) {
            AppIcon(bundleID: thread.bundleID, size: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(thread.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                StateLabel(thread: thread)
            }
            Spacer(minLength: 6)
            Image(systemName: "arrow.up.forward.app.fill")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .frame(height: 36)
    }
}

// MARK: - Open: header

private struct OpenHeader: View {
    @EnvironmentObject var model: NotchModel
    @ObservedObject var media: MediaController
    @ObservedObject var agents: AgentStore
    let pager: Pager

    var body: some View {
        HStack(spacing: 0) {
            TabSwitcher(pager: pager, mediaSymbol: media.now.isVideo ? "play.rectangle.fill" : "music.note",
                        badge: agents.attentionCount > 0 || model.hasUnseenFinish) { model.switchTab($0) }
                .padding(.leading, 12)
            Spacer(minLength: model.notch.width + 12)
            summary
                .padding(.trailing, 14)
        }
        .padding(.top, 2)
    }

    @ViewBuilder private var summary: some View {
        let parts = [
            agents.attentionCount > 0 ? "\(agents.attentionCount) need you" : nil,
            agents.workingCount > 0 ? "\(agents.workingCount) working" : nil,
        ].compactMap { $0 }
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(agents.attentionCount > 0 ? .orange : .white.opacity(0.45))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

/// The selection pill rides the pager's position, so it follows the fingers mid-swipe and
/// stretches a little between the two tabs.
private struct TabSwitcher: View {
    @ObservedObject var pager: Pager
    let mediaSymbol: String
    let badge: Bool
    let select: (Tab) -> Void

    private static let item = CGSize(width: 24, height: 16)
    private static let spacing: CGFloat = 2

    var body: some View {
        let progress = min(max(pager.position, 0), 1)
        let stretch = (1 - abs(progress * 2 - 1)) * 6
        ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.16))
                .frame(width: Self.item.width + stretch, height: Self.item.height)
                .offset(x: progress * (Self.item.width + Self.spacing) - stretch / 2)
            HStack(spacing: Self.spacing) {
                button(.media, symbol: mediaSymbol)
                button(.agents, symbol: "sparkles", badge: badge)
            }
        }
        .padding(2)
        .background(Capsule().fill(.white.opacity(0.07)))
    }

    private func button(_ tab: Tab, symbol: String, badge: Bool = false) -> some View {
        let focus = 1 - min(abs(pager.position - CGFloat(tab.page)), 1)
        return Button { select(tab) } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45 + 0.55 * focus))
                .frame(width: Self.item.width, height: Self.item.height)
                .overlay(alignment: .topTrailing) {
                    if badge { Circle().fill(.orange).frame(width: 4, height: 4).offset(x: -4, y: 2) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Open: media

private struct MediaPanel: View {
    @ObservedObject var media: MediaController

    var body: some View {
        if media.now.isEmpty {
            EmptyMedia()
        } else {
            HStack(spacing: 12) {
                let artSize = media.now.isVideo ? CGSize(width: 112, height: 63) : CGSize(width: 68, height: 68)
                Artwork(image: media.artwork, bundleID: media.now.bundleID, size: artSize.height, width: artSize.width,
                        radius: media.now.isVideo ? 10 : 12)
                    .overlay(alignment: .bottomTrailing) {
                        Group {
                            if media.isYouTube {
                                YouTubeLogo(height: 12).padding(5)
                            } else {
                                AppIcon(bundleID: media.now.bundleID, size: 16).offset(x: 4, y: 4)
                            }
                        }
                    }
                    .scaleEffect(media.now.playing ? 1 : 0.94)
                    .opacity(media.now.playing ? 1 : 0.75)
                    .animation(Motion.open, value: media.now.playing)
                    .onTapGesture { media.openSource() }
                    .help(media.isYouTube ? "Open YouTube tab" : "Open player")

                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(media.now.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                            Text(media.now.artist).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                        }
                        .lineLimit(1)
                        Spacer(minLength: 6)
                        Equalizer(color: media.tint, playing: media.now.playing)
                            .frame(width: 14, height: 11)
                            .padding(.top, 2)
                    }
                    Spacer(minLength: 4)
                    Scrubber(media: media)
                    Spacer(minLength: 2)
                    Controls(media: media)
                }
                .frame(height: 72)
            }
            .frame(maxHeight: .infinity)
            .padding(.bottom, 8)
        }
    }
}

private struct Controls: View {
    @ObservedObject var media: MediaController

    var body: some View {
        HStack(spacing: 20) {
            ControlButton(symbol: media.now.isVideo ? "gobackward.10" : "backward.fill", size: 12) { media.previous() }
            ControlButton(symbol: media.now.playing ? "pause.fill" : "play.fill", size: 17) { media.toggle() }
            ControlButton(symbol: media.now.isVideo ? "goforward.10" : "forward.fill", size: 12) { media.next() }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ControlButton: View {
    let symbol: String
    let size: CGFloat
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(.white)
                .frame(width: 26, height: 22)
                .background(Circle().fill(.white.opacity(hovered ? 0.1 : 0)).frame(width: 26, height: 26)
                    .scaleEffect(hovered ? 1 : 0.7))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovered = $0 }
        .animation(.spring(duration: 0.25, bounce: 0.2), value: hovered)
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(duration: 0.22, bounce: 0.35), value: configuration.isPressed)
    }
}

/// Elapsed / remaining with a draggable bar. Ticks twice a second, only while visible and playing.
private struct Scrubber: View {
    @ObservedObject var media: MediaController
    @State private var dragging: Double?

    var body: some View {
        TimelineView(.periodic(from: .now, by: media.now.playing && dragging == nil ? 0.5 : 3600)) { context in
            let duration = media.now.duration
            let position = dragging ?? media.now.position(at: context.date)
            let progress = duration > 0 ? position / duration : 0
            HStack(spacing: 6) {
                Text(clock(position)).frame(width: 28, alignment: .trailing)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.15))
                        Capsule().fill(.white.opacity(dragging == nil ? 0.85 : 1))
                            .frame(width: max(geo.size.width * progress, 4))
                    }
                    .frame(height: dragging == nil ? 3 : 5)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration > 0 else { return }
                            dragging = min(max(value.location.x / geo.size.width, 0), 1) * duration
                        }
                        .onEnded { _ in
                            if let target = dragging { media.seek(to: target) }
                            dragging = nil
                        })
                    .animation(.spring(response: 0.25), value: dragging == nil)
                }
                .frame(height: 10)
                Text(duration > 0 ? "-" + clock(duration - position) : "--:--").frame(width: 32, alignment: .leading)
            }
            .font(.system(size: 8.5, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.45))
        }
    }

    private func clock(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct EmptyMedia: View {
    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: "music.note").font(.system(size: 17)).foregroundStyle(.white.opacity(0.3))
            Text("Nothing playing").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.45))
            Button {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") {
                    NSWorkspace.shared.openApplication(at: url, configuration: .init())
                }
            } label: {
                Label("Open Spotify", systemImage: "arrow.up.forward")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(Color(red: 0.12, green: 0.84, blue: 0.38)))
            }
            .buttonStyle(PressStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 8)
    }
}

// MARK: - Open: agents

private struct AgentsPanel: View {
    @ObservedObject var agents: AgentStore
    @EnvironmentObject var model: NotchModel

    var body: some View {
        if agents.threads.isEmpty {
            VStack(spacing: 7) {
                HStack(spacing: 10) {
                    ForEach([AgentApp.t3, .chatgpt, .hermes], id: \.self) { app in
                        Button { launch(app.bundleID) } label: { AppIcon(bundleID: app.bundleID, size: 24) }
                            .buttonStyle(PressStyle())
                            .help("Open \(app.rawValue)")
                    }
                }
                Text("No agents running").font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.45))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 8)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 1) {
                    ForEach(agents.threads) { thread in
                        AgentRow(thread: thread) {
                            agents.open(thread)
                            model.close()
                        } dismiss: {
                            withAnimation(.spring(response: 0.3)) { agents.dismiss(thread) }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.bottom, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: agents.threads.map(\.id))
        }
    }

    private func launch(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}

private struct AgentRow: View {
    let thread: AgentThread
    let open: () -> Void
    let dismiss: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            AppIcon(bundleID: thread.bundleID, size: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(thread.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                StateLabel(thread: thread)
            }
            Spacer(minLength: 8)
            if hovered && thread.state.rank <= 2 {
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                        .frame(width: 16, height: 16).background(Circle().fill(.white.opacity(0.12)))
                }
                .buttonStyle(PressStyle())
                .help("Dismiss")
            } else {
                StateGlyph(state: thread.state)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(hovered ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: open)
        .animation(.smooth(duration: 0.18), value: hovered)
    }
}

struct StateLabel: View {
    let thread: AgentThread

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(text(now: context.date))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }

    private func text(now: Date) -> String {
        switch thread.state {
        case .needsInput(let detail): "\(thread.appName) · \(detail.isEmpty ? "Needs your input" : detail)"
        case .failed(let at): "\(thread.appName) · Failed \(ago(at, now))"
        case .done(let at): "\(thread.appName) · Done \(ago(at, now))"
        case .working(let since): "\(thread.appName) · Working · \(duration(since, now))"
        }
    }

    private var color: Color {
        switch thread.state {
        case .needsInput: .orange
        case .failed: .red.opacity(0.9)
        case .done: .green.opacity(0.9)
        case .working: .white.opacity(0.45)
        }
    }

    private func ago(_ date: Date, _ now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        return minutes < 1 ? "just now" : "\(minutes)m ago"
    }

    private func duration(_ since: Date, _ now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(since) / 60)
        return minutes < 1 ? "<1m" : minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }
}

private struct StateGlyph: View {
    let state: AgentState

    var body: some View {
        switch state {
        case .needsInput: Badge(count: 1, color: .orange, symbol: "exclamationmark")
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red).font(.system(size: 12))
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 12))
        case .working: Thinking(size: 13)
        }
    }
}

// MARK: - Settings (right-click the notch)

struct SettingsMenu: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        Toggle("Open on Hover", isOn: $model.openOnHover)
        Toggle("Launch at Login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
        Divider()
        Button("Quit Nook") { NSApp.terminate(nil) }
    }
}

// MARK: - Shared pieces

struct Artwork: View {
    let image: NSImage?
    let bundleID: String
    var size: CGFloat
    var width: CGFloat?
    var radius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    shape.fill(.white.opacity(0.08))
                    AppIcon(bundleID: bundleID, size: size * 0.55)
                }
            }
        }
        .frame(width: width ?? size, height: size)
        .clipShape(shape)
    }
}

/// YouTube's mark: red rounded rectangle with a white play triangle, drawn rather than shipped as an asset.
struct YouTubeLogo: View {
    let height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: height * 0.28, style: .continuous)
            .fill(Color(red: 1, green: 0, blue: 0))
            .frame(width: height * 1.42, height: height)
            .overlay {
                Path { path in
                    let side = height * 0.42
                    path.move(to: CGPoint(x: 0, y: 0))
                    path.addLine(to: CGPoint(x: side * 0.95, y: side / 2))
                    path.addLine(to: CGPoint(x: 0, y: side))
                    path.closeSubpath()
                }
                .fill(.white)
                .frame(width: height * 0.42 * 0.95, height: height * 0.42)
                .offset(x: height * 0.03)
            }
    }
}

@MainActor
enum IconCache {
    static var icons: [String: NSImage] = [:]

    static func icon(_ bundleID: String) -> NSImage? {
        if let cached = icons[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = icon
        return icon
    }
}

struct AppIcon: View {
    let bundleID: String
    let size: CGFloat

    var body: some View {
        if let icon = IconCache.icon(bundleID) {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            Image(systemName: "app.dashed").font(.system(size: size * 0.7)).foregroundStyle(.white.opacity(0.4))
                .frame(width: size, height: size)
        }
    }
}
