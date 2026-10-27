import Foundation

public struct LibraryEntry: Codable, Identifiable, Sendable {
    public let id: UUID
    public var preset: Preset
    public var favourite: Bool
    public var updated: Date
    /// Library-only presentation metadata. The original preset name and tone remain intact
    /// for THR Remote export and for provenance-aware future search.
    public var displayName: String?
    public var source: PresetSource?
    public var researchSources: [SoundResearchSource]?
    public var researchNote: String?
    public var generationMethod: String?
    public var designIntent: SoundDesignIntent?
    public var generationTraces: [SoundGenerationTrace]?
    public var archivedAt: Date?
    public var title: String { displayName ?? preset.name }
    public var subtitle: String {
        source.map { $0.id.hasPrefix("f3sty/") || title.localizedCaseInsensitiveContains($0.originalName) ? $0.publisher : "\($0.publisher) · \($0.originalName)" }
            ?? preset.tags.prefix(3).joined(separator: " · ")
    }
    public init(preset: Preset, displayName: String? = nil, source: PresetSource? = nil,
                researchSources: [SoundResearchSource]? = nil, researchNote: String? = nil,
                generationMethod: String? = nil, designIntent: SoundDesignIntent? = nil,
                generationTraces: [SoundGenerationTrace]? = nil) {
        id = UUID(); self.preset = preset; favourite = false; updated = Date()
        self.displayName = displayName; self.source = source; self.researchSources = researchSources
        self.researchNote = researchNote; self.generationMethod = generationMethod; self.designIntent = designIntent
        self.generationTraces = generationTraces
        self.archivedAt = nil
    }
}
public struct PresetSource: Codable, Sendable {
    public let id: String
    public let publisher: String
    public let originalName: String
    public let reference: String?
    public let relationship: String
    public init(id: String, publisher: String, originalName: String, reference: String?, relationship: String) {
        self.id = id; self.publisher = publisher; self.originalName = originalName
        self.reference = reference; self.relationship = relationship
    }
}
public actor PresetLibrary {
    public let directory: URL
    public init(directory: URL) throws { self.directory = directory; try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    public static var defaultDirectory: URL {
        #if os(iOS)
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AmpWorkbench", isDirectory: true)
        #else
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AmpWorkbench", isDirectory: true)
        #endif
    }
    public func entries() throws -> [LibraryEntry] {
        let url = directory.appendingPathComponent("library.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let entries = try JSONDecoder().decode([LibraryEntry].self, from: Data(contentsOf: url))
        for e in entries { try e.preset.validate() }; return entries.sorted { $0.updated > $1.updated }
    }
    public func save(_ entry: LibraryEntry) throws {
        try entry.preset.validate(); var items = try entries()
        var updated = entry; updated.updated = Date()
        if let i = items.firstIndex(where: { $0.id == entry.id }) { items[i] = updated } else { items.append(updated) }
        let url = directory.appendingPathComponent("library.json")
        if FileManager.default.fileExists(atPath: url.path) {
            try Data(contentsOf: url).write(to: directory.appendingPathComponent("library.previous.json"), options: .atomic)
        }
        try jsonEncoder().encode(items).write(to: url, options: .atomic)
    }
    public func delete(_ id: UUID) throws {
        var items = try entries()
        guard items.contains(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        let url = directory.appendingPathComponent("library.json")
        if FileManager.default.fileExists(atPath: url.path) {
            try Data(contentsOf: url).write(to: directory.appendingPathComponent("library.previous.json"), options: .atomic)
        }
        try jsonEncoder().encode(items).write(to: url, options: .atomic)
    }
    public func archive(_ entry: LibraryEntry) throws {
        var archived = entry
        archived.archivedAt = Date()
        try save(archived)
    }
    public func restore(_ id: UUID) throws {
        guard var entry = try entries().first(where: { $0.id == id }) else { return }
        entry.archivedAt = nil
        try save(entry)
    }
    public func syncCatalog(_ incoming: [LibraryEntry]) throws -> Int {
        var items = try entries()
        var changed = 0
        for entry in incoming where entry.source != nil {
            try entry.preset.validate()
            if let index=items.firstIndex(where: { $0.source?.id == entry.source?.id }) {
                // Refresh editorial labels without replacing a user's edited tone,
                // favourite state, or original imported Yamaha name.
                if items[index].displayName != entry.displayName {
                    items[index].displayName=entry.displayName
                    changed += 1
                }
            } else {
                items.append(entry); changed += 1
            }
        }
        guard changed > 0 else { return 0 }
        let url = directory.appendingPathComponent("library.json")
        if FileManager.default.fileExists(atPath: url.path) {
            try Data(contentsOf: url).write(to: directory.appendingPathComponent("library.previous.json"), options: .atomic)
        }
        try jsonEncoder().encode(items).write(to: url, options: .atomic)
        return changed
    }
}
public struct DiagnosticRecord: Codable, Sendable {
    public let timestamp: Date
    public let direction: String
    public let message: String
}
public final class DiagnosticLog: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [DiagnosticRecord] = []
    public init() {}
    public func append(_ direction: String, _ message: String) {
        lock.lock(); defer { lock.unlock() }
        records.append(.init(timestamp: Date(), direction: direction, message: message))
        if records.count > 5000 { records.removeFirst(records.count - 5000) }
    }
    public func export() throws -> Data { lock.lock(); defer { lock.unlock() }; return try jsonEncoder().encode(records) }
}

public protocol ToneDevice: Sendable {
    func readTone() async throws -> Preset
    /// Reject known unsupported transitions before a recovery journal is made.
    func validateToneChange(from current: Preset, to desired: Preset) async throws
    /// Implementations must validate before any writes and return only after readback.
    func applyTone(_ preset: Preset) async throws
    func identityKey() async throws -> String
}
public extension ToneDevice {
    func validateToneChange(from current: Preset, to desired: Preset) async throws {}
}
public struct RecoverySnapshot: Codable, Sendable {
    public let device: String
    public let original: Preset
    public let created: Date
}
/// Serializes whole operations (actors alone are reentrant across awaits).
public actor AuditionService {
    private let device: any ToneDevice
    private let journal: URL
    private var busy = false
    public init(device: any ToneDevice, journal: URL) { self.device = device; self.journal = journal }
    public func hasRecovery() -> Bool { FileManager.default.fileExists(atPath: journal.path) }
    public func preview(_ preset: Preset) async throws {
        guard !busy else { throw AmpError("Another device operation is still running.") }; busy = true; defer { busy = false }
        try preset.validate()
        if hasRecovery() {
            let snapshot=try JSONDecoder().decode(RecoverySnapshot.self,from:Data(contentsOf:journal))
            guard snapshot.device == (try await device.identityKey()) else { throw AmpError("Recovery belongs to another MIDI device. Reconnect the original endpoint.") }
            let current=try await device.readTone()
            try await device.validateToneChange(from:current,to:preset)
            try await device.applyTone(preset)
            return
        }
        let snapshot = RecoverySnapshot(device: try await device.identityKey(), original: try await device.readTone(), created: Date())
        try await device.validateToneChange(from: snapshot.original, to: preset)
        try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary=journal.deletingLastPathComponent().appendingPathComponent(".recovery-\(UUID().uuidString).json")
        try jsonEncoder().encode(snapshot).write(to: temporary, options: .atomic)
        defer { try? FileManager.default.removeItem(at: temporary) }
        // Hard-link publication is atomic and fails if a recovery journal already
        // exists. Foundation cannot combine .atomic with .withoutOverwriting.
        try FileManager.default.linkItem(at: temporary, to: journal)
        // Journal survives write failure, cancellation, disconnect, and application restart.
        try await device.applyTone(preset)
    }
    public func restore() async throws {
        guard !busy else { throw AmpError("Another device operation is still running.") }; busy = true; defer { busy = false }
        let snapshot = try JSONDecoder().decode(RecoverySnapshot.self, from: Data(contentsOf: journal))
        guard snapshot.device == (try await device.identityKey()) else { throw AmpError("Recovery belongs to another MIDI device. Reconnect the original endpoint.") }
        try await device.applyTone(snapshot.original)
        let readback = try await device.readTone()
        guard ToneComparison.equivalent(readback, snapshot.original) else { throw AmpError("Restoration readback differs; previous tone retained for retry.") }
        try FileManager.default.removeItem(at: journal)
    }
    public func keepCurrentTone() throws {
        guard !busy else { throw AmpError("Another device operation is still running.") }
        guard hasRecovery() else { return }
        let archived=journal.deletingLastPathComponent().appendingPathComponent("recovery.archived-\(UUID().uuidString).json")
        try FileManager.default.moveItem(at:journal,to:archived)
    }
}
public enum ToneComparison {
    public static func equivalent(_ a: Preset, _ b: Preset, tolerance: Double = 0.00001) -> Bool {
        guard a.target == b.target, a.tone.keys.sorted() == b.tone.keys.sorted() else { return false }
        for (group, block) in a.tone {
            guard let other = b.tone[group], block.model == other.model, block.parameters.keys.sorted() == other.parameters.keys.sorted() else { return false }
            for (key,value) in block.parameters {
                if let x = value.number, let y = other.parameters[key]?.number { if abs(x-y) > tolerance { return false } }
                else if value != other.parameters[key] { return false }
            }
        }; return true
    }
}
