import Foundation

final class LibraryWorker {
    enum Query: Hashable { case messages, files, gallery }
    private let queue: DispatchQueue
    private let paths: AppPaths
    private let readOnly: Bool
    private var archive: Archive?
    private let lock = NSLock()
    private var latest: [Query: UUID] = [:]
    init(paths: AppPaths, readOnly: Bool = false) {
        self.paths = paths
        self.readOnly = readOnly
        queue = DispatchQueue(label: "local.wechat-listener.library", qos: readOnly ? .userInitiated : .utility)
    }
    func perform<T>(_ action: @escaping (Archive) throws -> T, completion: @escaping (Result<T, Error>) -> Void) {
        enqueue(action, isCurrent: { true }, completion: completion)
    }
    func invalidate(_ query: Query) {
        lock.lock()
        latest[query] = UUID()
        lock.unlock()
    }
    func performLatest<T>(
        _ query: Query, _ action: @escaping (Archive) throws -> T,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        precondition(readOnly, "Only replaceable read queries may be coalesced")
        let id = UUID()
        lock.lock()
        latest[query] = id
        lock.unlock()
        enqueue(
            action,
            isCurrent: { [self] in
                lock.lock()
                defer { lock.unlock() }
                return latest[query] == id
            }, completion: completion)
    }
    private func enqueue<T>(
        _ action: @escaping (Archive) throws -> T, isCurrent: @escaping () -> Bool,
        completion: @escaping (Result<T, Error>) -> Void
    ) {
        queue.async {
            guard isCurrent() else { return }
            do {
                let archive: Archive
                if let cached = self.archive {
                    archive = cached
                } else {
                    archive = try Archive(paths: self.paths, readOnly: self.readOnly)
                    self.archive = archive
                }
                let value = try autoreleasepool { try action(archive) }
                DispatchQueue.main.async { if isCurrent() { completion(.success(value)) } }
            } catch { DispatchQueue.main.async { if isCurrent() { completion(.failure(error)) } } }
        }
    }
}
