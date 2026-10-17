import Darwin
import Foundation
import MapKit
import UIKit

/// Locus photographing its own window, for the `screenshot` remote command.
///
/// Public API only: `drawHierarchy(in:afterScreenUpdates:)` on the app's own
/// key window, falling back to `layer.render`. That sees what Locus draws, not
/// what is on the screen — no other app, no status bar, no system overlays.
@MainActor
enum RemoteScreenshot {
    static let directory = RemoteKey.directory + "screens/"
    static let noWindow = "Locus has no visible window; bring it to the front first"
    private static let lifetime: TimeInterval = 600
    private static let maxBytes = 12 * 1024 * 1024
    private static var lastShot = Date.distantPast

    /// - Parameter id: the inbox id, which names the file; `nil` (a URL command,
    ///   which has no id to hand back) writes `latest.png`.
    static func capture(id: String?, scale: Int) throws -> ScreenshotInfo {
        guard Date().timeIntervalSince(lastShot) >= 1 else {
            throw RemoteCommandError("too many screenshots; at most one per second")
        }
        guard let window = visibleWindow() else { throw RemoteCommandError(noWindow) }
        guard FileManager.default.fileExists(atPath: RemoteKey.directory) else {
            throw RemoteCommandError("state directory is missing")
        }
        lastShot = Date()

        var rendered = render(window, scale: scale)
        if rendered.png.count > maxBytes, scale > 1 {
            rendered = render(window, scale: 1)
        }
        guard rendered.png.count <= maxBytes else { throw RemoteCommandError("screenshot is too large") }

        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755, .protectionKey: FileProtectionType.none]
        )
        prune()
        let path = directory + (id.map { "\($0).png" } ?? "latest.png")
        let temporary = path + ".tmp"
        do {
            // `.noFileProtection`: a remote screenshot is as likely to be asked
            // for while the device is locked as not, and the default Data
            // Protection class would otherwise make the file unreadable until
            // the device has been unlocked once since boot.
            try rendered.png.write(to: URL(fileURLWithPath: temporary), options: [.noFileProtection])
        } catch {
            throw RemoteCommandError("couldn’t write \(path)")
        }
        chmod(temporary, 0o644)
        guard rename(temporary, path) == 0 else {
            unlink(temporary)
            throw RemoteCommandError("couldn’t write \(path)")
        }
        return ScreenshotInfo(file: path, width: rendered.width, height: rendered.height, mapMayBeBlank: rendered.mapBlank)
    }

    /// The key window of a scene that is on screen, else any window of one.
    private static func visibleWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive }
        let windows = scenes.flatMap(\.windows).filter { !$0.isHidden && $0.bounds.width > 0 && $0.bounds.height > 0 }
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }

    private struct Rendered {
        var png: Data
        var width: Int
        var height: Int
        var mapBlank: Bool
    }

    private static func render(_ window: UIWindow, scale: Int) -> Rendered {
        let format = UIGraphicsImageRendererFormat()
        format.scale = CGFloat(scale)
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        let image = renderer.image { context in
            // Forcing an update first is what makes hosted content (SwiftUI,
            // MapKit) current; if the snapshot machinery refuses, the layer
            // tree is the fallback.
            if !window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) {
                window.layer.render(in: context.cgContext)
            }
        }
        let width = Int(image.size.width * image.scale)
        let height = Int(image.size.height * image.scale)
        return Rendered(
            png: image.pngData() ?? Data(),
            width: width,
            height: height,
            mapBlank: mapLooksBlank(in: image, window: window)
        )
    }

    /// Metal-backed map content is not always captured: it comes out black.
    /// Looks for a map view, samples its area, and says so if it is nearly all
    /// black. No map on screen (Fun mode, a sheet over it) is not "blank".
    private static func mapLooksBlank(in image: UIImage, window: UIWindow) -> Bool {
        guard let map = firstMapView(in: window), let cgImage = image.cgImage else { return false }
        let frame = map.convert(map.bounds, to: window)
        let rect = CGRect(
            x: frame.minX * image.scale, y: frame.minY * image.scale,
            width: frame.width * image.scale, height: frame.height * image.scale
        ).intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        guard rect.width > 8, rect.height > 8, let cropped = cgImage.cropping(to: rect) else { return false }

        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(
            data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.interpolationQuality = .low
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))

        var dark = 0
        for index in stride(from: 0, to: pixels.count, by: 4)
        where pixels[index] < 12 && pixels[index + 1] < 12 && pixels[index + 2] < 12 {
            dark += 1
        }
        return Double(dark) / Double(side * side) > 0.85
    }

    private static func firstMapView(in view: UIView) -> MKMapView? {
        if let map = view as? MKMapView { return map }
        for subview in view.subviews {
            if let found = firstMapView(in: subview) { return found }
        }
        return nil
    }

    private static func prune() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        let cutoff = Date().timeIntervalSince1970 - lifetime
        for name in names where name.hasSuffix(".png") {
            let path = directory + name
            var info = stat()
            if lstat(path, &info) == 0, TimeInterval(info.st_mtimespec.tv_sec) < cutoff { unlink(path) }
        }
    }
}
