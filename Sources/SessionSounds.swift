import AppKit

/// Short UI cues when a dictation starts — same idea as Fluid Voice's start chime.
enum SessionSounds {

    /// Built-in macOS sounds. All are short ticks, not spoken syllables.
    enum StartCue: String, CaseIterable {
        case off
        case tink = "Tink"
        case pop = "Pop"
        case purr = "Purr"
        case glass = "Glass"
        case ping = "Ping"
        case bottle = "Bottle"

        var menuTitle: String {
            switch self {
            case .off:    return "Off"
            case .tink:   return "Tink"
            case .pop:    return "Pop"
            case .purr:   return "Purr"
            case .glass:  return "Glass"
            case .ping:   return "Ping"
            case .bottle: return "Bottle"
            }
        }

        /// `NSSound` name, or `nil` when silent.
        var systemName: String? {
            self == .off ? nil : rawValue
        }
    }

    /// Must be retained — `NSSound` stops if the instance is released mid-play.
    private static var current: NSSound?

    static func playStart() {
        play(Defaults.startCue)
    }

    static func play(_ cue: StartCue) {
        current?.stop()
        current = nil
        guard let name = cue.systemName else { return }
        // Load from the file, not `NSSound(named:)`. The named sounds are
        // shared singletons — the menu-bar click already plays Tink through
        // that instance, so `.play()` on Tink/Pop/Glass stacked as a double.
        let url = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
        guard FileManager.default.fileExists(atPath: url.path),
              let sound = NSSound(contentsOf: url, byReference: true) else { return }
        current = sound
        sound.play()
    }

    /// After the menu dismisses, so this doesn't land on the system menu tick.
    static func preview(_ cue: StartCue) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            guard Defaults.startCue == cue else { return }
            play(cue)
        }
    }
}
