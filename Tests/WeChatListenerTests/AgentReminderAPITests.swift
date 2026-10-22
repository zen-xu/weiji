import Darwin
import Foundation
import Testing

@testable import WeChatListener

@Test("Agent reminder API authentication, durable deduplication and validation")
func agentReminderAPI() throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(override: root.path)
    let api = AgentReminderAPI(paths: paths)
    let token = try api.token()
    let handler = MCPHTTPHandler(paths: paths, port: 18765)
    func request(_ payload: String, auth: String? = nil, origin: String? = nil) -> MCPHTTPResponse {
        var headers = ["host": "127.0.0.1:18765", "content-type": "application/json"]
        headers["authorization"] = auth
        headers["origin"] = origin
        return handler.response(
            to: MCPHTTPRequest(method: "POST", path: "/api/reminders", headers: headers, body: Data(payload.utf8)))
    }
    let payload = #"{"request_id":"job:1","title":"任务提醒","body":"请确认配置","source_message_ids":["message-1"]}"#
    #expect(request(payload).status == 401)
    #expect(request(payload, auth: "Bearer \(token)", origin: "http://localhost").status == 403)
    #expect(request(payload, auth: "Bearer \(token)").status == 202)
    #expect(request(payload, auth: "Bearer \(token)").status == 200)
    #expect(try AgentReminderAPI(paths: paths).pending().count == 1)
    #expect(try api.pending().first?.sourceMessageIDs == ["message-1"])
    #expect(request(payload.replacingOccurrences(of: "请确认配置", with: "changed"), auth: "Bearer \(token)").status == 409)
    #expect(
        request(#"{"request_id":"x","title":"x","body":"x","notify_at":"later"}"#, auth: "Bearer \(token)").status
            == 400)
    #expect(
        request(#"{"request_id":"x","title":"x","body":"x","source_message_ids":42}"#, auth: "Bearer \(token)").status
            == 400)
    try api.delivered("job:1")
    #expect(try api.pending().isEmpty)
    #expect(request(payload, auth: "Bearer \(token)").status == 200)
    let permissions =
        try FileManager.default.attributesOfItem(atPath: api.tokenURL.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
}

@Test("Agent reminders preserve identity, source and handled state across restart")
@MainActor
func agentReminderInboxPersistence() throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(override: root.path)
    try paths.prepare()
    var message = NotificationDecoder.make(
        record: 0, title: "Agent 标题", subtitle: "", body: "生成的提醒", delivered: nil, captured: Date())
    message.id = "agent:job-1"
    message.source = "agent_reminder"
    let hit = ReminderHit(message: message, ruleNames: ["Agent 提醒"], sourceMessageIDs: ["source-1"])
    let inbox = ReminderInbox(paths: paths)
    inbox.append([hit])
    #expect(inbox.isPersisted(hit.id))
    #expect(inbox.takeDue(rules: []).count == 1)
    #expect(inbox.takeDue(rules: []).isEmpty)
    inbox.handle(hit.id)
    inbox.flush()
    let restored = ReminderInbox(paths: paths)
    restored.append([hit])
    #expect(restored.entries.count == 1)
    #expect(restored.entries.first?.isHandled == true)
    #expect(restored.entries.first?.hit.sourceMessageIDs == ["source-1"])
    #expect(restored.entries.first?.hit.message.source == "agent_reminder")
    #expect(restored.takeDue(rules: []).isEmpty)
    restored.flush()
}

@Test("MCP agents discover Weiji delivery and create reminders without exposing credentials")
func agentReminderMCPDiscovery() throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let paths = AppPaths(override: root.path)
    let server = MCPServer(paths: paths, initialized: true)
    let listed = try #require(server.response(["jsonrpc": "2.0", "id": 1, "method": "tools/list"]))
    let tools = try #require((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]])
    let tool = try #require(tools.first { $0["name"] as? String == "wechat_create_reminder" })
    #expect((tool["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == false)
    #expect(MCPServer.instructions.contains("your own notification does not substitute"))
    let args: [String: Any] = ["request_id": "agent-event-1", "title": "待确认", "body": "请确认上线时间"]
    func call(_ arguments: [String: Any]) throws -> [String: Any] {
        let reply = try #require(
            server.response([
                "jsonrpc": "2.0", "id": 2, "method": "tools/call",
                "params": ["name": "wechat_create_reminder", "arguments": arguments],
            ]))
        return try #require(reply["result"] as? [String: Any])
    }
    let result = try call(args)
    #expect(result["isError"] as? Bool == false)
    let content = try #require(result["structuredContent"] as? [String: Any])
    #expect(content["delivery_provider"] as? String == "weiji")
    #expect(content["delivery_state"] as? String == "queued")
    let api = AgentReminderAPI(paths: paths)
    #expect(try api.pending().count == 1)
    let serialized = try JSONSerialization.data(withJSONObject: result)
    #expect(!String(decoding: serialized, as: UTF8.self).contains(try api.token()))
    #expect((try call(args)["structuredContent"] as? [String: Any])?["duplicate"] as? Bool == true)
    #expect(try call(["title": "incomplete"])["isError"] as? Bool == true)
    let status = try QueryService(paths: paths).status()
    #expect((status["agent_reminders"] as? [String: Any])?["mcp_tool"] as? String == "wechat_create_reminder")
}

@Test("Agent reminder writers honor a shared file lock")
func agentReminderProcessLock() throws {
    let root = try TestSupport.makeDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let api = AgentReminderAPI(paths: AppPaths(override: root.path))
    let token = try api.token()
    let descriptor = open(root.appendingPathComponent("agent-reminders.lock").path, O_RDWR)
    try #require(descriptor >= 0)
    defer { close(descriptor) }
    try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
    let request = MCPHTTPRequest(
        method: "POST", path: "/api/reminders",
        headers: ["authorization": "Bearer \(token)", "content-type": "application/json"],
        body: Data(#"{"request_id":"lock-test","title":"x","body":"x"}"#.utf8))
    #expect(api.response(to: request).status == 503)
    #expect(try api.pending().isEmpty)
    flock(descriptor, LOCK_UN)
    #expect(api.response(to: request).status == 202)
    #expect(try api.pending().count == 1)
}
