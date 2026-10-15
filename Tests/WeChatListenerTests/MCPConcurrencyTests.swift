import Foundation
import Testing

@testable import WeChatListener

private final class QueryGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0
    var started: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    func enter() {
        lock.lock()
        count += 1
        lock.unlock()
        _ = release.wait(timeout: .now() + 5)
    }
}

@Test("A slow MCP query does not block other connections or listener restart")
func mcpHTTPConcurrentLifecycle() async throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(override: root.appendingPathComponent("absent").path)
    let gate = QueryGate()
    let server = MCPHTTPServer(paths: paths) { request, port in
        if request.path == "/slow" {
            gate.enter()
            return .json(["slow_query": true])
        }
        return MCPHTTPHandler(paths: paths, port: port).response(to: request)
    }
    defer {
        gate.release.signal()
        server.stop()
    }
    func start(_ port: UInt16) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            var completed = false
            server.start(port: port) { state in
                guard !completed else { return }
                switch state {
                case .listening(let value):
                    completed = true
                    continuation.resume(returning: value)
                case .failed(let reason):
                    completed = true
                    continuation.resume(throwing: ListenerError(reason))
                default: break
                }
            }
        }
    }
    let port = try await start(0)
    func send(_ path: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 2
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":9,"method":"ping"}"#.utf8)
        let (bytes, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        return bytes
    }
    let slow = Task { try await send("/slow") }
    for _ in 0..<200 {
        if gate.started > 0 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(gate.started == 1)
    let ping = try await send("/mcp")
    #expect((try JSONSerialization.jsonObject(with: ping) as? [String: Any])?["id"] as? Int == 9)
    let restarted = try await start(port)
    #expect(restarted == port)
    _ = try await send("/mcp")
    gate.release.signal()
    // The earlier connection was cancelled, even though its query completed after restart.
    switch await slow.result {
    case .success: Issue.record("Stopped listener delivered a late result")
    case .failure: break
    }
    let pending = (0..<7).map { _ in Task { try await send("/slow") } }
    defer { for _ in pending { gate.release.signal() } }
    for _ in 0..<200 {
        if gate.started >= 5 { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(gate.started == 5)  // One completed request plus four active workers.
    try await Task.sleep(for: .milliseconds(30))
    #expect(gate.started == 5)
    for _ in pending { gate.release.signal() }
    for task in pending { _ = try await task.value }
    #expect(!FileManager.default.fileExists(atPath: paths.root.path))
}
