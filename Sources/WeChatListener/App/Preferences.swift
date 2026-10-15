import Foundation

struct Preferences: Codable {
    var collectOnLaunch = false
    var pollSeconds = 2
    var fileDirectory: String?
    static func load(_ paths: AppPaths) -> Preferences {
        (try? JSONDecoder().decode(Self.self, from: Data(contentsOf: paths.preferences))) ?? Self()
    }
    func save(_ paths: AppPaths) throws {
        try JSONEncoder().encode(self).write(to: paths.preferences, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.preferences.path)
    }
}
