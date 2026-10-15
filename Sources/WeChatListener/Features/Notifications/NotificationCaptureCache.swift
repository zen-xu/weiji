import CryptoKit
import Foundation

/// Writer-queue-only cache. Retains digests, never notification bodies or decoded sender metadata.
final class NotificationCaptureCache {
    static let limit = 10_000
    private var source = ""
    private var revision: UInt64?
    private var dataVersion: Int64?
    private var records: [Int64: Data] = [:]

    func reusable(source: String, revision: UInt64, dataVersion: Int64) -> [Int64: Data] {
        guard self.source == source, self.revision == revision, self.dataVersion == dataVersion else { return [:] }
        return records
    }

    func replace(_ records: [Int64: Data], source: String, revision: UInt64, dataVersion: Int64?) {
        self.records =
            records.count <= Self.limit
            ? records : Dictionary(uniqueKeysWithValues: records.prefix(Self.limit).map { ($0.key, $0.value) })
        self.source = source
        self.revision = revision
        self.dataVersion = dataVersion
    }

    static func fingerprint(_ row: [String: SQLValue]) -> (Int64, Data)? {
        guard let id = row.int("rec_id"), let bytes = row.data("data"), bytes.count <= 4_000_000 else { return nil }
        let uuid = row.data("uuid") ?? Data()
        let date = row.double("delivered_date").map { String($0.bitPattern) } ?? "nil"
        var hash = SHA256()
        hash.update(data: Data("v1|\(id)|\(date)|\(row.data("uuid") != nil)|\(uuid.count)|\(bytes.count)|".utf8))
        hash.update(data: uuid)
        hash.update(data: bytes)
        return (id, Data(hash.finalize()))
    }
}
