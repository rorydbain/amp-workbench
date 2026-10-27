import SwiftUI
import AmpCore

extension PresetStyle {
    var symbol: String {
        switch self {
        case .acoustic: "guitars"
        case .clean: "drop"
        case .warm: "sun.max"
        case .crunch: "waveform"
        case .lead: "music.note"
        case .highGain: "bolt.fill"
        case .bass: "speaker.wave.2"
        case .direct: "slider.horizontal.3"
        }
    }
    var color: Color {
        switch self {
        case .acoustic: .green
        case .clean: .blue
        case .warm: .orange
        case .crunch: .brown
        case .lead: .purple
        case .highGain: .red
        case .bass: .indigo
        case .direct: .gray
        }
    }
}
