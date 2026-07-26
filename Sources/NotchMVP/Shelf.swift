import AppKit
import UniformTypeIdentifiers

// One parked file. The shelf holds references, not copies — it's a staging spot
// for moving things between apps, so the file stays wherever it already lives.
struct ShelfItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL

    var name: String { url.lastPathComponent }

    var icon: NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }

    // Gone from disk since it was dropped (moved, deleted, ejected).
    var isMissing: Bool {
        !FileManager.default.fileExists(atPath: url.path)
    }
}

// Dropped text and images aren't files yet, so they get written into a cache
// folder first. From then on they behave like anything else on the shelf: they can
// be previewed, dragged out, revealed in Finder.
enum ShelfScratch {
    static var folder: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("NotchMVP/Shelf", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var stamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH-mm-ss"
        return formatter.string(from: Date())
    }

    static func writeText(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Name it after its own first line so the chip is recognisable.
        let firstLine = trimmed.components(separatedBy: .newlines)[0]
        let safe = firstLine
            .prefix(28)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let name = safe.isEmpty ? "Ghi chú \(stamp)" : "\(safe).txt"
        let url = folder.appendingPathComponent(name.hasSuffix(".txt") ? name : name + ".txt")
        do {
            try trimmed.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            notchDebug("shelf: could not save dropped text: \(error)")
            return nil
        }
    }

    static func writeImage(_ data: Data) -> URL? {
        guard let image = NSImage(data: data),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            notchDebug("shelf: dropped image wasn't decodable")
            return nil
        }
        let url = folder.appendingPathComponent("Ảnh \(stamp).png")
        do {
            try png.write(to: url)
            return url
        } catch {
            notchDebug("shelf: could not save dropped image: \(error)")
            return nil
        }
    }
}

// Deliberately in memory only: this is a temporary staging area, and quietly
// keeping a list of the user's files across launches isn't what "tạm" means.
extension NotchState {
    func addToShelf(_ urls: [URL]) {
        let known = Set(shelfItems.map(\.url))
        let fresh = urls.filter { !known.contains($0) }
        guard !fresh.isEmpty else { return }
        shelfItems.append(contentsOf: fresh.map { ShelfItem(url: $0) })
    }

    func removeFromShelf(_ item: ShelfItem) {
        shelfItems.removeAll { $0.id == item.id }
    }

    func clearShelf() {
        shelfItems.removeAll()
    }
}
