import AppKit

// Agent threads from T3 Code, ChatGPT (Codex), Hermes, OpenCode and Claude Code, read straight from
// their local state, read-only. FSEvents/kqueue tell us which source's files changed and only that
// one is re-read, coalesced to at most once a second while an agent is streaming.

enum AgentState: Equatable {
    /// `since` identifies the request: clicking one mutes it, not the next question in that thread.
    case needsInput(String, since: Date)
    case failed(Date)
    case done(Date)
    case working(Date)

    var isWaiting: Bool { if case .needsInput = self { true } else { false } }
    var isFailed: Bool { if case .failed = self { true } else { false } }
    var isFinished: Bool { switch self { case .failed, .done: true; default: false } }
    var isWorking: Bool { if case .working = self { true } else { false } }
    /// Waiting on you or finished: what the notch announces.
    var isAttention: Bool { !isWorking }

    var date: Date {
        switch self {
        case .needsInput(_, let date), .failed(let date), .done(let date), .working(let date): date
        }
    }

    /// List order only: needs you, failed, done, working.
    var sortOrder: Int {
        switch self {
        case .needsInput: 0
        case .failed: 1
        case .done: 2
        case .working: 3
        }
    }
}

enum AgentApp: String, CaseIterable {
    case t3 = "T3 Code"
    case chatgpt = "ChatGPT"
    case hermes = "Hermes"
    case other = "Other"

    var bundleID: String {
        switch self {
        case .t3: "com.t3tools.t3code"
        case .chatgpt: "com.openai.codex"
        case .hermes: "com.nousresearch.hermes"
        case .other: ""
        }
    }
}

struct AgentThread: Identifiable, Equatable {
    let id: String
    let app: AgentApp
    let appName: String
    let bundleID: String
    let title: String
    var state: AgentState
    let openURL: URL?
    var host: AgentHost? = nil
    /// When the record behind it stops counting (inbox files that set `expiresAt`).
    var expiresAt: Date? = nil
}

/// The app a Codex thread runs in when it isn't the ChatGPT app: the CLI in a terminal or an
/// editor's terminal, or a browser with Codex built in. A click goes back to that tab or window.
struct AgentHost: Equatable {
    let bundleID: String
    let name: String
    var tty: String? = nil
    var folder: String? = nil
}

enum AgentSource: CaseIterable { case t3, codex, hermes, opencode, inbox }

let home = FileManager.default.homeDirectoryForCurrentUser.path
let supportDir = "\(home)/Library/Application Support/Nook"
let inboxDir = "\(supportDir)/inbox"

@MainActor
final class AgentStore: ObservableObject {
    @Published private(set) var threads: [AgentThread] = []
    /// A thread that just finished or started waiting on you; drives the notch peek.
    @Published private(set) var alert: AgentThread?
    @Published private(set) var alertCount = 0

    /// How long a finish stays listed. A failure stays until you click or dismiss it, see `unseen`.
    static let recentWindow: TimeInterval = 20 * 60

    private let reader = AgentReader()
    private var bySource: [AgentSource: [AgentThread]] = [:]
    /// Threads you clicked or dismissed, and when. Kept across launches.
    private var acknowledged = loadDates("acknowledged") { didSet { saveDates(acknowledged, "acknowledged") } }
    /// Finishes you've hovered in the notch: still listed, no longer announced. Kept across launches.
    private var seen = loadDates("seen") { didSet { saveDates(seen, "seen") } }
    /// Failures you haven't cleared, held on to after their source stops reporting them.
    private var unseen: [String: AgentThread] = [:]
    private var known: [String: AgentState] = [:]
    private var seeded = false
    private var watchers: [AnyObject] = []
    /// Hermes profile databases being watched; a profile created later is added on its first read.
    private var watchedHermes = Set<String>()
    private var deadlineTimer: Timer?
    private var safetyTimer: Timer?
    /// Sources with something unfinished, re-read by the safety timer.
    private var unsettled = Set<AgentSource>()
    private var dirty = Set<AgentSource>()
    private var refreshScheduled = false
    private var lastRefresh = Date.distantPast

    init() {
        // Hook records carry working folders and transcript paths: owner-only.
        try? FileManager.default.createDirectory(atPath: inboxDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        for dir in [supportDir, inboxDir] { chmod(dir, 0o700) }
        refreshAll()
        // The apps keep their SQLite files open, and FSEvents only reports writes on close, so the
        // databases are watched with kqueue (fires on every write). Only -wal and the main file are
        // watched, never -shm, which our own reads touch.
        let databases: [(String, AgentSource)] = [
            (AgentReader.t3DB, .t3), (AgentReader.codexDB, .codex),
            (AgentReader.opencodeDB, .opencode),
        ]
        for (path, source) in databases {
            watch(path, source == .t3 ? [.t3, .codex] : [source])
        }
        watchHermesProfiles()
        // Inbox files are written and closed, which FSEvents does report.
        watchers.append(FolderWatcher(path: inboxDir) { [weak self] in
            Task { @MainActor in self?.markDirty([.inbox]) }
        })
        // A thread's host app quitting doesn't touch any agent file; re-read so it stops being named.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            Task { @MainActor in
                guard let self, self.threads.contains(where: { $0.host?.bundleID == id }) else { return }
                self.markDirty([.codex, .hermes, .opencode, .inbox])
            }
        }
    }

    private func watch(_ path: String, _ sources: Set<AgentSource>) {
        watchers.append(DatabaseWatcher(path: path) { [weak self] in
            Task { @MainActor in self?.markDirty(sources) }
        })
    }

    private func watchHermesProfiles() {
        for profile in HermesProfile.all() where watchedHermes.insert(profile.db).inserted {
            watch(profile.db, [.hermes])
        }
    }

    var attentionCount: Int { threads.filter(\.state.isWaiting).count }
    var workingCount: Int { threads.filter(\.state.isWorking).count }

    func refreshAll() { markDirty(Set(AgentSource.allCases), immediately: true) }

    func open(_ thread: AgentThread) {
        if thread.state.isAttention { acknowledge(thread) }
        if let host = thread.host {
            focus(host)
        } else if let url = thread.openURL {
            NSWorkspace.shared.open(url)
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: thread.bundleID) {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        }
        rebuild()
    }

    /// Terminal and iTerm tabs are picked by tty, editors by workspace folder; anything else is activated.
    private func focus(_ host: AgentHost) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: host.bundleID) else { return }
        if let tty = host.tty, let script = tabScript(host.bundleID, tty) {
            var error: NSDictionary?
            if NSAppleScript(source: script)?.executeAndReturnError(&error).booleanValue == true { return }
        }
        if let folder = host.folder, let root = editorWorkspace(host.bundleID, containing: folder) {
            NSWorkspace.shared.open([URL(fileURLWithPath: root)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        NSWorkspace.shared.openApplication(at: app, configuration: .init())
    }

    private func tabScript(_ bundleID: String, _ tty: String) -> String? {
        // A tty comes from devname(), so it's "/dev/ttys012"; anything else is never put in a script.
        guard tty.range(of: #"^/dev/[a-z]+[0-9]+$"#, options: .regularExpression) != nil else { return nil }
        switch bundleID {
        case "com.apple.Terminal":
            return """
            tell application id "com.apple.Terminal"
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is "\(tty)" then
                    set selected of t to true
                    set index of w to 1
                    activate
                    return true
                  end if
                end repeat
              end repeat
            end tell
            return false
            """
        case "com.googlecode.iterm2":
            return """
            tell application id "com.googlecode.iterm2"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with s in sessions of t
                    if tty of s is "\(tty)" then
                      select w
                      select t
                      select s
                      activate
                      return true
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            return false
            """
        default: return nil
        }
    }

    /// VS Code and its forks focus the window that already has a folder open when asked to open it
    /// again, so this is the nearest workspace at or above the thread's directory. Outside any known
    /// workspace, opening would spawn a new window, hence nil.
    private func editorWorkspace(_ bundleID: String, containing folder: String) -> String? {
        struct Workspace: Decodable { let folder: String? }
        let storage: [String: String] = [
            "com.microsoft.VSCode": "Code", "com.microsoft.VSCodeInsiders": "Code - Insiders",
            "com.todesktop.230313mzl4w4u92": "Cursor", "com.exafunction.windsurf": "Windsurf", "com.vscodium": "VSCodium",
        ]
        guard let name = storage[bundleID] else { return nil }
        let dir = "\(home)/Library/Application Support/\(name)/User/workspaceStorage"
        let roots = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).compactMap { entry -> String? in
            guard let data = FileManager.default.contents(atPath: "\(dir)/\(entry)/workspace.json"),
                  let uri = (try? JSONDecoder().decode(Workspace.self, from: data))?.folder.flatMap(URL.init(string:)),
                  uri.isFileURL else { return nil }
            return uri.path
        }
        return roots.filter { folder == $0 || folder.hasPrefix($0 + "/") }.max { $0.count < $1.count }
    }

    func dismiss(_ thread: AgentThread) {
        acknowledge(thread)
        rebuild()
    }

    /// Clears every successful finish at once; failures and questions stay.
    func dismissDone() {
        for thread in threads where thread.state.isFinished && !thread.state.isFailed { acknowledge(thread) }
        rebuild()
    }

    func isSeen(_ thread: AgentThread) -> Bool {
        seen[thread.id].map { $0 >= thread.state.date } ?? false
    }

    func markSeen(_ threads: [AgentThread]) {
        var updated = seen
        for thread in threads {
            updated[thread.id] = Date()
            unseen[thread.id] = nil
        }
        seen = updated
        rebuild()
    }

    private func acknowledge(_ thread: AgentThread) {
        acknowledged[thread.id] = Date()
        unseen[thread.id] = nil
        if alert?.id == thread.id { alert = nil }
    }

    /// Coalesces bursts of writes (an agent streaming tokens) into at most one read per second.
    private func markDirty(_ sources: Set<AgentSource>, immediately: Bool = false) {
        dirty.formUnion(sources)
        guard !refreshScheduled else { return }
        refreshScheduled = true
        let delay = immediately ? 0 : max(0.3, 1 - Date().timeIntervalSince(lastRefresh))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.lastRefresh = Date()
            let sources = self.dirty
            self.dirty = []
            self.refresh(sources)
        }
    }

    private func refresh(_ sources: Set<AgentSource>) {
        reader.read(sources, since: Date().addingTimeInterval(-Self.recentWindow)) { [weak self] results in
            debugLog("refresh \(sources.map { "\($0)" }.sorted()): " + results.values.joined().map { "\($0.title)=\($0.state)" }.joined(separator: ", "))
            Task { @MainActor in
                guard let self else { return }
                // A source that couldn't be read (its app holding the database while it starts) is
                // missing from `results` and keeps its last list, rather than briefly reporting nothing.
                self.bySource.merge(results) { $1 }
                if sources.contains(.hermes) { self.watchHermesProfiles() }
                self.rebuild()
            }
        }
    }

    private func rebuild() {
        var merged: [String: AgentThread] = [:]
        for source in [AgentSource.t3, .codex, .hermes, .opencode] {
            for thread in bySource[source] ?? [] { merged[thread.id] = thread }
        }
        // Inbox entries (Hermes approvals, scripts) win when they are more urgent.
        for thread in bySource[.inbox] ?? [] {
            if let existing = merged[thread.id], existing.state.sortOrder < thread.state.sortOrder { continue }
            merged[thread.id] = thread
        }

        // A failure stays until you click or dismiss it, even once it's too old for its source. A
        // success just ages out of the recent window, so nothing piles up waiting to be cleared.
        for thread in merged.values where thread.state.isFailed {
            if acknowledged[thread.id].map({ thread.state.date > $0 }) ?? true { unseen[thread.id] = thread }
        }
        unseen = unseen.filter { id, _ in merged[id].map(\.state.isFailed) ?? true }
        for (id, thread) in unseen where merged[id] == nil { merged[id] = thread }

        // A click or dismiss hides what was there at the time (a working row included): a later
        // question, finish or turn shows again.
        let visible = merged.values.filter { thread in
            guard let ackAt = acknowledged[thread.id] else { return true }
            return thread.state.date > ackAt
        }
        let sorted = visible.sorted {
            $0.state.sortOrder != $1.state.sortOrder ? $0.state.sortOrder < $1.state.sortOrder : $0.state.date > $1.state.date
        }

        // Peek only on transitions into "needs you" or "finished" (or a new question), never on first launch.
        if seeded {
            let fresh = sorted.filter { thread in
                guard thread.state.isAttention else { return false }
                guard let before = known[thread.id] else { return true }
                return before.sortOrder != thread.state.sortOrder || (thread.state.isWaiting && before != thread.state)
            }
            if let first = fresh.first {
                alert = first
                alertCount += 1
            }
        }
        seeded = true
        known = merged.mapValues(\.state)
        // A click is kept while its thread is listed (later states are newer, so they still show).
        // A thread missing from the list (aged out, or its app mid-restart) keeps it for a day, so
        // an old finish can't come back as new.
        let recent: (Date) -> Bool = { Date().timeIntervalSince($0) < 24 * 3600 }
        let pruned = acknowledged.filter { merged[$0.key] != nil || recent($0.value) }
        if pruned.count != acknowledged.count { acknowledged = pruned }
        let prunedSeen = seen.filter { id, at in merged[id].map(\.state.isAttention) ?? recent(at) }
        if prunedSeen.count != seen.count { seen = prunedSeen }
        if sorted != threads { threads = sorted }
        unsettled = Set(bySource.filter { $0.value.contains { !$0.state.isFinished } }.keys)
        scheduleTimers()
    }

    private func scheduleTimers() {
        // One timer for the next moment time alone changes the list: a finish leaving the recent
        // window, or an inbox record expiring. The sources drop those when re-read.
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        let now = Date()
        let deadlines = threads.flatMap { thread in
            [thread.expiresAt, thread.state.isFinished && !thread.state.isFailed ? thread.state.date + Self.recentWindow : nil].compactMap { $0 }
        }.filter { $0 > now }
        if let next = deadlines.min() {
            deadlineTimer = Timer.scheduledTimer(withTimeInterval: next.timeIntervalSince(now) + 0.5, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.refreshAll() }
            }
            deadlineTimer?.tolerance = 2
        }

        // Safety net while something is unfinished: a lease can expire, or an app or CLI can crash
        // (mid-turn or while waiting on you) without writing anything.
        if unsettled.isEmpty {
            safetyTimer?.invalidate()
            safetyTimer = nil
        } else if safetyTimer == nil {
            safetyTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.markDirty(self.unsettled)
                }
            }
            safetyTimer?.tolerance = 10
        }
    }
}

private func loadDates(_ key: String) -> [String: Date] {
    (UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]).mapValues { Date(timeIntervalSince1970: $0) }
}

private func saveDates(_ dates: [String: Date], _ key: String) {
    UserDefaults.standard.set(dates.mapValues(\.timeIntervalSince1970), forKey: key)
}
