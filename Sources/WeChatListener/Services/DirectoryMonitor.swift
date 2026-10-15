import CoreServices
import Foundation

/// Recursively observes the selected account's media folders. Notification collection has its own lifecycle.
final class DirectoryMonitor {
    private var stream: FSEventStreamRef?
    private let changed: () -> Void
    private let root: URL
    init(fileRoot: URL, changed: @escaping () -> Void) throws {
        self.changed = changed
        root = fileRoot.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, rawPaths, _, _ in
            guard let info else { return }
            let observer = Unmanaged<DirectoryMonitor>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self) as? [String] ?? []
            if paths.contains(where: { observer.isMediaPath($0) }) { observer.changed() }
        }
        guard
            let value = FSEventStreamCreate(
                kCFAllocatorDefault, callback, &context, [root.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
                FSEventStreamCreateFlags(
                    kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                        | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer))
        else {
            throw ListenerError("目录监听暂不可用，将定时自动补扫。")
        }
        stream = value
        FSEventStreamSetDispatchQueue(value, DispatchQueue.main)
        guard FSEventStreamStart(value) else {
            stop()
            throw ListenerError("目录监听暂不可用，将定时自动补扫。")
        }
    }
    func isMediaPath(_ path: String) -> Bool {
        // FSEvents supplies paths under the already-canonical watch root. Filtering must not do disk I/O on main.
        Self.isMediaPath(path, root: root.path)
    }
    static func isMediaPath(_ path: String, root: String) -> Bool {
        path == root || [root + "/file", root + "/attach"].contains { path == $0 || path.hasPrefix($0 + "/") }
    }
    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }
    deinit { stop() }
}
