import AppKit
import Quartz

// Space-bar style preview for shelf items.
//
// This builds its own window around QLPreviewView instead of using the shared
// QLPreviewPanel. That panel drives itself through the key window's responder
// chain, and the notch panel deliberately never becomes key (so it can't steal
// focus from whatever you're working in), which leaves the shared panel nothing
// to hook into. Owning the window also means Esc and click-away behave the way
// Quick Look does without fighting the responder chain.
final class PreviewWindow {
    static let shared = PreviewWindow()
    private init() {}

    private var window: NSPanel?
    private var previewView: QLPreviewView?
    private var keyMonitor: Any?
    // Activation is asynchronous, so the window reports a resign-key before it has
    // ever become key. Without this grace period the dismiss-on-look-away rule
    // fired during the opening sequence and closed the preview instantly.
    private var shownAt = Date.distantPast

    func show(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSSound.beep()
            return
        }

        let panel = window ?? makeWindow()
        window = panel
        panel.title = url.lastPathComponent

        previewView?.previewItem = url as NSURL
        previewView?.refreshPreviewItem()

        // An accessory app has to activate itself, or the preview opens behind
        // whatever is in front.
        NSApp.activate(ignoringOtherApps: true)
        if !panel.isVisible { panel.center() }
        shownAt = Date()
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    func close() {
        removeKeyMonitor()
        window?.orderOut(nil)
    }

    private func makeWindow() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let preview = QLPreviewView(frame: panel.contentLayoutRect, style: .normal)
        preview?.autoresizingMask = [.width, .height]
        preview?.shouldCloseWithWindow = false
        if let preview = preview {
            panel.contentView?.addSubview(preview)
            previewView = preview
        }

        // Quick Look dismisses when you look away; match that.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel, queue: .main) { [weak self] _ in
                guard let self = self,
                      Date().timeIntervalSince(self.shownAt) > 0.8 else { return }
                self.close()
        }
        return panel
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // 53 = Esc, 49 = Space, both close a Quick Look preview.
            guard event.keyCode == 53 || event.keyCode == 49 else { return event }
            self?.close()
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
        keyMonitor = nil
    }
}
