import Foundation

/// What Nook keeps of a Claude Code hook event: enough to show the session and find where it
/// runs. Tool input and output, prompts and messages are never stored.
struct ClaudeHookEvent: Codable {
    let sessionID: String
    let name: String
    var notificationType: String?
    var cwd: String?
    var transcriptPath: String?

    // Claude Code's own field names, so a record is a strict subset of the event.
    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id", name = "hook_event_name", notificationType = "notification_type"
        case cwd, transcriptPath = "transcript_path"
    }
}

/// `Nook --claude-hook <pid>` is the command the hooks from `install.sh --claude` run. It reads the
/// event Claude Code pipes in and writes the fields above to inbox/claude-<pid>.hook, owner-only and
/// atomically. It always exits 0 and prints nothing, so it can never hold up or change Claude Code.
enum ClaudeHook {
    /// Larger events (a tool returning a huge output) are skipped rather than buffered.
    private static let maxEventSize = 16 << 20

    static func run(pid argument: String) -> Never {
        record(pid: argument)
        exit(0)
    }

    private static func record(pid argument: String) {
        guard let pid = Int32(argument), pid > 1, FileManager.default.fileExists(atPath: inboxDir) else { return }
        var input = Data()
        while let chunk = try? FileHandle.standardInput.read(upToCount: 1 << 16), !chunk.isEmpty {
            input.append(chunk)
            guard input.count <= maxEventSize else { return }
        }
        guard let event = try? JSONDecoder().decode(ClaudeHookEvent.self, from: input),
              let record = try? JSONEncoder().encode(event) else { return }
        let target = "\(inboxDir)/claude-\(pid).hook"
        let temporary = "\(inboxDir)/.claude-\(pid)-\(UUID().uuidString)"
        guard FileManager.default.createFile(atPath: temporary, contents: record, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temporary, target) != 0 { unlink(temporary) }
    }
}
