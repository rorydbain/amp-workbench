import Foundation

/// A browsing aid derived from the tone, not a claim about an artist's sound.
public enum PresetStyle: String, CaseIterable, Sendable {
    case acoustic = "Acoustic"
    case clean = "Clean"
    case warm = "Warm"
    case crunch = "Crunch"
    case lead = "Lead"
    case highGain = "High gain"
    case bass = "Bass"
    case direct = "Direct"

    public static func classify(_ preset: Preset) -> Self {
        guard let amp = preset.tone["amp"],
              let model = Catalogue.shared.model(amp, group: "amp") else { return .direct }
        let name = model.name.lowercased()
        let tags = preset.tags.joined(separator: " ").lowercased()
        let gain = amp.parameters["Drive"]?.number ?? 0

        if name.contains("aco") { return .acoustic }
        if name.contains("bass") { return .bass }
        if name.contains("flat") { return .direct }
        if name.contains("hi gain") || name.contains("special") { return .highGain }
        if name.contains("lead") || tags.contains("solo") { return .lead }
        if name.contains("crunch") { return .crunch }
        if name.contains("clean") && (gain >= 0.55 || tags.contains("blues") || tags.contains("warm")) { return .warm }
        return .clean
    }
}
