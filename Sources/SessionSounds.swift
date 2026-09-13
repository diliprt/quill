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

    static func playStart() {
        play(Defaults.startCue)
    }

    static func play(_ cue: StartCue) {
        guard let name = cue.systemName else { return }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
