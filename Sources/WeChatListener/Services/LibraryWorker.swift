import Foundation

final class LibraryWorker {
    private let queue = DispatchQueue(label: "local.wechat-listener.library", qos: .utility)
    private let paths: AppPaths
    private let readOnly: Bool
    private var archive: Archive?
    init(paths: AppPaths, readOnly: Bool = false) {
        self.paths = paths
        self.readOnly = readOnly
    }
    func perform<T>(_ action: @escaping (Archive) throws -> T, completion: @escaping (Result<T, Error>) -> Void) {
        queue.async {
            do {
                let archive: Archive
                if let cached = self.archive {
                    archive = cached
                } else {
                    archive = try Archive(paths: self.paths, readOnly: self.readOnly)
                    self.archive = archive
                }
                let value = try action(archive)
                DispatchQueue.main.async { completion(.success(value)) }
            } catch { DispatchQueue.main.async { completion(.failure(error)) } }
        }
    }
}
