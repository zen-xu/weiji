import Foundation
import Network

final class MCPHTTPServer {
    static let defaultPort: UInt16 = 18765
    enum State {
        case starting
        case listening(UInt16)
        case stopped
        case failed(String)
    }

    private let queue = DispatchQueue(label: "local.xzy.WeChatListener.mcp-http", qos: .utility)
    private let queries: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "local.xzy.WeChatListener.mcp-queries"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 4
        return queue
    }()
    private let respond: (MCPHTTPRequest, UInt16) -> MCPHTTPResponse
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var stateChanged: ((State) -> Void)?

    init(paths: AppPaths, responder: ((MCPHTTPRequest, UInt16) -> MCPHTTPResponse)? = nil) {
        respond = responder ?? { MCPHTTPHandler(paths: paths, port: $1).response(to: $0) }
    }

    /// All listener and connection state is confined to the transport queue.
    func start(port: UInt16, stateChanged: @escaping (State) -> Void) {
        queue.async { [self] in
            stopOnQueue()
            self.stateChanged = stateChanged
            stateChanged(.starting)
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
                let listener = try NWListener(using: parameters)
                self.listener = listener
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        if let port = listener.port?.rawValue { self.stateChanged?(.listening(port)) }
                    case .failed(let error):
                        let callback = self.stateChanged
                        self.stopOnQueue()
                        callback?(.failed(error.localizedDescription))
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self, weak listener] connection in
                    guard let self, let listener, self.listener === listener else {
                        connection.cancel()
                        return
                    }
                    self.accept(connection, port: listener.port?.rawValue ?? port)
                }
                listener.start(queue: queue)
            } catch {
                stopOnQueue()
                stateChanged(.failed(error.localizedDescription))
            }
        }
    }

    func stop() {
        queue.async { [self] in
            let callback = stateChanged
            stopOnQueue()
            callback?(.stopped)
        }
    }

    private func stopOnQueue() {
        queries.cancelAllOperations()
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        stateChanged = nil
    }

    private func accept(_ connection: NWConnection, port: UInt16) {
        guard connections.count < 32 else {
            connection.cancel()
            return
        }
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.connections.removeValue(forKey: id)
            default: break
            }
        }
        connection.start(queue: queue)
        // Bound idle/partial requests; no unbounded client-held buffers or connections.
        queue.asyncAfter(deadline: .now() + 15) { [weak self, weak connection] in
            guard let self, let connection, self.connections[id] != nil else { return }
            connection.cancel()
            self.connections.removeValue(forKey: id)
        }
        receive(connection, id: id, bytes: Data(), port: port)
    }

    private func receive(_ connection: NWConnection, id: UUID, bytes: Data, port: UInt16) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, self.connections[id] != nil else { return }
            var buffer = bytes
            if let data { buffer.append(data) }
            do {
                guard buffer.count <= MCPHTTPRequest.maximumHeaderSize + MCPHTTPRequest.maximumBodySize else {
                    throw MCPHTTPError(status: 413)
                }
                if let request = try MCPHTTPRequest.parse(buffer) {
                    self.execute(request, connection: connection, id: id, port: port)
                } else if complete || error != nil {
                    self.finish(connection, id: id, response: MCPHTTPResponse(status: 400))
                } else {
                    self.receive(connection, id: id, bytes: buffer, port: port)
                }
            } catch {
                self.finish(
                    connection, id: id, response: MCPHTTPResponse(status: (error as? MCPHTTPError)?.status ?? 400))
            }
        }
    }

    private func execute(_ request: MCPHTTPRequest, connection: NWConnection, id: UUID, port: UInt16) {
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation, weak connection] in
            guard let self, let operation, !operation.isCancelled, let connection,
                self.queue.sync(execute: { self.connections[id] != nil })
            else { return }
            let response = autoreleasepool { self.respond(request, port) }
            self.queue.async {
                // Stopped listeners and timed-out clients must never receive a late result.
                guard !operation.isCancelled, self.connections[id] != nil else { return }
                self.finish(connection, id: id, response: response)
            }
        }
        queries.addOperation(operation)
    }

    private func finish(_ connection: NWConnection, id: UUID, response: MCPHTTPResponse) {
        connection.send(
            content: response.data,
            completion: .contentProcessed { [weak self] _ in
                self?.connections.removeValue(forKey: id)
                connection.cancel()
            })
    }
}
