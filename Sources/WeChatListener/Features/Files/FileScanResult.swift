import Foundation

struct FileScanResult: Codable {
    let root: String
    let scannedAt: String
    let files: Int
    let complete: Bool
    let failures: Int
    enum CodingKeys: String, CodingKey {
        case root, files, complete, failures
        case scannedAt = "scanned_at"
    }
}
