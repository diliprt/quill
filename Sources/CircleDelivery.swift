import Foundation

/// Pure delivery / clipboard planning for circle capture.
/// Extracted so scenario decisions can be unit-tested without Cocoa.
enum CircleDelivery {

    enum Mode: Equatable {
        /// No circle images — normal text insert into the focused app.
        case plainInsert
        /// Circle images present — insert speech first, then put images on clipboard.
        /// Never ⌘V text+image together: paste boxes prefer the image and drop speech.
        case textThenImagesOnClipboard
    }

    enum StopKind: Equatable {
        case click
        case hold
        case other
    }

    enum ClipboardLayout: Equatable {
        case empty
        case textOnly
        case imagesOnly(count: Int)
        case singleItemTextAndPng
        case textItemThenImageItems(imageCount: Int)
    }

    static func mode(circleImageCount: Int) -> Mode {
        circleImageCount > 0 ? .textThenImagesOnClipboard : .plainInsert
    }

    /// Focus settle before writing into the frontmost app after key release / click.
    static func settleSeconds(stop: StopKind,
                              circleCaptureEnabled: Bool,
                              deliveringCircleImages: Bool) -> TimeInterval {
        if deliveringCircleImages {
            switch stop {
            case .click: return 0.22
            case .hold:  return 0.32
            case .other: return 0.24
            }
        }
        switch stop {
        case .click: return 0.22
        case .hold:  return circleCaptureEnabled ? 0.32 : 0.16
        case .other: return 0.16
        }
    }

    /// Delay after text insert before replacing the pasteboard with images.
    /// Clipboard-fallback text paste no longer restores prior images, so a short
    /// settle is enough for ⌘V to finish before we write the PNG.
    static func imageClipboardDelay(textInsertedViaClipboard: Bool) -> TimeInterval {
        textInsertedViaClipboard ? 0.20 : 0.08
    }

    /// How to pack speech + captures when both must share the pasteboard
    /// (e.g. Accessibility blocked). Prefer one item with both types when possible.
    static func combinedClipboardLayout(transcript: String, imageCount: Int) -> ClipboardLayout {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && imageCount <= 0 { return .empty }
        if imageCount <= 0 { return .textOnly }
        if trimmed.isEmpty { return .imagesOnly(count: imageCount) }
        if imageCount == 1 { return .singleItemTextAndPng }
        return .textItemThenImageItems(imageCount: imageCount)
    }

    /// After a successful text insert, only images belong on the clipboard.
    static func postInsertClipboardLayout(imageCount: Int) -> ClipboardLayout {
        guard imageCount > 0 else { return .empty }
        return .imagesOnly(count: imageCount)
    }
}
