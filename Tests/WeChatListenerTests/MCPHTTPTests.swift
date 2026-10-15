import Foundation
import Testing

@testable import WeChatListener

@Test("HTTP framing bounds and ambiguous requests")
func mcpHTTPFraming() throws {
    let body = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
    let header = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:18765\r\nContent-Length: \(body.count)\r\n\r\n"
    let wire = Data(header.utf8) + body
    for count in 0..<wire.count { #expect(try MCPHTTPRequest.parse(Data(wire.prefix(count))) == nil) }
    let request = try #require(try MCPHTTPRequest.parse(wire))
    #expect(request.method == "POST" && request.path == "/mcp" && request.body == body)
    for raw in [
        "POST /mcp HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx",
        "POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
        "POST /mcp HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
        "POST /mcp HTTP/1.1\r\nContent-Length: 999999999999999999999\r\n\r\n",
        "POST /mcp HTTP/1.1\r\nContent-Length: 0\r\n\r\nx",
        "POST /mcp HTTP/1.1\r\nHost : localhost\r\nContent-Length: 0\r\n\r\n",
    ] {
        #expect(throws: MCPHTTPError.self) { try MCPHTTPRequest.parse(Data(raw.utf8)) }
    }
    #expect(throws: MCPHTTPError.self) {
        try MCPHTTPRequest.parse(Data(repeating: 65, count: MCPHTTPRequest.maximumHeaderSize + 1))
    }
    #expect(throws: MCPHTTPError.self) {
        try MCPHTTPRequest.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: 1048577\r\n\r\n".utf8))
    }
}

@Test("HTTP MCP negotiation, read-only queries and browser isolation")
func mcpHTTPProtocol() throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(override: root.appendingPathComponent("absent").path)
    let handler = MCPHTTPHandler(paths: paths, port: 18765)
    let headers = [
        "host": "127.0.0.1:18765", "content-type": "application/json; charset=utf-8",
        "accept": "application/json, text/event-stream", "mcp-protocol-version": "2025-06-18",
    ]
    func request(_ message: [String: Any], headers: [String: String]) throws -> MCPHTTPResponse {
        handler.response(
            to: MCPHTTPRequest(
                method: "POST", path: "/mcp", headers: headers,
                body: try JSONSerialization.data(withJSONObject: message)))
    }
    let initialize = try request(
        [
            "jsonrpc": "2.0", "id": "hello", "method": "initialize",
            "params": ["protocolVersion": "2025-11-25"],
        ], headers: headers)
    let hello = try #require(try JSONSerialization.jsonObject(with: initialize.body) as? [String: Any])
    #expect(initialize.status == 200 && hello["id"] as? String == "hello")
    #expect((hello["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18")
    #expect(initialize.headers["Mcp-Session-Id"] == nil)
    let notification = try request(["jsonrpc": "2.0", "method": "notifications/initialized"], headers: headers)
    #expect(notification.status == 202 && notification.body.isEmpty)
    let status = try request(
        [
            "jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "wechat_status", "arguments": [:]],
        ], headers: headers)
    let json = try #require(try JSONSerialization.jsonObject(with: status.body) as? [String: Any])
    let result = try #require(json["result"] as? [String: Any])
    let content = try #require(result["structuredContent"] as? [String: Any])
    #expect(content["archive_available"] as? Bool == false && content["read_only"] as? Bool == true)
    #expect(!FileManager.default.fileExists(atPath: paths.root.path))
    let ping: [String: Any] = ["jsonrpc": "2.0", "id": 3, "method": "ping"]
    for origin in ["https://evil.invalid", "null", "http://127.0.0.1:18765"] {
        var changed = headers
        changed["origin"] = origin
        #expect(try request(ping, headers: changed).status == 403)
    }
    for host in ["evil.invalid:18765", "127.0.0.1:9999"] {
        var changed = headers
        changed["host"] = host
        #expect(try request(ping, headers: changed).status == 403)
    }
    for (key, value, code) in [
        ("mcp-protocol-version", "unsupported", 400), ("content-type", "text/plain", 415),
        ("accept", "text/event-stream", 406),
    ] {
        var changed = headers
        changed[key] = value
        #expect(try request(ping, headers: changed).status == code)
    }
    #expect(
        handler.response(to: MCPHTTPRequest(method: "GET", path: "/mcp", headers: headers, body: Data())).status == 405)
    #expect(
        handler.response(to: MCPHTTPRequest(method: "POST", path: "/other", headers: headers, body: Data())).status
            == 404)
    #expect(
        handler.response(to: MCPHTTPRequest(method: "POST", path: "/mcp", headers: headers, body: Data("{".utf8)))
            .status == 400)
}

@Test("Existing preferences survive HTTP port configuration")
func mcpPreferencesMigration() throws {
    let old = Data(#"{"collectOnLaunch":true,"pollSeconds":5,"fileDirectory":"/synthetic/account"}"#.utf8)
    var preferences = try JSONDecoder().decode(Preferences.self, from: old)
    #expect(
        preferences.collectOnLaunch && preferences.pollSeconds == 5 && preferences.fileDirectory == "/synthetic/account"
    )
    #expect(preferences.mcpPort == nil)
    preferences.mcpPort = 23456
    let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
    #expect(decoded.mcpPort == 23456 && decoded.fileDirectory == preferences.fileDirectory)
}

@Test("HTTP listener can stop and restart on the same port")
func mcpHTTPRestart() async throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let server = MCPHTTPServer(paths: AppPaths(override: root.appendingPathComponent("absent").path))
    defer { server.stop() }
    func start(_ port: UInt16) async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            var completed = false
            server.start(port: port) { state in
                guard !completed else { return }
                switch state {
                case .listening(let actual):
                    completed = true
                    continuation.resume(returning: actual)
                case .failed(let message):
                    completed = true
                    continuation.resume(throwing: ListenerError(message))
                default: break
                }
            }
        }
    }
    let port = try await start(0)
    func ping() async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        let (body, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["id"] as? Int == 1 && json["result"] != nil)
    }
    try await ping()
    server.stop()
    let restartedPort = try await start(port)
    #expect(restartedPort == port)
    try await ping()
    let reappliedPort = try await start(port)
    #expect(reappliedPort == port)
    try await ping()
}
