import Foundation

extension Message {
    var notifiedFileName: String? {
        let body = presentation.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.hasPrefix("[文件]") else { return nil }
        let name = body.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
            !name.contains("\0"), !name.contains(where: { $0.isNewline })
        else { return nil }
        return name.precomposedStringWithCanonicalMapping
    }
}
