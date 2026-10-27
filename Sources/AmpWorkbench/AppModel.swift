import Foundation
import SwiftUI
import AppKit
import CoreAudioKit
import UniformTypeIdentifiers
import AmpCore
import AmpMIDI

enum PresetCollectionFilter: String, CaseIterable, Identifiable {
    case all = "All sounds", yamaha = "Yamaha", community = "Community", curated = "Made here", personal = "Mine"
    var id: Self { self }
}

@MainActor final class AppModel: ObservableObject {
    @Published var entries:[LibraryEntry]=[]
    @Published var selection:UUID?
    @Published var draft:Preset?
    @Published private(set) var draftCleanTone:Preset?
    @Published var search=""
    @Published var favouritesOnly=false
    @Published var collectionFilter:PresetCollectionFilter = .all
    @Published var styleFilter:PresetStyle?
    @Published var status="Offline · local library available"
    @Published var connected=false
    @Published var deviceName="Yamaha THR II"
    @Published var busy=false
    @Published var historyEntries:[ToneHistoryEntry]=[]
    @Published var activeAmpHistoryID:UUID?
    @Published var error:String?
    @Published var endpoints:[MIDIEndpoint]=[]
    @Published var selectedEndpoint:Int32?
    @Published var liveTone:Preset?
    @Published var showDiagnostics=false
    @Published var undoStack:[Preset]=[]
    @Published var redoStack:[Preset]=[]
    var library:PresetLibrary?
    var transport:MIDITransport?
    private var midiBluetoothWindow:CABTLEMIDIWindowController?
    var session:THRSession?
    private var toneHistory:ToneHistoryArchive?
    private var pendingDraftHistory:Task<Void,Never>?
    private var pendingAmpHistory:Task<Void,Never>?
    private var pendingApply:Task<Void,Never>?
    private var lastRevision = -1
    private var pollTask:Task<Void,Never>?
    private var usbEndpointID:Int32?
    private var attemptedUSBEndpointID:Int32?
    private var nextUSBAttempt:Date = .distantPast
    private let root=PresetLibrary.defaultDirectory
    var modified:Bool { guard let draft else { return false }; return draftCleanTone != draft }
    var filterLabel:String {
        if let styleFilter, collectionFilter != .all { return "\(styleFilter.rawValue) · \(collectionFilter.rawValue)" }
        return styleFilter?.rawValue ?? collectionFilter.rawValue
    }
    var filtered:[LibraryEntry] { entries.filter { e in
        let collectionMatches:Bool
        switch collectionFilter {
        case .all: collectionMatches=true
        case .yamaha: collectionMatches=e.source?.id.hasPrefix("yamaha-thr-remote/") == true
        case .community: collectionMatches=e.source?.id.hasPrefix("f3sty/") == true || e.source?.id.hasPrefix("cifra-club/") == true
        case .curated: collectionMatches=e.source?.id.hasPrefix("amp-workbench/") == true
        case .personal: collectionMatches=e.source == nil
        }
        return collectionMatches && (styleFilter == nil || PresetStyle.classify(e.preset) == styleFilter) && (!favouritesOnly || e.favourite) &&
            (search.isEmpty || ([e.title,e.subtitle,e.source?.originalName ?? "",e.preset.description]+e.preset.tags).joined(separator:" ").localizedCaseInsensitiveContains(search))
    } }
    var selectedEntry:LibraryEntry? { entries.first(where: { $0.id == selection }) }
    init() {
        do {
            library=try PresetLibrary(directory:root)
            let t=try MIDITransport(); transport=t
            let s=THRSession(transport:t,captureDirectory:root.appendingPathComponent("Captures")); session=s
            let history=try ToneHistoryArchive(url:root.appendingPathComponent("tone-history.json"))
            try history.migrateRecovery(at:root.appendingPathComponent("recovery.json"))
            toneHistory=history
            refreshHistory()
        } catch { self.error=error.localizedDescription }
        refreshEndpoints()
        Task {
            do {
                _ = try await library?.syncCatalog(CuratedPresets.load())
                // Read preset files from the user's installed Yamaha application.
                // No Yamaha tone files are bundled or copied into this project.
                let resources=URL(fileURLWithPath:"/Applications/THR Remote.app/Contents/Resources",isDirectory:true)
                if FileManager.default.fileExists(atPath: resources.path) {
                    let factory=try FactoryPresets.load(from:resources)
                    _ = try await library?.syncCatalog(factory)
                }
            } catch { self.error="Could not load Yamaha factory presets: \(error.localizedDescription)" }
            await reload()
        }
        pollTask=Task { [weak self] in
            var ticks=0
            while !Task.isCancelled {
                guard let self else { return }
                ticks += 1
                if ticks == 1 || ticks % 5 == 0 { await self.maintainUSBConnection() }
                if let session=self.session {
                    await session.poll(); let device=await session.status()
                    self.connected=device.connected
                    self.deviceName=device.model == 1 ? "Yamaha THR10II Wireless" : device.model == 2 ? "Yamaha THR30II Wireless" : "Yamaha THR II"
                    if device.connected || !self.busy {
                        let usbVisible=self.endpoints.contains { !$0.driverOwner.localizedCaseInsensitiveContains("Bluetooth") }
                        self.status = !device.connected && !usbVisible ? "THR USB is not visible to macOS · check cable and power" : device.message
                    }
                    if device.revision != self.lastRevision {
                        self.lastRevision=device.revision; self.liveTone=device.tone
                        if device.connected, let tone=device.tone, !self.busy { self.scheduleAmpHistory(tone) }
                    }
                }
                try? await Task.sleep(nanoseconds:200_000_000)
            }
        }
    }
    func reload() async { do { entries=try await library?.entries() ?? [] } catch { self.error="Could not read library. Existing file was preserved: \(error.localizedDescription)" } }
    func refreshEndpoints() {
        endpoints=MIDITransport.endpoints().filter { $0.isSource && !$0.offline && $0.name.localizedCaseInsensitiveContains("THR") }
        if !endpoints.contains(where:{$0.id == selectedEndpoint}) { selectedEndpoint=endpoints.count == 1 ? endpoints.first?.id:nil }
    }
    private func maintainUSBConnection() async {
        refreshEndpoints()
        // A failed tone transfer can invalidate the MIDI session without
        // removing the USB endpoint. Release the successful attempt marker so
        // a later amp restart can reconnect even if CoreMIDI reuses its ID.
        if usbEndpointID != nil && !connected && !busy {
            usbEndpointID=nil
            attemptedUSBEndpointID=nil
            nextUSBAttempt=Date().addingTimeInterval(5)
        }
        let all=MIDITransport.endpoints()
        let pairs=all.filter { source in
            source.isSource && !source.offline && source.name.localizedCaseInsensitiveContains("THR") &&
            !source.driverOwner.localizedCaseInsensitiveContains("Bluetooth") && source.entity != 0 &&
            all.contains(where: { !$0.isSource && !$0.offline && $0.entity == source.entity })
        }
        let available=Set(pairs.map(\.id))
        if let usbEndpointID, !available.contains(usbEndpointID), !busy {
            try? await session?.disconnect()
            self.usbEndpointID=nil
            attemptedUSBEndpointID=nil
            connected=false
            status="USB amp disconnected · waiting for THR"
        }
        if let attemptedUSBEndpointID, !available.contains(attemptedUSBEndpointID) {
            self.attemptedUSBEndpointID=nil
            nextUSBAttempt = .distantPast
        }
        guard !connected, !busy, attemptedUSBEndpointID == nil, Date() >= nextUSBAttempt, pairs.count == 1,
              let source=pairs.first,
              let dest=all.first(where: { !$0.isSource && !$0.offline && $0.entity == source.entity }),
              let session else { return }
        attemptedUSBEndpointID=source.id
        operation {
            self.status="Connecting to USB amp…"
            do {
                try await session.connect(source:source,destination:dest)
                self.usbEndpointID=source.id
                self.attemptedUSBEndpointID=nil
                self.nextUSBAttempt = .distantPast
            } catch {
                // A failed handshake must not permanently suppress USB autodetection.
                self.attemptedUSBEndpointID=nil
                self.nextUSBAttempt=Date().addingTimeInterval(5)
                throw error
            }
        }
    }
    func operation(_ action:@escaping () async throws -> Void) {
        guard !busy else { return }; busy=true
        Task { do { try await action() } catch { self.error=error.localizedDescription }; busy=false }
    }
    func connect() {
        refreshEndpoints()
        guard let source=endpoints.first(where:{$0.id == selectedEndpoint && !$0.driverOwner.localizedCaseInsensitiveContains("Bluetooth")}), let dest=MIDITransport.endpoints().first(where:{ !$0.isSource && $0.entity == source.entity && $0.entity != 0 }), let session else { error="No THR USB MIDI input/output pair. Power on the THR, connect a USB data cable and quit THR Remote, then Refresh."; return }
        attemptedUSBEndpointID=source.id
        operation { self.status="Connecting…"; try await session.connect(source:source,destination:dest); self.usbEndpointID=source.id }
    }
    func showBluetoothMIDIPairing() {
        if midiBluetoothWindow == nil { midiBluetoothWindow=CABTLEMIDIWindowController() }
        midiBluetoothWindow?.showWindow(nil)
        midiBluetoothWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
    }
    func connectPairedBluetoothMIDI() {
        let endpoints=MIDITransport.endpoints().filter { !$0.offline && $0.name.localizedCaseInsensitiveContains("THR") && $0.driverOwner.localizedCaseInsensitiveContains("Bluetooth") }
        let sources=endpoints.filter(\.isSource)
        guard sources.count == 1, let source=sources.first,
              let dest=endpoints.first(where:{ !$0.isSource && $0.entity == source.entity && $0.entity != 0 }), let session else {
            error="No LE_THRII Bluetooth MIDI pair is connected. Choose it in Pair MIDI, then try again. The THR10II WIRELESS device in Bluetooth Settings carries audio only."
            return
        }
        operation { self.status="Connecting over Bluetooth MIDI…"; try await session.connect(source:source,destination:dest) }
    }
    private func refreshHistory() {
        historyEntries=toneHistory?.entries ?? []
        activeAmpHistoryID=toneHistory?.activeAmpID
    }
    private func recordHistory(_ tone:Preset, label:String, kind:ToneHistoryKind, deviceKey:String?, coalesceWithin:TimeInterval=0) throws {
        _=try toneHistory?.record(tone,label:label,kind:kind,deviceKey:deviceKey,coalesceWithin:coalesceWithin)
        refreshHistory()
    }
    private func scheduleAmpHistory(_ observed:Preset) {
        pendingAmpHistory?.cancel()
        pendingAmpHistory=Task { [weak self] in
            try? await Task.sleep(nanoseconds:900_000_000)
            guard !Task.isCancelled, let self, !self.busy, let session=self.session else { return }
            do {
                let status=await session.status()
                guard status.connected, let tone=status.tone,
                      ToneComparison.equivalent(tone,observed) else { return }
                let key=try await session.identityKey()
                let kind:ToneHistoryKind=self.historyEntries.contains(where:{$0.kind.isAmpState && $0.deviceKey == key}) ? .ampControls:.baseline
                try self.recordHistory(tone,label:kind == .baseline ? "Amp when connected":"Amp controls",kind:kind,deviceKey:key,coalesceWithin:kind == .ampControls ? 2:0)
            } catch { self.error="Could not save tone history: \(error.localizedDescription)" }
        }
    }
    private func flushPendingDraftHistory() {
        guard pendingDraftHistory != nil else { return }
        pendingDraftHistory?.cancel(); pendingDraftHistory=nil
        guard let draft, selection == nil || modified else { return }
        do { try recordHistory(draft,label:"Edited \(selectedEntry?.title ?? draft.name)",kind:.draft,deviceKey:nil,coalesceWithin:2) }
        catch { self.error="Could not save edited tone: \(error.localizedDescription)" }
    }
    func flushHistoryForQuit() { flushPendingDraftHistory() }
    private func scheduleDraftHistory() {
        pendingDraftHistory?.cancel()
        pendingDraftHistory=Task { [weak self] in
            try? await Task.sleep(nanoseconds:900_000_000)
            guard !Task.isCancelled, let self else { return }
            self.flushPendingDraftHistory()
        }
    }
    func readTone() {
        guard let session else { return }
        operation {
            let tone=try await session.readTone(), key=try await session.identityKey()
            self.liveTone=tone
            try self.recordHistory(tone,label:"Amp readback",kind:.baseline,deviceKey:key)
        }
    }
    func editCurrentTone() {
        guard let liveTone else { return }; selectDraft(liveTone)
    }
    func selectDraft(_ preset:Preset) { pendingApply?.cancel(); flushPendingDraftHistory(); draft=preset; draftCleanTone=preset; selection=nil; undoStack=[]; redoStack=[] }
    func choose(_ id:UUID?) { guard let e=entries.first(where:{$0.id == id}) else { return }; if selection == id, draft != nil { return }; pendingApply?.cancel(); flushPendingDraftHistory(); selection=id; draft=e.preset; draftCleanTone=e.preset; undoStack=[]; redoStack=[] }
    func update(_ transform:(inout Preset)->Void) {
        guard var d=draft else { return }; let old=d; transform(&d)
        guard old != d else { return }; undoStack.append(old); if undoStack.count > 100 { undoStack.removeFirst() }; redoStack=[]; draft=d; scheduleDraftHistory()
        if old.tone != d.tone { queueApply(d,delay:450_000_000) }
    }
    func undo() { guard let value=undoStack.popLast(), let draft else { return }; redoStack.append(draft); self.draft=value; scheduleDraftHistory(); if draft.tone != value.tone { queueApply(value,delay:450_000_000) } }
    func redo() { guard let value=redoStack.popLast(), let draft else { return }; undoStack.append(draft); self.draft=value; scheduleDraftHistory(); if draft.tone != value.tone { queueApply(value,delay:450_000_000) } }
    func save(copy:Bool=false) {
        flushPendingDraftHistory()
        guard let draft else { return }
        operation {
            var entry = !copy ? self.entries.first(where:{$0.id == self.selection}) ?? LibraryEntry(preset:draft) : LibraryEntry(preset:draft)
            entry.preset=draft
            guard let library=self.library else { throw AmpError("Library unavailable.") }
            try await library.save(entry); await self.reload(); self.selection=entry.id
            self.draftCleanTone=draft
        }
    }
    func favourite(_ id:UUID) {
        guard var e=entries.first(where:{$0.id == id}) else { return }; e.favourite.toggle()
        operation { try await self.library?.save(e); await self.reload() }
    }
    func importPreset() {
        let panel=NSOpenPanel(); panel.title="Import a preset"; panel.allowedContentTypes=[.json, UTType(filenameExtension:"thrl6p") ?? .data]; panel.allowsMultipleSelection=true
        guard panel.runModal() == .OK else { return }
        let urls=panel.urls
        operation {
            // Validate every file before committing any library item.
            let presets=try urls.map(THRRemoteFile.importFile)
            let imported=presets.map { LibraryEntry(preset:$0) }
            for entry in imported { try await self.library?.save(entry) }
            await self.reload()
            if let first=imported.first {
                self.selection=first.id; self.draft=first.preset
                self.draftCleanTone=first.preset
                self.undoStack=[]; self.redoStack=[]
            }
        }
    }
    func downloadCommunityPresets() {
        guard let library else { return }
        operation {
            self.status="Downloading community presets…"
            let directory=self.root.appendingPathComponent("CommunitySources",isDirectory:true)
            let collection=try await CommunityPresets.download(into:directory)
            let featured=try await CommunityPresets.downloadFeatured(into:directory)
            let entries=collection + featured
            let changed=try await library.syncCatalog(entries)
            await self.reload()
            self.status="\(entries.count) community presets available · \(changed) new or updated"
        }
    }
    func exportPreset(thr:Bool=false) {
        guard let draft else { return }
        do {
            let data=try thr ? THRRemoteFile.encode(draft):draft.encoded()
            let p=NSSavePanel(); p.nameFieldStringValue=draft.name+(thr ? ".thrl6p":".json")
            if p.runModal() == .OK, let url=p.url { try data.write(to:url,options:.atomic) }
        } catch { self.error=error.localizedDescription }
    }
    func applyCurrentPreset() {
        guard let draft else { return }
        queueApply(draft,delay:0)
    }
    private func queueApply(_ tone:Preset,delay:UInt64) {
        guard connected, session != nil else { return }
        let label=selectedEntry?.title ?? tone.name
        pendingApply?.cancel()
        pendingApply=Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds:delay) }
            guard !Task.isCancelled, let self else { return }
            while self.busy && !Task.isCancelled {
                try? await Task.sleep(nanoseconds:100_000_000)
            }
            guard !Task.isCancelled, self.connected else { return }
            self.apply(tone,label:label)
        }
    }
    private func apply(_ draft:Preset,label:String) {
        guard let session else { return }
        flushPendingDraftHistory()
        operation {
            self.pendingAmpHistory?.cancel()
            let before=try await session.readTone(), key=try await session.identityKey()
            try self.recordHistory(before,label:"Amp before \(label)",kind:.baseline,deviceKey:key)
            try await session.applyTone(draft)
            guard let applied=(await session.status()).tone else { throw AmpError("The amp did not return the applied tone.") }
            try self.recordHistory(applied,label:label,kind:.audition,deviceKey:key)
            self.liveTone=applied
        }
    }
    func jumpToHistory(_ id:UUID) {
        guard let entry=historyEntries.first(where:{$0.id == id}) else { return }
        if entry.kind == .draft { selectDraft(entry.tone); return }
        guard let session else { return }
        flushPendingDraftHistory()
        operation {
            self.pendingAmpHistory?.cancel()
            let key=try await session.identityKey()
            guard key == entry.deviceKey else { throw AmpError("This history entry belongs to a different amp connection.") }
            let current=try await session.readTone()
            try self.recordHistory(current,label:"Amp before history jump",kind:.baseline,deviceKey:key)
            if !ToneComparison.equivalent(current,entry.tone) { try await session.applyTone(entry.tone) }
            let after=try await session.readTone()
            guard ToneComparison.equivalent(after,entry.tone) else { throw AmpError("The amp did not match the selected history entry.") }
            // Add the restored state at the end of the timeline. This leaves
            // the state we just departed immediately before it, so Undo Amp
            // Change can return there even when the user chose an old entry.
            try self.recordHistory(after,label:"Returned to \(entry.label)",kind:.audition,deviceKey:key)
            self.liveTone=after
            self.selection=nil; self.draft=entry.tone; self.draftCleanTone=entry.tone; self.undoStack=[]; self.redoStack=[]
        }
    }
    var previousAmpHistoryID:UUID? {
        guard let activeAmpHistoryID, let index=historyEntries.firstIndex(where:{$0.id == activeAmpHistoryID}), index > 0 else { return nil }
        let deviceKey=historyEntries[index].deviceKey
        return historyEntries[..<index].last(where:{$0.kind.isAmpState && $0.deviceKey == deviceKey})?.id
    }
    func undoAmpChange() { if let id=previousAmpHistoryID { jumpToHistory(id) } }
    func exportDiagnostics() {
        do {
            let panel=NSSavePanel(); panel.nameFieldStringValue="AmpWorkbench-diagnostics.json"
            if panel.runModal() == .OK, let url=panel.url, let transport { try transport.log.export().write(to:url,options:.atomic) }
        } catch { self.error=error.localizedDescription }
    }
    func diagnosticsText() -> String { guard let data=try? transport?.log.export() else { return "No log" }; return String(data:data,encoding:.utf8) ?? "No log" }
}
