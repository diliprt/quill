import Foundation

// Scenario checks for circle-capture delivery routing and clipboard packing.
// These encode the product rules that caused the "image pastes, speech missing" bug.

var failures = 0
func expect(_ condition: Bool, _ label: String) {
    if condition {
        print("ok   \(label)")
    } else {
        failures += 1
        print("FAIL \(label)")
    }
}

// MARK: - Delivery mode

expect(CircleDelivery.mode(circleImageCount: 0) == .plainInsert,
       "no circle → plain insert")
expect(CircleDelivery.mode(circleImageCount: 1) == .textThenImagesOnClipboard,
       "one circle → text then images")
expect(CircleDelivery.mode(circleImageCount: 3) == .textThenImagesOnClipboard,
       "many circles → text then images")

// MARK: - Settle timing (Alt+Tab focus)

expect(CircleDelivery.settleSeconds(stop: .hold, circleCaptureEnabled: false, deliveringCircleImages: false) == 0.16,
       "hold, circle off → short settle")
expect(CircleDelivery.settleSeconds(stop: .hold, circleCaptureEnabled: true, deliveringCircleImages: false) == 0.32,
       "hold, circle on, no image → longer settle for Alt+Tab")
expect(CircleDelivery.settleSeconds(stop: .hold, circleCaptureEnabled: true, deliveringCircleImages: true) == 0.32,
       "hold with captures → 0.32s settle")
expect(CircleDelivery.settleSeconds(stop: .click, circleCaptureEnabled: true, deliveringCircleImages: true) == 0.22,
       "click with captures → 0.22s settle")
expect(CircleDelivery.settleSeconds(stop: .other, circleCaptureEnabled: false, deliveringCircleImages: false) == 0.16,
       "hotkey/voice stop → 0.16s settle")

// MARK: - Image clipboard delay after text insert

expect(CircleDelivery.imageClipboardDelay(textInsertedViaClipboard: true) == 0.55,
       "after ⌘V text insert wait past pasteboard restore")
expect(CircleDelivery.imageClipboardDelay(textInsertedViaClipboard: false) == 0.08,
       "after AX text insert short delay before images")

// MARK: - Combined clipboard (blocked / fallback only)

expect(CircleDelivery.combinedClipboardLayout(transcript: "", imageCount: 0) == .empty,
       "empty transcript + no images → empty")
expect(CircleDelivery.combinedClipboardLayout(transcript: "  hello  ", imageCount: 0) == .textOnly,
       "transcript only → textOnly")
expect(CircleDelivery.combinedClipboardLayout(transcript: "", imageCount: 2) == .imagesOnly(count: 2),
       "images only → imagesOnly")
expect(CircleDelivery.combinedClipboardLayout(transcript: "hello", imageCount: 1) == .singleItemTextAndPng,
       "one image + text → single pasteboard item (not separate)")
expect(CircleDelivery.combinedClipboardLayout(transcript: "hello", imageCount: 2)
        == .textItemThenImageItems(imageCount: 2),
       "multi image + text → text item then image items")

// MARK: - Post-insert clipboard (the fix for speech-missing)

expect(CircleDelivery.postInsertClipboardLayout(imageCount: 0) == .empty,
       "no images after insert → empty clipboard plan")
expect(CircleDelivery.postInsertClipboardLayout(imageCount: 1) == .imagesOnly(count: 1),
       "after text insert → images only (never re-paste text+image)")
expect(CircleDelivery.postInsertClipboardLayout(imageCount: 3) == .imagesOnly(count: 3),
       "after text insert → all captures, no transcript on pasteboard")

// Critical regression: primary path must NOT use combined text+image paste.
let primary = CircleDelivery.mode(circleImageCount: 1)
let afterInsert = CircleDelivery.postInsertClipboardLayout(imageCount: 1)
expect(primary == .textThenImagesOnClipboard && afterInsert == .imagesOnly(count: 1),
       "regression: circle path inserts text, then images-only clipboard")

if failures == 0 {
    print("✓ circle delivery scenarios passed")
    exit(0)
} else {
    print("✗ \(failures) circle delivery scenario(s) failed")
    exit(1)
}
