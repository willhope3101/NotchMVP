import Foundation

// Launch at login through a LaunchAgent that calls `open`, not the executable
// directly: launching the binary itself makes macOS treat it as a different
// app identity, which spawns duplicate permission entries and loses grants.
enum LoginItem {
    static let label = "local.notchmvp.launcher"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func enable() {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
            "RunAtLoad": true,
        ]
        do {
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                         format: .xml, options: 0)
            try data.write(to: plistURL)
            // Replace any previous registration before loading the new one.
            launchctl(["bootout", "gui/\(getuid())/\(label)"])
            launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
            notchDebug("login item enabled for \(Bundle.main.bundlePath)")
        } catch {
            notchDebug("login item enable failed: \(error)")
        }
    }

    static func disable() {
        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(at: plistURL)
        notchDebug("login item disabled")
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}
