import AppKit

/// Reads the agent sources off the main thread. Every piece of mutable state below is only ever
/// touched on `queue` (`read` hops onto it and the rest is private), which is what makes sharing
/// the reader with the main actor safe.
final class AgentReader: @unchecked Sendable {
    static let t3DB = "\(home)/.t3/userdata/statev2.sqlite"
    static let codexDB = "\(home)/.codex/state_5.sqlite"
    static let hermesDB = "\(home)/.hermes/state.db"
    static let opencodeDB = "\(home)/.local/share/opencode/opencode.db"
    static let ironclawDB = "\(home)/.ironclaw/reborn/local-dev/reborn-local-dev.db"

    /// A turn whose session hasn't been written for this long is taken as abandoned (the app or
    /// CLI died mid-turn). Within it, a running turn is shown however long it's been running.
    static let activeWindow: TimeInterval = 6 * 3600

    private let queue = DispatchQueue(label: "nook.agents", qos: .utility)
    private var rolloutCache: [String: (offset: UInt64, state: AgentState?, activity: String?)] = [:]
    private var t3Owned = Set<String>()
    /// Codex and Claude Code sessions IronClaw runs as its backends (their native session ids).
    private var ironclawOwned = Set<String>()
    private var hermesTurns: [HermesProfile: HermesTurns] = [:]
    private var hosts: [String: (pid: pid_t, host: AgentHost?, checked: Date)] = [:]
    private var claudeTurns: [String: Date] = [:]
    private var claudeTitles: [String: String] = [:]
    private var drivenSessions = Set<String>()

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
        case .ironclaw: ironclaw(since: cutoff)
        case .opencode: opencode(since: cutoff)
        case .inbox: inbox(since: cutoff)
        }
    }

    private var activeCutoff: Date { Date().addingTimeInterval(-Self.activeWindow) }

    private func t3(since cutoff: Date) -> [AgentThread]? {
        let sql = """
            SELECT t.thread_id, t.title, r.status, r.requested_at, r.completed_at, p.kind AS pending_kind, p.created_at AS pending_at,
              CASE WHEN r.completed_at IS NULL THEN (
                SELECT COALESCE(json_extract(i.payload_json, '$.toolName'), i.type)
                FROM orchestration_v2_projection_turn_items i
                WHERE i.thread_id = t.thread_id ORDER BY i.ordinal DESC LIMIT 1) END AS step
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
                               title: shortTitle(row["title"] ?? "Untitled thread"), state: state, openURL: nil,
                               activity: activityPhrase(row["step"]))
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
        refreshIronclawOwned()
        guard let rows = sqliteQuery(Self.codexDB, """
            SELECT id, COALESCE(name, title) AS title, rollout_path, cwd, COALESCE(originator, '') AS originator FROM threads
            WHERE archived = 0 AND source NOT LIKE '{%' AND agent_role IS NULL
              AND COALESCE(updated_at_ms, updated_at * 1000) > \(Int(activeCutoff.timeIntervalSince1970 * 1000))
            """) else { return nil }
        return rows.compactMap { row in
            guard let id = row["id"], !t3Owned.contains(id), !ironclawOwned.contains(id),
                  row["originator"] != "ironclaw" || !FileManager.default.fileExists(atPath: Self.ironclawDB),
                  let path = row["rollout_path"], let (state, activity) = rolloutState(path) else { return nil }
            // Finishes count while recent; a running turn counts however long it's been quiet.
            if state.isFinished, state.date < cutoff { return nil }
            let host = codexHost(id, originator: row["originator"] ?? "", cwd: row["cwd"] ?? "")
            let fallbackName = row["originator"] == "codex-tui" ? "Codex CLI" : "ChatGPT"
            return AgentThread(id: "codex:\(id)", app: .chatgpt, appName: host.map { "Codex in \($0.name)" } ?? fallbackName,
                               bundleID: host?.bundleID ?? AgentApp.chatgpt.bundleID,
                               title: shortTitle(row["title"] ?? "Untitled chat"), state: state,
                               openURL: URL(string: "codex://threads/\(id)"), host: host, activity: activity)
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

    /// Latest turn lifecycle state of a Codex rollout, and while it works, its latest step. The
    /// first look scans back from the end in growing chunks until an event turns up (a long turn
    /// can push its start megabytes back); after that only the bytes appended since are read.
    private func rolloutState(_ path: String) -> (AgentState, String?)? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64 else { return nil }
        if let cached = rolloutCache[path], cached.offset == size { return cached.state.map { ($0, cached.activity) } }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        if let cached = rolloutCache[path], cached.offset < size {
            try? handle.seek(toOffset: cached.offset)
            let data = handle.readDataToEndOfFile()
            // Leave a half-written last line for next time.
            let complete = data.lastIndex(of: UInt8(ascii: "\n")).map { data.startIndex.distance(to: $0) + 1 } ?? 0
            let scan = scanRollout(data.prefix(complete))
            let state = scan.event.map(\.state) ?? cached.state
            // A new turn starts blank; within one, the newest step wins.
            let activity = scan.event == nil ? scan.step ?? cached.activity : scan.step
            rolloutCache[path] = (cached.offset + UInt64(complete), state, state?.isWorking == true ? activity : nil)
            return state.map { ($0, activity) }
        }
        var chunk: UInt64 = 256_000
        while true {
            let start = size > chunk ? size - chunk : 0
            try? handle.seek(toOffset: start)
            let data = handle.readData(ofLength: Int(size - start))
            // Skip the partial first line unless reading from the top.
            let body = start == 0 ? data : data.firstIndex(of: UInt8(ascii: "\n")).map { data[$0...] } ?? Data()
            let end = start + UInt64(data.lastIndex(of: UInt8(ascii: "\n")).map { data.startIndex.distance(to: $0) + 1 } ?? 0)
            let scan = scanRollout(body)
            if let event = scan.event {
                let activity = event.state?.isWorking == true ? scan.step : nil
                rolloutCache[path] = (end, event.state, activity)
                return event.state.map { ($0, activity) }
            }
            if start == 0 {
                rolloutCache[path] = (end, nil, nil)
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

    /// The last turn start, completion or abort in the text, if any, and the newest step after it
    /// (an `item_completed` event's item type, e.g. "CommandExecution"), read without decoding the
    /// line, which can hold a whole command output.
    private func scanRollout(_ data: Data) -> (event: LifecycleEvent?, step: String?) {
        let text = String(decoding: data, as: UTF8.self)
        var step: String?
        for line in text.split(separator: "\n").reversed() where line.contains("\"event_msg\"") {
            if step == nil, line.contains("\"item_completed\""), let marker = line.range(of: "\"item\":{\"type\":\"") {
                step = activityPhrase(String(line[marker.upperBound...].prefix { $0 != "\"" }))
                continue
            }
            guard line.contains("task_started") || line.contains("task_complete") || line.contains("turn_aborted"),
                  let event = try? JSONDecoder().decode(RolloutLine.self, from: Data(line.utf8)) else { continue }
            guard let date = parseISO(event.timestamp) else {
                debugLog("codex: unreadable timestamp \(event.timestamp)")
                continue
            }
            switch event.payload.type {
            case "task_started": return (.started(date), step)
            case "task_complete": return (.completed(date), step)
            case "turn_aborted": return (.aborted, step)
            default: continue
            }
        }
        return (nil, step)
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
        // A lease alone isn't a thread: Hermes also takes leases for client-addressed ids that
        // have no session row (its API/relay turns), and those used to surface as a phantom
        // "Hermes chat". Only a chat Hermes itself would list counts: a root, or a branch/reset
        // child (its own chat), never a subagent/compression subchat or an internal worker
        // (kanban/tool/oneshot), titled by Hermes or, until it writes a title, by its opening
        // user message; a session with neither isn't a chat yet.
        guard let leases = sqliteQuery(profile.db, """
            SELECT l.conversation_id AS id, l.acquired_at, s.title AS title,
              (SELECT m.content FROM messages m WHERE m.session_id = s.id AND m.role = 'user'
                AND m.content IS NOT NULL ORDER BY m.timestamp LIMIT 1) AS opener,
              s.cwd AS cwd, s.source AS source,
              (SELECT CASE WHEN m.role = 'assistant' AND m.tool_calls IS NOT NULL AND json_valid(m.tool_calls)
                        THEN json_extract(m.tool_calls, '$[0].function.name')
                      WHEN m.role = 'assistant' THEN 'message' ELSE 'reasoning' END
               FROM messages m WHERE m.session_id = s.id ORDER BY m.id DESC LIMIT 1) AS step
            FROM session_turn_leases l
            JOIN sessions s ON s.id = l.conversation_id
            WHERE l.expires_at > \(now)
              AND (s.parent_session_id IS NULL
                OR json_extract(CASE WHEN json_valid(s.model_config) THEN s.model_config ELSE json_object() END, '$._branched_from') IS NOT NULL
                OR EXISTS (SELECT 1 FROM sessions p WHERE p.id = s.parent_session_id
                  AND p.end_reason = 'branched' AND s.started_at >= p.ended_at)
                OR json_extract(CASE WHEN json_valid(s.model_config) THEN s.model_config ELSE json_object() END, '$._reset_from') IS NOT NULL
                OR EXISTS (SELECT 1 FROM sessions p WHERE p.id = s.parent_session_id
                  AND p.end_reason IN ('session_reset', 'session_switch', 'idle', 'daily', 'suspended', 'resume_pending_expired')
                  AND s.session_key IS NOT NULL AND s.session_key != '' AND s.session_key = p.session_key))
              AND json_extract(CASE WHEN json_valid(s.model_config) THEN s.model_config ELSE json_object() END, '$._delegate_from') IS NULL
              AND COALESCE(s.source, '') NOT IN ('kanban', 'tool', 'oneshot')
            """) else { return nil }
        var active: [String: (title: String, since: Date)] = [:]
        var steps: [String: String] = [:]
        for row in leases {
            guard let id = row["id"], let acquired = Double(row["acquired_at"] ?? ""),
                  let rawTitle = [row["title"], row["opener"]].compactMap({ $0 }).first(where: {
                      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  }) else { continue }
            turns.places[id] = (row["cwd"] ?? "", row["source"] ?? "")
            active[id] = (shortTitle(rawTitle), Date(timeIntervalSince1970: acquired))
            steps[id] = activityPhrase(row["step"])
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
                               openURL: hermesURL(id), host: host, activity: state.isWorking ? steps[id] : nil)
        }
        return active.map { thread($0.key, $0.value.title, .working($0.value.since)) }
            + finished.map { thread($0.key, $0.value.title, $0.value.state) }
    }

    /// How a turn ended, from its own last message only: this conversation plus its compression
    /// continuations (the same chat, continued), never its subchats — a subagent's last tool
    /// result must not fail the chat that spawned it. Mirrors Hermes' own session status: an
    /// error finish is a failure, a trailing user/tool row or pending tool call is a turn
    /// stopped mid-way, and anything else (a final answer with or without a `stop` marker, no
    /// messages at all) simply ended.
    private func hermesEndedCleanly(_ conversation: String, in profile: HermesProfile) -> Bool {
        let id = sqlQuote(conversation)
        guard let last = sqliteQuery(profile.db, """
            WITH RECURSIVE lineage(id) AS (
              SELECT id FROM sessions WHERE id = \(id)
              UNION
              SELECT c.id FROM sessions c
              JOIN lineage l ON c.parent_session_id = l.id
              JOIN sessions p ON p.id = l.id
              WHERE p.end_reason = 'compression' AND COALESCE(c.source, '') != 'tool'
                AND COALESCE(json_extract(CASE WHEN json_valid(c.model_config) THEN c.model_config ELSE json_object() END, '$._delegate_from'), '') != c.parent_session_id
                AND COALESCE(json_extract(CASE WHEN json_valid(c.model_config) THEN c.model_config ELSE json_object() END, '$._branched_from'), '') != c.parent_session_id
                AND COALESCE(json_extract(CASE WHEN json_valid(c.model_config) THEN c.model_config ELSE json_object() END, '$._reset_from'), '') != c.parent_session_id
            )
            SELECT role, finish_reason, tool_calls FROM messages
            WHERE session_id IN (SELECT id FROM lineage)
            ORDER BY id DESC LIMIT 1
            """)?.first else { return true }
        if ["error", "agent_error", "content_filter"].contains(last["finish_reason"]?.lowercased() ?? "") { return false }
        if last["role"] == "user" || last["role"] == "tool" { return false }
        if last["role"] == "assistant", last["tool_calls"] != nil { return false }
        return true
    }

    /// IronClaw's orchestrator keeps each thread's turn state in one row: `running` while a turn
    /// is live, back to idle (or `error`) with an end time when it stops; the run's own outcome is
    /// the last `orch_turns` row. It needs you while a thread is in `orch_awaiting` or a CLI
    /// approval is undecided (what IronClaw itself counts as attention). Subagent task threads
    /// belong to their parent. Untitled threads take their opening message, as IronClaw shows them.
    private func ironclaw(since cutoff: Date) -> [AgentThread]? {
        let ms = { (date: Date) in Int(date.timeIntervalSince1970 * 1000) }
        guard let rows = sqliteQuery(Self.ironclawDB, """
            SELECT t.thread_id AS id, t.profile_id AS profile, t.turn_state, t.turn_started_at, t.turn_ended_at,
              t.last_error, t.updated_at,
              COALESCE(NULLIF(TRIM(t.title), ''), (
                SELECT json_extract(CAST(e.contents AS TEXT), '$.content') FROM root_filesystem_entries e
                WHERE e.path LIKE '%/threads/' || t.thread_id || '/messages/%'
                  AND json_extract(e.indexed, '$.lookup_first_user') = 1 LIMIT 1)) AS title,
              a.kind AS awaiting, a.since AS awaiting_since,
              (SELECT MIN(c.requested_at) FROM orch_cli_approvals c
               WHERE c.thread_id = t.thread_id AND c.decision IS NULL) AS approval_since,
              (SELECT r.status FROM orch_turns r WHERE r.thread_id = t.thread_id ORDER BY r.ended_at DESC LIMIT 1) AS outcome,
              (SELECT w.detail FROM orch_live_work w WHERE w.thread_id = t.thread_id) AS live
            FROM orch_threads t LEFT JOIN orch_awaiting a ON a.thread_id = t.thread_id
            WHERE NOT EXISTS (SELECT 1 FROM orch_tasks k WHERE k.child_thread = t.thread_id)
              AND (a.thread_id IS NOT NULL
                OR EXISTS (SELECT 1 FROM orch_cli_approvals c WHERE c.thread_id = t.thread_id AND c.decision IS NULL)
                OR (t.turn_state = 'running' AND t.updated_at > \(ms(activeCutoff)))
                OR t.turn_ended_at > \(ms(cutoff)))
            """) else { return nil }
        // IronClaw stores milliseconds; anything that small is seconds.
        func date(_ value: String?) -> Date? {
            guard let number = Double(value ?? "") else { return nil }
            return Date(timeIntervalSince1970: number > 1e11 ? number / 1000 : number)
        }
        return rows.compactMap { row in
            guard let id = row["id"] else { return nil }
            let state: AgentState
            if let since = date(row["approval_since"]) {
                state = .needsInput("Waiting for approval", since: since)
            } else if let kind = row["awaiting"] {
                let since = date(row["awaiting_since"]) ?? date(row["updated_at"]) ?? Date()
                state = .needsInput(kind.contains("approv") ? "Waiting for approval" : "Needs your input", since: since)
            } else if row["turn_state"] == "running" {
                state = .working(date(row["turn_started_at"]) ?? date(row["updated_at"]) ?? Date())
            } else {
                guard let ended = date(row["turn_ended_at"]), ended > cutoff else { return nil }
                switch row["outcome"] {
                case "cancelled", "interrupted": return nil // stopped by you
                case "failed", "error": state = .failed(ended)
                default: state = row["turn_state"] == "error" || !(row["last_error"] ?? "").isEmpty ? .failed(ended) : .done(ended)
                }
            }
            let profile = row["profile"].flatMap { $0.isEmpty ? nil : $0 }
            return AgentThread(id: "ironclaw:\(id)", app: .ironclaw, appName: profile.map { "IronClaw · \($0)" } ?? "IronClaw",
                               bundleID: AgentApp.ironclaw.bundleID, title: shortTitle(row["title"] ?? "New thread"),
                               state: state, openURL: nil, activity: state.isWorking ? activityPhrase(row["live"]) : nil)
        }
    }

    /// Native ids of the Codex and Claude Code sessions IronClaw drives, so they're listed once,
    /// under IronClaw. When its database is busy the last known set stands.
    private func refreshIronclawOwned() {
        guard let rows = sqliteQuery(Self.ironclawDB, """
            SELECT native_session_id AS id FROM orch_thread_segments WHERE native_session_id IS NOT NULL
            UNION SELECT native_session_id FROM orch_threads WHERE native_session_id IS NOT NULL
            """) else { return }
        ironclawOwned = Set(rows.compactMap { $0["id"] })
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
        refreshIronclawOwned()
        var newest: [String: (at: Date, thread: AgentThread)] = [:]
        for file in files where file.hasPrefix("claude-") && file.hasSuffix(".hook") {
            let path = "\(inboxDir)/\(file)"
            guard let pid = pid_t(file.dropFirst(7).dropLast(5)),
                  let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  let data = FileManager.default.contents(atPath: path),
                  let event = try? JSONDecoder().decode(ClaudeHookEvent.self, from: data) else { continue }
            let session = event.sessionID
            // Hermes, IronClaw or T3 driving Claude Code as their model: listed under that app.
            if event.driver != nil || ironclawOwned.contains(session) || drivenSession(session, pid: pid) { continue }
            let state: AgentState
            var activity: String?
            switch event.name {
            case "UserPromptSubmit", "PostToolUse":
                if event.name == "UserPromptSubmit" || claudeTurns[session] == nil { claudeTurns[session] = modified }
                state = .working(claudeTurns[session] ?? modified)
                activity = event.name == "UserPromptSubmit" ? "Thinking" : activityPhrase(event.toolName)
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
                                     state: state, openURL: nil, host: host, activity: activity)
            if newest[session].map({ $0.at < modified }) ?? true { newest[session] = (modified, thread) }
        }
        return newest.values.map(\.thread)
    }

    /// Whether a Claude Code session is run by an app Nook already lists (see `drivingApp`), for
    /// records written before hooks noted it themselves. Once driven, always driven: after the
    /// process exits its parents are gone.
    private func drivenSession(_ session: String, pid: pid_t) -> Bool {
        if drivenSessions.contains(session) { return true }
        guard kill(pid, 0) == 0, drivingApp(of: pid) != nil else { return false }
        drivenSessions.insert(session)
        return true
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
                threadID = hermesConversation(threadID, in: profile)
                keyID = profile.key(threadID)
                title = title ?? sqliteQuery(profile.db, "SELECT title FROM sessions WHERE id = \(sqlQuote(threadID))")?.first?["title"]
            }
            let prefix = switch app {
            case .chatgpt: "codex"
            case .t3: "t3"
            case .hermes: "hermes"
            case .ironclaw: "ironclaw"
            case .other: record.app.lowercased()
            }
            let key = "\(prefix):\(keyID)"
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

    /// The chat a Hermes session belongs to. Subchats (subagent runs, compression continuations)
    /// belong to their parent chat, so a question from one is reported under that chat, not as a
    /// chat of its own; a branch/reset child is a chat of its own and stays itself. A gateway
    /// `session_key` resolves to its session first. Unknown ids stay as reported.
    private func hermesConversation(_ sessionID: String, in profile: HermesProfile) -> String {
        let id = sqlQuote(sessionID)
        let config = "CASE WHEN json_valid(s.model_config) THEN s.model_config ELSE json_object() END"
        guard let top = sqliteQuery(profile.db, """
            WITH RECURSIVE up(id, parent, branched, reset, started, skey, p_end, p_ended, p_skey, depth) AS (
              SELECT s.id, s.parent_session_id,
                json_extract(\(config), '$._branched_from'), json_extract(\(config), '$._reset_from'),
                s.started_at, s.session_key, p.end_reason, p.ended_at, p.session_key, 0
              FROM sessions s LEFT JOIN sessions p ON p.id = s.parent_session_id
              WHERE s.id = (SELECT id FROM sessions WHERE id = \(id) OR session_key = \(id)
                ORDER BY (id = \(id)) DESC LIMIT 1)
              UNION ALL
              SELECT s.id, s.parent_session_id,
                json_extract(\(config), '$._branched_from'), json_extract(\(config), '$._reset_from'),
                s.started_at, s.session_key, p.end_reason, p.ended_at, p.session_key, u.depth + 1
              FROM sessions s JOIN up u ON s.id = u.parent
              LEFT JOIN sessions p ON p.id = s.parent_session_id
              WHERE u.depth < 32 AND u.parent IS NOT NULL AND u.branched IS NULL AND u.reset IS NULL
                AND NOT (u.p_end = 'branched' AND u.started >= u.p_ended)
                AND NOT (u.p_end IN ('session_reset', 'session_switch', 'idle', 'daily', 'suspended', 'resume_pending_expired')
                  AND u.skey IS NOT NULL AND u.skey != '' AND u.skey = u.p_skey)
            )
            SELECT id FROM up ORDER BY depth DESC LIMIT 1
            """)?.first?["id"] else { return sessionID }
        return top
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
