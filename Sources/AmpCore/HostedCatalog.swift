import Foundation

/// A public, read-only sound catalogue. Local copies remain independent of updates.
public struct HostedPreset: Codable, Sendable {
    public let id: String
    public let displayName: String?
    public let originalName: String?
    public let publisher: String
    public let reference: String?
    public let relationship: String
    public let preset: Preset

    public init(id: String, displayName: String? = nil, originalName: String? = nil,
                publisher: String, reference: String?, relationship: String, preset: Preset) {
        self.id = id; self.displayName = displayName; self.originalName = originalName
        self.publisher = publisher; self.reference = reference
        self.relationship = relationship; self.preset = preset
    }
}

public struct HostedCatalog: Codable, Sendable {
    public let schemaVersion: Int
    public let revision: String
    public let presets: [HostedPreset]

    public init(revision: String, presets: [HostedPreset]) {
        schemaVersion = 1; self.revision = revision; self.presets = presets
    }

    public static func decode(_ data: Data) throws -> HostedCatalog {
        guard data.count <= 2_000_000 else { throw AmpError("Hosted catalogue exceeds 2 MB.") }
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        try catalog.validate()
        return catalog
    }

    public func validate() throws {
        guard schemaVersion == 1 else { throw AmpError("Unsupported hosted catalogue version.") }
        guard !revision.isEmpty, revision.utf8.count <= 80 else { throw AmpError("Invalid hosted catalogue revision.") }
        guard presets.count <= 500 else { throw AmpError("Hosted catalogue has too many sounds.") }
        var ids = Set<String>()
        for item in presets {
            guard !item.id.isEmpty, item.id.utf8.count <= 300,
                  !item.id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  ids.insert(item.id).inserted else { throw AmpError("Invalid or duplicate hosted sound ID: \(item.id)") }
            guard !item.publisher.isEmpty, item.publisher.utf8.count <= 100,
                  item.relationship.utf8.count <= 500,
                  (item.displayName?.utf8.count ?? 0) <= 160,
                  (item.originalName?.utf8.count ?? 0) <= 160 else { throw AmpError("Invalid hosted sound attribution.") }
            if let reference = item.reference {
                guard reference.utf8.count <= 500, URL(string: reference)?.scheme == "https" else {
                    throw AmpError("Hosted sound reference must be an HTTPS URL.")
                }
            }
            try item.preset.validate()
        }
    }

    public func entries() -> [LibraryEntry] {
        presets.map { item in
            LibraryEntry(preset: item.preset, displayName: item.displayName ?? item.preset.name,
                         source: PresetSource(id: item.id, publisher: item.publisher,
                                              originalName: item.originalName ?? item.preset.name, reference: item.reference,
                                              relationship: item.relationship))
        }
    }
}
