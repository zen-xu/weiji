import Foundation

/// Yield the writer between small decode batches so notification capture can run in between.
@MainActor
final class PreviewPreparation {
    private struct Request {
        let token: BackgroundWorkToken
        let onBatch: () -> Void
        let onFailure: (Error) -> Void
    }
    private let worker: LibraryWorker
    private let prepare: (Archive, Int, BackgroundWorkToken) throws -> [String: Int]
    private(set) var isRunning = false
    private var pending: Request?

    init(worker: LibraryWorker, prepare: ((Archive, Int, BackgroundWorkToken) throws -> [String: Int])? = nil) {
        self.worker = worker
        self.prepare =
            prepare ?? { archive, limit, token in
                try archive.prepareImagePreviews(limit: limit, shouldContinue: { !token.isCancelled })
            }
    }

    func prepareRecent(token: BackgroundWorkToken, onBatch: @escaping () -> Void, onFailure: @escaping (Error) -> Void)
    {
        let request = Request(token: token, onBatch: onBatch, onFailure: onFailure)
        guard !token.isCancelled else { return }
        guard !isRunning else {
            pending = request
            return
        }
        isRunning = true
        run(request, remaining: 100)
    }

    private func run(_ request: Request, remaining: Int) {
        let limit = min(5, remaining)
        let prepare = self.prepare
        worker.perform { archive in
            guard !request.token.isCancelled else { return [String: Int]() }
            return try prepare(archive, limit, request.token)
        } completion: { [self] result in
            guard !request.token.isCancelled else {
                finish()
                return
            }
            switch result {
            case .success(let stats):
                let attempted = stats["attempted"] ?? 0
                if attempted > 0 { request.onBatch() }
                if attempted == limit && remaining > attempted {
                    run(request, remaining: remaining - attempted)
                } else {
                    finish()
                }
            case .failure(let error):
                request.onFailure(error)
                finish()
            }
        }
    }

    private func finish() {
        isRunning = false
        if let next = pending {
            pending = nil
            prepareRecent(token: next.token, onBatch: next.onBatch, onFailure: next.onFailure)
        }
    }
}
