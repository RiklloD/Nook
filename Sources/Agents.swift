import AppKit
import CoreServices
import SQLite3

// Agent threads from T3 Code, ChatGPT (Codex) and Hermes, read straight from their local state,
// read-only. Nothing polls: FSEvents tells us which source's files changed and only that one is
// re-read, coalesced to at most once a second while an agent is streaming.

enum AgentState: Equatable {
    case needsInput(String)
    case failed(Date)
    case done(Date)
    case working(Date)

    var rank: Int {
        switch self {
        case .needsInput: 0
        case .failed: 1
        case .done: 2
        case .working: 3
        }
    }

    var isAttention: Bool { rank <= 2 }

    var date: Date {
        switch self {
        case .needsInput: .distantFuture
        case .failed(let date), .done(let date), .working(let date): date
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
}

enum AgentSource: CaseIterable { case t3, codex, hermes, inbox }

let home = FileManager.default.homeDirectoryForCurrentUser.path
let supportDir = "\(home)/Library/Application Support/Nook"
let inboxDir = "\(supportDir)/inbox"

@MainActor
final class AgentStore: ObservableObject {
    @Published private(set) var threads: [AgentThread] = []
    /// A thread that just finished or started waiting on you; drives the notch peek.
    @Published private(set) var alert: AgentThread?
    @Published private(set) var alertCount = 0
    /// Bumped when time alone changes what the notch should show (a finish getting old).
    @Published private(set) var clock = 0

    /// How far back the sources are read. A finish you haven't clicked stays past this, see `unseen`.
    static let recentWindow: TimeInterval = 20 * 60

    private let queue = DispatchQueue(label: "nook.agents", qos: .utility)
    private let reader = AgentReader()
    private var bySource: [AgentSource: [AgentThread]] = [:]
    /// Threads you clicked or dismissed, and when. Kept across launches.
    private var acknowledged = loadDates("acknowledged") { didSet { saveDates(acknowledged, "acknowledged") } }
    /// Finishes you've hovered in the notch: still listed, no longer announced. Kept across launches.
    private var seen = loadDates("seen") { didSet { saveDates(seen, "seen") } }
    /// Finished threads you haven't seen yet, held on to after their source stops reporting them.
    private var unseen: [String: AgentThread] = [:]
    private var known: [String: AgentState] = [:]
    private var seeded = false
    private var watchers: [AnyObject] = []
    private var expiryTimer: Timer?
    private var safetyTimer: Timer?
    private var dirty = Set<AgentSource>()
    private var refreshScheduled = false
    private var lastRefresh = Date.distantPast

    init() {
        try? FileManager.default.createDirectory(atPath: inboxDir, withIntermediateDirectories: true)
        refreshAll()
        // The apps keep their SQLite files open, and FSEvents only reports writes on close, so the
        // databases are watched with kqueue (fires on every write). Only -wal and the main file are
        // watched, never -shm, which our own reads touch.
        let databases: [(String, AgentSource)] = [
            ("\(home)/.t3/userdata/statev2.sqlite", .t3),
            ("\(home)/.codex/state_5.sqlite", .codex),
            ("\(home)/.hermes/state.db", .hermes),
        ]
        for (path, source) in databases {
            let sources: Set<AgentSource> = source == .t3 ? [.t3, .codex] : [source]
            watchers.append(DatabaseWatcher(path: path) { [weak self] in
                Task { @MainActor in self?.markDirty(sources) }
            })
        }
        // Inbox files are written and closed, which FSEvents does report.
        watchers.append(FolderWatcher(path: inboxDir) { [weak self] in
            Task { @MainActor in self?.markDirty([.inbox]) }
        })
    }

    var attentionCount: Int { threads.filter { $0.state.rank == 0 }.count }
    var workingCount: Int { threads.filter { $0.state.rank == 3 }.count }

    func refreshAll() { markDirty(Set(AgentSource.allCases), immediately: true) }

    func open(_ thread: AgentThread) {
        if thread.state.isAttention { acknowledge(thread) }
        if let url = thread.openURL {
            NSWorkspace.shared.open(url)
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: thread.bundleID) {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        }
        rebuild()
    }

    func dismiss(_ thread: AgentThread) {
        acknowledge(thread)
        rebuild()
    }

    func isSeen(_ thread: AgentThread) -> Bool {
        seen[thread.id].map { $0 >= thread.state.date } ?? false
    }

    func markSeen(_ threads: [AgentThread]) {
        for thread in threads {
            seen[thread.id] = Date()
            unseen[thread.id] = nil
        }
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
        let cutoff = Date().addingTimeInterval(-Self.recentWindow)
        queue.async { [weak self, reader] in
            var results: [AgentSource: [AgentThread]] = [:]
            for source in sources { results[source] = reader.read(source, since: cutoff) }
            debugLog("refresh \(sources.map { "\($0)" }.sorted()): " + results.values.joined().map { "\($0.title)=\($0.state)" }.joined(separator: ", "))
            Task { @MainActor in
                guard let self else { return }
                for (source, list) in results { self.bySource[source] = list }
                self.rebuild()
            }
        }
    }

    private func rebuild() {
        var merged: [String: AgentThread] = [:]
        for source in [AgentSource.t3, .codex, .hermes] {
            for thread in bySource[source] ?? [] { merged[thread.id] = thread }
        }
        // Inbox entries (Hermes approvals, scripts) win when they are more urgent.
        for thread in bySource[.inbox] ?? [] {
            if let existing = merged[thread.id], existing.state.rank < thread.state.rank { continue }
            merged[thread.id] = thread
        }

        // A finish you haven't clicked stays until you do, even once it's too old for its source.
        for thread in merged.values where thread.state.rank == 1 || thread.state.rank == 2 {
            if acknowledged[thread.id].map({ thread.state.date > $0 }) ?? true, !isSeen(thread) { unseen[thread.id] = thread }
        }
        unseen = unseen.filter { id, _ in merged[id].map { $0.state.rank == 1 || $0.state.rank == 2 } ?? true }
        for (id, thread) in unseen where merged[id] == nil { merged[id] = thread }

        let visible = merged.values.filter { thread in
            guard let ackAt = acknowledged[thread.id] else { return true }
            switch thread.state {
            case .needsInput: return false
            case .done(let at), .failed(let at): return at > ackAt
            case .working: return true
            }
        }
        let sorted = visible.sorted {
            $0.state.rank != $1.state.rank ? $0.state.rank < $1.state.rank : $0.state.date > $1.state.date
        }

        // Peek only on transitions into "needs you" or "finished", never on first launch.
        if seeded {
            let fresh = sorted.filter { thread in
                guard thread.state.isAttention else { return false }
                return known[thread.id].map { $0.rank != thread.state.rank } ?? true
            }
            if let first = fresh.first {
                alert = first
                alertCount += 1
            }
        }
        seeded = true
        known = merged.mapValues(\.state)
        let pruned = acknowledged.filter { merged[$0.key]?.state.isAttention == true }
        if pruned.count != acknowledged.count { acknowledged = pruned }
        let prunedSeen = seen.filter { merged[$0.key]?.state.isAttention == true }
        if prunedSeen.count != seen.count { seen = prunedSeen }
        if sorted != threads { threads = sorted }
        scheduleTimers()
    }

    private func scheduleTimers() {
        // One timer for the next moment a finish gets old, instead of a polling loop.
        expiryTimer?.invalidate()
        let now = Date()
        let deadlines = threads.flatMap { thread -> [Date] in
            switch thread.state {
            case .done(let at), .failed(let at): [at + Self.recentWindow]
            default: []
            }
        }.filter { $0 > now }
        if let next = deadlines.min() {
            expiryTimer = Timer.scheduledTimer(withTimeInterval: next.timeIntervalSince(now) + 0.5, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.clock += 1
                    self?.rebuild()
                }
            }
            expiryTimer?.tolerance = 2
        }

        // Safety net while something runs: a lease can expire or an app can crash without writing.
        if workingCount > 0 {
            guard safetyTimer == nil else { return }
            safetyTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.markDirty([.t3, .codex, .hermes]) }
            }
            safetyTimer?.tolerance = 10
        } else {
            safetyTimer?.invalidate()
            safetyTimer = nil
        }
    }
}

private func loadDates(_ key: String) -> [String: Date] {
    (UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]).mapValues { Date(timeIntervalSince1970: $0) }
}

private func saveDates(_ dates: [String: Date], _ key: String) {
    UserDefaults.standard.set(dates.mapValues(\.timeIntervalSince1970), forKey: key)
}

// MARK: - File watching

/// Watches a SQLite database and its -wal with kqueue, re-attaching when files are replaced.
final class DatabaseWatcher {
    private let paths: [String]
    private let directory: String
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "nook.dbwatch", qos: .utility)
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var directorySource: DispatchSourceFileSystemObject?

    init(path: String, onChange: @escaping () -> Void) {
        paths = [path, path + "-wal"]
        directory = (path as NSString).deletingLastPathComponent
        self.onChange = onChange
        queue.async { [self] in
            attachMissing()
            // The directory changes only when files are created/removed, e.g. a new -wal.
            directorySource = watch(directory, events: .write) { [weak self] in
                self?.attachMissing()
                self?.onChange()
            }
        }
    }

    private func attachMissing() {
        for path in paths where sources[path] == nil {
            sources[path] = watch(path, events: [.write, .extend, .delete, .rename]) { [weak self] in
                guard let self else { return }
                if let source = self.sources[path], !source.data.isDisjoint(with: [.delete, .rename]) {
                    source.cancel()
                    self.sources[path] = nil
                    self.attachMissing()
                }
                self.onChange()
            }
        }
    }

    private func watch(_ path: String, events: DispatchSource.FileSystemEvent,
                       handler: @escaping () -> Void) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: queue)
        source.setEventHandler(handler: handler)
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    deinit {
        sources.values.forEach { $0.cancel() }
        directorySource?.cancel()
    }
}

/// FSEvents on a folder of small files that are written and closed (the inbox).
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let handler: () -> Void

    init(path: String, handler: @escaping () -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().handler()
        }
        stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents))
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "nook.inbox", qos: .utility))
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}


// MARK: - Readers (run on the agents queue)

final class AgentReader: @unchecked Sendable {
    let t3DB = "\(home)/.t3/userdata/statev2.sqlite"
    let codexDB = "\(home)/.codex/state_5.sqlite"
    let hermesDB = "\(home)/.hermes/state.db"

    private var rolloutCache: [String: (stamp: String, state: AgentState?)] = [:]
    private var hermesWorking: [String: (title: String, since: Date)] = [:]
    private var hermesFinished: [String: (title: String, at: Date)] = [:]

    func read(_ source: AgentSource, since cutoff: Date) -> [AgentThread] {
        switch source {
        case .t3: t3(since: cutoff)
        case .codex: codex(since: cutoff)
        case .hermes: hermes(since: cutoff)
        case .inbox: inbox(since: cutoff)
        }
    }

    private func t3(since cutoff: Date) -> [AgentThread] {
        let sql = """
            SELECT t.thread_id, t.title, r.status, r.requested_at, r.completed_at,
              (SELECT kind FROM orchestration_v2_projection_runtime_requests q
                 WHERE q.thread_id = t.thread_id AND q.status = 'pending' ORDER BY q.created_at LIMIT 1) AS pending_kind
            FROM orchestration_v2_projection_threads t
            JOIN orchestration_v2_projection_runs r ON r.thread_id = t.thread_id
            WHERE t.deleted_at IS NULL AND t.archived_at IS NULL
              AND r.ordinal = (SELECT MAX(ordinal) FROM orchestration_v2_projection_runs WHERE thread_id = t.thread_id)
              AND (r.completed_at IS NULL OR r.completed_at > \(sqlQuote(isoFractional.string(from: cutoff))))
            """
        return sqliteRows(t3DB, sql).compactMap { row in
            guard let id = row["thread_id"], let status = row["status"] else { return nil }
            let state: AgentState
            if let kind = row["pending_kind"] {
                state = .needsInput(kind == "user_input" ? "Asking you a question" : "Waiting for approval")
            } else {
                switch status {
                case "queued", "preparing", "starting", "running", "waiting": state = .working(parseISO(row["requested_at"]) ?? Date())
                case "completed": state = .done(parseISO(row["completed_at"]) ?? Date())
                case "failed", "interrupted": state = .failed(parseISO(row["completed_at"]) ?? Date())
                default: return nil // cancelled by you: nothing to report
                }
            }
            return AgentThread(id: "t3:\(id)", app: .t3, appName: "T3 Code", bundleID: AgentApp.t3.bundleID,
                               title: shortTitle(row["title"] ?? "Untitled thread"), state: state, openURL: nil)
        }
    }

    private func codex(since cutoff: Date) -> [AgentThread] {
        // T3 drives Codex too; those threads are reported once, under T3.
        let t3Owned = Set(sqliteRows(t3DB, """
            SELECT json_extract(payload_json, '$.nativeThreadRef.nativeId') AS id
            FROM orchestration_v2_projection_provider_threads
            WHERE json_extract(payload_json, '$.driver') = 'codex'
            """).compactMap { $0["id"] })
        let rows = sqliteRows(codexDB, """
            SELECT id, COALESCE(name, title) AS title, rollout_path FROM threads
            WHERE archived = 0 AND source NOT LIKE '{%' AND agent_role IS NULL
              AND COALESCE(updated_at_ms, updated_at * 1000) > \(Int(cutoff.timeIntervalSince1970 * 1000))
            """)
        return rows.compactMap { row in
            guard let id = row["id"], !t3Owned.contains(id), let path = row["rollout_path"],
                  let state = rolloutState(path) else { return nil }
            if case .done(let date) = state, date < cutoff { return nil }
            return AgentThread(id: "codex:\(id)", app: .chatgpt, appName: "ChatGPT", bundleID: AgentApp.chatgpt.bundleID,
                               title: shortTitle(row["title"] ?? "Untitled chat"), state: state,
                               openURL: URL(string: "codex://threads/\(id)"))
        }
    }

    /// Latest turn lifecycle event of a Codex rollout, reading only the file's tail.
    private func rolloutState(_ path: String) -> AgentState? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? UInt64 else { return nil }
        let stamp = "\(size)-\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        if let cached = rolloutCache[path], cached.stamp == stamp { return cached.state }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: size > 256_000 ? size - 256_000 : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        var state: AgentState?
        for line in text.split(separator: "\n").reversed() where line.contains("\"event_msg\"") {
            guard line.contains("task_started") || line.contains("task_complete") || line.contains("turn_aborted"),
                  let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = json["payload"] as? [String: Any],
                  let type = payload["type"] as? String else { continue }
            let date = parseISO(json["timestamp"] as? String) ?? Date()
            if type == "task_started" { state = .working(date) }
            else if type == "task_complete" { state = .done(date) }
            else if type == "turn_aborted" { state = nil }
            else { continue }
            break
        }
        rolloutCache[path] = (stamp, state)
        return state
    }

    private func hermes(since cutoff: Date) -> [AgentThread] {
        let now = Date().timeIntervalSince1970
        let leases = sqliteRows(hermesDB, """
            SELECT l.conversation_id AS id, l.acquired_at,
              COALESCE((SELECT title FROM sessions s WHERE s.id = l.conversation_id), 'Hermes chat') AS title
            FROM session_turn_leases l WHERE l.expires_at > \(now)
            """)
        var active: [String: (title: String, since: Date)] = [:]
        for row in leases {
            guard let id = row["id"] else { continue }
            active[id] = (shortTitle(row["title"] ?? "Hermes chat"),
                          Date(timeIntervalSince1970: Double(row["acquired_at"] ?? "") ?? now))
        }
        // A released lease is the only completion signal Hermes leaves on disk.
        for (id, info) in hermesWorking where active[id] == nil { hermesFinished[id] = (info.title, Date()) }
        for id in active.keys { hermesFinished[id] = nil }
        hermesFinished = hermesFinished.filter { $0.value.at > cutoff }
        hermesWorking = active
        func thread(_ id: String, _ title: String, _ state: AgentState) -> AgentThread {
            AgentThread(id: "hermes:\(id)", app: .hermes, appName: "Hermes", bundleID: AgentApp.hermes.bundleID,
                        title: title, state: state, openURL: nil)
        }
        return active.map { thread($0.key, $0.value.title, .working($0.value.since)) }
            + hermesFinished.map { thread($0.key, $0.value.title, .done($0.value.at)) }
    }

    /// One JSON file per status, written by the Hermes plugin or any script:
    /// {"app","title","state":"needs_input|working|done|failed","detail","threadId","openURL","bundleId","updatedAt","expiresAt"}
    private func inbox(since cutoff: Date) -> [AgentThread] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: inboxDir)) ?? []
        return files.filter { $0.hasSuffix(".json") }.compactMap { file in
            let path = "\(inboxDir)/\(file)"
            guard let data = FileManager.default.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let appName = json["app"] as? String, let stateName = json["state"] as? String else { return nil }
            if let expires = json["expiresAt"] as? Double, expires < Date().timeIntervalSince1970 {
                try? FileManager.default.removeItem(atPath: path)
                return nil
            }
            let updated = Date(timeIntervalSince1970: json["updatedAt"] as? Double ?? Date().timeIntervalSince1970)
            let state: AgentState
            switch stateName {
            case "needs_input": state = .needsInput(json["detail"] as? String ?? "")
            case "working": state = .working(updated)
            case "done": state = .done(updated)
            case "failed": state = .failed(updated)
            default: return nil
            }
            if state.rank == 1 || state.rank == 2, updated < cutoff { return nil }
            let app = AgentApp.allCases.first { $0.rawValue == appName } ?? .other
            var threadID = json["threadId"] as? String ?? file
            var title = json["title"] as? String
            if app == .hermes {
                threadID = hermesRoot(threadID)
                title = title ?? sqliteRows(hermesDB, "SELECT title FROM sessions WHERE id = \(sqlQuote(threadID))").first?["title"]
            }
            let key = app == .other ? "\(appName.lowercased()):\(threadID)" : "\(app == .chatgpt ? "codex" : app == .t3 ? "t3" : "hermes"):\(threadID)"
            return AgentThread(id: key, app: app, appName: appName, bundleID: json["bundleId"] as? String ?? app.bundleID,
                               title: shortTitle(title ?? appName), state: state,
                               openURL: (json["openURL"] as? String).flatMap(URL.init(string:)))
        }
    }

    /// Hermes keys turns by the conversation's lineage root; walk parents to find it.
    private func hermesRoot(_ sessionID: String) -> String {
        var current = sessionID
        for _ in 0..<32 {
            guard let parent = sqliteRows(hermesDB, "SELECT parent_session_id AS p FROM sessions WHERE id = \(sqlQuote(current))")
                .first?["p"], !parent.isEmpty else { break }
            current = parent
        }
        return current
    }
}

// MARK: - Helpers

let debugEnabled = ProcessInfo.processInfo.environment["NOOK_DEBUG"] != nil

func debugLog(_ message: @autoclosure () -> String) {
    guard debugEnabled else { return }
    FileHandle.standardError.write(Data("[\(Date().formatted(.dateTime.hour().minute().second()))] \(message())\n".utf8))
}

func sqliteRows(_ path: String, _ sql: String) -> [[String: String]] {
    guard FileManager.default.fileExists(atPath: path) else { return [] }
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        sqlite3_close(db)
        return []
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 500)
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(statement) }
    var rows: [[String: String]] = []
    while sqlite3_step(statement) == SQLITE_ROW {
        var row: [String: String] = [:]
        for index in 0..<sqlite3_column_count(statement) {
            guard let text = sqlite3_column_text(statement, index) else { continue }
            row[String(cString: sqlite3_column_name(statement, index))] = String(cString: text)
        }
        rows.append(row)
    }
    return rows
}

func sqlQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }

nonisolated(unsafe) let isoFractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()
nonisolated(unsafe) let isoPlain = ISO8601DateFormatter()

func parseISO(_ value: String?) -> Date? {
    guard let value else { return nil }
    return isoFractional.date(from: value) ?? isoPlain.date(from: value)
}

func shortTitle(_ raw: String) -> String {
    let line = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? raw
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.count > 80 ? String(trimmed.prefix(79)) + "…" : trimmed
}
