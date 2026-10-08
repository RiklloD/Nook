import AppKit

/// Reads the agent sources off the main thread. Every piece of mutable state below is only ever
/// touched on `queue` (`read` hops onto it and the rest is private), which is what makes sharing
/// the reader with the main actor safe.
final class AgentReader: @unchecked Sendable {
    static let t3DB = "\(home)/.t3/userdata/statev2.sqlite"
    static let codexDB = "\(home)/.codex/state_5.sqlite"
    static let hermesDB = "\(home)/.hermes/state.db"
    static let opencodeDB = "\(home)/.local/share/opencode/opencode.db"

    /// A turn whose session hasn't been written for this long is taken as abandoned (the app or
    /// CLI died mid-turn). Within it, a running turn is shown however long it's been running.
    static let activeWindow: TimeInterval = 6 * 3600

    private let queue = DispatchQueue(label: "nook.agents", qos: .utility)
    private var rolloutCache: [String: (offset: UInt64, state: AgentState?)] = [:]
    private var t3Owned = Set<String>()
    private var hermesTurns: [HermesProfile: HermesTurns] = [:]
    private var hosts: [String: (pid: pid_t, host: AgentHost?, checked: Date)] = [:]
    private var claudeTurns: [String: Date] = [:]
    private var claudeTitles: [String: String] = [:]

    /// Calls back (on the reader's queue) with the sources that could be read; one that couldn't is
    /// left out, so the caller keeps its last list.
    func read(_ sources: Set<AgentSource>, since cutoff: Date,
              then deliver: @escaping @Sendable ([AgentSource: [AgentThread]]) -> Void) {
        queue.async { [self] in
            var results: [AgentSource: [AgentThread]] = [:]
            for source in sources { results[source] = read(source, since: cutoff) }
            deliver(results)
        }
    }

    private func read(_ source: AgentSource, since cutoff: Date) -> [AgentThread]? {
        dispatchPrecondition(condition: .onQueue(queue))
        return switch source {
        case .t3: t3(since: cutoff)
        case .codex: codex(since: cutoff)
        case .hermes: hermes(since: cutoff)
        case .opencode: opencode(since: cutoff)
        case .inbox: inbox(since: cutoff)
        }
    }

    private var activeCutoff: Date { Date().addingTimeInterval(-Self.activeWindow) }

    private func t3(since cutoff: Date) -> [AgentThread]? {
        let sql = """
            SELECT t.thread_id, t.title, r.status, r.requested_at, r.completed_at, p.kind AS pending_kind, p.created_at AS pending_at
            FROM orchestration_v2_projection_threads t
            JOIN orchestration_v2_projection_runs r ON r.thread_id = t.thread_id
            LEFT JOIN orchestration_v2_projection_runtime_requests p ON p.runtime_request_id = (
              SELECT q.runtime_request_id FROM orchestration_v2_projection_runtime_requests q
              WHERE q.thread_id = t.thread_id AND q.status = 'pending' ORDER BY q.created_at LIMIT 1)
            WHERE t.deleted_at IS NULL AND t.archived_at IS NULL
              AND r.ordinal = (SELECT MAX(ordinal) FROM orchestration_v2_projection_runs WHERE thread_id = t.thread_id)
              AND (r.completed_at IS NULL OR r.completed_at > \(sqlQuote(cutoff.formatted(isoFractional))))
            """
        return sqliteQuery(Self.t3DB, sql)?.compactMap { row in
            guard let id = row["thread_id"], let status = row["status"] else { return nil }
            let state: AgentState
            if let kind = row["pending_kind"] {
                guard let since = parseISO(row["pending_at"]) else { return nil }
                state = .needsInput(kind == "user_input" ? "Asking you a question" : "Waiting for approval", since: since)
            } else {
                switch status {
                case "queued", "preparing", "starting", "running", "waiting":
                    guard let at = parseISO(row["requested_at"]) else { return nil }
                    state = .working(at)
                case "completed", "failed", "interrupted":
                    guard let at = parseISO(row["completed_at"]) else { return nil }
                    state = status == "completed" ? .done(at) : .failed(at)
                default: return nil // cancelled by you: nothing to report
                }
            }
            return AgentThread(id: "t3:\(id)", app: .t3, appName: "T3 Code", bundleID: AgentApp.t3.bundleID,
                               title: shortTitle(row["title"] ?? "Untitled thread"), state: state, openURL: nil)
        }
    }

    private func codex(since cutoff: Date) -> [AgentThread]? {
        // T3 drives Codex too; those threads are reported once, under T3. When T3's database is busy
        // the last known set stands, rather than hiding standalone Codex threads.
        if let rows = sqliteQuery(Self.t3DB, """
            SELECT json_extract(payload_json, '$.nativeThreadRef.nativeId') AS id
            FROM orchestration_v2_projection_provider_threads
            WHERE json_extract(payload_json, '$.driver') = 'codex'
            """) {
            t3Owned = Set(rows.compactMap { $0["id"] })
        }
        guard let rows = sqliteQuery(Self.codexDB, """
            SELECT id, COALESCE(name, title) AS title, rollout_path, cwd, COALESCE(originator, '') AS originator FROM threads
            WHERE archived = 0 AND source NOT LIKE '{%' AND agent_role IS NULL
              AND COALESCE(updated_at_ms, updated_at * 1000) > \(Int(activeCutoff.timeIntervalSince1970 * 1000))
            """) else { return nil }
        return rows.compactMap { row in
            guard let id = row["id"], !t3Owned.contains(id), let path = row["rollout_path"],
                  let state = rolloutState(path) else { return nil }
            // Finishes count while recent; a running turn counts however long it's been quiet.
            if state.isFinished, state.date < cutoff { return nil }
            let host = codexHost(id, originator: row["originator"] ?? "", cwd: row["cwd"] ?? "")
            let fallbackName = row["originator"] == "codex-tui" ? "Codex CLI" : "ChatGPT"
            return AgentThread(id: "codex:\(id)", app: .chatgpt, appName: host.map { "Codex in \($0.name)" } ?? fallbackName,
                               bundleID: host?.bundleID ?? AgentApp.chatgpt.bundleID,
                               title: shortTitle(row["title"] ?? "Untitled chat"), state: state,
                               openURL: URL(string: "codex://threads/\(id)"), host: host)
        }
    }

    /// Where a Codex thread outside the ChatGPT app runs: the CLI's host, or an app embedding Codex
    /// (the Yab browser), which names itself as the originator.
    private func codexHost(_ id: String, originator: String, cwd: String) -> AgentHost? {
        guard originator != "Codex Desktop" else { return nil }
        if let host = cliHost("codex:\(id)", cwd: cwd, matching: { $1 == "codex" }) {
            return host.isNativeApp ? nil : host
        }
        return installedApp(named: originator).map { AgentHost(bundleID: $0.bundleID, name: $0.name) }
    }

    /// The app an agent CLI runs in. Without a known pid, the CLI is found among running processes
    /// by working directory (newest first) and traced up to the app it lives in, noting its terminal
    /// tab on the way. Remembered per thread; looked up again, at most every 10 s, only while the
    /// remembered process is gone. The last host is kept if nothing turns up, but only while that
    /// app is still running: a CLI whose editor has quit no longer runs anywhere.
    private func cliHost(_ key: String, cwd: String, pid knownPID: pid_t? = nil,
                         matching isAgent: (pid_t, String) -> Bool = { _, _ in false }) -> AgentHost? {
        if let cached = hosts[key] {
            if cached.pid != 0 && kill(cached.pid, 0) == 0 && (knownPID == nil || knownPID == cached.pid) { return cached.host }
            if Date().timeIntervalSince(cached.checked) < 10 && knownPID == nil { return cached.host.flatMap(stillRunning) }
        }
        let candidates = knownPID.map { [$0] }
            ?? agentProcesses(isAgent).filter { currentDirectory($0.pid) == cwd }.sorted { $0.started > $1.started }.map(\.pid)
        for pid in candidates {
            guard var host = hostApp(of: pid) else { continue }
            if knownPID == nil, host.isNativeApp, candidates.count > 1 { continue } // a desktop app's own worker
            host.folder = cwd
            hosts[key] = (pid, host, Date())
            return host
        }
        let previous = hosts[key]?.host.flatMap(stillRunning)
        hosts[key] = (0, previous, Date())
        return previous
    }

    private func stillRunning(_ host: AgentHost) -> AgentHost? {
        NSRunningApplication.runningApplications(withBundleIdentifier: host.bundleID).isEmpty ? nil : host
    }

    /// Latest turn lifecycle state of a Codex rollout. The first look scans back from the end in
    /// growing chunks until an event turns up (a long turn can push its start megabytes back);
    /// after that only the bytes appended since the last look are read.
    private func rolloutState(_ path: String) -> AgentState? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64 else { return nil }
        if let cached = rolloutCache[path], cached.offset == size { return cached.state }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        if let cached = rolloutCache[path], cached.offset < size {
            try? handle.seek(toOffset: cached.offset)
            let data = handle.readDataToEndOfFile()
            // Leave a half-written last line for next time.
            let complete = data.lastIndex(of: UInt8(ascii: "\n")).map { data.startIndex.distance(to: $0) + 1 } ?? 0
            let state = lastLifecycleEvent(data.prefix(complete)).map(\.state) ?? cached.state
            rolloutCache[path] = (cached.offset + UInt64(complete), state)
            return state
        }
        var chunk: UInt64 = 256_000
        while true {
            let start = size > chunk ? size - chunk : 0
            try? handle.seek(toOffset: start)
            let data = handle.readData(ofLength: Int(size - start))
            // Skip the partial first line unless reading from the top.
            let body = start == 0 ? data : data.firstIndex(of: UInt8(ascii: "\n")).map { data[$0...] } ?? Data()
            let end = start + UInt64(data.lastIndex(of: UInt8(ascii: "\n")).map { data.startIndex.distance(to: $0) + 1 } ?? 0)
            if let event = lastLifecycleEvent(body) {
                rolloutCache[path] = (end, event.state)
                return event.state
            }
            if start == 0 {
                rolloutCache[path] = (end, nil)
                return nil
            }
            chunk *= 4
        }
    }

    private enum LifecycleEvent {
        case started(Date), completed(Date), aborted

        /// An aborted turn was stopped by you: nothing to report.
        var state: AgentState? {
            switch self {
            case .started(let at): .working(at)
            case .completed(let at): .done(at)
            case .aborted: nil
            }
        }
    }

    private struct RolloutLine: Decodable {
        struct Payload: Decodable { let type: String }
        let timestamp: String
        let payload: Payload
    }

    /// The last turn start, completion or abort in the text, if any.
    private func lastLifecycleEvent(_ data: Data) -> LifecycleEvent? {
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n").reversed() where line.contains("\"event_msg\"") {
            guard line.contains("task_started") || line.contains("task_complete") || line.contains("turn_aborted"),
                  let event = try? JSONDecoder().decode(RolloutLine.self, from: Data(line.utf8)) else { continue }
            guard let date = parseISO(event.timestamp) else {
                debugLog("codex: unreadable timestamp \(event.timestamp)")
                continue
            }
            switch event.payload.type {
            case "task_started": return .started(date)
            case "task_complete": return .completed(date)
            case "turn_aborted": return .aborted
            default: continue
            }
        }
        return nil
    }

    /// Each Hermes profile keeps its own database. One that can't be read keeps its last list, so
    /// one busy profile doesn't hide or finish the others.
    private func hermes(since cutoff: Date) -> [AgentThread]? {
        HermesProfile.all().flatMap { profile in
            var turns = hermesTurns[profile] ?? HermesTurns()
            if let list = hermes(profile, &turns, since: cutoff) { turns.last = list }
            hermesTurns[profile] = turns
            return turns.last
        }
    }

    private struct HermesTurns {
        var working: [String: (title: String, since: Date)] = [:]
        var finished: [String: (title: String, state: AgentState)] = [:]
        var places: [String: (cwd: String, source: String)] = [:]
        var last: [AgentThread] = []
    }

    private func hermes(_ profile: HermesProfile, _ turns: inout HermesTurns, since cutoff: Date) -> [AgentThread]? {
        let now = Date().timeIntervalSince1970
        guard let leases = sqliteQuery(profile.db, """
            SELECT l.conversation_id AS id, l.acquired_at,
              COALESCE((SELECT title FROM sessions s WHERE s.id = l.conversation_id), 'Hermes chat') AS title,
              (SELECT cwd FROM sessions s WHERE s.id = l.conversation_id) AS cwd,
              (SELECT source FROM sessions s WHERE s.id = l.conversation_id) AS source
            FROM session_turn_leases l WHERE l.expires_at > \(now)
            """) else { return nil }
        var active: [String: (title: String, since: Date)] = [:]
        for row in leases {
            guard let id = row["id"], let acquired = Double(row["acquired_at"] ?? "") else { continue }
            turns.places[id] = (row["cwd"] ?? "", row["source"] ?? "")
            active[id] = (shortTitle(row["title"] ?? "Hermes chat"), Date(timeIntervalSince1970: acquired))
        }
        // A released lease is the only sign on disk that a turn ended; how it ended comes from its
        // last message.
        for (id, info) in turns.working where active[id] == nil {
            let at = Date()
            turns.finished[id] = (info.title, hermesEndedCleanly(id, in: profile) ? .done(at) : .failed(at))
        }
        for id in active.keys { turns.finished[id] = nil }
        turns.finished = turns.finished.filter { $0.value.state.date > cutoff }
        turns.working = active
        let finished = turns.finished
        turns.places = turns.places.filter { active[$0.key] != nil || finished[$0.key] != nil }
        let places = turns.places
        func thread(_ id: String, _ title: String, _ state: AgentState) -> AgentThread {
            // Sessions outside the desktop app come from the CLI, a python process running hermes.
            var host: AgentHost?
            if let place = places[id], place.source != "desktop", !place.cwd.isEmpty {
                host = cliHost("hermes:\(profile.key(id))", cwd: place.cwd) { pid, name in
                    name.hasPrefix("python") && processArguments(pid).contains { $0.contains("hermes") }
                }.flatMap { $0.isNativeApp ? nil : $0 }
            }
            return AgentThread(id: "hermes:\(profile.key(id))", app: .hermes,
                               appName: host.map { "\(profile.appName) in \($0.name)" } ?? profile.appName,
                               bundleID: host?.bundleID ?? AgentApp.hermes.bundleID, title: title, state: state,
                               openURL: hermesURL(id), host: host)
        }
        return active.map { thread($0.key, $0.value.title, .working($0.value.since)) }
            + finished.map { thread($0.key, $0.value.title, $0.value.state) }
    }

    /// A turn that ended on the assistant's final answer finished; one that stopped mid-way (on a
    /// tool call or result: interrupted, crashed) didn't. Unknown counts as finished.
    private func hermesEndedCleanly(_ conversation: String, in profile: HermesProfile) -> Bool {
        let id = sqlQuote(conversation)
        guard let last = sqliteQuery(profile.db, """
            SELECT role, finish_reason FROM messages
            WHERE session_id IN (SELECT id FROM sessions WHERE id = \(id) OR parent_session_id = \(id))
            ORDER BY timestamp DESC LIMIT 1
            """)?.first else { return true }
        return last["role"] == "assistant" && last["finish_reason"] == "stop"
    }

    /// OpenCode sessions record each turn as messages; an "idle" message ends it with an outcome.
    /// Approvals live only in the running OpenCode server, so "needs you" isn't visible.
    private func opencode(since cutoff: Date) -> [AgentThread]? {
        guard let rows = sqliteQuery(Self.opencodeDB, """
            SELECT s.id, s.title, s.directory, s.time_idle, s.idle_outcome,
              (SELECT MAX(time_created) FROM session_message m WHERE m.session_id = s.id AND m.type = 'user') AS prompted
            FROM session_v2 s
            WHERE s.parent_id IS NULL AND s.time_archived IS NULL
              AND s.time_updated > \(Int(activeCutoff.timeIntervalSince1970 * 1000))
            """) else { return nil }
        return rows.compactMap { row in
            guard let id = row["id"] else { return nil }
            func date(_ key: String) -> Date? { Double(row[key] ?? "").map { Date(timeIntervalSince1970: $0 / 1000) } }
            let idle = date("time_idle") ?? .distantPast
            let state: AgentState
            if let prompted = date("prompted"), prompted > idle { state = .working(prompted) }
            else if idle < cutoff { return nil }
            else {
                switch row["idle_outcome"] {
                case "succeeded": state = .done(idle)
                case "failed": state = .failed(idle)
                default: return nil // interrupted by you
                }
            }
            let cwd = row["directory"] ?? ""
            let host = cliHost("opencode:\(id)", cwd: cwd) { $1 == "opencode" }
            return AgentThread(id: "opencode:\(id)", app: .other, appName: host.map { "OpenCode in \($0.name)" } ?? "OpenCode",
                               bundleID: host?.bundleID ?? "", title: shortTitle(row["title"] ?? (cwd as NSString).lastPathComponent),
                               state: state, openURL: nil, host: host)
        }
    }

    /// Claude Code hooks (see install.sh --claude) leave each event in `claude-<pid>.hook` (see
    /// `ClaudeHook`), the pid being the Claude Code process that ran the hook. That pid gives the
    /// exact terminal or app. One file per process; a session resumed elsewhere shows the newest.
    private func claude(since cutoff: Date, files: [String]) -> [AgentThread] {
        var newest: [String: (at: Date, thread: AgentThread)] = [:]
        for file in files where file.hasPrefix("claude-") && file.hasSuffix(".hook") {
            let path = "\(inboxDir)/\(file)"
            guard let pid = pid_t(file.dropFirst(7).dropLast(5)),
                  let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  let data = FileManager.default.contents(atPath: path),
                  let event = try? JSONDecoder().decode(ClaudeHookEvent.self, from: data) else { continue }
            let session = event.sessionID
            let state: AgentState
            switch event.name {
            case "UserPromptSubmit", "PostToolUse":
                if event.name == "UserPromptSubmit" || claudeTurns[session] == nil { claudeTurns[session] = modified }
                state = .working(claudeTurns[session] ?? modified)
            case "Notification":
                state = .needsInput(event.notificationType == "elicitation_dialog" ? "Asking you a question" : "Waiting for approval",
                                    since: modified)
            case "PreToolUse": state = .needsInput("Asking you a question", since: modified)
            case "Stop": state = .done(modified)
            case "StopFailure": state = .failed(modified)
            default: // SessionEnd
                try? FileManager.default.removeItem(atPath: path)
                continue
            }
            // Quit, crashed or long finished: nothing left to show.
            if state.isFinished ? modified < cutoff : kill(pid, 0) != 0 {
                try? FileManager.default.removeItem(atPath: path)
                continue
            }
            let cwd = event.cwd ?? ""
            let host = cliHost("claude:\(session)", cwd: cwd, pid: pid)
            if host?.bundleID == AgentApp.t3.bundleID { continue } // T3 drives Claude too and reports it itself
            if !state.isWorking || claudeTitles[session] == nil, let transcript = event.transcriptPath {
                claudeTitles[session] = claudeTitle(transcript) ?? claudeTitles[session]
            }
            let thread = AgentThread(id: "claude:\(session)", app: .other, appName: host.map { "Claude Code in \($0.name)" } ?? "Claude Code",
                                     bundleID: host?.bundleID ?? "", title: shortTitle(claudeTitles[session] ?? (cwd as NSString).lastPathComponent),
                                     state: state, openURL: nil, host: host)
            if newest[session].map({ $0.at < modified }) ?? true { newest[session] = (modified, thread) }
        }
        return newest.values.map(\.thread)
    }

    /// Claude Code keeps rewriting an AI title into the transcript; the last one is current.
    private func claudeTitle(_ transcript: String) -> String? {
        struct Entry: Decodable { let customTitle: String?, aiTitle: String? }
        guard let handle = FileHandle(forReadingAtPath: transcript) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 128_000 ? size - 128_000 : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        for line in text.split(separator: "\n").reversed() where line.contains("\"aiTitle\"") || line.contains("\"customTitle\"") {
            guard let entry = try? JSONDecoder().decode(Entry.self, from: Data(line.utf8)) else { continue }
            if let title = entry.customTitle ?? entry.aiTitle { return title }
        }
        return nil
    }

    /// One JSON file per status, written by the Hermes plugin or any script.
    private struct InboxRecord: Decodable {
        enum Status: String, Decodable { case needsInput = "needs_input", working, done, failed }
        let app: String
        let state: Status
        var title: String?
        var detail: String?
        var threadId: String?
        var openURL: String?
        var bundleId: String?
        var updatedAt: Double?
        var expiresAt: Double?
        /// The Hermes profile the session belongs to; none for the default one.
        var profile: String?
    }

    private func inbox(since cutoff: Date) -> [AgentThread] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: inboxDir)) ?? []
        return claude(since: cutoff, files: files) + files.filter { $0.hasSuffix(".json") }.compactMap { file -> AgentThread? in
            let path = "\(inboxDir)/\(file)"
            guard let data = FileManager.default.contents(atPath: path),
                  let record = try? JSONDecoder().decode(InboxRecord.self, from: data),
                  let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            else {
                debugLog("inbox: skipped unreadable \(file)")
                return nil
            }
            let expires = record.expiresAt.map(Date.init(timeIntervalSince1970:))
            if let expires, expires < Date() {
                try? FileManager.default.removeItem(atPath: path)
                return nil
            }
            let updated = record.updatedAt.map(Date.init(timeIntervalSince1970:)) ?? modified
            let state: AgentState = switch record.state {
            case .needsInput: .needsInput(record.detail ?? "", since: updated)
            case .working: .working(updated)
            case .done: .done(updated)
            case .failed: .failed(updated)
            }
            if state.isFinished, updated < cutoff { return nil }
            let app = AgentApp.allCases.first { $0.rawValue == record.app } ?? .other
            var threadID = record.threadId ?? file
            var title = record.title
            var keyID = threadID
            if app == .hermes {
                let profile = HermesProfile.named(record.profile)
                threadID = hermesRoot(threadID, in: profile)
                keyID = profile.key(threadID)
                title = title ?? sqliteQuery(profile.db, "SELECT title FROM sessions WHERE id = \(sqlQuote(threadID))")?.first?["title"]
            }
            let key = app == .other ? "\(record.app.lowercased()):\(keyID)" : "\(app == .chatgpt ? "codex" : app == .t3 ? "t3" : "hermes"):\(keyID)"
            // Any local script can write here, so a click may open an app's link, never a file.
            let link = record.openURL.flatMap(URL.init(string:)).flatMap { $0.isFileURL ? nil : $0 }
            return AgentThread(id: key, app: app, appName: record.app, bundleID: record.bundleId ?? app.bundleID,
                               title: shortTitle(title ?? record.app), state: state,
                               openURL: link ?? (app == .hermes ? hermesURL(threadID) : nil), expiresAt: expires)
        }
    }

    /// The Hermes app routes `hermes://open/<path>` to that page, and holds it until its window is ready.
    private func hermesURL(_ sessionID: String) -> URL? {
        sessionID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed).flatMap { URL(string: "hermes://open/sessions/\($0)") }
    }

    /// Hermes keys turns by the conversation's lineage root; walk parents to find it.
    private func hermesRoot(_ sessionID: String, in profile: HermesProfile) -> String {
        var current = sessionID
        for _ in 0..<32 {
            guard let parent = sqliteQuery(profile.db, "SELECT parent_session_id AS p FROM sessions WHERE id = \(sqlQuote(current))")?
                .first?["p"], !parent.isEmpty else { break }
            current = parent
        }
        return current
    }
}

/// A Hermes profile: the default one in ~/.hermes, or one under ~/.hermes/profiles/<name>, each
/// with its own state.db.
struct HermesProfile: Hashable {
    /// nil for the default profile.
    let name: String?
    let db: String

    static let `default` = HermesProfile(name: nil, db: AgentReader.hermesDB)

    static func all() -> [HermesProfile] {
        let dir = "\(home)/.hermes/profiles"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        return [.default] + names.sorted().compactMap { name in
            let db = "\(dir)/\(name)/state.db"
            return FileManager.default.fileExists(atPath: db) ? HermesProfile(name: name, db: db) : nil
        }
    }

    /// A profile by the name a plugin reported; unknown or missing names mean the default one.
    static func named(_ name: String?) -> HermesProfile {
        guard let name, name != "default" else { return .default }
        return all().first { $0.name == name } ?? .default
    }

    /// Thread keys stay as they were for the default profile, so clicks remembered before still match.
    func key(_ id: String) -> String { name.map { "\($0)/\(id)" } ?? id }

    var appName: String { name.map { "Hermes · \($0)" } ?? "Hermes" }
}
