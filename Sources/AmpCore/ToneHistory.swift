import Foundation

public enum ToneHistoryKind: String, Codable, Sendable {
    case baseline, ampControls, audition, draft, earlierTone
    public var isAmpState: Bool { self != .draft }
}

public struct ToneHistoryEntry: Codable, Identifiable, Sendable {
    public let id: UUID
    public var date: Date
    public var label: String
    public let kind: ToneHistoryKind
    public let deviceKey: String?
    public var tone: Preset
    public init(id: UUID = UUID(), date: Date = Date(), label: String, kind: ToneHistoryKind, deviceKey: String?, tone: Preset) {
        self.id=id; self.date=date; self.label=label; self.kind=kind; self.deviceKey=deviceKey; self.tone=tone
    }
}

/// Local, bounded history of verified amp tones and unsaved editor drafts.
/// An amp entry becomes active only after the caller verifies the device readback.
public final class ToneHistoryArchive {
    private struct FileContents: Codable {
        var version: Int
        var entries: [ToneHistoryEntry]
        var activeAmpID: UUID?
    }
    public let url: URL
    public private(set) var entries: [ToneHistoryEntry]
    public private(set) var activeAmpID: UUID?
    public init(url: URL) throws {
        self.url=url
        if FileManager.default.fileExists(atPath:url.path) {
            let contents=try JSONDecoder().decode(FileContents.self,from:Data(contentsOf:url))
            guard contents.version == 1 else { throw AmpError("Unknown tone-history format; the existing file was preserved.") }
            for entry in contents.entries { try entry.tone.validate() }
            entries=contents.entries
            activeAmpID=contents.activeAmpID
        } else { entries=[]; activeAmpID=nil }
    }
    public var activeAmpTone: Preset? { entries.first(where:{ $0.id == activeAmpID })?.tone }
    @discardableResult public func record(_ tone: Preset, label: String, kind: ToneHistoryKind, deviceKey: String?, coalesceWithin: TimeInterval = 0, at date: Date = Date()) throws -> ToneHistoryEntry {
        try tone.validate()
        guard kind.isAmpState == (deviceKey != nil) else { throw AmpError("Amp history requires a device identity; editor history must not have one.") }
        if kind.isAmpState, let active=entries.first(where:{ $0.id == activeAmpID }),
           active.deviceKey == deviceKey, ToneComparison.equivalent(active.tone,tone) { return active }
        if let last=entries.last, last.kind == kind, last.deviceKey == deviceKey,
           ToneComparison.equivalent(last.tone,tone) {
            if kind.isAmpState { activeAmpID=last.id; try save() }
            return last
        }
        if coalesceWithin > 0, let last=entries.last, last.kind == kind,
           last.deviceKey == deviceKey, last.label == label,
           date.timeIntervalSince(last.date) <= coalesceWithin {
            entries[entries.count-1].tone=tone
            entries[entries.count-1].date=date
            entries[entries.count-1].label=label
            if kind.isAmpState { activeAmpID=last.id }
            try save()
            return entries[entries.count-1]
        }
        let entry=ToneHistoryEntry(date:date,label:label,kind:kind,deviceKey:deviceKey,tone:tone)
        entries.append(entry)
        if kind.isAmpState { activeAmpID=entry.id }
        if entries.count > 150 { entries.removeFirst(entries.count-150) }
        if !entries.contains(where:{$0.id == activeAmpID}) { activeAmpID=nil }
        try save()
        return entry
    }
    public func activate(_ id: UUID, deviceKey: String) throws {
        guard entries.contains(where:{ $0.id == id && $0.kind.isAmpState && $0.deviceKey == deviceKey }) else {
            throw AmpError("This tone belongs to another amp connection or is an editor draft.")
        }
        activeAmpID=id
        try save()
    }
    public func migrateRecovery(at journal: URL) throws {
        guard FileManager.default.fileExists(atPath:journal.path) else { return }
        let snapshot=try JSONDecoder().decode(RecoverySnapshot.self,from:Data(contentsOf:journal))
        _=try record(snapshot.original,label:"Before earlier auditions",kind:.earlierTone,deviceKey:snapshot.device,at:snapshot.created)
        let archived=journal.deletingLastPathComponent().appendingPathComponent("recovery.archived-in-history-\(UUID().uuidString).json")
        try FileManager.default.moveItem(at:journal,to:archived)
    }
    private func save() throws {
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try jsonEncoder().encode(FileContents(version:1,entries:entries,activeAmpID:activeAmpID)).write(to:url,options:.atomic)
    }
}
