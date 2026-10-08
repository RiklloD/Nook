import AppKit
import SQLite3

// MARK: - Processes

extension AgentHost {
    /// Apps Nook reads directly, which open their own threads better than any window guess.
    var isNativeApp: Bool { [AgentApp.t3, .chatgpt, .hermes].contains { $0.bundleID == bundleID } }
}

/// Running processes `isAgent` accepts (given pid and executable name), minus helpers spawned by
/// another process of the same name (Codex's app-server daemon).
func agentProcesses(_ isAgent: (pid_t, String) -> Bool) -> [(pid: pid_t, started: UInt64)] {
    var pids = [pid_t](repeating: 0, count: Int(proc_listallpids(nil, 0)) + 64)
    let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
    return pids.prefix(max(count, 0)).compactMap { pid in
        let name = processName(pid)
        guard !name.isEmpty, isAgent(pid, name), let info = bsdInfo(pid), processName(pid_t(info.pbi_ppid)) != name else { return nil }
        return (pid, info.pbi_start_tvsec)
    }
}

/// argv of a process (environment excluded).
func processArguments(_ pid: pid_t) -> [String] {
    var mib = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
    let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
    // argc, the executable path, padding NULs, then argc strings.
    return buffer[4..<size].split(separator: 0, omittingEmptySubsequences: true).dropFirst()
        .prefix(Int(argc)).map { String(decoding: $0, as: UTF8.self) }
}

func processName(_ pid: pid_t) -> String {
    var name = [CChar](repeating: 0, count: 256)
    return proc_name(pid, &name, UInt32(name.count)) > 0 ? String(nulTerminated: name) : ""
}

func bsdInfo(_ pid: pid_t) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
}

func currentDirectory(_ pid: pid_t) -> String? {
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
    return withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
}

/// Walks up from a process to the app bundle it runs under (the outermost .app in the path, so
/// "Code Helper" counts as VS Code), keeping the first terminal seen on the way.
func hostApp(of pid: pid_t) -> AgentHost? {
    var current = pid
    var tty: String?
    for _ in 0..<32 {
        guard current > 1, let info = bsdInfo(current) else { return nil }
        if tty == nil, info.e_tdev != UInt32.max, let name = devname(dev_t(bitPattern: info.e_tdev), S_IFCHR) {
            tty = "/dev/" + String(cString: name)
        }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(current, &path, UInt32(path.count)) > 0 {
            let executable = String(nulTerminated: path)
            if let range = executable.range(of: ".app/") {
                let bundlePath = String(executable[..<range.lowerBound]) + ".app"
                if let id = Bundle(path: bundlePath)?.bundleIdentifier {
                    return AgentHost(bundleID: id, name: FileManager.default.displayName(atPath: bundlePath), tty: tty)
                }
            }
        }
        current = pid_t(info.pbi_ppid)
    }
    return nil
}

func installedApp(named name: String) -> (bundleID: String, name: String)? {
    guard !name.isEmpty else { return nil }
    for dir in ["/Applications", "\(home)/Applications"] {
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        if let app = apps.first(where: { $0.lowercased() == name.lowercased() + ".app" }),
           let id = Bundle(path: "\(dir)/\(app)")?.bundleIdentifier {
            return (id, FileManager.default.displayName(atPath: "\(dir)/\(app)"))
        }
    }
    return nil
}

extension String {
    /// A C string from a fixed-size buffer the kernel filled in.
    init(nulTerminated buffer: [CChar]) {
        self.init(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

// MARK: - SQLite

/// Rows as text, read-only. `[]` when the database doesn't exist (the app isn't installed); nil
/// when it's there but couldn't be read (busy, locked, mid-migration, a query the schema no longer
/// fits), so callers can keep what they had instead of taking the failure for "nothing running".
func sqliteQuery(_ path: String, _ sql: String) -> [[String: String]]? {
    guard FileManager.default.fileExists(atPath: path) else { return [] }
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        sqlite3_close(db)
        return nil
    }
    defer { sqlite3_close(db) }
    sqlite3_busy_timeout(db, 500)
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
        debugLog("sqlite \((path as NSString).lastPathComponent): \(String(cString: sqlite3_errmsg(db)))")
        return nil
    }
    defer { sqlite3_finalize(statement) }
    var rows: [[String: String]] = []
    var status = sqlite3_step(statement)
    while status == SQLITE_ROW {
        var row: [String: String] = [:]
        for index in 0..<sqlite3_column_count(statement) {
            guard let text = sqlite3_column_text(statement, index) else { continue }
            row[String(cString: sqlite3_column_name(statement, index))] = String(cString: text)
        }
        rows.append(row)
        status = sqlite3_step(statement)
    }
    return status == SQLITE_DONE ? rows : nil
}

func sqlQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "''") + "'" }

// MARK: - Text and dates

let debugEnabled = ProcessInfo.processInfo.environment["NOOK_DEBUG"] != nil

func debugLog(_ message: @autoclosure () -> String) {
    guard debugEnabled else { return }
    FileHandle.standardError.write(Data("[\(Date().formatted(.dateTime.hour().minute().second()))] \(message())\n".utf8))
}

/// "2026-10-06T21:17:46.123Z", the form T3 stores and compares as text.
let isoFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

func parseISO(_ value: String?) -> Date? {
    guard let value else { return nil }
    return (try? isoFractional.parse(value)) ?? (try? Date.ISO8601FormatStyle().parse(value))
}

func shortTitle(_ raw: String) -> String {
    let line = raw.split(whereSeparator: \.isNewline).first.map(String.init) ?? raw
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.count > 80 ? String(trimmed.prefix(79)) + "…" : trimmed
}
