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
/// Agent cases carry the distinct apps involved (bundle IDs, list order), so two harnesses show
/// two logos side by side and two threads of the same one show it once.
enum Activity: Equatable {
    case needsYou(apps: [String], count: Int)
    case finished(apps: [String], failed: Bool)
    case playing
    case unread(apps: [String], failed: Bool)
    case working(apps: [String], count: Int)
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
    /// The silhouette's springs. They run in Core Animation (see `NotchSilhouette`), not SwiftUI.
    enum Shape {
        /// Expanding: unhurried enough to read as one continuous gesture, with a touch of life at
        /// the end like the Dynamic Island.
        static let open = Spring(duration: 0.37, bounce: 0.2)
        /// Collapsing: critically damped, so nothing wobbles into the camera.
        static let close = Spring(duration: 0.4, bounce: 0)
        /// The small "I see you" swell under the pointer; its velocity carries into `open`.
        static let hover = Spring(duration: 0.26, bounce: 0.22)
        /// Wings growing out of the camera, overshooting a hair past their width...
        static let widen = Spring(duration: 0.4, bounce: 0.24)
        /// ...and folding back into it, easing all the way in.
        static let narrow = Spring(duration: 0.44, bounce: 0)
    }

    static let open = Animation.spring(duration: 0.28, bounce: 0.2)
    static let close = Animation.spring(duration: 0.36, bounce: 0)
    static let hover = Animation.spring(duration: 0.21, bounce: 0.15)
    static let wings = Animation.spring(duration: 0.42, bounce: 0.12)
    /// Wing content comes out once the edge has started moving...
    static let wingIn = Animation.spring(duration: 0.34, bounce: 0.16).delay(0.064)
    /// ...and is mostly gone before the edge reaches the camera.
    static let wingOut = Animation.smooth(duration: 0.2)
    /// Content arrives a beat after the shape starts moving and leaves before it finishes.
    static let reveal = Animation.spring(duration: 0.27, bounce: 0).delay(0.04)
    static let hide = Animation.smooth(duration: 0.15)
    /// Follows the fingers, smoothing trackpad events that don't line up with display frames.
    static let track = Animation.interactiveSpring(duration: 0.1, extraBounce: 0)
    /// Lands on a page, inheriting the release velocity from `track`.
    static let settle = Animation.spring(duration: 0.42, bounce: 0.1)
}

/// SwiftUI's `.spring(duration:bounce:)` parameters, for Core Animation.
struct Spring: Equatable {
    var duration: Double
    var bounce: Double
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
    /// Set by the app delegate, which owns the Settings window.
    var showSettings: (() -> Void)?
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
        let waiting = threads.filter(\.state.isWaiting)
        if !waiting.isEmpty { return .needsYou(apps: Self.apps(waiting), count: waiting.count) }
        // Finishes you haven't hovered yet are announced; successes then age out, failures wait for you.
        let finished = unseenFinishes
        if !finished.isEmpty {
            return .finished(apps: Self.apps(finished), failed: finished.contains(where: \.state.isFailed))
        }
        if media.now.playing { return .playing }
        let unread = threads.filter(\.state.isFinished)
        if !unread.isEmpty { return .unread(apps: Self.apps(unread), failed: unread.contains(where: \.state.isFailed)) }
        let working = threads.filter(\.state.isWorking)
        if !working.isEmpty { return .working(apps: Self.apps(working), count: working.count) }
        return .idle
    }

    private static func apps(_ threads: [AgentThread]) -> [String] {
        var seen = Set<String>()
        return threads.map(\.bundleID).filter { seen.insert($0).inserted }
    }

    /// Logos shown in the closed wings for the current activity.
    var wingApps: [String] {
        switch activity {
        case .needsYou(let apps, _), .finished(let apps, _), .unread(let apps, _), .working(let apps, _): apps
        case .playing, .idle: []
        }
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
    /// Several logos share the one-logo wing at full size: they spread edge to edge across it and
    /// overlap as needed (a 30 pt wing fits two 18 pt logos with a third of each tucked under).
    var wingLogoLayout: (size: CGFloat, spacing: CGFloat) {
        let size: CGFloat = 18, n = CGFloat(wingApps.count)
        guard n > 1 else { return (size, 0) }
        return (size, min(2, (wing - 1 - size) / (n - 1) - size)) // 1 pt clear of the left edge
    }
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
        agents.threads.filter { $0.state.isFinished && !agents.isSeen($0) }
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
    func endSwipe(velocity: CGFloat) {
        guard phase == .open, let page = pager.release(velocity: velocity) else { return }
        let next: Tab = page == 0 ? .media : .agents
        guard next != tab else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        tab = next
    }

    func switchTab(_ next: Tab) {
        tab = next
        pager.go(to: next.page)
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

    /// Registered, but macOS wants it allowed under Login Items first.
    var launchAtLoginNeedsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// Turns launch at login on the first time Nook runs; after that it's the user's switch.
    func enableLaunchAtLoginOnce() {
        guard !UserDefaults.standard.bool(forKey: "launchAtLoginSetUp") else { return }
        UserDefaults.standard.set(true, forKey: "launchAtLoginSetUp")
        if SMAppService.mainApp.status != .enabled { launchAtLogin = true }
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
    func release(velocity: CGFloat) -> Int? {
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

// MARK: - Silhouette

/// The notch's black shape, as Core Animation layers: a body with rounded bottom corners and two
/// concave "ears" melting into the menu bar. Its springs run in the render server, so every frame
/// lands exactly on the display's clock; SwiftUI's own animations step unevenly at 120 Hz, which
/// reads as judder on a large moving edge. Every spring is additive: a new target adds a spring
/// from the old target to the new one on top of those still running, so the motion keeps its
/// velocity through any interruption, the way UIKit and the Dynamic Island retarget.
@MainActor
final class NotchSilhouette {
    struct Geometry: Equatable {
        var width: CGFloat // the body, ears excluded
        var height: CGFloat
        var ear: CGFloat
        var bottom: CGFloat
        var shadow: Float
    }

    /// The visible black shape (and its shadow).
    let fill = CALayer()
    /// The same shape, clipping the content. Ears are left out: nothing is drawn in them.
    let mask = CALayer()
    private let body = CALayer()
    private let leftEar = CAShapeLayer()
    private let rightEar = CAShapeLayer()
    private let canvas: CGSize
    private var current: Geometry?

    init(canvas: CGSize) {
        self.canvas = canvas
        fill.frame = CGRect(origin: .zero, size: canvas)
        for layer in [body, mask] {
            // Pinned at the top center (layers here have a bottom-left origin), so only the size moves.
            layer.anchorPoint = CGPoint(x: 0.5, y: 1)
            layer.position = CGPoint(x: canvas.width / 2, y: canvas.height)
            layer.backgroundColor = .black
            layer.cornerCurve = .continuous
            layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        }
        body.shadowColor = .black
        body.shadowRadius = 10
        body.shadowOffset = CGSize(width: 0, height: -4)
        body.shadowOpacity = 0
        // Unit-sized fillets, scaled to the ear radius. Each one's corner that touches the body's
        // top edge is its anchor, so it sits on the body's top corner.
        let left = CGMutablePath()
        left.move(to: CGPoint(x: 0, y: 1))
        left.addQuadCurve(to: CGPoint(x: 1, y: 0), control: CGPoint(x: 1, y: 1))
        left.addLine(to: CGPoint(x: 1, y: 1))
        left.closeSubpath()
        let right = CGMutablePath()
        right.move(to: CGPoint(x: 0, y: 0))
        right.addQuadCurve(to: CGPoint(x: 1, y: 1), control: CGPoint(x: 0, y: 1))
        right.addLine(to: CGPoint(x: 0, y: 1))
        right.closeSubpath()
        for (ear, path, anchor) in [(leftEar, left, CGPoint(x: 1, y: 1)), (rightEar, right, CGPoint(x: 0, y: 1))] {
            ear.bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
            ear.path = path
            ear.fillColor = .black
            ear.anchorPoint = anchor
        }
        fill.addSublayer(body)
        fill.addSublayer(leftEar)
        fill.addSublayer(rightEar)
    }

    func set(_ new: Geometry, spring: Spring?) {
        guard new != current else { return }
        let old = current
        current = new
        CATransaction.begin()
        CATransaction.setDisableActions(true) // no implicit animations; only the springs below
        defer { CATransaction.commit() }
        for layer in [body, mask] {
            layer.bounds = CGRect(x: 0, y: 0, width: new.width, height: new.height)
            layer.cornerRadius = new.bottom
        }
        body.shadowOpacity = new.shadow
        leftEar.position = CGPoint(x: (canvas.width - new.width) / 2, y: canvas.height)
        rightEar.position = CGPoint(x: (canvas.width + new.width) / 2, y: canvas.height)
        // Transforms don't add up like numbers, so the ears' size springs from where it is on screen.
        let earFrom = leftEar.presentation()?.transform ?? leftEar.transform
        for ear in [leftEar, rightEar] { ear.transform = CATransform3DMakeScale(new.ear, new.ear, 1) }
        guard let old, let spring else { return }

        let widen = new.width - old.width
        for layer in [body, mask] {
            animate(layer, "bounds.size.width", by: widen, spring)
            animate(layer, "bounds.size.height", by: new.height - old.height, spring)
            animate(layer, "cornerRadius", by: new.bottom - old.bottom, spring)
        }
        animate(body, "shadowOpacity", by: CGFloat(new.shadow - old.shadow), spring)
        // The ears ride the body's edges on the very same spring, so they never come apart.
        animate(leftEar, "position.x", by: -widen / 2, spring)
        animate(rightEar, "position.x", by: widen / 2, spring)
        if new.ear != old.ear {
            for ear in [leftEar, rightEar] {
                let animation = CASpringAnimation(perceptualDuration: spring.duration, bounce: spring.bounce)
                animation.keyPath = "transform"
                animation.fromValue = earFrom
                animation.toValue = ear.transform
                animation.duration = animation.settlingDuration
                ear.add(animation, forKey: "size")
            }
        }
    }

    /// Springs `keyPath` from `delta` behind its new value to zero, on top of any running springs.
    private func animate(_ layer: CALayer, _ keyPath: String, by delta: CGFloat, _ spring: Spring) {
        guard delta != 0 else { return }
        let animation = CASpringAnimation(perceptualDuration: spring.duration, bounce: spring.bounce)
        animation.keyPath = keyPath
        animation.isAdditive = true
        animation.fromValue = -delta
        animation.toValue = 0
        animation.duration = animation.settlingDuration
        layer.add(animation, forKey: nil)
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
    /// Lift-off velocity (points per second).
    var onEnd: ((CGFloat) -> Void)?
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
        finished ? onEnd?(velocity(at: event.timestamp)) : onChange?(travel.width)
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
    private let silhouette: NotchSilhouette
    private var observers: [AnyCancellable] = []
    private var shown: (phase: Phase, wings: Bool, swell: Bool)?

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
        silhouette = NotchSilhouette(canvas: Self.canvas)
        host.sizingOptions = []
        host.onHover = { [weak self] inside in self?.model.hover(inside) }
        panel.swipes.onChange = { [weak self] travel in self?.model.swipe(travel) }
        panel.swipes.onEnd = { [weak self] velocity in self?.model.endSwipe(velocity: velocity) }
        // Bottom to top: the silhouette's black layers, then the SwiftUI content clipped to it.
        let root = NSView(frame: CGRect(origin: .zero, size: Self.canvas))
        let backdrop = NSView(frame: root.bounds)
        backdrop.layer = CALayer()
        backdrop.wantsLayer = true // layer-hosting: the silhouette owns these layers
        let clip = NSView(frame: root.bounds)
        clip.wantsLayer = true
        host.frame = clip.bounds
        clip.addSubview(host)
        root.addSubview(backdrop)
        root.addSubview(clip)
        backdrop.layer?.addSublayer(silhouette.fill)
        clip.layer?.mask = silhouette.mask
        panel.contentView = root
        place()
        panel.orderFrontRegardless()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.place() }
        }
        // Keep the hover area matched to whatever the notch currently looks like.
        let changes = Publishers.Merge3(model.objectWillChange, model.media.objectWillChange, model.agents.objectWillChange)
        observers.append(changes.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.updateShape()
            self?.updateHoverRect()
        })
        updateShape()
        updateHoverRect()
    }

    /// Moves the silhouette to what the model now looks like, with the spring that fits the change.
    private func updateShape() {
        let now = (phase: model.phase, wings: model.hasWings, swell: model.hovering || model.nudging)
        let spring: Spring? = shown.map { was in
            if was.phase != now.phase {
                switch now.phase {
                case .open: return Motion.Shape.open
                case .closed: return Motion.Shape.close
                case .peek: return was.phase == .open ? Motion.Shape.close : Motion.Shape.open
                }
            }
            if now.phase == .closed, was.wings != now.wings { return now.wings ? Motion.Shape.widen : Motion.Shape.narrow }
            if now.phase == .closed, was.swell != now.swell { return Motion.Shape.hover }
            return Motion.Shape.open // a peek changing what it shows
        }
        shown = now
        let size = model.size
        silhouette.set(.init(width: size.width, height: size.height, ear: model.earRadius,
                             bottom: model.bottomRadius, shadow: model.phase == .open ? 0.45 : 0),
                       spring: spring)
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
