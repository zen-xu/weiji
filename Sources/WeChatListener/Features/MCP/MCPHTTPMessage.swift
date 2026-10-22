import Foundation

/// A deliberately bounded HTTP/1.1 request. Each connection carries one request, then closes.
struct MCPHTTPRequest {
    static let maximumHeaderSize = 16_384
    static let maximumBodySize = 1_048_576
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    static func parse(_ data: Data) throws -> Self? {
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
            guard data.count <= maximumHeaderSize else { throw MCPHTTPError(status: 431) }
            return nil
        }
        guard boundary.upperBound <= maximumHeaderSize else { throw MCPHTTPError(status: 431) }
        guard let head = String(data: data[..<boundary.lowerBound], encoding: .utf8) else {
            throw MCPHTTPError(status: 400)
        }
        let lines = head.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[2] == "HTTP/1.1" else { throw MCPHTTPError(status: 400) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw MCPHTTPError(status: 400) }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty,
                name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                headers[name] == nil
            else { throw MCPHTTPError(status: 400) }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.utf8.contains(where: { $0 < 32 && $0 != 9 || $0 == 127 }) else {
                throw MCPHTTPError(status: 400)
            }
            headers[name] = value
        }
        // Reject ambiguous framing; MCP clients send a known-length JSON body.
        guard headers["transfer-encoding"] == nil, headers["expect"] == nil else {
            throw MCPHTTPError(status: 400)
        }
        let length: Int
        if let raw = headers["content-length"] {
            guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }), let value = Int(raw) else {
                throw MCPHTTPError(status: 400)
            }
            length = value
        } else {
            guard first[0] != "POST" else { throw MCPHTTPError(status: 411) }
            length = 0
        }
        guard length <= maximumBodySize else { throw MCPHTTPError(status: 413) }
        let available = data.count - boundary.upperBound
        guard available <= length else { throw MCPHTTPError(status: 400) }
        guard available == length else { return nil }
        return Self(
            method: String(first[0]), path: String(first[1]), headers: headers,
            body: Data(data[boundary.upperBound...]))
    }
}

struct MCPHTTPError: Error {
    let status: Int
}

struct MCPHTTPResponse {
    let status: Int
    var body = Data()
    var headers: [String: String] = [:]

    static func json(_ value: [String: Any], status: Int = 200) -> Self {
        Self(
            status: status,
            body: (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]))
                ?? Data(),
            headers: ["Content-Type": "application/json"])
    }

    var data: Data {
        let reason =
            [
                200: "OK", 401: "Unauthorized", 409: "Conflict", 202: "Accepted", 400: "Bad Request", 403: "Forbidden",
                404: "Not Found",
                405: "Method Not Allowed", 406: "Not Acceptable", 408: "Request Timeout", 411: "Length Required",
                413: "Content Too Large", 415: "Unsupported Media Type", 431: "Request Header Fields Too Large",
                503: "Service Unavailable",
            ][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nContent-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n"
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(key): \(value)\r\n" }
        return Data((head + "\r\n").utf8) + body
    }
}

/// Stateless Streamable HTTP: JSON replies, no session IDs or unsolicited SSE events.
struct MCPHTTPHandler {
    let paths: AppPaths
    let port: UInt16

    func response(to request: MCPHTTPRequest) -> MCPHTTPResponse {
        // Native clients omit Origin. Reject browser-origin requests, including localhost pages.
        guard request.headers["origin"] == nil,
            let host = request.headers["host"],
            ["127.0.0.1:\(port)", "localhost:\(port)"].contains(host.lowercased())
        else { return MCPHTTPResponse(status: 403) }
        if request.path == "/api/reminders" {
            return AgentReminderAPI(paths: paths).response(to: request)
        }
        guard request.path == "/mcp" else { return MCPHTTPResponse(status: 404) }
        guard request.method == "POST" else {
            return MCPHTTPResponse(status: 405, headers: ["Allow": "POST"])
        }
        if let version = request.headers["mcp-protocol-version"],
            !["2025-03-26", "2025-06-18"].contains(version)
        {
            return MCPHTTPResponse(status: 400)
        }
        guard
            request.headers["content-type"]?.split(separator: ";").first?
                .trimmingCharacters(in: .whitespaces).lowercased() == "application/json"
        else { return MCPHTTPResponse(status: 415) }
        let accepted = (request.headers["accept"] ?? "").lowercased().split(separator: ",").map {
            $0.split(separator: ";").first?.trimmingCharacters(in: .whitespaces) ?? ""
        }
        guard accepted.contains("application/json"), accepted.contains("text/event-stream") else {
            return MCPHTTPResponse(status: 406)
        }
        let server = MCPServer(paths: paths, initialized: true)
        guard let value = try? JSONSerialization.jsonObject(with: request.body) else {
            return .json(server.error(id: nil, code: -32700, message: "Parse error"), status: 400)
        }
        guard let message = value as? [String: Any], message["jsonrpc"] as? String == "2.0" else {
            return .json(server.error(id: nil, code: -32600, message: "Invalid JSON-RPC request"), status: 400)
        }
        // Clients may send a JSON-RPC response even though this service never initiates requests.
        if message["method"] == nil, message["id"] != nil,
            (message["result"] != nil) != (message["error"] != nil)
        {
            return MCPHTTPResponse(status: 202)
        }
        if let reply = server.response(message) { return .json(reply) }
        return MCPHTTPResponse(status: 202)
    }
}
