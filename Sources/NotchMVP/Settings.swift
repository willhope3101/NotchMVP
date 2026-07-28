import AppKit

// Everything that used to be a hard-coded number, in a JSON file the user can
// edit. Deliberately a file rather than a preferences window: for a personal
// tool it's a fraction of the work, and every value is visible at once.
struct Settings: Codable, Equatable {
    var miniTimeoutSeconds: Double = 10
    var miniAfterHoverSeconds: Double = 10
    var collapseDelaySeconds: Double = 0.3
    // Hidden-state hover target, as a fraction of the notch width. Full width made
    // it easy to trip while moving along the menu bar; the entry-direction check
    // in NotchController now carries most of that job, so this can afford to be
    // generous again — a narrow target just made deliberate hovers feel fiddly.
    var hoverZoneScale: Double = 0.85
    // Same idea, vertically: the hidden-state target reached a few points below
    // the physical notch, which was enough to catch a cursor just passing by
    // underneath it (a browser's tab strip, a maximized window's title bar).
    var hoverZoneHeightScale: Double = 0.5
    // The pointer has to linger this long before the panel opens, so merely
    // crossing the notch doesn't trigger it.
    var hoverDwellSeconds: Double = 0.22
    var panelWidth: Double = 600
    var miniSideWidth: Double = 42
    // Title + time row + progress bar come to ~32pt, so this leaves ~7pt of
    // breathing room above and below them.
    var miniInfoHeight: Double = 46
    // Off for now: the taller pill with the title got in the way. The full style
    // is still built, just not used — flip this to bring it back.
    var miniShowsTitle: Bool = false
    var showWeather: Bool = true
    var showWave: Bool = true
    // Carbon key code + modifier names. 49 is Space.
    var hotkeyKeyCode: Int = 49
    var hotkeyModifiers: [String] = ["option"]

    static let `default` = Settings()
}

final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published private(set) var current: Settings = .default

    private init() {
        load()
    }

    var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("NotchMVP", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    // Written on first launch so there's something to open and edit, rather than
    // the user having to guess the format.
    func createFileIfMissing() {
        let url = fileURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        write(current)
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            // Decoding the whole struct means a missing key falls back to the
            // property's default, so an old or partial file still works.
            current = try JSONDecoder().decode(Settings.self, from: data)
            notchDebug("settings loaded from \(fileURL.path)")
        } catch {
            notchDebug("settings unreadable, using defaults: \(error)")
        }
    }

    func reload() {
        let before = current
        load()
        if current != before { notchDebug("settings changed") }
    }

    func revealInFinder() {
        createFileIfMissing()
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    func openInEditor() {
        createFileIfMissing()
        NSWorkspace.shared.open(fileURL)
    }

    private func write(_ settings: Settings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        try? data.write(to: fileURL)
    }
}
