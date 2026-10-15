import Foundation

struct ImportResult {
    var inserted = 0
    var updated = 0
    var unchanged = 0
    var failed = 0
}
struct CaptureResult {
    var sourceRows = 0
    var decodedRows = 0
    var reusedRows = 0
    var inserted = 0
    var updated = 0
    var failed = 0
    var journalError = false
}
