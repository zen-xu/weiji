import Foundation

@testable import WeChatListener

enum TestSupport {
    static let referenceDate = Dates.parse("2026-10-15T09:00:00.000+08:00")!

    static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "wechat-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.resolvingSymlinksInPath()
    }
}
