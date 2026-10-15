import AppKit
import Darwin

@main
enum WeChatListenerApplication {
    static func main() {
        umask(0o077)
        var arguments = Array(CommandLine.arguments.dropFirst())
        var override: String?
        if let index = arguments.firstIndex(of: "--data-dir") {
            guard index + 1 < arguments.count else {
                fputs("--data-dir 缺少目录\n", stderr)
                exit(2)
            }
            override = arguments[index + 1]
            arguments.removeSubrange(index...index + 1)
        }
        let paths = AppPaths(override: override)
        do {
            let demo = arguments.first == "--demo"
            if demo {
                guard override != nil else { throw ListenerError("演示模式必须指定独立的 --data-dir，避免混入真实档案。") }
                try DemoData.populate(paths: paths)
            }
            if !arguments.isEmpty && !demo {
                try CommandLineInterface.run(arguments, paths: paths)
                exit(0)
            }
            MainActor.assumeIsolated {
                let app = NSApplication.shared
                if let id = Bundle.main.bundleIdentifier,
                    let existing = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: {
                        $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                    })
                {
                    existing.activate(options: [.activateAllWindows])
                    exit(0)
                }
                let delegate = ApplicationDelegate(paths: paths, allowNotificationCapture: !demo)
                app.delegate = delegate
                app.setActivationPolicy(.regular)
                withExtendedLifetime(delegate) { app.run() }
            }
        } catch {
            try? CommandLineInterface.writeJSON(["ok": false, "error": error.localizedDescription])
            exit(1)
        }
    }
}
