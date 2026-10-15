import Foundation

enum ApplicationInfo {
    static let name = "微迹"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }
}
