import AppKit
import Combine
import ServiceManagement
import SwiftUI

enum Phase: Equatable { case closed, peek, open }
enum Tab: Equatable {
    case media, agents
    var page: Int { self == .media ? 0 : 1 }
}
enum Peek: Equatable {
    case track
    case agent(AgentThread)
}

/// The one thing the closed notch shows, highest priority first:
/// 1. an agent needs you  2. an agent finished and you haven't hovered it yet  3. media playing
/// 4. finishes you've seen but not clicked (so they resurface when you pause)  5. agents working
/// 6. nothing (the notch disappears into the camera).
enum Activity: Equatable {
    case needsYou(AgentThread, count: Int)
    case finished(AgentThread, failed: Bool)
    case playing
    case unread(AgentThread, failed: Bool)
    case working(AgentThread, count: Int)
    case idle

    var kind: Int {
        switch self {
        case .needsYou: 0
        case .finished: 1
        case .playing: 2
        case .unread: 3
        case .working: 4
        case .idle: 5
        }
    }
}

/// Every curve is a spring, so any motion can be interrupted mid-flight and the next one picks up
/// its velocity instead of restarting from rest (hover → open, open → close, drag → settle).
enum Motion {
    /// Expanding: a touch of life at the end, like the Dynamic Island.
    static let open = Animation.spring(duration: 0.28, bounce: 0.2)
    /// Collapsing: quick and critically damped, nothing wobbles into the camera.
    static let close = Animation.spring(duration: 0.36, bounce: 0)
    /// The small "I see you" swell under the pointer; hands its velocity to `open`.
    static let hover = Animation.spring(duration: 0.21, bounce: 0.15)
    static let wings = Animation.spring(duration: 0.42, bounce: 0.12)
    /// Content arrives a beat after the shape starts moving and leaves before it finishes.
    static let reveal = Animation.spring(duration: 0.26, bounce: 0).delay(0.03)
    static let hide = Animation.smooth(duration: 0.15)
    /// Follows the fingers, smoothing trackpad events that don't line up with display frames.
    static let track = Animation.interactiveSpring(duration: 0.1, extraBounce: 0)
    /// Lands on a page, inheriting the release velocity from `track`.
    static let settle = Animation.spring(duration: 0.42, bounce: 0.1)
}

@MainActor
final class NotchModel: ObservableObject {
    @Published private(set) var phase = Phase.closed
    @Published private(set) var peek: Peek?
    @Published private(set) var hovering = false
    @Published var tab = Tab.media
    @Published var notch = CGSize(width: 185, height: 32)
    @AppStorage("openOnHover") var openOnHover = true

    let media = MediaController()
    let agents = AgentStore()
    let pager = Pager()

    private var peekTimer: Timer?
    private var hoverTask: Task<Void, Never>?
    /// Finishes the notch was showing when the pointer came in; seen once it leaves.
    private var glimpsed: [AgentThread] = []
    /// A one-off swell that announces a finish without opening anything.
    @Published private(set) var nudging = false
    private var outsideClick: Any?
    private var observers: [AnyCancellable] = []

    static let openSize = CGSize(width: 420, height: 106) // body below the notch

    init() {
        observers.append(media.$trackChange.dropFirst().sink { [weak self] _ in
            // Only when music is what the notch is showing; an agent needing you wins.
            guard let self, self.activity.kind >= Activity.playing.kind else { return }
            self.showPeek(.track, for: 2.6)
        })
        observers.append(agents.$alertCount.dropFirst().sink { [weak self] _ in
            guard let self, let thread = self.agents.alert else { return }
            // Only a thread waiting on you pops a card; a finish stays passive in the wings.
            if case .needsInput = thread.state { self.showPeek(.agent(thread), for: 4.5) } else { self.nudge() }
        })
    }

    // MARK: What to show

    var activity: Activity {
        let threads = agents.threads
        let waiting = threads.filter { $0.state.rank == 0 }
        if let first = waiting.first { return .needsYou(first, count: waiting.count) }
        // Finished threads stay listed until you click them (or dismiss them), then drop out.
        let finished = unseenFinishes
        if let first = finished.first {
            return .finished(first, failed: finished.contains { $0.state.rank == 1 })
        }
        if media.now.playing { return .playing }
        let unread = threads.filter { $0.state.rank == 1 || $0.state.rank == 2 }
        if let first = unread.first { return .unread(first, failed: unread.contains { $0.state.rank == 1 }) }
        let working = threads.filter { $0.state.rank == 3 }
        if let first = working.first { return .working(first, count: working.count) }
        return .idle
    }

    // MARK: Geometry

    /// Width of the notch body (ears excluded) and its full height.
    var size: CGSize {
        switch phase {
        case .open:
            return CGSize(width: Self.openSize.width, height: notch.height + Self.openSize.height)
        case .peek:
            let width = peek == .track ? max(closedWidth + 50, 250) : max(closedWidth + 30, 290)
            return CGSize(width: width, height: notch.height + (peek == .track ? 24 : 40))
        case .closed:
            let swell = hovering || nudging
            return CGSize(width: closedWidth + (swell ? 14 : 0), height: notch.height + (swell ? 3 : 0))
        }
    }

    /// The shape's frame including the ears, in canvas coordinates (top-left origin).
    var shapeFrame: CGRect {
        let width = size.width + earRadius * 2
        return CGRect(x: (NotchWindowController.canvas.width - width) / 2, y: 0, width: width, height: size.height)
    }

    var wing: CGFloat { notch.height - 2 }
    var hasWings: Bool { activity != .idle }
    var closedWidth: CGFloat { notch.width + (hasWings ? wing * 2 : 0) }
    var earRadius: CGFloat { phase == .open ? 9 : 6 }
    var bottomRadius: CGFloat {
        switch phase {
        case .open: 22
        case .peek: 16
        case .closed: hovering || nudging ? 12 : 9
        }
    }

    /// Finished threads still announced in the closed notch; hovering it counts as seeing them.
    private var unseenFinishes: [AgentThread] {
        agents.threads.filter { ($0.state.rank == 1 || $0.state.rank == 2) && !agents.isSeen($0) }
    }

    private var isAgentPeek: Bool {
        if phase == .peek, case .agent = peek { return true }
        return false
    }

    var hasUnseenFinish: Bool {
        if case .finished = activity { return true }
        return false
    }

    // MARK: Interaction

    /// Lets the new wings settle in first, then swells once like a tap on the shoulder.
    private func nudge() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, self.phase == .closed, !self.hovering else { return }
            withAnimation(Motion.hover) { self.nudging = true }
            try? await Task.sleep(for: .milliseconds(320))
            withAnimation(Motion.hover) { self.nudging = false }
        }
    }

    func hover(_ inside: Bool) {
        guard inside != hovering else { return }
        hoverTask?.cancel()
        if inside {
            glimpsed = unseenFinishes
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            withAnimation(Motion.hover) { hovering = true }
            peekTimer?.invalidate()
            // An agent notification stays a notification under the pointer, so it can be clicked.
            if openOnHover && phase != .open && !isAgentPeek {
                // A beat of intent so sweeping across the menu bar doesn't pop it open.
                hoverTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(70))
                    guard !Task.isCancelled, let self, self.hovering else { return }
                    self.open()
                }
            }
        } else {
            // Seen: once the pointer leaves, whatever ranks next (e.g. a video) takes the notch back.
            if !glimpsed.isEmpty { agents.markSeen(glimpsed) }
            glimpsed = []
            withAnimation(Motion.hover) { hovering = false }
            // A short grace period so grazing the edge doesn't snap it shut.
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(140))
                guard !Task.isCancelled, let self, !self.hovering else { return }
                if self.phase == .open { self.close() }
                else if self.phase == .peek { self.schedulePeekEnd(after: 1.2) }
            }
        }
    }

    /// Clicks on the background: open when closed, follow an agent peek. Inside the open panel,
    /// only its buttons and rows act.
    func tap() {
        if case .agent(let thread) = peek, phase == .peek {
            agents.open(thread)
            close()
        } else if phase != .open {
            hoverTask?.cancel()
            open()
        }
    }

    func open() {
        guard phase != .open else { return }
        peekTimer?.invalidate()
        agents.refreshAll()
        tab = preferredTab
        pager.jump(to: tab.page)
        withAnimation(Motion.open) {
            phase = .open
            peek = nil
        }
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    /// Opened from a launcher with the pointer elsewhere: close on its own unless you come to it.
    func openFromLaunch() {
        open()
        hoverTask?.cancel()
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, !self.hovering else { return }
            self.close()
        }
    }

    func close() {
        if let outsideClick { NSEvent.removeMonitor(outsideClick) }
        outsideClick = nil
        peekTimer?.invalidate()
        pager.cancel()
        guard phase != .closed else { return }
        withAnimation(Motion.close) {
            phase = .closed
            peek = nil
        }
    }

    // MARK: Two-finger swipe between tabs

    /// `travel` is the total finger travel so far, positive when the fingers move right.
    func swipe(_ travel: CGFloat) {
        guard phase == .open else { return }
        pager.drag(travel)
    }

    /// `velocity` is the finger speed at lift-off in points per second.
    func endSwipe(_ travel: CGFloat, velocity: CGFloat) {
        guard phase == .open, let page = pager.release(travel, velocity: velocity) else { return }
        let next: Tab = page == 0 ? .media : .agents
        guard next != tab else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        commit(next)
    }

    func switchTab(_ next: Tab) {
        commit(next)
        pager.go(to: next.page)
    }

    private func commit(_ next: Tab) {
        tab = next
    }

    /// Follows the same priority as the closed notch.
    private var preferredTab: Tab {
        switch activity {
        case .needsYou, .finished, .unread: .agents
        case .playing: .media
        case .working: .agents
        case .idle: media.now.isEmpty && !agents.threads.isEmpty ? .agents : .media
        }
    }

    private func showPeek(_ kind: Peek, for duration: TimeInterval) {
        guard phase != .open else { return }
        // A thread needing you is never replaced by a song change.
        if kind == .track, case .agent = peek, phase == .peek { return }
        withAnimation(Motion.open) {
            peek = kind
            phase = .peek
        }
        if !hovering { schedulePeekEnd(after: duration) }
    }

    private func schedulePeekEnd(after delay: TimeInterval) {
        peekTimer?.invalidate()
        peekTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .peek, !self.hovering else { return }
                withAnimation(Motion.close) {
                    self.phase = .closed
                    self.peek = nil
                }
            }
        }
    }

    // MARK: Settings

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
            objectWillChange.send()
        }
    }
}

// MARK: - Pager

/// The open panel's tabs laid side by side. Kept apart from `NotchModel` so a swipe only
/// re-renders the pages and the tab switcher, not the whole notch, on every trackpad event.
@MainActor
final class Pager: ObservableObject {
    /// Continuous page position: 0 = media, 1 = agents; rubber-bands a little past either end.
    @Published private(set) var position: CGFloat = 0
    /// The page it's resting on or heading to.
    @Published private(set) var page = 0
    /// Both pages render while moving; at rest only the current one does.
    @Published private(set) var moving = false

    static let width = NotchModel.openSize.width
    static let gap: CGFloat = 24
    static let stride = width + gap
    private static let count = 2

    private var dragging = false
    private var origin: CGFloat = 0
    private var generation = 0

    /// Fingers left reveal the page on the right, like swiping between Spaces. Tracks 1:1.
    func drag(_ travel: CGFloat) {
        if !dragging {
            dragging = true
            origin = CGFloat(page)
            moving = true
        }
        let raw = origin - travel / Self.stride
        let last = CGFloat(Self.count - 1)
        // Past either end the page resists more the further it goes, and never runs away.
        let target = raw < 0 ? -Self.rubberBand(-raw * Self.stride) / Self.stride
            : raw > last ? last + Self.rubberBand((raw - last) * Self.stride) / Self.stride
            : raw
        withAnimation(Motion.track) { position = target }
    }

    /// Picks the page from where a flick would coast to, not just where the fingers stopped.
    /// Returns the page it settles on, or nil when no drag was in progress.
    func release(_ travel: CGFloat, velocity: CGFloat) -> Int? {
        guard dragging else { return nil }
        dragging = false
        let pageVelocity = -velocity / Self.stride
        // UIScrollView's projection with the fast deceleration rate: v · 0.99 / (1 − 0.99) / 1000.
        let projected = position + pageVelocity * 0.099
        var next = Int(projected.rounded())
        if abs(velocity) > 350 { next = Int(origin) + (pageVelocity > 0 ? 1 : -1) } // a clear flick always turns
        next = min(max(next, Int(origin) - 1, 0), min(Int(origin) + 1, Self.count - 1))
        settle(on: next)
        return next
    }

    func go(to page: Int) {
        dragging = false
        moving = true
        settle(on: page)
    }

    /// Places it on a page instantly, e.g. before the panel opens.
    func jump(to page: Int) {
        dragging = false
        generation += 1
        self.page = page
        position = CGFloat(page)
        moving = false
    }

    func cancel() {
        guard dragging || moving else { return }
        jump(to: page)
    }

    private func settle(on page: Int) {
        self.page = page
        generation += 1
        let current = generation
        withAnimation(Motion.settle, completionCriteria: .removed) {
            position = CGFloat(page)
        } completion: { [weak self] in
            guard let self, self.generation == current, !self.dragging else { return }
            self.moving = false
        }
    }

    /// Apple's rubber band: f(x) = (1 − 1 / (x·c / d + 1)) · d.
    private static func rubberBand(_ offset: CGFloat) -> CGFloat {
        let dimension = width / 2
        return (1 - 1 / (offset * 0.55 / dimension + 1)) * dimension
    }
}

// MARK: - Shape

/// The notch silhouette: concave "ears" melting into the menu bar, rounded bottom corners.
struct NotchShape: Shape {
    var ear: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ear, bottom) }
        set { ear = newValue.first; bottom = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let b = min(bottom, (w - ear * 2) / 2, h - ear)
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addQuadCurve(to: CGPoint(x: ear, y: ear), control: CGPoint(x: ear, y: 0))
        path.addLine(to: CGPoint(x: ear, y: h - b))
        path.addQuadCurve(to: CGPoint(x: ear + b, y: h), control: CGPoint(x: ear, y: h))
        path.addLine(to: CGPoint(x: w - ear - b, y: h))
        path.addQuadCurve(to: CGPoint(x: w - ear, y: h - b), control: CGPoint(x: w - ear, y: h))
        path.addLine(to: CGPoint(x: w - ear, y: ear))
        path.addQuadCurve(to: CGPoint(x: w, y: 0), control: CGPoint(x: w - ear, y: 0))
        path.closeSubpath()
        return path
    }
}

// MARK: - Window

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    let swipes = SwipeTracker()

    /// Scroll events are seen here before any view (e.g. the agents list) can claim them.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .scrollWheel, swipes.consume(event) { return }
        super.sendEvent(event)
    }
}

/// Two-finger horizontal trackpad swipes switch tabs; vertical ones pass through to scroll lists.
final class SwipeTracker {
    var onChange: ((CGFloat) -> Void)?
    /// Travel and lift-off velocity (points per second).
    var onEnd: ((CGFloat, CGFloat) -> Void)?
    private var travel = CGSize.zero
    private var samples: [(time: TimeInterval, x: CGFloat)] = [] // the last ~80 ms of travel
    private var horizontal: Bool? // decided by the first few points of travel

    /// Returns true when the event belongs to a horizontal swipe.
    func consume(_ event: NSEvent) -> Bool {
        // Mouse wheels aren't gestures; the momentum tail after a swipe is swallowed.
        guard event.hasPreciseScrollingDeltas else { return false }
        if !event.momentumPhase.isEmpty { return horizontal == true }
        if event.phase.contains(.began) {
            travel = .zero
            horizontal = nil
            samples.removeAll()
        }
        // Finger movement, whatever the "natural scrolling" setting.
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        travel.width += event.scrollingDeltaX * sign
        travel.height += event.scrollingDeltaY
        if event.scrollingDeltaX != 0 {
            samples.append((event.timestamp, travel.width))
            samples.removeAll { event.timestamp - $0.time > 0.08 }
        }
        if horizontal == nil, abs(travel.width) + abs(travel.height) > 6 {
            horizontal = abs(travel.width) > abs(travel.height)
        }
        let finished = event.phase.contains(.ended) || event.phase.contains(.cancelled)
        guard horizontal == true else { return false }
        finished ? onEnd?(travel.width, velocity(at: event.timestamp)) : onChange?(travel.width)
        return true
    }

    /// Zero when the fingers rested before lifting.
    private func velocity(at time: TimeInterval) -> CGFloat {
        guard let first = samples.first, let last = samples.last, time - last.time < 0.05,
              last.time - first.time > 0.008 else { return 0 }
        return (last.x - first.x) / CGFloat(last.time - first.time)
    }
}

/// Hosts the SwiftUI notch and owns hover: one tracking area that follows the shape's outline.
/// AppKit tracking stays reliable for an inactive app and while the shape animates, where
/// SwiftUI's onHover can miss exits.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?
    private var inside = false

    /// In SwiftUI coordinates (top-left origin).
    var hoverRect = CGRect.zero {
        didSet {
            guard hoverRect != oldValue else { return }
            updateTrackingAreas()
            syncWithPointer()
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let rect = isFlipped ? hoverRect
            : CGRect(x: hoverRect.minX, y: bounds.height - hoverRect.maxY, width: hoverRect.width, height: hoverRect.height)
        let area = NSTrackingArea(rect: rect, options: [.mouseEnteredAndExited, .activeAlways, .enabledDuringMouseDrag],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseEntered(with event: NSEvent) { set(true) }
    override func mouseExited(with event: NSEvent) { set(false) }

    /// Tracking areas don't fire when the area moves under a still pointer; check directly.
    func syncWithPointer() {
        guard let window else { return }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        set(hoverRect.contains(isFlipped ? point : CGPoint(x: point.x, y: bounds.height - point.y)))
    }

    private func set(_ value: Bool) {
        guard value != inside else { return }
        inside = value
        onHover?(value)
    }
}

@MainActor
final class NotchWindowController {
    static let canvas = CGSize(width: 640, height: 250)

    let model = NotchModel()
    let panel: NotchPanel
    private let host: NotchHostingView<AnyView>
    private var observers: [AnyCancellable] = []

    init() {
        panel = NotchPanel(contentRect: CGRect(origin: .zero, size: Self.canvas),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        host = NotchHostingView(rootView: AnyView(NotchRoot().environmentObject(model)))
        host.sizingOptions = []
        host.onHover = { [weak self] inside in self?.model.hover(inside) }
        panel.swipes.onChange = { [weak self] travel in self?.model.swipe(travel) }
        panel.swipes.onEnd = { [weak self] travel, velocity in self?.model.endSwipe(travel, velocity: velocity) }
        panel.contentView = host
        place()
        panel.orderFrontRegardless()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.place() }
        }
        // Keep the hover area matched to whatever the notch currently looks like.
        let changes = Publishers.Merge3(model.objectWillChange, model.media.objectWillChange, model.agents.objectWillChange)
        observers.append(changes.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateHoverRect() })
        updateHoverRect()
    }

    private func updateHoverRect() {
        // A few points of slack below a closed notch make it easier to catch.
        var rect = model.shapeFrame
        if model.phase == .closed { rect = rect.insetBy(dx: -4, dy: 0); rect.size.height += 4 }
        host.hoverRect = rect
    }

    /// Centers the canvas on the built-in notch, or fakes a notch at the top of the main screen.
    func place() {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.frame
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, screen.safeAreaInsets.top > 0 {
            model.notch = CGSize(width: frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
        } else {
            model.notch = CGSize(width: 185, height: max(NSStatusBar.system.thickness, 24))
        }
        panel.setFrame(CGRect(x: frame.midX - Self.canvas.width / 2, y: frame.maxY - Self.canvas.height,
                              width: Self.canvas.width, height: Self.canvas.height), display: true)
    }
}
