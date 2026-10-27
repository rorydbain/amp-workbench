import AmpCore

/// Guitar controls are starting points. THR presets cannot set the guitar's physical controls.
struct GuitarSetupSuggestion {
    let pickup:String
    let tone:String
    let volume:String
    let basis:String

    static func forEntry(_ entry:LibraryEntry?, preset:Preset) -> Self {
        switch entry?.source?.id {
        case "amp-workbench/stevie-ray-vaughan/pride-and-joy":
            return .init(pickup:"Strat neck + middle",tone:"8–10",volume:"8–10",basis:"Artist-rig-inspired starting point")
        case "amp-workbench/chris-stapleton/tennessee-whiskey":
            return .init(pickup:"Jazzmaster neck",tone:"6–8",volume:"7–9",basis:"Artist-rig-inspired starting point")
        case "amp-workbench/john-mayer-trio/come-when-i-call":
            return .init(pickup:"Warm neck humbucker",tone:"6–8",volume:"6–10",basis:"Tone-inspired starting point")
        default: break
        }
        switch PresetStyle.classify(preset) {
        case .acoustic: return .init(pickup:"Acoustic pickup or mic",tone:"Neutral",volume:"As needed",basis:"Style-based suggestion")
        case .clean: return .init(pickup:"Neck or middle",tone:"7–10",volume:"8–10",basis:"Style-based suggestion")
        case .warm: return .init(pickup:"Neck",tone:"5–8",volume:"7–10",basis:"Style-based suggestion")
        case .crunch: return .init(pickup:"Bridge or middle",tone:"7–10",volume:"7–10",basis:"Style-based suggestion")
        case .lead: return .init(pickup:"Bridge or neck",tone:"7–10",volume:"9–10",basis:"Style-based suggestion")
        case .highGain: return .init(pickup:"Bridge humbucker",tone:"8–10",volume:"9–10",basis:"Style-based suggestion")
        case .bass: return .init(pickup:"Both pickups",tone:"Neutral",volume:"8–10",basis:"Style-based suggestion")
        case .direct: return .init(pickup:"Your choice",tone:"Neutral",volume:"8–10",basis:"Style-based suggestion")
        }
    }
}
