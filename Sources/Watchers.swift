import CoreServices
import Foundation

/// Watches a SQLite database and its -wal with kqueue, re-attaching when files are replaced. If the
/// app isn't set up yet (no folder), the nearest existing parent is watched until the folder appears.
/// Its state is only touched on `queue` (checked in `attachMissing`), so it can be handed across threads.
final class DatabaseWatcher: @unchecked Sendable {
    private let paths: [String]
    private let directory: String
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "nook.dbwatch", qos: .utility)
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var directorySource: DispatchSourceFileSystemObject?

    init(path: String, onChange: @escaping @Sendable () -> Void) {
        paths = [path, path + "-wal"]
        directory = (path as NSString).deletingLastPathComponent
        self.onChange = onChange
        queue.async { [self] in watchDirectory(initial: true) }
    }

    /// The directory changes only when files are created/removed (e.g. a new -wal). When it's
    /// missing, or it goes away, its nearest existing parent stands in until it's back.
    private func watchDirectory(initial: Bool = false) {
        directorySource?.cancel()
        let target = nearestExisting()
        let found = target == directory
        directorySource = watch(target, events: [.write, .delete, .rename]) { [weak self] in
            guard let self else { return }
            let gone = !(self.directorySource?.data.isDisjoint(with: [.delete, .rename]) ?? true)
            if !found || gone { self.watchDirectory() }
            if found {
                self.attachMissing()
                self.onChange()
            }
        }
        if found {
            attachMissing()
            if !initial { onChange() } // appeared after launch: read it now
        } else if nearestExisting() != target {
            watchDirectory(initial: initial) // a level was created before the watch was in place
        }
    }

    private func nearestExisting() -> String {
        var path = directory
        while !FileManager.default.fileExists(atPath: path), path != "/" {
            path = (path as NSString).deletingLastPathComponent
        }
        return path
    }

    private func attachMissing() {
        dispatchPrecondition(condition: .onQueue(queue))
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
