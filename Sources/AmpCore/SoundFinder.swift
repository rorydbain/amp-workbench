import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

public struct SoundSuggestion: Sendable {
    public let entry: LibraryEntry
    public let reason: String
    public let method: String
}

/// Grounds a natural-language request in actual, playable library entries.
/// The model chooses among candidates; it never invents amp parameters.
public enum SoundFinder {
    public static var modelStatus: String {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return "Apple Intelligence ready"
            case .unavailable(let reason): return "Apple Intelligence unavailable: \(reason)"
            }
        }
        #endif
        return "Apple Intelligence requires iOS 26 or macOS 26"
    }
    public static func shortlist(_ request: String, from entries: [LibraryEntry], limit: Int = 12) -> [LibraryEntry] {
        let words = tokens(request)
        guard !words.isEmpty else { return [] }
        var ranked: [(entry: LibraryEntry, score: Int)] = []
        for entry in entries {
            let title = entry.title.lowercased()
            let tags = entry.preset.tags.joined(separator: " ").lowercased()
            let about = [entry.preset.description, entry.preset.suggestions, entry.subtitle].joined(separator: " ").lowercased()
            let amp = ModelLabels.ampReference(entry.preset).lowercased()
            let cabinet = ModelLabels.cabinetReference(entry.preset).lowercased()
            var score = title.range(of: request.lowercased()) != nil ? 15 : 0
            if amp.range(of: request.lowercased()) != nil { score += 10 }
            if cabinet.range(of: request.lowercased()) != nil { score += 5 }
            for word in words {
                if title.range(of: word) != nil { score += 8 }
                if tags.range(of: word) != nil { score += 4 }
                if about.range(of: word) != nil { score += 1 }
                if amp.range(of: word) != nil { score += 5 }
                if cabinet.range(of: word) != nil { score += 2 }
            }
            if score > 0 { ranked.append((entry, score)) }
        }
        ranked.sort { lhs, rhs in
            lhs.score == rhs.score ? lhs.entry.title < rhs.entry.title : lhs.score > rhs.score
        }
        guard let best = ranked.first?.score else { return [] }
        return Array(ranked.filter { $0.score >= max(3, best / 3) }
            .prefix(max(1, limit)).map { $0.entry })
    }

    public static func suggest(_ request: String, from entries: [LibraryEntry]) async -> SoundSuggestion? {
        let candidates = shortlist(request, from: entries)
        guard let first = candidates.first else { return nil }
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            if case .available = SystemLanguageModel.default.availability {
                let lines = candidates.enumerated().map { index, entry in
                    "\(index + 1). \(entry.title) | amp: \(ModelLabels.ampReference(entry.preset)) | cabinet: \(ModelLabels.cabinetReference(entry.preset)) | tags: \(entry.preset.tags.prefix(5).joined(separator: ", ")) | \(entry.preset.description.prefix(100))"
                }.joined(separator: "\n")
                let session = LanguageModelSession(instructions: "Choose the closest sound from the numbered list. Use its descriptive brand-style amp and cabinet references, tags, and description. The brand references are editorial analogies, not verified hardware or exact replicas. Return only a listed number. Do not invent gear facts.")
                let prompt = "Request: \(request.prefix(300))\nAvailable sounds:\n\(lines)"
                if let response = try? await session.respond(to: prompt, generating: Choice.self),
                   (1...candidates.count).contains(response.content.number) {
                    let selected=candidates[response.content.number - 1]
                    return SoundSuggestion(entry: selected,
                                           reason: ModelLabels.ampReference(selected.preset), method: "Apple Intelligence")
                }
            }
        }
        #endif
        return SoundSuggestion(entry: first, reason: "Closest match in the sound library", method: "Library search")
    }

    private static func tokens(_ text: String) -> [String] {
        let stop: Set<String> = ["a", "an", "and", "for", "in", "of", "on", "the", "to", "want", "with", "sound", "tone", "like", "me", "give", "when", "can", "have", "this", "that"]
        return text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init).filter { $0.count > 1 && !stop.contains($0) }
    }
}

#if canImport(FoundationModels)
@available(macOS 26, iOS 26, *)
@Generable
private struct Choice {
    @Guide(description: "Number of one sound in the provided list")
    var number: Int
}
#endif
