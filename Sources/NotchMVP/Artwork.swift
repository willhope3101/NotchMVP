import AppKit

// Opt-in tracing (NOTCH_DEBUG=1) to ~/Library/Logs/NotchMVP.log. NSLog from an
// ad-hoc signed app launched by Launch Services doesn't reach the unified log.
func notchDebug(_ message: String) {
    guard ProcessInfo.processInfo.environment["NOTCH_DEBUG"] == "1" else { return }
    let path = ("~/Library/Logs/NotchMVP.log" as NSString).expandingTildeInPath
    let line = "\(Date()) \(message)\n"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

// The artwork's dominant colour, adjusted to stay legible on black.
//
// Averaging alone gives muddy results — a dark album cover averages to near-black,
// which would be invisible — so saturation and brightness are floored. A greyscale
// cover deliberately stays near-white rather than being forced into a hue.
extension NSImage {
    var accentColor: NSColor {
        guard let tiff = tiffRepresentation,
              let source = NSBitmapImageRep(data: tiff),
              let scaled = NSBitmapImageRep(bitmapDataPlanes: nil,
                                            pixelsWide: 1, pixelsHigh: 1,
                                            bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB,
                                            bytesPerRow: 4, bitsPerPixel: 32) else {
            return .white
        }

        // Drawing into a 1x1 bitmap is the averaging step.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: scaled)
        source.draw(in: CGRect(x: 0, y: 0, width: 1, height: 1))
        NSGraphicsContext.restoreGraphicsState()

        guard let average = scaled.colorAt(x: 0, y: 0)?
            .usingColorSpace(.deviceRGB) else { return .white }

        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        // Nearly colourless art shouldn't be tinted at all.
        guard saturation > 0.08 else { return .white }
        return NSColor(hue: hue,
                       saturation: min(1, max(0.5, saturation * 1.5)),
                       brightness: min(1, max(0.75, brightness * 1.4)),
                       alpha: 1)
    }
}

// Loads and caches album art. Keys are opaque: either a remote URL (YouTube
// thumbnail, Spotify CDN) or a local file path (artwork dumped out of Music).
final class ArtworkStore {
    static let shared = ArtworkStore()

    private var cache: [String: NSImage] = [:]   // main-thread only

    func load(key: String, completion: @escaping (NSImage?) -> Void) {
        guard !key.isEmpty else { completion(nil); return }
        if let hit = cache[key] { completion(hit); return }

        if key.hasPrefix("http") {
            guard let url = URL(string: key) else { completion(nil); return }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
                let image = data.flatMap { NSImage(data: $0) }
                DispatchQueue.main.async {
                    if let image = image { self?.cache[key] = image }
                    completion(image)
                }
            }.resume()
        } else {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let image = NSImage(contentsOfFile: key)
                DispatchQueue.main.async {
                    if let image = image { self?.cache[key] = image }
                    completion(image)
                }
            }
        }
    }
}
