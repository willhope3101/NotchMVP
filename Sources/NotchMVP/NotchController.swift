import AppKit
import SwiftUI
import Combine

// Holds the notch geometry read from the active screen.
struct NotchMetrics {
    var notchWidth: CGFloat
    var notchHeight: CGFloat

    // Fallback for external displays / Macs without a notch.
    static let fallback = NotchMetrics(notchWidth: 200, notchHeight: 32)

    static func read(from screen: NSScreen) -> NotchMetrics {
        let topInset = screen.safeAreaInsets.top
        guard topInset > 0 else { return fallback }

        // The two auxiliary areas flank the physical notch. The gap between
        // them is the notch width.
        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = right.minX - left.maxX
            if width > 0 {
                return NotchMetrics(notchWidth: width, notchHeight: topInset)
            }
        }
        return NotchMetrics(notchWidth: 200, notchHeight: topInset)
    }
}

// Shared observable state driving the SwiftUI view.
final class NotchState: ObservableObject {
    @Published var isExpanded = false
    @Published var isHovering = false
    @Published var showMini = false
    // Two shapes of pill. `full` announces a track — artwork, meter, title and
    // progress. `compact` is the quieter reminder shown after you've just had the
    // panel open: artwork and meter only, no words to re-read.
    enum MiniStyle { case full, compact }
    @Published var miniStyle: MiniStyle = .full
    @Published var metrics = NotchMetrics.fallback
    // Files parked on the shelf. Empty means the shelf row isn't shown at all.
    @Published var shelfItems: [ShelfItem] = []
    // True while a file drag is hovering us, for the drop highlight.
    @Published var dropTargeted = false

    let media = MediaController()
    let weather = WeatherService()

    // Set by the controller: lets a view ask the panel to get out of the way
    // after an action that hands focus to another app.
    var requestDismiss: (() -> Void)?

    private var settings: Settings { SettingsStore.shared.current }

    var maxWidth: CGFloat { settings.panelWidth }
    // Snug around the content: notch height + 8 above, the 112pt media row, and
    // 18 below. Extra height would just leave dead black under the controls.
    var baseHeight: CGFloat { 184 }
    // The shelf row only takes space once something is on it.
    var shelfHeight: CGFloat { shelfItems.isEmpty ? 0 : 74 }
    // The warning strip only takes space when there's something to warn about.
    var noticeHeight: CGFloat { media.blocker == nil ? 0 : 40 }
    var showsWeather: Bool { settings.showWeather }
    var showsWave: Bool { settings.showWave }
    var maxHeight: CGFloat { baseHeight + shelfHeight + noticeHeight }

    // The concave corners spill this far past the panel on each side, so the
    // window has to be wider than the panel or they'd be clipped away.
    var topFlare: CGFloat { 13 }
    var windowWidth: CGFloat { maxWidth + topFlare * 2 }

    // Mini geometry: the black pill reaches this far past each side of the
    // notch, with the cover art and waveform tucked against its edges.
    // Wings wide enough that the 20pt artwork isn't pinned against the notch.
    var miniSide: CGFloat { settings.miniSideWidth }
    var miniWidth: CGFloat { metrics.notchWidth + miniSide * 2 }
    // The strip below the notch carries the title and a progress line. Sized to
    // hold both rather than one cramped line of text: at 22pt the title filled it
    // edge to edge while the 37pt side wings looked airy, which is what read as
    // lopsided.
    var miniInfoHeight: CGFloat { settings.miniInfoHeight }
    var miniHeight: CGFloat { metrics.notchHeight + miniInfoHeight }
    // What the pill actually occupies right now — the compact style is exactly the
    // notch's own height, since it carries nothing below it.
    var miniVisibleHeight: CGFloat {
        miniStyle == .full ? miniHeight : metrics.notchHeight
    }
}

// Hosting view that reports zero safe-area insets, so SwiftUI content can
// sit flush against the notch instead of being pushed below it.
final class NoSafeAreaHostingView<Content: View>: NSHostingView<Content> {
    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets() }

    // The panel never becomes key, so without this the first click into it is
    // swallowed and the transport buttons appear dead.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// A panel that refuses to be constrained below the menu bar, so it can sit at
// the very top of the screen and cover the notch area.
final class NotchPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect   // no constraining — keep the frame exactly where we asked
    }
    override var canBecomeKey: Bool { false }
}

final class NotchController {
    private let panel: NotchPanel
    private let hosting: NoSafeAreaHostingView<NotchRootView>
    private let state = NotchState()
    private var mouseTimer: Timer?
    private var fullscreenTimer: Timer?
    private var hiddenForFullscreen = false
    private var hoverSuppressed = false
    // A file drag is in flight over us. The panel is click-through while collapsed,
    // so it can't be a drop target until we notice the drag and switch that off.
    private var draggingFiles = false
    // Cursor ticks spent outside the panel. Collapsing the instant the pointer
    // crosses the edge felt twitchy, and made it easy to lose the panel while
    // reaching for something near its border.
    private var ticksOutside = 0
    // Opened by keyboard: hover rules don't apply until it's dismissed the same way.
    private var pinnedOpen = false
    private var miniTimer: Timer?
    private var blockerTimer: Timer?
    private var miniTimeout: Double { SettingsStore.shared.current.miniTimeoutSeconds }
    private var miniAfterHover: Double { SettingsStore.shared.current.miniAfterHoverSeconds }
    // Set for the one collapse that shouldn't leave anything behind: opening the
    // source app is a request to get out of the way.
    private var suppressMiniOnCollapse = false
    private var collapseDelay: Double { SettingsStore.shared.current.collapseDelaySeconds }
    private var hoverZoneScale: Double { SettingsStore.shared.current.hoverZoneScale }
    private var hoverZoneHeightScale: Double { SettingsStore.shared.current.hoverZoneHeightScale }
    private var hoverDwell: Double { SettingsStore.shared.current.hoverDwellSeconds }
    // Consecutive ticks the pointer has been inside the opening zone.
    private var ticksInside = 0
    // Where the pointer was on the previous tick, and whether it entered the zone
    // from underneath. Travelling sideways along the menu bar — reaching for a menu
    // or a status icon — crosses the zone too, and shrinking it twice still left
    // that happening constantly. Coming up from the content area is the thing that
    // actually distinguishes "I want the notch" from "I'm passing through".
    private var previousLocation: NSPoint?
    private var enteredFromBelow = false
    private var cancellables = Set<AnyCancellable>()
    private var lastTrackID = ""
    private var lastPlaying = false

    init() {
        let contentRect = NSRect(x: 0, y: 0, width: state.windowWidth, height: state.maxHeight)
        panel = NotchPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        // Must come after isFloatingPanel, which resets the level to .floating.
        // The menu bar is at 24 and status items at 25, so 26 puts the panel over
        // both. That also puts it over fullscreen windows, which is why fullscreen
        // is handled explicitly in syncFullscreenVisibility().
        //
        // Raising this to .screenSaver was tried to stop the panel sliding with
        // each Spaces switch; it made no difference, so it stays at the lower,
        // more conservative level.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.ignoresMouseEvents = true   // collapsed: fully click-through
        // SwiftUI's onContinuousHover rides on mouseMoved events, which AppKit
        // only delivers if the window opts in — without this, the hand cursor
        // stayed the system arrow until some other event (a click) happened to
        // wake the window up.
        panel.acceptsMouseMovedEvents = true

        let root = NotchRootView(state: state)
        hosting = NoSafeAreaHostingView(rootView: root)
        hosting.frame = contentRect
        if #available(macOS 13.3, *) {
            hosting.safeAreaRegions = []   // opt out of notch safe area entirely
        }
        panel.contentView = hosting

        state.requestDismiss = { [weak self] in self?.dismissAfterAction() }
    }

    // Opening the source app should reveal it, not leave the panel hovering over
    // it. The pointer hasn't moved, so hover has to stay muted until it leaves —
    // otherwise the panel springs straight back open on top of the app.
    private func dismissAfterAction() {
        pinnedOpen = false
        suppressMiniOnCollapse = true
        // This is the one collapse that happens right under the pointer, so the
        // hand cursor pushed by the artwork button never gets its matching pop.
        NSCursor.arrow.set()
        setExpanded(false, animated: true)
        hoverSuppressed = true
        notchDebug("dismissed for action; hover muted until pointer leaves")
    }

    func show() {
        reposition()
        panel.orderFrontRegardless()
        state.media.start()
        state.weather.start()
        // Plugging in or removing a display changes screen frames; without this
        // the panel can end up stranded off-screen.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.reposition()
        }
        SettingsStore.shared.createFileIfMissing()
        registerHotkey()
        // Debug helper: NOTCH_FORCE_EXPAND=1 starts expanded for screenshotting.
        observeMedia()
        observeShelf()
        observeBlocker()
        if ProcessInfo.processInfo.environment["NOTCH_FORCE_EXPAND"] == "1" {
            state.isHovering = true
            setExpanded(true, animated: false)
        } else {
            startMouseTracking()
            startFullscreenWatch()
        }
        // Debug helper: seeds the shelf so its layout can be checked without a
        // real drag (dragging needs a hand on the trackpad).
        if let seed = ProcessInfo.processInfo.environment["NOTCH_SEED_SHELF"] {
            let urls = seed.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.state.addToShelf(urls)
                notchDebug("seeded shelf with \(urls.count) item(s)")
            }
        }
        if ProcessInfo.processInfo.environment["NOTCH_DEBUG"] == "1" {
            // Give the first poll time to identify a player, then self-test.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.state.media.diagnoseBrowserJS()
            }
        }
    }

    // Called after the settings file is re-read: width, timings and the shortcut
    // all come from there.
    func applySettings() {
        state.objectWillChange.send()
        registerHotkey()
        reposition()
    }

    // MARK: Keyboard

    private func registerHotkey() {
        let settings = SettingsStore.shared.current
        Hotkey.shared.register(keyCode: settings.hotkeyKeyCode,
                               modifierNames: settings.hotkeyModifiers) { [weak self] in
            self?.toggleFromKeyboard()
        }
    }

    private func toggleFromKeyboard() {
        guard !hiddenForFullscreen else { return }
        if state.isExpanded {
            pinnedOpen = false
            setExpanded(false, animated: true)
        } else {
            pinnedOpen = true
            ticksOutside = 0
            setExpanded(true, animated: true)
        }
    }

    // MARK: Mini pill

    // The mini appears when playback starts or the track changes and then stays
    // put; hovering the panel and leaving again is what dismisses it.
    private func observeMedia() {
        state.media.$nowPlaying
            .removeDuplicates()
            .sink { [weak self] info in self?.handleNowPlaying(info) }
            .store(in: &cancellables)
    }

    private func handleNowPlaying(_ info: NowPlaying) {
        let playing = info.isPlaying && !info.title.isEmpty
        let trackChanged = !info.title.isEmpty && info.trackID != lastTrackID
        let justStarted = playing && !lastPlaying
        lastTrackID = info.trackID
        lastPlaying = playing

        guard playing else { hideMini(); syncVisualizer(); return }
        if trackChanged || justStarted { showMini() }
        syncVisualizer()
    }

    // Sampling costs an Apple Event per frame, so only run while the meter is
    // actually on screen.
    private func syncVisualizer() {
        // Also gated on the setting: with the meter switched off there's nothing to
        // draw, so paying for an Apple Event several times a second is pure waste.
        state.media.wantsLevels = state.showsWave
            && (state.showMini || state.isExpanded)
            && state.media.nowPlaying.isPlaying
    }

    private func showMini() {
        let appearing = !state.showMini
        if appearing { notchDebug("mini shown") }
        withAnimation(.smooth(duration: 0.34)) {
            // A track announcement uses the full pill only when the setting asks
            // for it; otherwise everything is the compact pill.
            state.miniStyle = SettingsStore.shared.current.miniShowsTitle ? .full : .compact
            state.showMini = true
        }
        if appearing { syncVisualizer() }
        armMiniTimeout()
    }

    // Re-armed on every appearance, so a run of quick track changes doesn't leave
    // the pill hiding on the first one's schedule.
    private func armMiniTimeout(seconds: Double? = nil) {
        let duration = seconds ?? miniTimeout
        miniTimer?.invalidate()
        let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            // Don't pull it out from under the pointer; wait until they leave.
            if self.state.isExpanded || self.state.isHovering {
                self.armMiniTimeout(seconds: duration)
                return
            }
            self.hideMini()
        }
        // .common, not the default mode: a timer in the default mode stops firing
        // while the system is tracking a menu or a drag.
        RunLoop.main.add(timer, forMode: .common)
        miniTimer = timer
    }

    private func hideMini() {
        miniTimer?.invalidate()
        miniTimer = nil
        guard state.showMini else { return }
        notchDebug("mini hidden")
        withAnimation(.smooth(duration: 0.28)) { state.showMini = false }
        syncVisualizer()
    }

    // The shelf row changes the panel's height, so the window has to follow.
    // Both the notice strip and the shelf change the panel's height.
    private func observeBlocker() {
        state.media.$blocker
            .map { $0 == nil }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.state.objectWillChange.send()
                    self?.reposition()
                }
            }
            .store(in: &cancellables)

        // Re-check periodically: the browser toggle can be switched off mid-session.
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.state.media.checkBrowserControls()
        }
        RunLoop.main.add(t, forMode: .common)
        blockerTimer = t
    }

    private func observeShelf() {
        state.$shelfItems
            .map(\.isEmpty)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                // Let the published change land first, so maxHeight is up to date.
                DispatchQueue.main.async { self?.reposition() }
            }
            .store(in: &cancellables)
    }

    // MARK: Fullscreen

    // The panel deliberately outranks the menu bar, which would also float it
    // over fullscreen apps — distracting, so pull it off screen there instead.
    private func startFullscreenWatch() {
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.syncFullscreenVisibility()
        }
        RunLoop.main.add(t, forMode: .common)
        fullscreenTimer = t
        syncFullscreenVisibility()
    }

    private func syncFullscreenVisibility() {
        guard let screen = notchScreen else { return }
        let fullscreen = isFullscreenSpaceActive(on: screen)
        guard fullscreen != hiddenForFullscreen else { return }
        hiddenForFullscreen = fullscreen
        notchDebug("fullscreen=\(fullscreen)")
        if fullscreen {
            setExpanded(false, animated: false)
            hideMini()
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    private func isFullscreenSpaceActive(on screen: NSScreen) -> Bool {
        // In a fullscreen space the menu bar is hidden, so the visible frame
        // reaches the top of the display.
        guard screen.visibleFrame.maxY >= screen.frame.maxY - 1 else { return false }

        // That's also true when the menu bar is set to auto-hide, so confirm a
        // window is really covering the whole display.
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else {
            return true
        }
        for entry in list {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = bounds["Width"], let height = bounds["Height"] else { continue }
            if width >= screen.frame.width - 1 && height >= screen.frame.height - 1 { return true }
        }
        return false
    }

    // The menu-bar strip doesn't deliver mouse-moved events to our window, so
    // SwiftUI's onHover never fires over the notch. Poll the cursor instead —
    // no permissions needed, and it works everywhere on screen.
    private static let mouseInterval = 0.04

    private func startMouseTracking() {
        let t = Timer(timeInterval: Self.mouseInterval, repeats: true) { [weak self] _ in
            self?.trackMouse()
        }
        RunLoop.main.add(t, forMode: .common)
        mouseTimer = t
    }

    private func trackMouse() {
        guard !hiddenForFullscreen, let screen = notchScreen else { return }
        let loc = NSEvent.mouseLocation
        let f = screen.frame
        let m = state.metrics

        // While the mini pill is showing, the zone covers the whole pill — art,
        // waveform and the title row — so pointing at visible pixels always works.
        // With nothing showing it's deliberately smaller than the notch: the target
        // is invisible then, and a full-width one was easy to trip by accident.
        let openWidth = state.showMini ? state.miniWidth : m.notchWidth * hoverZoneScale
        let openHeight = state.showMini ? state.miniVisibleHeight + 4 : m.notchHeight * hoverZoneHeightScale
        let trigger = topSlopped(NSRect(x: f.midX - openWidth / 2,
                                        y: f.maxY - openHeight,
                                        width: openWidth,
                                        height: openHeight))
        // Closing zone: anywhere over the open panel keeps it open.
        let overPanel = topSlopped(panel.frame).contains(loc)
        let insideZone = trigger.contains(loc)
        let wanted = state.isExpanded ? (overPanel || insideZone) : insideZone

        if hoverSuppressed {
            // Only listen to hover again once the pointer has actually left.
            if !insideZone && !overPanel { hoverSuppressed = false }
            previousLocation = loc
            return
        }

        // How the pointer arrived decides whether this counts as asking for the
        // panel: judged on the first tick inside, the only one that still knows
        // where it came from.
        if insideZone {
            if ticksInside == 0 {
                enteredFromBelow = (previousLocation?.y ?? 0) < trigger.minY
            }
            ticksInside += 1
        } else {
            ticksInside = 0
            enteredFromBelow = false
        }
        previousLocation = loc

        if state.isHovering != wanted { state.isHovering = wanted }

        if wanted {
            ticksOutside = 0
            guard !state.isExpanded else { return }
            // Dwell as well as direction, so a fast flick up past the notch on the
            // way somewhere else doesn't open it either.
            let dwellTicks = max(1, Int((hoverDwell / Self.mouseInterval).rounded()))
            if enteredFromBelow, ticksInside >= dwellTicks {
                setExpanded(true, animated: true)
            }
        } else if state.isExpanded, !pinnedOpen {
            // Crossing the panel's edge while reaching for something just outside
            // it shouldn't yank it shut.
            ticksOutside += 1
            if ticksOutside >= max(1, Int((collapseDelay / Self.mouseInterval).rounded())) {
                setExpanded(false, animated: true)
            }
        }
    }

    // Collapsed and idle the panel must not swallow clicks meant for the menu bar;
    // expanded, or while a file drag is looking for a drop target, it needs them.
    private func syncClickThrough(expanded: Bool) {
        panel.ignoresMouseEvents = !(expanded || draggingFiles)
    }

    // A drag is only interesting if the button is actually held — checking that
    // first keeps the pasteboard lookup off the 25Hz path in the common case.
    private var fileDragInFlight: Bool {
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return false }
        guard let types = NSPasteboard(name: .drag).types else { return false }
        return types.contains(.fileURL)
    }

    // NSRect.contains excludes its top edge, and the cursor parked against the
    // top of the screen reports exactly that y — which read as "not hovering".
    // Extend rects past the screen edge so the topmost row still counts.
    private func topSlopped(_ rect: NSRect) -> NSRect {
        NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + 3)
    }

    // Collapsed the window must not swallow clicks meant for the menu bar or
    // whatever is behind it; expanded it needs them for the media buttons.
    private func setExpanded(_ expanded: Bool, animated: Bool) {
        syncClickThrough(expanded: expanded)
        notchDebug("expanded=\(expanded) cursor=\(NSEvent.mouseLocation)")
        // Leaving an open panel used to retire the pill outright. Now, if something
        // is still playing, it falls back to the mini for a few seconds instead —
        // unless this collapse was a deliberate "get out of the way".
        let leavingPanel = state.isExpanded && !expanded
        let playing = state.media.nowPlaying.isPlaying && !state.media.nowPlaying.title.isEmpty
        let keepMini = leavingPanel && playing && !suppressMiniOnCollapse
        let apply = {
            self.state.isExpanded = expanded
            if leavingPanel {
                self.state.showMini = keepMini
                // Set here rather than after the transaction: the pill's height
                // comes from this, so outside the animation it snapped 84 → 38pt.
                if keepMini { self.state.miniStyle = .compact }
            }
        }
        if animated {
            // No overshoot: growing past the target and settling back reads as
            // fussy. Opening is a touch slower than closing so it feels led.
            let animation: Animation = expanded
                ? .smooth(duration: 0.34)
                : .smooth(duration: 0.26)
            withAnimation(animation, apply)
        } else {
            apply()
        }
        if leavingPanel {
            if keepMini {
                notchDebug("back to compact mini for \(Int(miniAfterHover))s")
                armMiniTimeout(seconds: miniAfterHover)
            } else {
                miniTimer?.invalidate()
                miniTimer = nil
            }
            suppressMiniOnCollapse = false
        }
        syncVisualizer()
    }

    // The notch lives on the built-in display, so target that one — not
    // NSScreen.main, which follows keyboard focus onto external monitors.
    private var notchScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    func reposition() {
        guard let screen = notchScreen else { return }
        state.metrics = NotchMetrics.read(from: screen)

        let f = screen.frame
        let x = f.midX - state.windowWidth / 2
        // Align window top with the very top of the screen. NotchPanel refuses
        // AppKit's attempt to push it below the menu bar, so this sticks.
        let y = f.maxY - state.maxHeight
        panel.setFrame(NSRect(x: x, y: y, width: state.windowWidth, height: state.maxHeight),
                       display: true)
    }




}
