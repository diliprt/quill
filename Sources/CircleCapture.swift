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
@MainActor
final class CircleCaptureSession {
    private var detector = CircleGestureDetector()
    private var mouseTimer: Timer?
    private var folder: URL?
    private(set) var imageURLs: [URL] = []
    private var captureTasks: [Task<Void, Never>] = []
    private var lastMouseLocation: CGPoint?

    var captureCount: Int { imageURLs.count }

    func start() throws {
        resetDetector()
        imageURLs = []
        captureTasks = []
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("com.freeze.quill.circle-capture", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
            Task { @MainActor [weak self] in
                samplePending = false
                guard let self else { return }
                self.sampleMouse(onGesture: onGesture, onError: onError)
            }
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

    /// After text lands in the field, put transcript + PNGs on the clipboard for attachment-aware apps.
    static func copyToClipboard(transcript: String, imageURLs: [URL]) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        var items: [NSPasteboardItem] = []
        for url in imageURLs {
            guard let data = try? Data(contentsOf: url) else { continue }
            let item = NSPasteboardItem()
            guard item.setData(data, forType: .png) else { continue }
            items.append(item)
        }

        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let textItem = NSPasteboardItem()
            guard textItem.setString(trimmed, forType: .string) else {
                return copyTextOnly(trimmed)
            }
            if items.isEmpty {
                return pasteboard.writeObjects([textItem])
            }
            items.insert(textItem, at: 0)
        }

        guard !items.isEmpty else { return false }
        return pasteboard.writeObjects(items)
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
        guard folder != nil else { return }

        let previous = captureTasks.last
        let task = Task { @MainActor in
            await previous?.value
            do {
                let url = try await CircleScreenshot.capture(gesture: gesture, index: imageURLs.count + 1, folder: folder!)
                imageURLs.append(url)
                onGesture(imageURLs.count)
            } catch let error as CircleCaptureError {
                onError(error)
            } catch {
                onError(.captureFailed)
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

        let image: CGImage
        if #available(macOS 15.2, *) {
            image = try await SCScreenshotManager.captureImage(in: displayRegion)
        } else if #available(macOS 14.0, *) {
            image = try await captureViaShareableContent(displayRegion: displayRegion, center: gesture.center)
        } else {
            guard let legacy = CGDisplayCreateImage(displayID(containing: gesture.center)) else {
                throw CircleCaptureError.captureFailed
            }
            image = legacy
        }

        let marked = highlight(image, target: gesture.center, region: displayRegion, radius: gesture.radius)
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
