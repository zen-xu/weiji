import Foundation

struct MessageFilter {
    var query = ""
    var conversation: String?
    var from: String?
    var before: String?
    var limit = 100
    var offset = 0
}
