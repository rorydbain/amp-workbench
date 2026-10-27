import SwiftUI
import UniformTypeIdentifiers
import AmpCore
import AmpMIDI

struct USBMIDIPair: Identifiable {
    let source: MIDIEndpoint
    let destination: MIDIEndpoint
    var id: Int32 { source.id }
    var title: String { source.name == destination.name ? source.name : "\(source.name) ↔ \(destination.name)" }
}

@MainActor final class PhoneProbeModel: ObservableObject {
    @Published var pairs: [USBMIDIPair] = []
    @Published var endpoints: [MIDIEndpoint] = []
    @Published var status = "Connect the amp with a USB-C data cable."
    @Published var result: USBProbeResult?
    @Published var probing = false
    @Published var connected = false
    @Published var busy = false
    @Published var currentTone: Preset?
    @Published var history: [ToneHistoryEntry] = []
    @Published var imported: [LibraryEntry] = []
    @Published var hosted: [LibraryEntry] = []
    @Published var catalogStatus = "Bundled sounds available"
    @Published var catalogRefreshing = false
    @Published var catalogRevision: String?
    @Published var downloading = false
    @Published var diagnosticURL: URL?
    @Published var lastSoundDesignMethod: String?
    @Published var lastSoundResearchStatus: String?
    private var probe: USBIdentityProbe?
    private var session: THRSession?
    private var transport: MIDITransport?
    private var toneHistory: ToneHistoryArchive?
    private var pendingEdit: Task<Void, Never>?
    private let root = PresetLibrary.defaultDirectory
    private var catalogURL: URL? { SoundResearchClient.serviceURL("v1/catalog.json") }
    private var lastCatalogCheck: Date?
    private var attemptedPairID: Int32?
    private var connectionEpoch = 0
    private var hasSeenTHR = false

    init() {
        loadCachedCatalog()
        refreshCatalog()
        do {
            let transport = try MIDITransport()
            self.transport = transport
            probe = USBIdentityProbe(transport: transport)
            session = THRSession(transport: transport, captureDirectory: root.appendingPathComponent("Captures"))
            toneHistory = try ToneHistoryArchive(url: root.appendingPathComponent("tone-history.json"))
            history = toneHistory?.entries.reversed() ?? []
            Task { imported = (try? await PresetLibrary(directory: root).entries()) ?? [] }
            refresh()
            saveDiagnostics()
        }
        catch { status = "Core MIDI could not start: \(error.localizedDescription)" }
    }

    private var catalogCacheURL: URL { root.appendingPathComponent("hosted-catalog.json") }

    private func loadCachedCatalog() {
        guard let data = try? Data(contentsOf: catalogCacheURL),
              let catalog = try? HostedCatalog.decode(data) else { return }
        hosted = catalog.entries()
        catalogRevision = catalog.revision
        catalogStatus = "Saved catalogue · \(hosted.count) sounds"
    }

    func refreshCatalog(force: Bool = false) {
        guard let catalogURL else {
            catalogStatus = "Bundled sounds available"
            return
        }
        guard !catalogRefreshing else { return }
        if !force, let checked = lastCatalogCheck, Date().timeIntervalSince(checked) < 300 { return }
        catalogRefreshing = true
        Task {
            defer { catalogRefreshing = false }
            do {
                var request = URLRequest(url: catalogURL)
                request.timeoutInterval = 12
                request.cachePolicy = .reloadIgnoringLocalCacheData
                if let catalogRevision { request.setValue("\"\(catalogRevision)\"", forHTTPHeaderField: "If-None-Match") }
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw AmpError("No HTTP response from sound catalogue.") }
                if http.statusCode == 304 {
                    lastCatalogCheck = Date()
                    catalogStatus = "Up to date · \(hosted.count) sounds"
                    return
                }
                guard http.statusCode == 200 else { throw AmpError("Sound catalogue returned HTTP \(http.statusCode).") }
                let catalog = try HostedCatalog.decode(data)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try data.write(to: catalogCacheURL, options: .atomic)
                hosted = catalog.entries()
                catalogRevision = catalog.revision
                lastCatalogCheck = Date()
                catalogStatus = "Updated · \(hosted.count) sounds"
            } catch {
                lastCatalogCheck = Date()
                catalogStatus = "Offline · using \(hosted.isEmpty ? "bundled" : "saved") sounds"
            }
        }
    }

    func refresh() {
        let previousIDs = Set(endpoints.map(\.id))
        let all = MIDITransport.endpoints().filter { !$0.offline }
        endpoints = all
        let endpointsChanged = previousIDs != Set(all.map(\.id))
        pairs = all.filter {
            $0.isSource && $0.entity != 0 &&
            $0.name.localizedCaseInsensitiveContains("THR") &&
            !$0.driverOwner.localizedCaseInsensitiveContains("Bluetooth")
        }
            .compactMap { source in
                guard let destination = all.first(where: {
                    !$0.isSource && $0.entity == source.entity &&
                    $0.name.localizedCaseInsensitiveContains("THR") &&
                    !$0.driverOwner.localizedCaseInsensitiveContains("Bluetooth")
                }) else { return nil }
                return USBMIDIPair(source: source, destination: destination)
            }
        if pairs.isEmpty {
            let disappeared = attemptedPairID != nil || connected || result != nil
            if attemptedPairID != nil {
                attemptedPairID = nil
                connectionEpoch += 1
            }
            result = nil
            if connected { connected = false; currentTone = nil; Task { try? await session?.disconnect() } }
            if disappeared {
                status = "THR disconnected. Reconnect its USB cable."
                saveDiagnostics()
            }
            else if endpointsChanged { saveDiagnostics() }
            return
        }
        if let attemptedPairID, !pairs.contains(where: { $0.id == attemptedPairID }) {
            self.attemptedPairID = nil
            connectionEpoch += 1
            result = nil
            connected = false
            currentTone = nil
            status = "THR changed USB endpoint · reconnecting…"
            Task { try? await session?.disconnect() }
        }
        hasSeenTHR = true
        if result == nil && !probing && !busy && attemptedPairID == nil, let pair = pairs.first {
            inspect(pair)
        }
        if endpointsChanged { saveDiagnostics() }
    }

    func inspect(_ pair: USBMIDIPair) {
        guard let probe, !probing, !busy else { return }
        attemptedPairID = pair.id
        let epoch = connectionEpoch
        probing = true
        result = nil
        status = "Requesting MIDI identity and firmware…"
        Task {
            do {
                let reply = try await probe.probe(source: pair.source, destination: pair.destination)
                if epoch == connectionEpoch && pairs.contains(where: { $0.id == pair.id }) {
                    result = reply
                    status = "THR identified · activating editor session…"
                    probing = false
                    await connect(pair)
                    return
                }
            } catch {
                if epoch == connectionEpoch { status = error.localizedDescription }
            }
            probing = false
            saveDiagnostics()
            if epoch != connectionEpoch { refresh() }
        }
    }

    private func connect(_ pair: USBMIDIPair) async {
        guard let session else { return }
        let epoch = connectionEpoch
        busy = true
        do {
            try await session.connect(source: pair.source, destination: pair.destination)
            let state = await session.status()
            if epoch == connectionEpoch && pairs.contains(where: { $0.id == pair.id }) {
                connected = state.connected
                currentTone = state.tone
                status = state.message
                if let tone = state.tone { record(tone, label: "Amp when connected", kind: .baseline) }
            }
        } catch {
            if epoch == connectionEpoch { connected = false; status = "Connection failed: \(error.localizedDescription)" }
        }
        busy = false
        saveDiagnostics()
    }

    private var historyKey: String { "thr-ii-\(result?.model ?? "unknown"):iphone" }
    private func record(_ tone: Preset, label: String, kind: ToneHistoryKind) {
        do {
            try toneHistory?.record(tone, label: label, kind: kind, deviceKey: historyKey)
            history = toneHistory?.entries.reversed() ?? []
        } catch { status = "Tone read, but history could not be saved: \(error.localizedDescription)" }
    }

    func apply(_ preset: Preset, label: String) {
        guard connected, !busy, let session else { return }
        busy = true; status = "Applying \(label)…"
        Task {
            do {
                try await session.applyTone(preset)
                let state = await session.status()
                currentTone = state.tone
                connected = state.connected
                status = "Applied and verified: \(label)"
                if let tone = state.tone { record(tone, label: label, kind: .audition) }
            } catch {
                let state = await session.status()
                connected = state.connected
                currentTone = state.tone
                status = "Apply failed: \(error.localizedDescription)"
            }
            busy = false
            saveDiagnostics()
        }
    }

    func queueEdit(_ preset: Preset, label: String) {
        pendingEdit?.cancel()
        pendingEdit = Task {
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled else { return }
            while busy && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            guard !Task.isCancelled else { return }
            apply(preset, label: label)
        }
    }

    func readTone() {
        guard connected, !busy, let session else { return }
        busy = true; status = "Reading amp…"
        Task {
            do {
                let tone = try await session.readTone()
                currentTone = tone; status = "Current sound read"
                record(tone, label: "Amp readback", kind: .ampControls)
            } catch { status = "Read failed: \(error.localizedDescription)" }
            busy = false; saveDiagnostics()
        }
    }

    func importPreset(_ url: URL) {
        Task {
            do {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let preset = try THRRemoteFile.importFile(url)
                let entry = LibraryEntry(preset: preset)
                let library = try PresetLibrary(directory: root)
                try await library.save(entry)
                imported = try await library.entries()
                status = "Imported \(preset.name)"
            } catch { status = "Import failed: \(error.localizedDescription)" }
            saveDiagnostics()
        }
    }

    func getSounds() {
        guard !downloading else { return }
        downloading = true; status = "Downloading reviewed community sounds…"
        Task {
            do {
                let library = try PresetLibrary(directory: root)
                let downloaded = try await CommunityPresets.download(into: root.appendingPathComponent("Downloads"))
                _ = try await library.syncCatalog(downloaded)
                imported = try await library.entries()
                status = "\(downloaded.count) community sounds available"
            } catch { status = "Sound download failed: \(error.localizedDescription)" }
            downloading = false; saveDiagnostics()
        }
    }

    func saveSound(_ preset: Preset) {
        saveEntry(LibraryEntry(preset: preset))
    }

    func saveEntry(_ entry: LibraryEntry) {
        Task {
            do {
                let library = try PresetLibrary(directory: root)
                try await library.save(entry)
                imported = try await library.entries()
                status = "Saved \(entry.title) to My sounds"
            } catch { status = "Save failed: \(error.localizedDescription)" }
            saveDiagnostics()
        }
    }

    func archiveEntry(_ entry: LibraryEntry) {
        Task {
            do {
                let library = try PresetLibrary(directory: root)
                try await library.archive(entry)
                imported = try await library.entries()
                status = "Sound moved to Archived"
            } catch { status = "Archive failed: \(error.localizedDescription)" }
            saveDiagnostics()
        }
    }

    func restoreEntry(_ id: UUID) {
        Task {
            do {
                let library = try PresetLibrary(directory: root)
                try await library.restore(id)
                imported = try await library.entries()
                status = "Sound restored"
            } catch { status = "Restore failed: \(error.localizedDescription)" }
            saveDiagnostics()
        }
    }

    func saveDiagnostics() {
        do {
            let log = try transport?.log.export() ?? Data("[]".utf8)
            let payload: [String: Any] = [
                "appBuild": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
                "date": ISO8601DateFormatter().string(from: Date()),
                "status": status,
                "catalogStatus": catalogStatus,
                "catalogRevision": catalogRevision ?? "bundled",
                "lastSoundDesignMethod": lastSoundDesignMethod ?? "none",
                "lastSoundResearchStatus": lastSoundResearchStatus ?? "none",
                "connected": connected,
                "firmware": result?.firmware ?? "unknown",
                "endpoints": endpoints.map { ["name": $0.name, "id": "\($0.id)", "entity": "\($0.entity)", "driver": $0.driverOwner, "input": "\($0.isSource)"] },
                "midiLog": try JSONSerialization.jsonObject(with: log)
            ]
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("amp-workbench-diagnostics.json")
            try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
            diagnosticURL = url
        } catch { diagnosticURL = nil }
    }
}

private enum PhonePage: Hashable {
    case connection
    case settings
    case preset(String)
}

struct PhoneWorkbenchView: View {
    @ObservedObject var probe: PhoneProbeModel
    @AppStorage("soundAIMode") private var soundAIMode = SoundAIMode.appleIntelligence.rawValue
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: PhonePage?
    private let bundled: [LibraryEntry]
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    private var featured: [LibraryEntry] {
        let archivedSources = Set(probe.imported.filter { $0.archivedAt != nil }.compactMap { $0.source?.id })
        let remote = Dictionary(uniqueKeysWithValues: probe.hosted.compactMap { entry in
            entry.source.map { ($0.id, entry) }
        })
        let bundledIDs = Set(bundled.compactMap { $0.source?.id })
        return (bundled.map { remote[$0.source?.id ?? ""] ?? $0 }
            + probe.hosted.filter { entry in !bundledIDs.contains(entry.source?.id ?? "") })
            .filter { !archivedSources.contains($0.source?.id ?? "") }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private var importedUnique: [LibraryEntry] {
        let hostedIDs = Set(featured.compactMap { $0.source?.id })
        return probe.imported.filter { $0.archivedAt == nil && ($0.source == nil || !hostedIDs.contains($0.source!.id)) }
    }
    private var unsavedCreated: LibraryEntry? {
        guard let createdSound, !probe.imported.contains(where: { $0.id == createdSound.id }) else { return nil }
        return createdSound
    }
    private var presets: [LibraryEntry] { featured + importedUnique + (unsavedCreated.map { [$0] } ?? []) }
    private var searchResults: [LibraryEntry] { SoundFinder.shortlist(search, from: presets, limit: 30) }
    private func matches(_ entry: LibraryEntry) -> Bool {
        search.isEmpty || ([entry.title, entry.subtitle, entry.preset.description, entry.source?.originalName ?? ""]
            + entry.preset.tags).joined(separator: " ").localizedCaseInsensitiveContains(search)
    }
    private func hostedIn(_ prefix: String) -> [LibraryEntry] {
        featured.filter { $0.source?.id.hasPrefix(prefix) == true && matches($0) }
    }
    @State private var showingImporter = false
    @State private var creatingSound = false
    @State private var creationStage = ""
    @State private var creationError: String?
    @State private var createdSound: LibraryEntry?
    @State private var incomingPreset: Preset?
    @State private var showingImportLink = false
    @State private var linkError: String?

    private func createSound() {
        let request = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !creatingSound else { return }
        creatingSound = true
        creationStage = soundAIMode == SoundAIMode.appleIntelligence.rawValue ? "Designing on device…" :
            soundAIMode == SoundAIMode.localRules.rawValue ? "Designing offline…" : "Researching…"
        creationError = nil
        Task {
            do {
                let research: SoundResearchResponse?
                var directSources: [SoundResearchSource] = []
                var result: DesignedSound
                let researchNote: String
                if soundAIMode == SoundAIMode.cloud.rawValue {
                    let cloud = try await SoundResearchClient.design(request)
                    research = cloud.research
                    researchNote = cloud.researchStatus
                    result = try SoundDesigner.create(request, cloudIntent: cloud.intent)
                    result.trace = try SoundGenerationTrace(phase: "Create", provider: cloud.promptTrace?.model ?? "Cloudflare AI",
                        request: request, systemPrompt: cloud.promptTrace?.systemPrompt,
                        userPrompt: cloud.promptTrace?.userPrompt ?? request,
                        intent: result.intent, preset: result.preset, rawResponse: cloud.promptTrace?.rawResponse)
                } else if soundAIMode == SoundAIMode.openAI.rawValue {
                    let response = try await DirectOpenAI.design(request)
                    research = nil
                    directSources = response.sources
                    researchNote = response.usedWebSearch
                        ? response.sources.isEmpty
                            ? "OpenAI searched the web, but returned no source links. Treat gear claims as unverified."
                            : "OpenAI searched the web. Review linked sources before relying on gear claims."
                        : "OpenAI designed this from your description without a web search."
                    result = try SoundDesigner.create(request, cloudIntent: response.intent,
                                                      method: "OpenAI \(response.model)")
                    result.trace = try SoundGenerationTrace(phase: "Create", provider: "OpenAI \(response.model)",
                        request: request, systemPrompt: response.systemPrompt,
                        userPrompt: response.userPrompt, intent: result.intent,
                        preset: result.preset, rawResponse: response.rawResponse)
                } else {
                    research = nil
                    let policy: OnDeviceSoundPolicy = soundAIMode == SoundAIMode.localRules.rawValue
                        ? .localRules : .appleIntelligence
                    creationStage = policy == .appleIntelligence ? "Designing on device…" : "Designing offline…"
                    result = try await SoundDesigner.create(request, policy: policy)
                    researchNote = "Designed from your description without web research."
                }
                let entry = LibraryEntry(preset: result.preset,
                                         researchSources: research?.sources ?? directSources,
                                         researchNote: researchNote,
                                         generationMethod: result.method,
                                         designIntent: result.intent,
                                         generationTraces: result.trace.map { [$0] })
                createdSound = entry
                probe.lastSoundDesignMethod = result.method
                probe.lastSoundResearchStatus = researchNote
                selection = .preset(entry.id.uuidString)
                search = ""
                searchFocused = false
            } catch { creationError = error.localizedDescription }
            creatingSound = false
            creationStage = ""
        }
    }

    init(probe: PhoneProbeModel) {
        self.probe = probe
        let entries = (try? CuratedPresets.load()) ?? []
        self.bundled = entries
        self._selection = State(initialValue: entries.first.map { .preset($0.source?.id ?? $0.title) } ?? .connection)
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find or describe a sound", text: $search)
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .onSubmit { if !searchResults.isEmpty { selection = .preset(searchResults[0].source?.id ?? searchResults[0].id.uuidString) } }
                        .accessibilityIdentifier("soundSearchField")
                    if !search.isEmpty {
                        Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 11)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 16).padding(.vertical, 8)
            List(selection: $selection) {
                if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section {
                        Button(action: createSound) {
                            HStack(spacing: 12) {
                                Image(systemName: "sparkles").foregroundStyle(.purple)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(creatingSound ? creationStage : "Create a new sound")
                                        .font(.headline)
                                    Text(search).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer()
                                if creatingSound { ProgressView() }
                                else { Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        .disabled(creatingSound)
                        .accessibilityIdentifier("createSoundButton")
                        if let creationError { Text(creationError).font(.caption).foregroundStyle(.red) }
                    }
                }
                if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Section("Matching sounds") {
                        ForEach(searchResults) { entry in
                            NavigationLink(value: PhonePage.preset(entry.source?.id ?? entry.id.uuidString)) { PhoneSoundRow(entry: entry) }
                        }
                    }
                } else {
                if let unsavedCreated {
                    Section("Unsaved") {
                        NavigationLink(value: PhonePage.preset(unsavedCreated.id.uuidString)) {
                            PhoneSoundRow(entry: unsavedCreated)
                        }
                    }
                }
                Section("Made here") {
                    ForEach(hostedIn("amp-workbench/")) { entry in
                        NavigationLink(value: PhonePage.preset(entry.source?.id ?? entry.title)) {
                            PhoneSoundRow(entry: entry)
                        }
                    }
                }
                Section("Yamaha") {
                    ForEach(hostedIn("yamaha-thr-remote/")) { entry in
                        NavigationLink(value: PhonePage.preset(entry.source?.id ?? entry.title)) { PhoneSoundRow(entry: entry) }
                    }
                }
                Section("Community") {
                    ForEach(featured.filter { $0.source?.id.hasPrefix("f3sty/") == true || $0.source?.id.hasPrefix("cifra-club/") == true }.filter(matches)) { entry in
                        NavigationLink(value: PhonePage.preset(entry.source?.id ?? entry.title)) { PhoneSoundRow(entry: entry) }
                    }
                }
                if !importedUnique.isEmpty {
                    Section("My sounds") {
                        ForEach(importedUnique.filter(matches)) { entry in
                            NavigationLink(value: PhonePage.preset(entry.id.uuidString)) {
                                PhoneSoundRow(entry: entry)
                            }
                        }
                    }
                }
                }
            }
            .navigationTitle("Sounds")
            }
            .safeAreaInset(edge: .bottom) {
                Button { selection = .connection } label: {
                    HStack(spacing: 12) {
                        Image(systemName: probe.connected ? "checkmark.circle.fill" : "cable.connector")
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(probe.connected ? (probe.result?.model ?? "THR connected") : "Amp offline").font(.headline)
                            Text(probe.connected ? "USB-C connected" : "Connect THR via USB-C")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(.regularMaterial)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { selection = .settings } label: { Label("Settings", systemImage: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { probe.refreshCatalog(force: true) } label: { Label("Refresh sounds", systemImage: "arrow.clockwise") }
                            .disabled(probe.catalogRefreshing)
                        Button { probe.getSounds() } label: { Label("Get community sounds", systemImage: "square.and.arrow.down") }
                            .disabled(probe.downloading)
                        Button { showingImporter = true } label: { Label("Import sound", systemImage: "doc.badge.plus") }
                        Text(probe.catalogStatus)
                    } label: { Label("Sound library actions", systemImage: "ellipsis.circle") }
                }
            }
        } detail: {
            switch selection {
            case .connection, .none: USBProbeView(model: probe)
            case .settings: PhoneSettingsView(model: probe)
            case .preset(let id):
                if let entry = (createdSound?.id.uuidString == id ? createdSound : nil) ?? presets.first(where: { ($0.source?.id ?? $0.title) == id || $0.id.uuidString == id }) {
                    PhonePresetView(entry: entry, model: probe, onConnectionRequest: { selection = .connection },
                        onDraftChange: { draft, intent, method, traces in
                            if createdSound?.id == entry.id {
                                createdSound?.preset = draft
                                createdSound?.designIntent = intent
                                createdSound?.generationMethod = method
                                createdSound?.generationTraces = traces
                            }
                        },
                        onSave: { draft, intent, method, traces in
                            var saved = entry.source == nil ? entry : LibraryEntry(preset: draft,
                                researchSources: entry.researchSources, researchNote: entry.researchNote,
                                generationMethod: method, designIntent: intent, generationTraces: traces)
                            saved.preset = draft
                            saved.designIntent = intent
                            saved.generationMethod = method
                            saved.generationTraces = traces
                            probe.saveEntry(saved)
                            createdSound = saved
                            selection = .preset(saved.id.uuidString)
                        },
                        onDelete: {
                            probe.archiveEntry(entry)
                            if createdSound?.id == entry.id { createdSound = nil }
                            selection = .connection
                        },
                        canDelete: true)
                        .id("\(id):\(probe.catalogRevision ?? "bundled")")
                }
                else { ContentUnavailableView("Sound unavailable", systemImage: "guitars") }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { selection = .connection } label: {
                    Label(probe.connected ? (probe.result?.model ?? "THR connected") : "Amp offline", systemImage: probe.connected ? "checkmark.circle.fill" : "cable.connector")
                }
                .accessibilityLabel(probe.connected ? "Amp connected, show connection" : "Amp offline, show connection")
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { probe.refresh(); probe.refreshCatalog() }
        }
        .onOpenURL { url in
            do {
                incomingPreset = try PresetShareLink.read(url)
                showingImportLink = true
            } catch { linkError = error.localizedDescription }
        }
        .confirmationDialog("Import \(incomingPreset?.name ?? "sound")?", isPresented: $showingImportLink) {
            Button("Save to My sounds") {
                if let incomingPreset { probe.saveEntry(LibraryEntry(preset: incomingPreset)) }
                incomingPreset = nil
            }
            Button("Cancel", role: .cancel) { incomingPreset = nil }
        } message: {
            Text("Review the imported sound before applying it to your amp.")
        }
        .alert("Could not open sound", isPresented: Binding(get: { linkError != nil }, set: { if !$0 { linkError = nil } })) {
            Button("OK", role: .cancel) { linkError = nil }
        } message: { Text(linkError ?? "Invalid link") }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.json, UTType(filenameExtension: "thrl6p") ?? .data]) { result in
            if case .success(let url) = result { probe.importPreset(url) }
        }
        .task {
            while !Task.isCancelled {
                if scenePhase == .active { probe.refresh() }
                do { try await Task.sleep(nanoseconds: 1_000_000_000) }
                catch { break }
            }
        }
    }
}

private struct PhoneSoundRow: View {
    let entry: LibraryEntry
    private var style: PresetStyle { PresetStyle.classify(entry.preset) }
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: style.phoneSymbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(style.phoneColor)
                .frame(width: 32, height: 32)
                .background(style.phoneColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.body.weight(.medium)).lineLimit(2)
                Text(style.rawValue).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 2)
    }
}

private struct USBProbeView: View {
    @ObservedObject var model: PhoneProbeModel
    var body: some View {
        List {
            Section {
                Label(model.status, systemImage: model.connected ? "checkmark.circle.fill" : "cable.connector")
                if model.probing || model.busy { ProgressView("Working with amp…") }
                if model.connected {
                    Button("Read current sound") { model.readTone() }.disabled(model.busy)
                }
            } header: { Text("USB-C connection") }
            if let result = model.result {
                Section("Verified response") {
                    LabeledContent("Amp", value: result.model)
                    LabeledContent("Firmware", value: result.firmware)
                    LabeledContent("MIDI source", value: result.source)
                }
            }
            if let tone = model.currentTone {
                Section("On the amp") {
                    LabeledContent("Amplifier", value: ModelLabels.ampTitles[tone.tone["amp"]?.model ?? ""] ?? tone.tone["amp"]?.model ?? "Unknown")
                    LabeledContent("Cabinet", value: ModelLabels.cabinetTitle(Int(tone.tone["cabinet"]?.parameters["SpkSimType"]?.number ?? 0)))
                    Button { model.saveSound(tone) } label: { Label("Save current sound", systemImage: "square.and.arrow.down") }
                }
            }
            if !model.history.isEmpty {
                Section("Earlier sounds") {
                    ForEach(model.history.prefix(12)) { item in
                        Button { model.apply(item.tone, label: item.label) } label: {
                            VStack(alignment: .leading) {
                                Text(item.label)
                                Text(item.date, style: .time).font(.caption).foregroundStyle(.secondary)
                            }
                        }.disabled(!model.connected || model.busy)
                    }
                }
            }
            Section("Diagnostics") {
                if let url = model.diagnosticURL {
                    ShareLink(item: url) { Label("Share diagnostic report", systemImage: "square.and.arrow.up") }
                }
                Text("Includes USB endpoint details and MIDI messages from this session. Send the JSON file if connection or applying a sound fails.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("USB MIDI pairs") {
                if model.pairs.isEmpty {
                    ContentUnavailableView("No THR USB MIDI pair", systemImage: "cable.connector", description: Text("Connect the powered-on THR to this iPhone. Audio appearing in GarageBand alone does not prove MIDI control is available."))
                } else {
                    ForEach(model.pairs) { pair in
                        Button { model.inspect(pair) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(pair.title).foregroundStyle(.primary)
                                Text("Entity \(pair.source.entity) · \(pair.source.driverOwner.isEmpty ? "Core MIDI" : pair.source.driverOwner)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.disabled(model.probing)
                    }
                }
            }
            Section("All visible MIDI endpoints") {
                ForEach(model.endpoints, id: \.id) { endpoint in
                    LabeledContent(endpoint.name, value: endpoint.isSource ? "Input" : "Output")
                }
            }
        }
        .navigationTitle("Connection")
        .toolbar { Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") } }
    }
}

private struct PhoneSettingsView: View {
    @ObservedObject var model: PhoneProbeModel
    @AppStorage("soundAIMode") private var soundAIMode = SoundAIMode.appleIntelligence.rawValue
    @State private var researchKey = ResearchAccessKey.load() ?? ""
    @State private var keySaved = ResearchAccessKey.load() != nil
    @State private var openAIKey = ""
    @State private var openAIKeySaved = OpenAIUserKey.load() != nil
    var body: some View {
        Form {
            Section("Sound creation") {
                Picker("Run AI", selection: $soundAIMode) {
                    ForEach(SoundAIMode.allCases.filter { $0 != .cloud || SoundResearchClient.isConfigured }) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                Text(soundAIMode == SoundAIMode.cloud.rawValue ?
                     "Cloudflare designs the sound using the owner's private quota." :
                     soundAIMode == SoundAIMode.openAI.rawValue ?
                     "Your description goes directly to OpenAI using your API key. Named songs may trigger a paid web search." :
                     soundAIMode == SoundAIMode.localRules.rawValue ?
                     "Offline tone rules make a quick starting sound without an AI model or account." :
                     SoundDesigner.appleIntelligenceAvailable ?
                     "Sound creation and refinement run entirely on this iPhone. No cloud AI or web research is used. The preset library may sync separately." :
                     "Apple Intelligence is unavailable on this iPhone. Choose Local rules or another AI mode.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if soundAIMode == SoundAIMode.openAI.rawValue {
                Section {
                    SecureField(openAIKeySaved ? "Saved key (enter a new one to replace)" : "sk-…", text: $openAIKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Save key") {
                        openAIKeySaved = OpenAIUserKey.save(openAIKey)
                        if openAIKeySaved { openAIKey = "" }
                    }
                    .disabled(openAIKey.isEmpty)
                    if openAIKeySaved {
                        Button("Remove key", role: .destructive) {
                            if OpenAIUserKey.save("") { openAIKeySaved = false }
                            openAIKey = ""
                        }
                    }
                    Text(openAIKeySaved ? "Stored in this iPhone's Keychain." : "Add an API key from your own OpenAI account.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: {
                    Text("Your OpenAI API key")
                } footer: {
                    Text("The key is sent only to api.openai.com for requests you start. OpenAI usage and web-search charges are billed to your account. It is never added to shared sounds or diagnostics.")
                }
            }
            if soundAIMode == SoundAIMode.cloud.rawValue {
            Section {
                SecureField("Access key", text: $researchKey)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save key") {
                    keySaved = ResearchAccessKey.save(researchKey.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                Text(keySaved ? "Key stored in this iPhone’s Keychain." : "Cloud AI and song research require a private key.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Private cloud access")
            } footer: {
                Text("Requests run only when you create a sound. Cloud access is limited to 20 requests per day across all devices.")
            }
            }
            Section("Archived sounds") {
                let archived = model.imported.filter { $0.archivedAt != nil }
                if archived.isEmpty {
                    Text("No archived sounds").foregroundStyle(.secondary)
                } else {
                    ForEach(archived) { entry in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(entry.title)
                                if let date = entry.archivedAt {
                                    Text(date, style: .date).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Restore") { model.restoreEntry(entry.id) }
                        }
                    }
                }
            }
            Section("AI generation history") {
                let generated = model.imported.filter { !($0.generationTraces ?? []).isEmpty }
                if generated.isEmpty {
                    Text("Save an AI sound to inspect its generation here.").foregroundStyle(.secondary)
                } else {
                    ForEach(generated) { entry in
                        DisclosureGroup(entry.title) {
                            ForEach(entry.generationTraces ?? []) { trace in
                                DisclosureGroup("\(trace.phase) · \(trace.provider)") {
                                    LabeledContent("Request", value: trace.request)
                                    if let systemPrompt = trace.systemPrompt {
                                        DisclosureGroup("System prompt") { Text(systemPrompt).textSelection(.enabled) }
                                    }
                                    DisclosureGroup("User prompt") { Text(trace.userPrompt).textSelection(.enabled) }
                                    DisclosureGroup("Structured output") { Text(trace.modelResponse).textSelection(.enabled) }
                                    DisclosureGroup("Rendered THR preset") { Text(trace.renderedPreset).textSelection(.enabled) }
                                }
                            }
                        }
                    }
                }
                Text("These details stay in this app’s library and are excluded from shared sound links.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
    }
}

private struct PhonePresetView: View {
    let entry: LibraryEntry
    @ObservedObject var model: PhoneProbeModel
    let onConnectionRequest: () -> Void
    let onDraftChange: (Preset, SoundDesignIntent, String?, [SoundGenerationTrace]) -> Void
    let onSave: (Preset, SoundDesignIntent, String?, [SoundGenerationTrace]) -> Void
    let onDelete: () -> Void
    let canDelete: Bool
    @AppStorage("soundAIMode") private var soundAIMode = SoundAIMode.appleIntelligence.rawValue
    private var preset: Preset { entry.preset }
    private var style: PresetStyle { PresetStyle.classify(draft) }
    @State private var draft: Preset
    @State private var workingIntent: SoundDesignIntent
    @State private var refinement = ""
    @State private var refining = false
    @State private var refinementError: String?
    @State private var workingMethod: String?
    @State private var traces: [SoundGenerationTrace]
    @State private var showingDetails = false
    @State private var confirmDelete = false
    init(entry: LibraryEntry, model: PhoneProbeModel, onConnectionRequest: @escaping () -> Void,
         onDraftChange: @escaping (Preset, SoundDesignIntent, String?, [SoundGenerationTrace]) -> Void,
         onSave: @escaping (Preset, SoundDesignIntent, String?, [SoundGenerationTrace]) -> Void, onDelete: @escaping () -> Void,
         canDelete: Bool) {
        self.entry = entry
        self.model = model
        self.onConnectionRequest = onConnectionRequest
        self.onDraftChange = onDraftChange
        self.onSave = onSave
        self.onDelete = onDelete
        self.canDelete = canDelete
        self._draft = State(initialValue: entry.preset)
        self._workingIntent = State(initialValue: entry.designIntent ?? SoundDesigner.approximateIntent(from: entry.preset))
        self._workingMethod = State(initialValue: entry.generationMethod)
        self._traces = State(initialValue: entry.generationTraces ?? [])
    }
    private func change(_ update: (inout Preset) -> Void) {
        update(&draft)
        workingIntent = SoundDesigner.approximateIntent(from: draft)
        onDraftChange(draft, workingIntent, workingMethod, traces)
        if model.connected { model.queueEdit(draft, label: "Edited \(entry.title)") }
    }
    private func refineSound() {
        let request = refinement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !refining else { return }
        refining = true
        refinementError = nil
        Task {
            do {
                var result: DesignedSound
                if soundAIMode == SoundAIMode.cloud.rawValue {
                    let response = try await SoundResearchClient.refine(request, current: workingIntent)
                    result = try SoundDesigner.refine(request, current: draft, from: workingIntent,
                                                      to: response.intent)
                    result.trace = try SoundGenerationTrace(phase: "Refine", provider: response.promptTrace?.model ?? "Cloudflare AI",
                        request: request, systemPrompt: response.promptTrace?.systemPrompt,
                        userPrompt: response.promptTrace?.userPrompt ?? request,
                        intent: result.intent, preset: result.preset, rawResponse: response.promptTrace?.rawResponse)
                } else if soundAIMode == SoundAIMode.openAI.rawValue {
                    let response = try await DirectOpenAI.refine(request, current: workingIntent)
                    result = try SoundDesigner.refine(request, current: draft, from: workingIntent,
                                                      to: response.intent, method: "OpenAI \(response.model)")
                    result.trace = try SoundGenerationTrace(phase: "Refine", provider: "OpenAI \(response.model)",
                        request: request, systemPrompt: response.systemPrompt,
                        userPrompt: response.userPrompt, intent: result.intent,
                        preset: result.preset, rawResponse: response.rawResponse)
                } else {
                    let policy: OnDeviceSoundPolicy = soundAIMode == SoundAIMode.localRules.rawValue
                        ? .localRules : .appleIntelligence
                    result = try await SoundDesigner.refine(request, current: draft, from: workingIntent,
                                                            policy: policy)
                }
                guard !ToneComparison.equivalent(result.preset, draft) else {
                    refinementError = "No controls changed. Try a more specific request."
                    refining = false
                    return
                }
                draft = result.preset
                workingIntent = result.intent
                workingMethod = result.method
                if let trace = result.trace { traces.append(trace) }
                onDraftChange(draft, workingIntent, workingMethod, traces)
                refinement = ""
                model.lastSoundDesignMethod = result.method
                if model.connected { model.apply(result.preset, label: "Refined \(entry.title)") }
            } catch { refinementError = error.localizedDescription }
            refining = false
        }
    }
    private func control(_ spec: Parameter, group: String) -> some View {
        let value = draft.tone[group]?.parameters[spec.id]
        return Group {
            if spec.type == "boolean" {
                Toggle(spec.name, isOn: Binding(
                    get: { value?.bool ?? false },
                    set: { next in change { $0.tone[group]?.parameters[spec.id] = .boolean(next) } }
                ))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(spec.name)
                        Spacer()
                        Text(String(format: "%.0f%%", ((value?.number ?? 0) - spec.minimum) / max(0.0001, spec.maximum - spec.minimum) * 100))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { value?.number ?? spec.minimum },
                        set: { next in change { $0.tone[group]?.parameters[spec.id] = .number(next) } }
                    ), in: spec.minimum...spec.maximum)
                }
            }
        }
    }
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: style.phoneSymbol)
                            .font(.title2.weight(.medium))
                            .foregroundStyle(style.phoneColor)
                            .frame(width: 46, height: 46)
                            .background(style.phoneColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                            Text("\(style.rawValue) · \(ModelLabels.ampTitles[draft.tone["amp"]?.model ?? ""] ?? "THR amp")")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if !preset.description.isEmpty || entry.source != nil || !preset.suggestions.isEmpty || entry.researchSources != nil {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { showingDetails.toggle() }
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                if !preset.description.isEmpty {
                                    Text(preset.description)
                                        .lineLimit(showingDetails ? nil : 2)
                                        .multilineTextAlignment(.leading)
                                } else {
                                    Text("Details")
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.down")
                                    .rotationEffect(.degrees(showingDetails ? 180 : 0))
                                    .font(.caption.weight(.semibold))
                            }
                            .font(.caption).foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(showingDetails ? "Collapse sound details" : "Expand sound details")
                        if showingDetails {
                            if !preset.suggestions.isEmpty {
                                Text(preset.suggestions).font(.caption).foregroundStyle(.secondary)
                            }
                            if let source = entry.source {
                                Text("\(source.publisher) · \(source.relationship)")
                                    .font(.caption).foregroundStyle(.tertiary)
                                if let reference = source.reference, let url = URL(string: reference) {
                                    Link("Open source", destination: url).font(.caption)
                                }
                            }
                            if let method = entry.generationMethod { Text(method).font(.caption).foregroundStyle(.secondary) }
                            if let note = entry.researchNote { Text(note).font(.caption).foregroundStyle(.secondary) }
                            if let sources = entry.researchSources {
                                ForEach(sources, id: \.url) { source in
                                    Link(source.title, destination: source.url).font(.caption)
                                    Text(source.excerpt).font(.caption2).foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Refine this sound") {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("More midrange, less reverb…", text: $refinement, axis: .vertical)
                        .lineLimit(1...3)
                        .submitLabel(.done)
                        .accessibilityIdentifier("soundRefinementField")
                    Button(action: refineSound) {
                        if refining { ProgressView() }
                        else { Label("Refine", systemImage: "sparkles").labelStyle(.iconOnly) }
                    }
                    .disabled(refining || refinement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
                    .accessibilityLabel("Refine sound with AI")
                }
                if let refinementError { Text(refinementError).font(.caption).foregroundStyle(.red) }
            }
            ForEach(["amp", "cabinet", "compressor", "gate", "modulation", "delay", "reverb"], id: \.self) { group in
                if let block = draft.tone[group], let options = Catalogue.shared.models[group],
                   let selected = options.first(where: { $0.id == block.model }) {
                    Section(group.capitalized) {
                        if options.count > 1 {
                            Picker("Model", selection: Binding(
                                get: { block.model },
                                set: { id in
                                    if let selected = options.first(where: { $0.id == id }) {
                                        change { $0.tone[group] = ToneBlock(model: selected.id, parameters: selected.defaults) }
                                    }
                                }
                            )) {
                                ForEach(options) { option in
                                    Text(group == "amp" ? (ModelLabels.ampTitles[option.id] ?? option.name) : option.name).tag(option.id)
                                }
                            }
                        }
                        if group == "cabinet" {
                            Picker("Speaker", selection: Binding(
                                get: { Int(block.parameters["SpkSimType"]?.number ?? 0) },
                                set: { index in change { $0.tone[group]?.parameters["SpkSimType"] = .number(Double(index)) } }
                            )) {
                                ForEach(0...16, id: \.self) { index in Text(ModelLabels.cabinetTitle(index)).tag(index) }
                            }
                        } else {
                            let enabled = block.parameters["@enabled"]?.bool ?? true
                            ForEach(selected.parameters) { spec in
                                if spec.id == "@enabled" || enabled { control(spec, group: group) }
                            }
                            if !enabled { Text("Off").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
        .navigationTitle("Sound")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { onSave(draft, workingIntent, workingMethod, traces) } label: {
                    Label("Save sound", systemImage: "square.and.arrow.down")
                }
            }
            if let shareURL = try? PresetShareLink.make(for: draft) {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: shareURL) {
                        Label("Share sound", systemImage: "square.and.arrow.up")
                    }
                }
            }
            if canDelete {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Archive sound", systemImage: "archivebox")
                    }
                }
            }
        }
        .confirmationDialog("Archive this sound?", isPresented: $confirmDelete) {
            Button("Archive sound", action: onDelete)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 5) {
                Button {
                    if model.connected { model.apply(draft, label: entry.title) }
                    else { onConnectionRequest() }
                } label: {
                    Label(model.busy ? "Applying…" : model.connected ? "Apply to amp" : "Connect amp",
                          systemImage: model.connected ? "play.fill" : "cable.connector")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy)
                if model.status.lowercased().contains("failed") || model.status.lowercased().contains("error") {
                    Text(model.status).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
            .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 8)
            .background(.regularMaterial)
        }
    }
}

private extension PresetStyle {
    var phoneSymbol: String {
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
    var phoneColor: Color {
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

@main struct AmpWorkbenchPhoneApp: App {
    @StateObject private var probe = PhoneProbeModel()
    var body: some Scene {
        WindowGroup { PhoneWorkbenchView(probe: probe) }
    }
}
