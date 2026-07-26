import AppKit
import ApplicationServices
import SwiftUI
import Combine

// Now-playing snapshot pulled from Apple Music / Spotify via AppleScript.
struct NowPlaying: Equatable {
    var app: String = ""        // "Music", "Spotify" or a browser name
    var title: String = ""
    var artist: String = ""
    var isPlaying: Bool = false
    var artKey: String = ""     // remote URL or local file path for the cover
    var position: Double = 0    // seconds played
    var duration: Double = 0    // seconds total; 0 when unknown (live, ads)

    // Stable-ish identity used to detect track changes.
    var trackID: String { "\(app)|\(title)|\(artist)" }

    static let empty = NowPlaying()
}

// The waveform updates many times a second. Publishing that through
// MediaController would re-render the whole panel each time, so it gets its own
// tiny observable and only the meter listens to it.
final class LevelFeed: ObservableObject {
    @Published var levels: [Double] = []
}

// NOTE: macOS 15.4+ blocks third-party access to the private MediaRemote
// framework, so we drive the two most common players over AppleScript.
// The first run triggers an Automation permission prompt per app.
final class MediaController: ObservableObject {
    @Published private(set) var nowPlaying: NowPlaying = .empty
    @Published private(set) var artwork: NSImage?
    // Derived from the artwork once per track and reused by the meter and the
    // progress bars, so the panel picks up the mood of what's playing.
    @Published private(set) var accent: Color = .white
    // When `position` was sampled, so the UI can advance it smoothly between
    // the two-second polls instead of jumping.
    private(set) var positionSampledAt = Date()

    private var timer: Timer?

    // Why the transport controls can't work, when they can't. Both of these fail
    // silently otherwise: the buttons simply do nothing and the meter quietly
    // falls back to a decorative animation, with no way to tell from the UI.
    enum Blocker: Equatable {
        case browserJavaScriptOff(String)   // the browser's Apple Events JS toggle
        case automationDenied(String)       // macOS Automation permission
    }
    @Published private(set) var blocker: Blocker?

    // Spectrum bands, 0...1. Empty means the page wouldn't give us data, and the
    // meter falls back to a decorative animation.
    static let bandCount = 4
    // Each sample is an Apple Event round trip to the browser, so these rates are
    // a smoothness/cost trade. Measured on this machine: ~2% CPU idle, ~12% while
    // the meter is running. Lowering them further was tried and barely moved the
    // number, so they're set for how the meter looks rather than to save CPU.
    private static let fetchInterval = 0.3
    private static let playFPS = 15.0
    let levelFeed = LevelFeed()
    private var levels: [Double] {
        get { levelFeed.levels }
        set { levelFeed.levels = newValue }
    }

    // Each sample costs an Apple Event round trip, so only run while the meter is
    // actually on screen.
    var wantsLevels = false {
        didSet {
            guard wantsLevels != oldValue else { return }
            wantsLevels ? startLevelPolling() : stopLevelPolling()
        }
    }
    private var levelTimer: Timer?
    private var displayTimer: Timer?
    private var frameQueue: [[Double]] = []
    private var fetchBusy = false
    private var underrunTicks = 0

    // Drives the mini presentation. Music/Spotify report play state honestly, so
    // a paused track still counts; for a browser tab, "playing" is inferred from
    // the page, and a silent tab shouldn't sit in the notch forever.
    var isActive: Bool {
        guard !nowPlaying.title.isEmpty else { return false }
        return isBrowser(nowPlaying.app) ? nowPlaying.isPlaying : true
    }

    func start() {
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        stopLevelPolling()
    }

    // MARK: Spectrum

    private func startLevelPolling() {
        levelTimer?.invalidate()
        displayTimer?.invalidate()

        // Deliberately one rate for both the mini and the open panel: switching
        // rates meant tearing down and restarting both timers at the exact moment
        // the panel animated open, which showed up as the meter hitching.
        let fetchInterval = Self.fetchInterval
        let fetch = Timer(timeInterval: fetchInterval, repeats: true) { [weak self] _ in
            self?.sampleLevels()
        }
        RunLoop.main.add(fetch, forMode: .common)
        levelTimer = fetch

        // Replay the buffered frames in order rather than showing one stale
        // sample per fetch — that's what makes beats actually land.
        let playInterval = 1.0 / Self.playFPS
        let play = Timer(timeInterval: playInterval, repeats: true) { [weak self] _ in
            self?.advanceFrame()
        }
        RunLoop.main.add(play, forMode: .common)
        displayTimer = play

        sampleLevels()
    }

    private func stopLevelPolling() {
        levelTimer?.invalidate()
        levelTimer = nil
        displayTimer?.invalidate()
        displayTimer = nil
        frameQueue.removeAll()
        if !levels.isEmpty { levels = [] }
    }

    private func advanceFrame() {
        if !frameQueue.isEmpty {
            levels = frameQueue.removeFirst()
            underrunTicks = 0
            return
        }
        guard !levels.isEmpty else { return }
        // The queue runs dry for a moment whenever a fetch lands late. Decaying
        // straight away made the bars sag and then snap back — read as a stutter,
        // most visibly right after opening the panel. Hold first, then ease down
        // only if the data really has stopped coming.
        underrunTicks += 1
        if underrunTicks > 3 {
            levels = levels.map { $0 * 0.88 }
        }
    }

    private func sampleLevels() {
        let app = nowPlaying.app
        guard isBrowser(app), nowPlaying.isPlaying else {
            frameQueue.removeAll()
            if !levels.isEmpty { levels = [] }
            return
        }
        // One fetch in flight at a time — piling them up only adds latency.
        guard !fetchBusy else { return }
        fetchBusy = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let raw = self.browserJSValue(JS.levels, browser: app) ?? ""
            let frames = Self.decodeLevels(raw)

            DispatchQueue.main.async {
                self.fetchBusy = false
                guard self.wantsLevels else { return }
                let live = !frames.isEmpty
                if live == self.levels.isEmpty {
                    notchDebug("levels \(live ? "live" : "unavailable — using decorative")")
                }
                if live {
                    // Only keep what can actually be played before the next fetch
                    // replaces it — a deeper queue just means showing older frames,
                    // i.e. a meter that visibly trails the audio.
                    let playable = Int(Self.fetchInterval * Self.playFPS) + 1
                    self.frameQueue = Array(frames.suffix(playable))
                } else {
                    self.frameQueue.removeAll()
                    self.levels = []
                }
            }
        }
    }

    private static func decodeLevels(_ text: String) -> [[Double]] {
        text.components(separatedBy: ";").compactMap { frame in
            let bands = frame.components(separatedBy: ",")
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                .map { min(max($0 / 99, 0), 1) }
            return bands.count == bandCount ? bands : nil
        }
    }

    // Browsers we try to read YouTube / web media from.
    private let browsers = ["Google Chrome", "Cốc Cốc", "Microsoft Edge", "Brave Browser", "Arc", "Safari"]
    // Scriptable desktop players, tried in order after Music and Spotify.
    private let desktopPlayers = ["VLC", "QuickTime Player"]

    // Sites we recognise as "something is playing here". Kept in one place because
    // it has to match in five different AppleScripts.
    private static let mediaHosts = [
        "youtube.com/watch", "music.youtube", "soundcloud.com",
        "music.apple.com", "open.spotify.com", "bandcamp.com",
        "vimeo.com", "twitch.tv", "nhaccuatui", "zingmp3"
    ]
    // As an AppleScript condition over the variable `u`.
    private static var urlCondition: String {
        mediaHosts.map { "u contains \"\($0)\"" }.joined(separator: " or ")
    }
    // As a JavaScript condition over location.href.
    private static var hrefCondition: String {
        mediaHosts.map { "h.indexOf('\($0)')>=0" }.joined(separator: "||")
    }
    private func isBrowser(_ app: String) -> Bool { browsers.contains(app) }

    // MARK: Playback commands

    // JavaScript run in the page itself. This only needs the Automation
    // permission we already hold — media keys, by contrast, require
    // Accessibility, whose grant breaks on every rebuild.
    private enum JS {
        // Real spectrum data, via an analyser tapped onto the page's <video>. The
        // source is reconnected to ctx.destination in the same statement so audio
        // keeps flowing — a MediaElementSource steals the output otherwise.
        //
        // The sampling loop hangs off a ScriptProcessorNode, i.e. the audio
        // thread: requestAnimationFrame is throttled to a stop while the tab sits
        // in the background, which is exactly when music usually plays. Frames are
        // buffered so one fetch returns everything since the last, and the app
        // replays them in order instead of showing a single stale sample.
        static let levels = """
        (function(){try{\
        var v=document.querySelector('video');if(!v)return '';\
        var N=4,VER=12,S=window.__notchViz;\
        if(!S||S.el!==v||S.ver!==VER){\
        var AC=window.AudioContext||window.webkitAudioContext;if(!AC)return '';\
        var ctx=(S&&S.ctx)||new AC();var src;\
        if(S&&S.raf){try{cancelAnimationFrame(S.raf)}catch(e){}}\
        if(S&&S.sp){try{S.sp.onaudioprocess=null;S.sp.disconnect()}catch(e){}}\
        if(S&&S.an){try{S.an.disconnect()}catch(e){}}\
        try{src=ctx.createMediaElementSource(v)}catch(e){if(S&&S.src){src=S.src}else{return ''}}\
        var an=ctx.createAnalyser();an.fftSize=256;an.smoothingTimeConstant=0.25;\
        an.minDecibels=-68;an.maxDecibels=-20;\
        src.connect(an);an.connect(ctx.destination);\
        S=window.__notchViz={ver:VER,el:v,ctx:ctx,src:src,an:an,sp:null,\
        data:new Uint8Array(an.frequencyBinCount),\
        raw:new Array(N).fill(0),disp:new Array(N).fill(0),peak:new Array(N).fill(40),frames:[],raf:0};\
        S.step=function(){try{\
        S.an.getByteFrequencyData(S.data);var d=S.data,n=d.length;\
        var top=Math.floor(n*0.7),cur=1;\
        for(var b=0;b<N;b++){\
        var hi=Math.min(top,Math.max(cur+1,Math.round(Math.pow(top,(b+1)/N))));\
        var sum=0,c=0;for(var i=cur;i<hi;i++){sum+=d[i];c++}cur=hi;\
        S.raw[b]=(c?sum/c:0)*(1+b*0.45)}\
        var f=[];for(var k=0;k<N;k++){\
        var r=S.raw[k],pk=S.peak[k];\
        S.peak[k]=r>pk?pk+(r-pk)*0.15:Math.max(30,pk*0.9997);\
        var t=Math.min(1,Math.max(0,(r-8)/Math.max(10,S.peak[k]-8)));\
        t=Math.pow(t,1.8);\
        var p=S.disp[k];S.disp[k]=p+(t-p)*(t>p?0.55:0.18);\
        f.push(Math.round(S.disp[k]*99))}\
        if(S.frames.length>24){S.frames.shift()}\
        S.frames.push(f.join(','))}catch(e){}};\
        try{if(ctx.createScriptProcessor){\
        var sp=ctx.createScriptProcessor(2048,1,1);\
        sp.onaudioprocess=function(){S.step()};\
        src.connect(sp);sp.connect(ctx.destination);S.sp=sp}}catch(e){}\
        if(!S.sp){var loop=function(){S.step();S.raf=requestAnimationFrame(loop)};loop()}}\
        if(S.ctx.state==='suspended'){S.ctx.resume()}\
        if(!S.frames.length){S.step()}\
        var out=S.frames.join(';');S.frames=[];return out\
        }catch(e){return ''}})()
        """

        static let playPause = "var v=document.querySelector('video'); if(v){ if(v.paused){v.play()}else{v.pause()} }"
        static let next = "var b=document.querySelector('.ytp-next-button'); if(b){b.click()}"
        static let previous = """
        var b=document.querySelector('.ytp-prev-button'); \
        if(b){b.click()}else{var v=document.querySelector('video'); if(v){v.currentTime=0}}
        """
    }

    // A command is in flight. The UI refuses further presses until the player
    // confirms the new state — free-clicking otherwise desyncs the icon.
    @Published private(set) var isBusy = false
    private(set) var expectedPlaying: Bool?
    private var expectsTrackChange = false
    private var busyDeadline = Date.distantPast

    // Which way the current track change went, so the UI can slide the artwork
    // and title in from the matching side.
    enum Direction { case forward, backward }
    @Published private(set) var direction: Direction = .forward
    // Set when *we* ask for a skip, and consumed by the track change it causes.
    // A change we didn't ask for — next/prev pressed in the browser itself, or
    // autoplay rolling on — is always treated as going forward, rather than
    // inheriting the direction of whatever button was pressed last.
    private var requestedDirection: Direction?

    func playPause() {
        guard !isBusy else { return }
        beginCommand(expectPlaying: !nowPlaying.isPlaying, expectTrackChange: false)
        transport(name: "playPause", js: JS.playPause, key: 16, verb: "playpause")
    }

    func next() {
        guard !isBusy else { return }
        requestedDirection = .forward
        beginCommand(expectPlaying: nil, expectTrackChange: true)
        transport(name: "next", js: JS.next, key: 17, verb: "next track")
    }

    func previous() {
        guard !isBusy else { return }
        requestedDirection = .backward
        beginCommand(expectPlaying: nil, expectTrackChange: true)
        transport(name: "previous", js: JS.previous, key: 18, verb: "previous track")
    }

    private func beginCommand(expectPlaying: Bool?, expectTrackChange: Bool) {
        isBusy = true
        expectedPlaying = expectPlaying
        expectsTrackChange = expectTrackChange
        busyDeadline = Date().addingTimeInterval(2.5)
    }

    // Does this reading show the pending command having taken effect?
    private func commandSatisfied(by value: NowPlaying, trackChanged: Bool) -> Bool {
        if let expected = expectedPlaying, value.isPlaying == expected { return true }
        if expectsTrackChange, trackChanged, !value.title.isEmpty { return true }
        return false
    }

    // Players pass through junk states mid-switch (title of the old video, zero
    // duration, momentarily paused). Holding the previous snapshot until the
    // command lands keeps the UI from flickering through all of it.
    private func shouldHoldSnapshot(for value: NowPlaying, trackChanged: Bool) -> Bool {
        isBusy && !commandSatisfied(by: value, trackChanged: trackChanged) && Date() <= busyDeadline
    }

    // Called from the poll: has the pending command actually landed?
    private func settleCommand(with value: NowPlaying, trackChanged: Bool) {
        guard isBusy else { return }
        var done = commandSatisfied(by: value, trackChanged: trackChanged)
        if Date() > busyDeadline {
            done = true
            notchDebug("cmd gave up waiting for confirmation")
        }
        guard done else { return }
        // A skip that never produced a new track (YouTube's back button just
        // rewinds when there's no playlist) would otherwise leave the requested
        // direction dangling for some later, unrelated change to pick up.
        if !trackChanged { requestedDirection = nil }
        isBusy = false
        expectedPlaying = nil
        expectsTrackChange = false
    }

    // Bring whatever is playing to the front: the exact browser tab, or the
    // player app itself.
    func revealSource() {
        let app = nowPlaying.app
        guard !app.isEmpty else { return }
        notchDebug("reveal source \(app)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            guard self.isBrowser(app) else {
                self.run("tell application \"\(app)\" to activate")
                return
            }

            let isSafari = (app == "Safari")
            // Select the media tab, raise its window, then bring the browser up.
            let selectTab = isSafari
                ? "set current tab of w to t"
                : "set active tab index of w to i"
            let script = """
            tell application "\(app)"
                repeat with w in windows
                    set i to 0
                    repeat with t in tabs of w
                        set i to i + 1
                        set u to URL of t
                        if \(Self.urlCondition) then
                            \(selectTab)
                            set index of w to 1
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
                activate
                return ""
            end tell
            """
            if self.run(script) != "ok" {
                notchDebug("reveal: no media tab found in \(app)")
            }
        }
    }

    // VLC and QuickTime don't speak Music's vocabulary: VLC's `play` toggles, and
    // QuickTime has no toggle at all, so its state has to be read first.
    private func desktopCommandScript(_ name: String, app: String) -> String? {
        switch app {
        case "VLC":
            let verbs = ["playPause": "play", "next": "next", "previous": "previous"]
            guard let verb = verbs[name] else { return nil }
            return "tell application \"VLC\" to \(verb)"
        case "QuickTime Player":
            guard name == "playPause" else { return nil }   // no track list to skip
            return """
            tell application "QuickTime Player"
                if (count of documents) is 0 then return
                if playing of document 1 then
                    pause document 1
                else
                    play document 1
                end if
            end tell
            """
        default:
            return nil
        }
    }

    private func desktopSeekScript(_ seconds: Double, app: String) -> String? {
        switch app {
        case "VLC":
            return "tell application \"VLC\" to set current time to \(Int(seconds))"
        case "QuickTime Player":
            return "tell application \"QuickTime Player\" to set current time of document 1 to \(seconds)"
        default:
            return nil
        }
    }

    // Jump to a position, in seconds.
    func seek(to seconds: Double) {
        let app = nowPlaying.app
        let target = max(0, seconds)
        let viaBrowser = isBrowser(app)
        notchDebug("seek to \(Int(target))s app=\(app)")

        // Show the new position immediately rather than waiting for the poll.
        nowPlaying.position = target
        positionSampledAt = Date()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            if viaBrowser {
                let js = "var v=document.querySelector('video'); if(v){v.currentTime=\(target)}"
                if !self.runBrowserJS(js, browser: app) {
                    notchDebug("seek failed — browser javascript unavailable")
                }
            } else if let script = self.desktopSeekScript(target, app: app) {
                self.run(script)
            } else {
                self.run("tell application \"\(app.isEmpty ? "Spotify" : app)\" to set player position to \(target)")
            }
            self.refreshSoon()
        }
    }

    // AppleScript blocks for a moment, so keep it off the main thread.
    private func transport(name: String, js: String, key: Int32, verb: String) {
        let app = nowPlaying.app
        let viaBrowser = isBrowser(app)
        notchDebug("cmd \(name) app=\(app) browser=\(viaBrowser)")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            if viaBrowser {
                if self.runBrowserJS(js, browser: app) {
                    notchDebug("cmd \(name) via javascript")
                    DispatchQueue.main.async {
                        if case .browserJavaScriptOff = self.blocker { self.blocker = nil }
                    }
                } else {
                    DispatchQueue.main.async { self.blocker = .browserJavaScriptOff(app) }
                    // Needs "Allow JavaScript from Apple Events" in the
                    // browser's Developer menu; fall back to a media key.
                    notchDebug("cmd \(name) javascript failed → media key")
                    DispatchQueue.main.async { self.postMediaKey(key) }
                }
            } else if let script = self.desktopCommandScript(name, app: app) {
                self.run(script)
            } else {
                self.command(for: app.isEmpty ? "Spotify" : app, verb: verb)
            }
            // Poll in a burst so confirmation (and re-enabling) arrives quickly.
            for delay in [0.25, 0.6, 1.0, 1.6, 2.4] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self = self, self.isBusy else { return }
                    self.poll()
                }
            }
        }
    }

    // Debug aid: reports whether the browser will actually run our JavaScript,
    // so a dead transport button can be told apart from a blocked one.
    // Runs on a timer as well as on demand: the browser toggle can be switched off
    // at any time, and the app should stop claiming the buttons work.
    func checkBrowserControls() {
        let app = nowPlaying.app
        guard isBrowser(app), !nowPlaying.title.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let ok = self.runBrowserJS("void 0", browser: app)
            DispatchQueue.main.async {
                if ok {
                    if case .browserJavaScriptOff = self.blocker { self.blocker = nil }
                } else {
                    self.blocker = .browserJavaScriptOff(app)
                }
            }
        }
    }

    func diagnoseBrowserJS() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let app = self.nowPlaying.app
            guard self.isBrowser(app) else {
                notchDebug("diag: no browser media detected (app=\(app))")
                return
            }
            let ok = self.runBrowserJS("void 0", browser: app)
            let state = self.nowPlaying.isPlaying ? "playing" : "paused"
            notchDebug("diag: \(app) javascript-from-apple-events available=\(ok) reportedState=\(state)")
        }
    }

    // Where the media tab was last found. Walking every tab costs one Apple
    // Event per tab, which dominated the cost of each frame grab; addressing the
    // remembered tab directly turns that into a single event.
    private var cachedTab: (window: Int, tab: Int)?
    private let tabCacheLock = NSLock()

    private func rememberedTab() -> (window: Int, tab: Int)? {
        tabCacheLock.lock(); defer { tabCacheLock.unlock() }
        return cachedTab
    }

    private func remember(tab: (window: Int, tab: Int)?) {
        tabCacheLock.lock(); defer { tabCacheLock.unlock() }
        cachedTab = tab
    }

    func invalidateTabCache() { remember(tab: nil) }

    // Like runBrowserJS, but hands back whatever the script evaluated to.
    private func browserJSValue(_ js: String, browser: String) -> String? {
        if let cached = rememberedTab(),
           let value = evaluate(js, browser: browser, window: cached.window, tab: cached.tab) {
            return value
        }
        guard let found = locateMediaTab(browser: browser) else { return nil }
        remember(tab: found)
        return evaluate(js, browser: browser, window: found.window, tab: found.tab)
    }

    // Runs JS against one specific tab. The "is this still the media tab?" check
    // lives inside the JavaScript rather than in AppleScript: reading `URL of t`
    // was a separate Apple Event on every sample, and those round trips — not the
    // drawing — were the bulk of the waveform's CPU cost. Results are prefixed
    // with "1" so an empty JS result still counts as a hit.
    private func evaluate(_ js: String, browser: String, window: Int, tab: Int) -> String? {
        // Plain string checks, not a regex: no backslashes to escape twice on the
        // way through AppleScript.
        let guarded = """
        (function(){var h=location.href;\
        if(!(\(Self.hrefCondition)))return '';\
        return \(js)})()
        """
        let isSafari = (browser == "Safari")
        let escaped = guarded
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let call = isSafari
            ? "set r to (do JavaScript \"\(escaped)\" in tab \(tab) of window \(window))"
            : """
              tell tab \(tab) of window \(window)
                              set r to (execute javascript "\(escaped)")
                          end tell
              """
        let script = """
        tell application "\(browser)"
            try
                \(call)
                return "1" & (r as string)
            end try
            return ""
        end tell
        """
        guard let out = run(script), out.hasPrefix("1") else { return nil }
        let value = String(out.dropFirst())
        // Empty means the tab moved on to something else — go hunting again.
        return value.isEmpty ? nil : value
    }

    private func locateMediaTab(browser: String) -> (window: Int, tab: Int)? {
        let script = """
        tell application "\(browser)"
            set wi to 0
            repeat with w in windows
                set wi to wi + 1
                set ti to 0
                repeat with t in tabs of w
                    set ti to ti + 1
                    set u to URL of t
                    if \(Self.urlCondition) then
                        return (wi as string) & "," & (ti as string)
                    end if
                end repeat
            end repeat
            return ""
        end tell
        """
        guard let out = run(script), !out.isEmpty else { return nil }
        let parts = out.components(separatedBy: ",")
        guard parts.count == 2, let w = Int(parts[0]), let t = Int(parts[1]) else { return nil }
        notchDebug("located media tab: window \(w) tab \(t)")
        return (w, t)
    }

    // Runs JS in the first media tab of the given browser.
    private func runBrowserJS(_ js: String, browser: String) -> Bool {
        let isSafari = (browser == "Safari")
        let escaped = js
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let call = isSafari
            ? "do JavaScript \"\(escaped)\" in t"
            : "tell t to execute javascript \"\(escaped)\""
        let script = """
        tell application "\(browser)"
            repeat with w in windows
                repeat with t in tabs of w
                    set u to URL of t
                    if \(Self.urlCondition) then
                        \(call)
                        return "ok"
                    end if
                end repeat
            end repeat
            return ""
        end tell
        """
        return run(script) == "ok"
    }

    private var playerApp: String { nowPlaying.app.isEmpty ? "Spotify" : nowPlaying.app }

    private func command(for appName: String, verb: String) {
        run("tell application \"\(appName)\" to \(verb)")
    }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.poll() }
    }

    // Last-resort path: posting a media key is an accessibility-level action, so
    // it silently does nothing unless the app is trusted — and that grant is tied
    // to the code signature, so it breaks on every rebuild.
    private func postMediaKey(_ key: Int32) {
        guard AXIsProcessTrusted() else {
            notchDebug("media key skipped — app not trusted for accessibility")
            return
        }

        func send(_ down: Bool) {
            let data1 = Int((key << 16) | ((down ? 0xA : 0xB) << 8))
            let flags = NSEvent.ModifierFlags(rawValue: UInt(down ? 0xA00 : 0xB00))
            if let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero,
                                           modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: 0, context: nil,
                                           subtype: 8, data1: data1, data2: -1) {
                ev.cgEvent?.post(tap: .cghidEventTap)
            }
        }
        send(true); send(false)
    }

    // MARK: Polling

    private func poll() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            var result = self.query(app: "Music")
            if result == nil { result = self.query(app: "Spotify") }
            if result == nil { result = self.queryDesktopPlayers() }
            if result == nil { result = self.queryBrowsers() }
            let value = result ?? .empty
            DispatchQueue.main.async {
                let trackChanged = self.nowPlaying.trackID != value.trackID
                let stateChanged = self.nowPlaying.isPlaying != value.isPlaying

                // Freeze the display through a command's transitional states.
                if self.shouldHoldSnapshot(for: value, trackChanged: trackChanged) { return }
                self.settleCommand(with: value, trackChanged: trackChanged)
                if trackChanged {
                    let source = self.requestedDirection == nil ? "external" : "our button"
                    self.direction = self.requestedDirection ?? .forward
                    self.requestedDirection = nil
                    notchDebug("track changed → slide \(self.direction) (\(source))")
                }
                if self.nowPlaying != value {
                    self.nowPlaying = value
                    self.positionSampledAt = Date()
                    // Position moves every poll; only log the interesting changes.
                    if trackChanged || stateChanged {
                        notchDebug("now=\(value.app) playing=\(value.isPlaying) active=\(self.isActive) dur=\(Int(value.duration))s title=\(value.title.prefix(30))")
                    }
                }
                guard trackChanged else { return }
                // The media might now be in a different tab.
                self.invalidateTabCache()
                // New track → drop the old cover and fetch the new one.
                self.artwork = nil
                self.accent = .white
                let key = value.artKey
                guard !key.isEmpty else { return }
                ArtworkStore.shared.load(key: key) { [weak self] image in
                    // Ignore a late arrival for a track we've already left.
                    guard let self = self, self.nowPlaying.artKey == key else { return }
                    self.artwork = image
                    self.accent = image.map { Color(nsColor: $0.accentColor) } ?? .white
                    notchDebug("art key=\(key) loaded=\(image != nil) size=\(image?.size ?? .zero)")
                }
            }
        }
    }

    // Returns nil if the app isn't running / nothing is playing.
    private func query(app: String) -> NowPlaying? {
        // Only talk to the app if it is already running (avoids launching it).
        let running = NSWorkspace.shared.runningApplications.contains {
            $0.localizedName == app || $0.bundleIdentifier == bundleID(for: app)
        }
        guard running else { return nil }

        // Spotify exposes a cover URL directly; Music needs a separate dump.
        let artLine = (app == "Spotify")
            ? "set u to artwork url of current track"
            : "set u to \"\""
        let script = """
        tell application "\(app)"
            if player state is playing or player state is paused then
                set t to name of current track
                set a to artist of current track
                set p to (player state is playing)
                try
                    \(artLine)
                on error
                    set u to ""
                end try
                set pos to 0
                try
                    set pos to player position
                end try
                set dur to 0
                try
                    set dur to duration of current track
                end try
                return (t as string) & "\\n" & (a as string) & "\\n" & (p as string) & "\\n" & (u as string) & "\\n" & (pos as string) & "\\n" & (dur as string)
            else
                return ""
            end if
        end tell
        """
        guard let output = run(script), !output.isEmpty else { return nil }
        let parts = output.components(separatedBy: "\n")
        guard parts.count >= 3 else { return nil }

        // Spotify reports track length in milliseconds; Music in seconds.
        let rawDuration = parts.count >= 6 ? Double(parts[5]) ?? 0 : 0
        let duration = (app == "Spotify") ? rawDuration / 1000 : rawDuration

        var info = NowPlaying(app: app,
                              title: parts[0],
                              artist: parts[1],
                              isPlaying: parts[2].contains("true"),
                              artKey: parts.count >= 4 ? parts[3] : "",
                              position: parts.count >= 5 ? Double(parts[4]) ?? 0 : 0,
                              duration: duration)
        if app == "Music", info.artKey.isEmpty {
            info.artKey = musicArtworkPath(trackKey: info.trackID) ?? ""
        }
        return info
    }

    // Music has no artwork URL, so ask AppleScript to write the raw image data
    // into a temp file and read that. Cached per track.
    private func musicArtworkPath(trackKey: String) -> String? {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("NotchMVP-art")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = (dir as NSString).appendingPathComponent("\(abs(trackKey.hashValue)).dat")
        if FileManager.default.fileExists(atPath: path) { return path }

        let script = """
        tell application "Music"
            try
                set d to raw data of artwork 1 of current track
            on error
                return ""
            end try
        end tell
        try
            set f to open for access (POSIX file "\(path)") with write permission
            set eof f to 0
            write d to f
            close access f
        on error
            try
                close access (POSIX file "\(path)")
            end try
            return ""
        end try
        return "\(path)"
        """
        guard let out = run(script), !out.isEmpty else { return nil }
        return out
    }

    // VLC and QuickTime Player speak just enough AppleScript to report a title and
    // whether they're playing. Neither exposes artwork, so those fall back to the
    // placeholder, and neither can be tapped for a spectrum.
    private func queryDesktopPlayers() -> NowPlaying? {
        for app in desktopPlayers {
            let running = NSWorkspace.shared.runningApplications.contains { $0.localizedName == app }
            guard running else { continue }

            let script: String
            if app == "VLC" {
                script = """
                tell application "VLC"
                    if not (exists current item) then return ""
                    set t to name of current item
                    set p to playing
                    set pos to 0
                    try
                        set pos to current time
                    end try
                    set dur to 0
                    try
                        set dur to duration of current item
                    end try
                    return (t as string) & "\\n" & (p as string) & "\\n" & (pos as string) & "\\n" & (dur as string)
                end tell
                """
            } else {
                script = """
                tell application "QuickTime Player"
                    if (count of documents) is 0 then return ""
                    set d to document 1
                    set t to name of d
                    set p to (playing of d)
                    return (t as string) & "\\n" & (p as string) & "\\n" & ((current time of d) as string) & "\\n" & ((duration of d) as string)
                end tell
                """
            }

            guard let out = run(script), !out.isEmpty else { continue }
            let parts = out.components(separatedBy: "\n")
            guard parts.count >= 2, !parts[0].isEmpty else { continue }
            return NowPlaying(app: app,
                              title: parts[0],
                              artist: app,
                              isPlaying: parts[1].contains("true"),
                              artKey: "",
                              position: parts.count >= 3 ? Double(parts[2]) ?? 0 : 0,
                              duration: parts.count >= 4 ? Double(parts[3]) ?? 0 : 0)
        }
        return nil
    }

    // Best-effort web media detection: find a YouTube/SoundCloud tab in any
    // running browser and show its title. We can't tell play/paused state or
    // read exact track metadata this way, so isPlaying is assumed true.
    private func queryBrowsers() -> NowPlaying? {
        for browser in browsers {
            let running = NSWorkspace.shared.runningApplications.contains { $0.localizedName == browser }
            guard running else { continue }

            // Reading the remembered tab directly is one Apple Event; hunting for
            // it costs one per tab, which dominated this poll.
            if let cached = rememberedTab(),
               let payload = readMediaTab(browser: browser, window: cached.window, tab: cached.tab),
               let info = makeNowPlaying(from: payload, browser: browser) {
                return info
            }
            guard let found = locateMediaTab(browser: browser),
                  let payload = readMediaTab(browser: browser, window: found.window, tab: found.tab),
                  let info = makeNowPlaying(from: payload, browser: browser) else { continue }
            remember(tab: found)
            return info
        }
        return nil
    }

    // Title, URL and playback state of one specific tab. Returns nil when that
    // tab is no longer the media tab, so the caller can go hunting again.
    private func readMediaTab(browser: String, window: Int, tab: Int) -> String? {
        let isSafari = (browser == "Safari")
        let titleProp = isSafari ? "name" : "title"
        // Ask the page itself whether it is paused. CoreAudio can't answer this:
        // browsers keep the output stream running while paused, so it reports
        // "playing" forever. Returns "playing|12.5|301.2".
        let stateJS = "(function(){var v=document.querySelector('video');if(!v)return 'none';var d=isFinite(v.duration)?v.duration:0;return (v.paused?'paused':'playing')+'|'+v.currentTime+'|'+d;})()"
        let readState = isSafari
            ? "set s to (do JavaScript \"\(stateJS)\" in t)"
            : """
              tell t
                              set s to (execute javascript "\(stateJS)")
                          end tell
              """
        let script = """
        tell application "\(browser)"
            try
                set t to tab \(tab) of window \(window)
                set u to URL of t
                if \(Self.urlCondition) then
                    set s to "unknown"
                    try
                        \(readState)
                    end try
                    return (\(titleProp) of t as string) & "\\n" & (u as string) & "\\n" & (s as string)
                end if
            end try
            return ""
        end tell
        """
        guard let raw = run(script), !raw.isEmpty else { return nil }
        return raw
    }

    private func makeNowPlaying(from payload: String, browser: String) -> NowPlaying? {
        let lines = payload.components(separatedBy: "\n")
        let title = cleanBrowserTitle(lines[0])
        guard !title.isEmpty else { return nil }
        let url = lines.count >= 2 ? lines[1] : ""
        // "playing|12.5|301.2" — or "unknown"/"none" when JS is unavailable.
        let fields = (lines.count >= 3 ? lines[2] : "unknown").components(separatedBy: "|")
        let pageState = fields[0]

        let playing: Bool
        switch pageState {
        case "playing": playing = true
        case "paused": playing = false
        // The browser won't run our JavaScript, so fall back to whether the
        // output device is making sound at all.
        default: playing = AudioActivity.isOutputActive
        }

        return NowPlaying(app: browser,
                          title: title,
                          artist: "YouTube",
                          isPlaying: playing,
                          artKey: youtubeThumbURL(from: url),
                          position: fields.count >= 2 ? Double(fields[1]) ?? 0 : 0,
                          duration: fields.count >= 3 ? Double(fields[2]) ?? 0 : 0)
    }

    // YouTube covers come straight off the thumbnail CDN, keyed by video id.
    private func youtubeThumbURL(from pageURL: String) -> String {
        guard let comps = URLComponents(string: pageURL) else { return "" }
        if let id = comps.queryItems?.first(where: { $0.name == "v" })?.value, !id.isEmpty {
            return "https://i.ytimg.com/vi/\(id)/mqdefault.jpg"
        }
        return ""
    }

    // "(3) Song Name - YouTube" -> "Song Name"
    private func cleanBrowserTitle(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: #"^\(\d+\)\s*"#, options: .regularExpression) {
            s.removeSubrange(r)
        }
        for suffix in [" - YouTube", " - YouTube Music", " | SoundCloud"] {
            if s.hasSuffix(suffix) { s = String(s.dropLast(suffix.count)) }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func bundleID(for app: String) -> String {
        switch app {
        case "Music": return "com.apple.Music"
        case "Spotify": return "com.spotify.client"
        default: return ""
        }
    }

    private let scriptLock = NSLock()
    private var compiledScripts: [String: NSAppleScript] = [:]

    @discardableResult
    private func run(_ source: String) -> String? {
        scriptLock.lock()
        defer { scriptLock.unlock() }
        var error: NSDictionary?

        // The fetch loop sends the same source many times a second, and building
        // an NSAppleScript recompiles it every time — expensive enough to show up
        // as CPU. Keep the compiled scripts around instead.
        let script: NSAppleScript
        if let cached = compiledScripts[source] {
            script = cached
        } else {
            guard let fresh = NSAppleScript(source: source) else { return nil }
            fresh.compileAndReturnError(nil)
            if compiledScripts.count > 12 { compiledScripts.removeAll() }
            compiledScripts[source] = fresh
            script = fresh
        }

        let descriptor = script.executeAndReturnError(&error)
        if let error = error {
            // -1743 == user hasn't granted Automation permission yet.
            if let code = error[NSAppleScript.errorNumber] as? Int, code == -1743 {
                notchDebug("automation denied (-1743)")
                let app = nowPlaying.app.isEmpty ? "trình phát" : nowPlaying.app
                DispatchQueue.main.async { self.blocker = .automationDenied(app) }
            }
            return nil
        }
        return descriptor.stringValue
    }
}
