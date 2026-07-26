import SwiftUI
import UniformTypeIdentifiers

// The panel silhouette: rounded chin, and at the top two concave flares that
// spread outwards into the screen edge — tangent to the edge above and to the
// side wall below, so the black reads as flowing out of the notch rather than
// being a box stuck under it. The flares are drawn outside `rect`, so the
// hosting window must be wider than the panel by `topFlare` on each side.
struct NotchPanelShape: Shape {
    var topFlare: CGFloat
    var bottomRadius: CGFloat

    // Without this a Shape's parameters snap: the chin radius differs between the
    // two pill styles, so it has to interpolate along with the height.
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topFlare, bottomRadius) }
        set {
            topFlare = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let rt = max(0, topFlare)
        let rb = max(0, min(bottomRadius, min(rect.width / 2, rect.height - rt)))

        p.move(to: CGPoint(x: rect.minX - rt, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + rt),
                       control: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - rb))
        p.addQuadCurve(to: CGPoint(x: rect.minX + rb, y: rect.maxY),
                       control: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - rb, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - rb),
                       control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rt))
        p.addQuadCurve(to: CGPoint(x: rect.maxX + rt, y: rect.minY),
                       control: CGPoint(x: rect.maxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

struct NotchRootView: View {
    @ObservedObject var state: NotchState
    @ObservedObject var media: MediaController

    init(state: NotchState) {
        self.state = state
        self.media = state.media
    }

    private var expanded: Bool { state.isExpanded }
    private var isVisible: Bool { expanded || state.showMini }

    // One black shape for both states: animating its size between the mini pill
    // and the full panel is what produces the grow-out-of-the-notch motion. When
    // the mini is dismissed the shape retracts to exactly the notch width, so
    // the art and waveform appear to slide back in behind the notch.
    private var shapeWidth: CGFloat {
        if expanded { return state.maxWidth }
        return state.showMini ? state.miniWidth : state.metrics.notchWidth
    }
    private var shapeHeight: CGFloat {
        if expanded { return state.maxHeight }
        return state.showMini ? state.miniVisibleHeight : state.metrics.notchHeight
    }

    private var panelShape: NotchPanelShape {
        let chin: CGFloat = expanded ? 24
            : (state.showMini && state.miniStyle == .full ? 16 : 13)
        return NotchPanelShape(topFlare: state.topFlare, bottomRadius: chin)
    }

    var body: some View {
        ZStack(alignment: .top) {
            panelShape
                .fill(Color.black)
                .frame(width: shapeWidth, height: shapeHeight)
                .overlay(alignment: .top) { content }
                // Clipping is what makes the mini read as sliding out sideways:
                // art and waveform sit outside the notch-wide shape and are
                // revealed as it widens, rather than growing from the bottom.
                .clipShape(panelShape)
                .opacity(isVisible ? 1 : 0)
        }
        .frame(width: state.windowWidth, height: state.maxHeight, alignment: .top)
        // Draw right up to the screen edge — don't let the notch safe area
        // push the panel down below the notch.
        .ignoresSafeArea(.all)
    }

    // Both layers stay in the tree and scale together with the background, so
    // the content grows with the panel instead of popping in at full size.
    private var content: some View {
        ZStack(alignment: .top) {
            // Only visible in the mini state. Tying this to showMini too matters:
            // hovering straight from hidden used to fade the mini content out
            // over the opening panel, which flashed the pill for an instant.
            miniRow
                .opacity(state.showMini && !expanded ? 1 : 0)
                .scaleEffect(expanded ? 1.35 : 1, anchor: .top)

            expandedContent
                .opacity(expanded ? 1 : 0)
                .scaleEffect(expanded ? 1 : 0.72, anchor: .top)
        }
    }

    private var expandedContent: some View {
        VStack(spacing: 0) {
            ExpandedContent(state: state, media: media)
                .frame(height: state.baseHeight - state.metrics.notchHeight - 8 - 18)

            if let blocker = media.blocker {
                BlockerNotice(blocker: blocker)
                    .padding(.top, 6)
                    .transition(.opacity)
            }

            if !state.shelfItems.isEmpty {
                ShelfRow(state: state)
                    .frame(height: state.shelfHeight - 12)
                    .padding(.top, 12)
            }
        }
        .padding(.horizontal, 24)
        // Content starts below the physical notch so nothing hides behind it.
        .padding(.top, state.metrics.notchHeight + 8)
        .padding(.bottom, 18)
        .frame(width: state.maxWidth, height: state.maxHeight, alignment: .top)
        // The whole panel takes drops, not just the shelf strip — aiming at a
        // 74pt row while dragging would be fussy.
        // Files, images and text all land here; the last two get written to disk
        // first so everything on the shelf behaves the same way.
        .onDrop(of: [.fileURL, .image, .png, .tiff, .utf8PlainText, .plainText],
                isTargeted: dropTargetBinding) { providers in
            receive(providers)
        }
        .overlay(alignment: .bottom) { dropHint }
    }

    private var dropTargetBinding: Binding<Bool> {
        Binding(get: { state.dropTargeted }, set: { state.dropTargeted = $0 })
    }

    @ViewBuilder private var dropHint: some View {
        if state.dropTargeted {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .overlay(
                    Text(state.shelfItems.isEmpty ? "Thả file để lưu tạm" : "Thêm vào shelf")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                )
                .padding(.horizontal, 20)
                .padding(.top, state.metrics.notchHeight + 6)
                .padding(.bottom, 12)
                .transition(.opacity)
                .animation(.smooth(duration: 0.18), value: state.dropTargeted)
        }
    }

    private func receive(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            // A real file wins over any other representation the drag carries — a
            // Finder drag also offers an icon image, and saving that would be wrong.
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                load(provider, UTType.fileURL) { data in
                    URL(dataRepresentation: data, relativeTo: nil)
                }
                continue
            }
            for type in [UTType.png, .tiff, .image] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
                handled = true
                load(provider, type) { ShelfScratch.writeImage($0) }
                break
            }
            for type in [UTType.utf8PlainText, .plainText] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
                handled = true
                load(provider, type) { data in
                    guard let text = String(data: data, encoding: .utf8) else { return nil }
                    return ShelfScratch.writeText(text)
                }
                break
            }
        }
        return handled
    }

    private func load(_ provider: NSItemProvider,
                      _ type: UTType,
                      convert: @escaping (Data) -> URL?) {
        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            guard let data = data, let url = convert(data) else { return }
            DispatchQueue.main.async { state.addToShelf([url]) }
        }
    }

    // MARK: Mini

    // Tucked behind the notch while hidden, so showing the mini slides the two
    // pieces outwards from under it.
    private var miniTuck: CGFloat { isVisible && !expanded ? 0 : state.miniSide }

    private var miniRow: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    ZStack {
                        CoverArt(image: media.artwork, size: 26, radius: 7)
                            .id(media.nowPlaying.trackID)   // re-animate on track change
                            .transition(
                                .asymmetric(
                                    insertion: .offset(x: media.direction == .forward ? 14 : -14)
                                        .combined(with: .opacity),
                                    removal: .offset(x: media.direction == .forward ? -14 : 14)
                                        .combined(with: .opacity)
                                )
                            )
                    }
                    .frame(width: 26, height: 26)
                    .clipped()
                    .animation(.smooth(duration: 0.35), value: media.nowPlaying.trackID)
                    // 8pt each side of a 42pt wing, so the art sits centred in it.
                    .padding(.trailing, 8)
                }
                .frame(width: state.miniSide)
                .offset(x: miniTuck)

                // The physical notch sits here, so nothing can be drawn in it.
                Color.clear.frame(width: state.metrics.notchWidth)

                HStack(spacing: 0) {
                    // Removed from the tree, not just hidden: an off-screen meter still
                    // re-renders on every level update, and there are two of them.
                    if !expanded, state.showsWave {
                        WaveBars(isPlaying: media.nowPlaying.isPlaying && isVisible,
                                 feed: media.levelFeed,
                                 tint: media.accent,
                                 animateFallback: false,
                                 maxHeight: 15)
                            // The 21pt meter centred in the same 42pt wing.
                            .padding(.leading, 10.5)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: state.miniSide)
                .offset(x: -miniTuck)
            }
            .frame(height: state.metrics.notchHeight)

            // Below the notch there's finally room for words — but only the full
            // style has that room.
            if state.miniStyle == .full {
                VStack(spacing: 5) {
                    Text(media.nowPlaying.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: state.miniWidth - 30)

                    if media.nowPlaying.duration > 0 {
                        MiniProgress(position: media.nowPlaying.position,
                                     duration: media.nowPlaying.duration,
                                     width: state.miniWidth - 30,
                                     tint: media.accent)
                    }
                }
                .frame(height: state.miniInfoHeight, alignment: .center)
                .opacity(state.showMini ? 1 : 0)
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
            }
        }
        .frame(width: state.miniWidth, height: state.miniVisibleHeight)
    }
}

// Says out loud why the transport buttons can't do anything. Both causes are
// silent by nature — the buttons just don't respond — so without this the only
// way to find out is to read the debug log.
struct BlockerNotice: View {
    let blocker: MediaController.Blocker

    private var message: String {
        switch blocker {
        case .browserJavaScriptOff(let app):
            return "Bật \(app) → View → Developer → Allow JavaScript from Apple Events để dùng nút điều khiển"
        case .automationDenied(let app):
            return "Cấp quyền điều khiển \(app) trong System Settings → Privacy & Security → Automation"
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(Color.yellow.opacity(0.9))
            Text(message)
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.yellow.opacity(0.12))
        )
    }
}

// Shared so the mini strip and the panel's scrub bar can't format time
// differently.
func clockLabel(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded())
    let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, secs)
        : String(format: "%d:%02d", minutes, secs)
}

// A hairline of progress under the mini title. No interpolation: the pill is only
// up for a few seconds, so the two-second poll is plenty and it costs nothing to
// draw.
struct MiniProgress: View {
    let position: Double
    let duration: Double
    let width: CGFloat
    var tint: Color = .white

    private let labelWidth: CGFloat = 32

    var body: some View {
        let clamped = duration > 0 ? min(max(position / duration, 0), 1) : 0
        let barWidth = width - labelWidth * 2 - 12
        HStack(spacing: 6) {
            Text(clockLabel(position))
                .frame(width: labelWidth, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule().fill(tint.opacity(0.9))
                    .frame(width: max(2, barWidth * clamped))
            }
            .frame(width: barWidth, height: 3)
            // Remaining, not total: "how much longer" is the thing you actually
            // want to know at a glance.
            Text("-" + clockLabel(max(0, duration - position)))
                .frame(width: labelWidth, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .medium))
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.5))
        .frame(width: width)
    }
}

// Album art with a placeholder for tracks that have none.
struct CoverArt: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.45))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// Cover art that opens whatever is playing it — the browser tab, or the player.
struct CoverArtButton: View {
    let image: NSImage?
    let size: CGFloat
    let enabled: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            CoverArt(image: image, size: size, radius: 16)
                .overlay(
                    // Hint that it's clickable, only while pointed at.
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.black.opacity(hovering ? 0.35 : 0))
                        .overlay(
                            Image(systemName: "arrow.up.forward.app.fill")
                                .font(.system(size: size * 0.22))
                                .foregroundStyle(.white.opacity(hovering ? 0.9 : 0))
                        )
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .handCursor()
        .onHover { hovering = enabled && $0 }
        .animation(.smooth(duration: 0.2), value: hovering)
    }
}

// Level meter. `feed` carries real spectrum bands read out of the page's audio
// graph; when that isn't available (no JavaScript access, or a non-browser
// player) it falls back to a decorative animation.
struct WaveBars: View {
    let isPlaying: Bool
    @ObservedObject var feed: LevelFeed
    var tint: Color = .white
    // The fallback is invented motion, so only spend frames on it while the user
    // is actually looking at the open panel.
    var animateFallback: Bool = true
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 3
    var maxHeight: CGFloat = 15

    private var levels: [Double] { feed.levels }
    private var bars: Int { MediaController.bandCount }
    private var minBar: CGFloat { max(2, barWidth) }

    var body: some View {
        if levels.count == bars {
            HStack(alignment: .center, spacing: spacing) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    Capsule()
                        .fill(tint.opacity(0.92))
                        .frame(width: barWidth, height: max(minBar, maxHeight * CGFloat(level)))
                }
            }
            .frame(height: maxHeight)
            // Frames already arrive in order; glide only far enough to look
            // continuous without smearing the transients.
            .animation(.linear(duration: 1.0 / 20.0), value: levels)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 20.0,
                                    paused: !isPlaying || !animateFallback)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                HStack(alignment: .center, spacing: spacing) {
                    ForEach(0..<bars, id: \.self) { i in
                        Capsule()
                            .fill(tint.opacity(0.92))
                            .frame(width: barWidth, height: decorativeHeight(index: i, time: t))
                    }
                }
                .frame(height: maxHeight)
            }
        }
    }

    private func decorativeHeight(index: Int, time: Double) -> CGFloat {
        guard isPlaying else { return minBar }
        // Mixed frequencies per bar so they don't move in lockstep.
        let phase = Double(index) * 1.7
        let wave = abs(sin(time * 3.2 + phase)) * 0.7 + abs(sin(time * 5.1 + phase * 0.6)) * 0.3
        return max(minBar, maxHeight * CGFloat(0.25 + 0.75 * wave))
    }
}

// Pointing-hand cursor over anything clickable.
//
// This re-applies the cursor on every mouse move inside the view rather than
// pushing it once: the notch panel is a non-activating window that never becomes
// key, and the window server resets the cursor as the pointer moves across it, so
// a single push/pop silently did nothing. Setting per move also removes any
// push/pop imbalance to worry about when the panel collapses under the pointer.
private struct HandCursor: ViewModifier {
    func body(content: Content) -> some View {
        content.onContinuousHover { phase in
            switch phase {
            case .active: NSCursor.pointingHand.set()
            case .ended:  NSCursor.arrow.set()
            }
        }
    }
}

extension View {
    func handCursor() -> some View { modifier(HandCursor()) }
}

// The shelf strip: parked files, each one draggable straight back out into
// whatever app needs it.
struct ShelfRow: View {
    @ObservedObject var state: NotchState

    var body: some View {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(state.shelfItems) { item in
                        ShelfChip(item: item) { state.removeFromShelf(item) }
                    }
                }
                .padding(.vertical, 1)
            }

            ClearShelfButton { state.clearShelf() }
        }
    }
}

struct ShelfChip: View {
    let item: ShelfItem
    let onRemove: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Image(nsImage: item.icon)
                .resizable()
                .frame(width: 26, height: 26)

            Text(item.name)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(item.isMissing ? .white.opacity(0.4) : .white.opacity(0.9))
                .lineLimit(1)
                .frame(maxWidth: 110, alignment: .leading)
                .strikethrough(item.isMissing)

            if hovering {
                ChipRemoveButton(action: onRemove)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, hovering ? 7 : 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(hovering ? 0.16 : 0.09))
        )
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.15), value: hovering)
        // Dragging out hands over the real file, so dropping it in Finder, Mail or
        // an upload field behaves exactly like dragging the original.
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .onTapGesture { PreviewWindow.shared.show(item.url) }
        .contextMenu {
            Button("Xem trước") { PreviewWindow.shared.show(item.url) }
            Button("Hiện trong Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            Divider()
            Button("Sao chép file") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([item.url as NSURL])
            }
            Button("Sao chép đường dẫn") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.path, forType: .string)
            }
            Divider()
            Button("Bỏ khỏi shelf") { onRemove() }
        }
        .handCursor()
        .help("\(item.url.path)\n\nBấm để xem trước · kéo ra để dùng")
    }
}

// Both delete affordances lean red on hover: the rest of the panel's controls
// only brighten, so a colour shift is what marks these apart as destructive.
private struct ClearShelfButton: View {
    let action: () -> Void

    @State private var hovering = false
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering ? Color.red.opacity(0.95) : .white.opacity(0.6))
                .symbolEffect(.bounce, value: taps)
                .frame(width: 26, height: 26)
                .background(
                    Circle().fill(hovering ? Color.red.opacity(0.22) : Color.white.opacity(0.08))
                )
                .scaleEffect(hovering ? 1.1 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .handCursor()
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.18), value: hovering)
        .help("Xoá hết")
    }
}

private struct ChipRemoveButton: View {
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 12.5))
                .foregroundStyle(hovering ? Color.red.opacity(0.9) : .white.opacity(0.55))
                .scaleEffect(hovering ? 1.25 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .handCursor()
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.15), value: hovering)
        .help("Bỏ khỏi shelf")
    }
}

// The widget layout shown when the panel is open.
struct ExpandedContent: View {
    @ObservedObject var state: NotchState
    @ObservedObject var media: MediaController

    var body: some View {
        HStack(spacing: 18) {
            ClockWidget(weather: state.weather, enabled: state.showsWeather)
            SoftDivider()
            MediaWidget(media: media,
                        showsWave: state.showsWave,
                        onScreen: state.isExpanded,
                        onOpenSource: { state.requestDismiss?() })
        }
        .foregroundStyle(.white)
    }
}

// A hard edge-to-edge Divider reads as a stray line inside a rounded panel;
// fading it out at both ends makes it feel like part of the surface.
struct SoftDivider: View {
    var body: some View {
        LinearGradient(
            colors: [.white.opacity(0), .white.opacity(0.16), .white.opacity(0)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(width: 1)
        .padding(.vertical, 6)
    }
}

// Live clock + date, with current conditions underneath.
struct ClockWidget: View {
    @ObservedObject var weather: WeatherService
    let enabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let date = context.date
                VStack(alignment: .leading, spacing: 2) {
                    Text(date, format: .dateTime.hour().minute())
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(date, format: .dateTime.weekday(.wide).day().month())
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            if enabled, let now = weather.current {
                HStack(spacing: 5) {
                    Image(systemName: now.symbol)
                        .font(.system(size: 12))
                        .symbolRenderingMode(.hierarchical)
                    Text("\(Int(now.temperature.rounded()))°")
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                    Text(now.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                .padding(.top, 6)
                .transition(.opacity)
            }
        }
        .frame(width: 152, alignment: .leading)
    }
}

// Cover art + now-playing info + transport controls.
struct MediaWidget: View {
    @ObservedObject var media: MediaController
    let showsWave: Bool
    // False while the panel is collapsed: everything here is still in the view
    // tree, and animating it off-screen is pure waste.
    let onScreen: Bool
    // Called after opening the source app, so the panel can step aside.
    let onOpenSource: () -> Void

    // Skipping forward pushes the old track out to the left and brings the new
    // one in from the right; going back mirrors it.
    private var forward: Bool { media.direction == .forward }

    private func slide(_ distance: CGFloat) -> AnyTransition {
        .asymmetric(
            insertion: .offset(x: forward ? distance : -distance).combined(with: .opacity),
            removal: .offset(x: forward ? -distance : distance).combined(with: .opacity)
        )
    }

    var body: some View {
        let np = media.nowPlaying
        HStack(spacing: 15) {
            // Sized to match the height of the column beside it.
            ZStack {
                CoverArtButton(image: media.artwork,
                               size: 112,
                               enabled: !np.title.isEmpty) {
                    media.revealSource()
                    onOpenSource()
                }
                    .id(np.trackID)
                    .transition(slide(40).combined(with: .scale(scale: 0.9)))
            }
            .frame(width: 112, height: 112)
            .clipped()
            .animation(.smooth(duration: 0.4), value: np.trackID)

            VStack(alignment: .leading, spacing: 9) {
                if np.title.isEmpty {
                    Text("Không có nhạc đang phát")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ZStack(alignment: .leading) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(np.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                            Text(np.artist).font(.system(size: 11.5))
                                .foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        }
                        .id(np.trackID)
                        .transition(slide(26))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipped()
                    .animation(.smooth(duration: 0.4), value: np.trackID)
                }

                if np.duration > 0 {
                    // Poll only lands every 2s, so tick the elapsed time forward
                    // locally to keep the bar moving smoothly. Freeze it while
                    // paused, or while a command is still being confirmed —
                    // otherwise the clock runs on after a pause.
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        let running = np.isPlaying && !media.isBusy
                        // Never drift further than one poll interval, so a stale
                        // "playing" reading can't let the bar run away.
                        let drift = running
                            ? min(max(0, context.date.timeIntervalSince(media.positionSampledAt)), 2.5)
                            : 0
                        ScrubBar(position: min(np.position + drift, np.duration),
                                 duration: np.duration,
                                 tint: media.accent,
                                 onSeek: { media.seek(to: $0) })
                    }
                }

                HStack(spacing: 20) {
                    ControlButton(symbol: "backward.fill", disabled: media.isBusy) { media.previous() }
                    // While a press is pending, show the state it is heading to.
                    ControlButton(symbol: (media.expectedPlaying ?? np.isPlaying) ? "pause.fill" : "play.fill",
                                  disabled: media.isBusy) { media.playPause() }
                    ControlButton(symbol: "forward.fill", disabled: media.isBusy) { media.next() }

                    Spacer(minLength: 8)

                    if onScreen, showsWave {
                        WaveBars(isPlaying: np.isPlaying,
                                 feed: media.levelFeed,
                                 tint: media.accent,
                                 barWidth: 5,
                                 spacing: 5,
                                 maxHeight: 26)
                            .padding(.trailing, 2)
                    } else {
                        // Same footprint, no redraws.
                        Color.clear.frame(width: 35, height: 26)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

// Draggable progress bar. Click anywhere or drag the knob to seek.
struct ScrubBar: View {
    let position: Double
    let duration: Double
    var tint: Color = .white
    let onSeek: (Double) -> Void

    @State private var dragging = false
    @State private var dragFraction: Double = 0

    private var fraction: Double {
        if dragging { return dragFraction }
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    private var shownPosition: Double {
        dragging ? dragFraction * duration : position
    }

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18))
                    Capsule().fill(tint.opacity(0.9))
                        .frame(width: max(0, w * fraction))
                    Circle()
                        .fill(.white)
                        .frame(width: dragging ? 11 : 7, height: dragging ? 11 : 7)
                        .offset(x: max(0, w * fraction) - (dragging ? 5.5 : 3.5))
                }
                .frame(height: dragging ? 5 : 3.5)
                .frame(height: geo.size.height, alignment: .center)
                // Generous hit area — the bar itself is only a few points tall.
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration > 0 else { return }
                            dragging = true
                            dragFraction = min(max(value.location.x / w, 0), 1)
                        }
                        .onEnded { value in
                            guard duration > 0 else { return }
                            let f = min(max(value.location.x / w, 0), 1)
                            dragging = false
                            onSeek(f * duration)
                        }
                )
                .animation(.easeOut(duration: 0.14), value: dragging)
            }
            .frame(height: 14)

            HStack(spacing: 0) {
                Text(clockLabel(shownPosition))
                Spacer(minLength: 0)
                Text(clockLabel(duration))
            }
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.55))
        }
    }

}

// Transport button: hover highlight, springy press, a ring that pulses out on
// click, and the symbol itself bouncing / morphing between play and pause.
struct ControlButton: View {
    let symbol: String
    var disabled: Bool = false
    let action: () -> Void

    @State private var hovering = false
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(disabled ? 0.35 : 1))
                .contentTransition(.symbolEffect(.replace.downUp))
                .symbolEffect(.bounce, value: taps)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(hovering && !disabled ? 0.15 : 0)))
                .background(TapRipple(trigger: taps))
                .contentShape(Circle())
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(disabled)
        .handCursor()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.2), value: disabled)
    }
}

// A ring that expands and fades once per tap. Phase 1 is the finished state, so
// at rest it is fully transparent — otherwise it reads as a border on the button.
private struct TapRipple: View {
    let trigger: Int
    @State private var phase: Double = 1

    var body: some View {
        Circle()
            .stroke(Color.white.opacity(0.45 * (1 - phase)), lineWidth: 1.5)
            .scaleEffect(0.75 + phase * 1.05)
            .allowsHitTesting(false)
            .onChange(of: trigger) { _, _ in
                phase = 0
                withAnimation(.easeOut(duration: 0.4)) { phase = 1 }
            }
    }
}

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.8 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.5),
                       value: configuration.isPressed)
    }
}
