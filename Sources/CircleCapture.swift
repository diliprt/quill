import Cocoa
import CoreGraphics
import ScreenCaptureKit

// Screen capture on circle gesture — adapted from BetterVoice (MIT, TarunTomar122/better-voice).

enum CircleCaptureError: LocalizedError {
    case screenPermissionRequired
    case captureFailed

    var errorDescription: String? {
        switch self {
        case .screenPermissionRequired:
            return "Screen Recording access is required to capture circled areas."
        case .captureFailed:
            return "The screen area could not be captured."
        }
    }
}

/// Captures full-display screenshots when the user draws a circle during dictation.
final class CircleCaptureSession {
    private var detector = CircleGestureDetector()
    private var mouseTimer: Timer?
    private var folder: URL?
    private(set) var imageURLs: [URL] = []
    private var captureTasks: [Task<Void, Never>] = []
    private var lastMouseLocation: CGPoint?

    /// Temp root for all circle-capture sessions.
    static var rootDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("com.freeze.quill.circle-capture", isDirectory: true)
    }

    var captureCount: Int { imageURLs.count }

    /// Wipe prior session folders (and any leftover circle PNGs on the pasteboard)
    /// when a new dictation starts — no timers, no age thresholds.
    static func purgePreviousCaptures() {
        let fm = FileManager.default
        let root = rootDirectory
        guard let kids = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else {
            clearClipboardImages()
            return
        }
        var removed = 0
        for url in kids {
            try? fm.removeItem(at: url)
            removed += 1
        }
        if removed > 0 {
            Log.write("circle capture: purged \(removed) previous folder(s) (new dictation)")
        }
        clearClipboardImages()
    }

    /// Drop image types from the general pasteboard so an old circle doesn't
    /// linger for the next ⌘V. Leaves plain text alone.
    static func clearClipboardImages() {
        let pb = NSPasteboard.general
        let types = pb.types ?? []
        let imageTypes: Set<NSPasteboard.PasteboardType> = [
            .png, .tiff, .pdf,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.heic"),
        ]
        guard types.contains(where: { imageTypes.contains($0) }) else { return }
        let text = pb.string(forType: .string)
        pb.clearContents()
        if let text, !text.isEmpty {
            pb.setString(text, forType: .string)
        }
    }

    func start() throws {
        resetDetector()
        imageURLs = []
        captureTasks = []
        let root = Self.rootDirectory
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        Self.purgePreviousCaptures()
        folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder!, withIntermediateDirectories: true)
    }

    func beginTracking(onGesture: @escaping (Int) -> Void,
                       onError: @escaping (CircleCaptureError) -> Void) {
        guard mouseTimer == nil else { return }
        lastMouseLocation = nil
        // Coalesce samples — a fresh Task per 60 Hz tick flooded the main queue and
        // delayed STT HUD / insert work during dictation.
        var samplePending = false
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self, !samplePending else { return }
            samplePending = true
            self.sampleMouse(onGesture: onGesture, onError: onError)
            samplePending = false
        }
        mouseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stopTracking() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        lastMouseLocation = nil
    }

    func waitForCaptures(timeout: TimeInterval = 3.0) async {
        guard !captureTasks.isEmpty else { return }
        let deadline = Date().addingTimeInterval(timeout)
        for task in captureTasks {
            if Date() >= deadline {
                Log.write("circle capture: wait timed out — \(captureTasks.count) task(s) still pending")
                break
            }
            await task.value
        }
        captureTasks.removeAll(keepingCapacity: true)
    }

    var hasPendingCaptures: Bool { !captureTasks.isEmpty }

    func discard() {
        stopTracking()
        captureTasks.forEach { $0.cancel() }
        captureTasks = []
        if let folder {
            try? FileManager.default.removeItem(at: folder)
        }
        folder = nil
        imageURLs = []
        resetDetector()
    }

    /// Put screenshots on the clipboard (no transcript). Used after speech is already inserted,
    /// so a follow-up ⌘V attaches the image without replacing the text.
    static func copyImagesToClipboard(imageURLs: [URL]) -> Bool {
        guard case .imagesOnly = CircleDelivery.postInsertClipboardLayout(imageCount: imageURLs.count)
        else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var items: [NSPasteboardItem] = []
        for url in imageURLs {
            guard let data = try? Data(contentsOf: url) else { continue }
            let item = NSPasteboardItem()
            guard item.setData(data, forType: .png) else { continue }
            items.append(item)
        }
        guard !items.isEmpty else { return false }
        return pasteboard.writeObjects(items)
    }

    /// Pack transcript + PNGs when both must share the pasteboard (blocked fallback).
    static func copyToClipboard(transcript: String, imageURLs: [URL]) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let layout = CircleDelivery.combinedClipboardLayout(
            transcript: transcript,
            imageCount: imageURLs.count
        )
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        switch layout {
        case .empty:
            return false
        case .textOnly:
            return copyTextOnly(trimmed)
        case .imagesOnly:
            return copyImagesToClipboard(imageURLs: imageURLs)
        case .singleItemTextAndPng:
            guard let data = try? Data(contentsOf: imageURLs[0]) else {
                return copyTextOnly(trimmed)
            }
            let item = NSPasteboardItem()
            guard item.setString(trimmed, forType: .string),
                  item.setData(data, forType: .png)
            else { return copyTextOnly(trimmed) }
            return pasteboard.writeObjects([item])
        case .textItemThenImageItems:
            var items: [NSPasteboardItem] = []
            let textItem = NSPasteboardItem()
            guard textItem.setString(trimmed, forType: .string) else {
                return copyTextOnly(trimmed)
            }
            items.append(textItem)
            for url in imageURLs {
                guard let data = try? Data(contentsOf: url) else { continue }
                let item = NSPasteboardItem()
                guard item.setData(data, forType: .png) else { continue }
                items.append(item)
            }
            return pasteboard.writeObjects(items)
        }
    }

    private static func copyTextOnly(_ transcript: String) -> Bool {
        guard !transcript.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(transcript, forType: .string)
    }

    private func resetDetector() {
        detector = CircleGestureDetector()
    }

    private func sampleMouse(onGesture: @escaping (Int) -> Void,
                             onError: @escaping (CircleCaptureError) -> Void) {
        guard let location = CGEvent(source: nil)?.location else { return }
        guard location != lastMouseLocation else { return }
        lastMouseLocation = location
        handleMouse(at: location, onGesture: onGesture, onError: onError)
    }

    private func handleMouse(at quartzPoint: CGPoint,
                             onGesture: @escaping (Int) -> Void,
                             onError: @escaping (CircleCaptureError) -> Void) {
        let now = ProcessInfo.processInfo.systemUptime
        guard let gesture = detector.add(point: quartzPoint, at: now) else { return }
        guard let captureFolder = folder else { return }
        Log.write(String(format: "circle gesture recognized r=%.0f at (%.0f, %.0f)",
                         gesture.radius, gesture.center.x, gesture.center.y))

        let previous = captureTasks.last
        let nextIndex = imageURLs.count + 1
        let task = Task {
            await previous?.value
            do {
                let url = try await CircleScreenshot.capture(
                    gesture: gesture, index: nextIndex, folder: captureFolder)
                await MainActor.run {
                    imageURLs.append(url)
                    Log.write("circle capture wrote \(url.lastPathComponent)"
                        + " cropped to the circled area (\(imageURLs.count) total)")
                    onGesture(imageURLs.count)
                }
            } catch let error as CircleCaptureError {
                await MainActor.run { onError(error) }
            } catch {
                await MainActor.run { onError(.captureFailed) }
            }
        }
        captureTasks.append(task)
    }
}

private enum CircleScreenshot {
    static func capture(gesture: CircleGesture, index: Int, folder: URL) async throws -> URL {
        guard CGPreflightScreenCaptureAccess() else {
            throw CircleCaptureError.screenPermissionRequired
        }
        guard let displayRegion = displayBounds(containing: gesture.center) else {
            throw CircleCaptureError.captureFailed
        }
        // Capture what was circled, not the whole screen. A full-display grab
        // swept in every other window — mail, password managers, the other half
        // of the desktop — and then put it on the clipboard.
        let region = cropRegion(for: gesture, within: displayRegion)

        let image: CGImage
        if #available(macOS 15.2, *) {
            image = try await SCScreenshotManager.captureImage(in: region)
        } else if #available(macOS 14.0, *) {
            image = try await captureViaShareableContent(displayRegion: region, center: gesture.center)
        } else {
            // Pre-14 has no region capture exposed to Swift, so grab the display
            // and crop before anything is written or copied.
            guard let full = CGDisplayCreateImage(displayID(containing: gesture.center)) else {
                throw CircleCaptureError.captureFailed
            }
            image = crop(full, to: region, within: displayRegion) ?? full
        }

        let marked = highlight(image, target: gesture.center, region: region, radius: gesture.radius)
        let url = folder.appendingPathComponent("context-\(index).png")
        let rep = NSBitmapImageRep(cgImage: marked)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CircleCaptureError.captureFailed
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    @available(macOS 14.0, *)
    private static func captureViaShareableContent(displayRegion: CGRect, center: CGPoint) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.frame.contains(center) }) else {
            throw CircleCaptureError.captureFailed
        }
        let own = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = displayRegion.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        configuration.width = Int(displayRegion.width * CGFloat(display.width) / display.frame.width)
        configuration.height = Int(displayRegion.height * CGFloat(display.height) / display.frame.height)
        configuration.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// Cut `region` out of a full-display image. `region` is in display points;
    /// the image is in pixels, so scale by the backing factor.
    private static func crop(_ image: CGImage, to region: CGRect, within display: CGRect) -> CGImage? {
        guard display.width > 0, display.height > 0 else { return nil }
        let scaleX = CGFloat(image.width) / display.width
        let scaleY = CGFloat(image.height) / display.height
        let rect = CGRect(x: (region.minX - display.minX) * scaleX,
                          y: (region.minY - display.minY) * scaleY,
                          width: region.width * scaleX,
                          height: region.height * scaleY).integral
        return image.cropping(to: rect)
    }

    /// The circled area plus enough margin to keep it readable in context,
    /// clamped to the display the gesture happened on.
    private static func cropRegion(for gesture: CircleGesture, within display: CGRect) -> CGRect {
        let margin = max(56, gesture.radius * 0.55)
        let half = gesture.radius + margin
        let box = CGRect(x: gesture.center.x - half,
                         y: gesture.center.y - half,
                         width: half * 2,
                         height: half * 2)
        let clamped = box.intersection(display)
        // A gesture at the very edge can clip to nothing usable.
        guard !clamped.isNull, clamped.width >= 32, clamped.height >= 32 else { return display }
        return clamped.integral
    }

    private static func displayBounds(containing point: CGPoint) -> CGRect? {
        var display = CGDirectDisplayID()
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count == 1 else { return nil }
        return CGDisplayBounds(display)
    }

    private static func displayID(containing point: CGPoint) -> CGDirectDisplayID {
        var display = CGDirectDisplayID()
        var count: UInt32 = 0
        if CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count == 1 {
            return display
        }
        return CGMainDisplayID()
    }

    private static func highlight(_ image: CGImage, target: CGPoint, region: CGRect, radius: CGFloat) -> CGImage {
        let width = image.width
        let height = image.height
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }

        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let scaleX = CGFloat(width) / region.width
        let scaleY = CGFloat(height) / region.height
        let x = (target.x - region.minX) * scaleX
        let y = CGFloat(height) - (target.y - region.minY) * scaleY
        let markedRadius = max(24, radius * min(scaleX, scaleY))

        let colors = [
            NSColor.systemCyan.withAlphaComponent(0.18).cgColor,
            NSColor.systemBlue.withAlphaComponent(0.12).cgColor,
            NSColor.systemBlue.withAlphaComponent(0).cgColor,
        ] as CFArray
        if let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: colors,
            locations: [0, 0.68, 1]
        ) {
            context.drawRadialGradient(
                gradient,
                startCenter: CGPoint(x: x, y: y),
                startRadius: 0,
                endCenter: CGPoint(x: x, y: y),
                endRadius: markedRadius * 1.35,
                options: [.drawsAfterEndLocation]
            )
        }

        let marker = CGRect(
            x: x - markedRadius,
            y: y - markedRadius,
            width: markedRadius * 2,
            height: markedRadius * 2
        )
        context.setStrokeColor(NSColor.systemBlue.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(max(4, markedRadius * 0.055))
        context.strokeEllipse(in: marker)
        return context.makeImage() ?? image
    }
}
