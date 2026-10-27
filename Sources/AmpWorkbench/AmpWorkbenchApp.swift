import SwiftUI
import AppKit
import AmpCore

@main struct AmpWorkbenchApp: App {
    @StateObject private var model=AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("Amp Workbench") {
            WorkbenchView().environmentObject(model).frame(minWidth:1000,minHeight:700)
                .alert("Amp Workbench",isPresented:Binding(get:{model.error != nil},set:{if !$0 {model.error=nil}})) { Button("OK"){model.error=nil} } message: { Text(model.error ?? "") }
                .onReceive(NotificationCenter.default.publisher(for:NSApplication.willTerminateNotification)) { _ in model.flushHistoryForQuit() }
        }.defaultSize(width:1220,height:850)
        .commands {
            CommandGroup(replacing:.newItem) {
                Button("New Preset") { do { model.selectDraft(try Preset.sample()) } catch { model.error=error.localizedDescription } }.keyboardShortcut("n")
                Button("Import Presets…",action:model.importPreset).keyboardShortcut("o")
                Button("Download Community Collection",action:model.downloadCommunityPresets).disabled(model.busy)
            }
            CommandGroup(replacing:.saveItem) {
                Button("Save to Library") { model.save() }.keyboardShortcut("s").disabled(model.draft == nil || model.busy)
                Button("Save a Copy") { model.save(copy:true) }.keyboardShortcut("s",modifiers:[.command,.shift]).disabled(model.draft == nil || model.busy)
                Button("Export Preset JSON…") { model.exportPreset() }.keyboardShortcut("e").disabled(model.draft == nil)
                Button("Export for THR Remote…") { model.exportPreset(thr:true) }.disabled(model.draft == nil)
            }
            CommandGroup(replacing:.undoRedo) {
                Button("Undo",action:model.undo).keyboardShortcut("z").disabled(model.undoStack.isEmpty)
                Button("Redo",action:model.redo).keyboardShortcut("z",modifiers:[.command,.shift]).disabled(model.redoStack.isEmpty)
            }
            CommandMenu("Amplifier") {
                Button("Connect via MIDI",action:model.connect).disabled(model.busy)
                Button("Read Current Tone",action:model.readTone).keyboardShortcut("r").disabled(!model.connected || model.busy)
                Button("Apply Preset",action:model.applyCurrentPreset).keyboardShortcut(.return,modifiers:.command).disabled(!model.connected || model.draft == nil)
                Button("Undo Amp Change",action:model.undoAmpChange).keyboardShortcut("z",modifiers:[.command,.option]).disabled(!model.connected || model.busy || model.previousAmpHistoryID == nil)
                Divider()
                Button("Export Diagnostics…",action:model.exportDiagnostics)
            }
        }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification:Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps:true) }
}
struct WorkbenchView: View {
    @EnvironmentObject var m:AppModel
    @State private var showConnection=false
    @State private var showHistory=false
    @State private var showSoundFinder=false
    @State private var soundRequest=""
    @State private var soundFinding=false
    @State private var soundFinderMessage=""
    @State private var soundCandidates:[LibraryEntry]=[]
    @State private var soundSuggestionID:UUID?
    var body: some View {
        NavigationSplitView {
            VStack(spacing:0) {
                HStack(spacing:8) {
                    Menu {
                        Button { m.styleFilter=nil } label: { Label("All styles",systemImage:m.styleFilter == nil ? "checkmark":"circle") }
                        ForEach(PresetStyle.allCases,id:\.self) { style in
                            Button { m.styleFilter=style } label: { Label(style.rawValue,systemImage:m.styleFilter == style ? "checkmark":style.symbol) }
                        }
                        Divider()
                        ForEach(PresetCollectionFilter.allCases) { collection in
                            Button { m.collectionFilter=collection } label: { Label(collection.rawValue,systemImage:m.collectionFilter == collection ? "checkmark":"circle") }
                        }
                    } label: {
                        Label(m.filterLabel,systemImage:"line.3.horizontal.decrease")
                    }.help("Filter by style or collection")
                    Spacer(minLength:0)
                    Button { showSoundFinder=true } label: { Image(systemName:"sparkle.magnifyingglass") }
                        .buttonStyle(.borderless).help("Describe a sound")
                    Button { m.favouritesOnly.toggle() } label: {
                        Image(systemName:m.favouritesOnly ? "star.fill":"star")
                            .foregroundStyle(m.favouritesOnly ? .orange:.secondary)
                    }.buttonStyle(.borderless).help(m.favouritesOnly ? "Show all sounds":"Show favourites only")
                    Button(action:m.importPreset) { Image(systemName:"square.and.arrow.down") }
                        .buttonStyle(.borderless).help("Import JSON or THR Remote presets")
                }.controlSize(.small).padding(.horizontal,12).padding(.vertical,8)
                List(selection:Binding(get:{m.selection},set:{m.choose($0)})) {
                    ForEach(m.filtered) { e in
                        let style=PresetStyle.classify(e.preset)
                        let selected=m.selection == e.id
                        HStack(spacing:10) {
                            Image(systemName:style.symbol)
                                .font(.system(size:13,weight:.medium))
                                .foregroundStyle(selected ? .white:style.color)
                                .frame(width:26,height:26)
                                .background(selected ? Color.white.opacity(0.18):style.color.opacity(0.13),in:RoundedRectangle(cornerRadius:6))
                                .accessibilityLabel("\(style.rawValue) tone")
                            VStack(alignment:.leading,spacing:4) {
                                Text(e.title).lineLimit(1).fontWeight(.medium)
                                HStack(spacing:4) {
                                    Text(style.rawValue.uppercased())
                                        .font(.system(size:10,weight:.semibold,design:.rounded))
                                        .foregroundStyle(selected ? .white:style.color)
                                    Text("· \(e.subtitle)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            Button { m.favourite(e.id) } label:{ Image(systemName:e.favourite ? "star.fill":"star").foregroundStyle(e.favourite ? .orange:.secondary) }.buttonStyle(.plain).help("Toggle favourite")
                        }.padding(.vertical,4).tag(e.id)
                            .onTapGesture(count:2) { m.choose(e.id); m.applyCurrentPreset() }
                            .help("\(style.rawValue) · \(e.title) · \(e.subtitle)")
                    }
                }.listStyle(.sidebar)
                Divider()
                HStack {
                    Text("\(m.entries.count) presets").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Get sounds",action:m.downloadCommunityPresets).disabled(m.busy).help("Download the THR II community collection and featured patches")
                    Button("New") { do { m.selectDraft(try Preset.sample()) } catch { m.error=error.localizedDescription } }
                }.padding(12)
            }.navigationSplitViewColumnWidth(min:240,ideal:280,max:360)
        } detail: {
            VStack(spacing:0) {
                if m.draft != nil { editor }
                else {
                    ContentUnavailableView {
                        Label("Choose a sound",systemImage:"waveform")
                    } description: { Text("Select a preset, import one, or make your own.") } actions: {
                        Button("Import Presets…",action:m.importPreset)
                        Button("New Sound") { do { m.selectDraft(try Preset.sample()) } catch { m.error=error.localizedDescription } }
                    }
                }
            }
        }
        .searchable(text:$m.search,placement:.sidebar,prompt:"Search sounds")
        .sheet(isPresented:$showSoundFinder) {
            VStack(alignment:.leading,spacing:16) {
                Text("Find a sound").font(.title2.weight(.semibold))
                TextField("Artist, song or sound",text:$soundRequest)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(findSound)
                Text(SoundFinder.modelStatus).font(.caption).foregroundStyle(.secondary)
                if !soundFinderMessage.isEmpty { Text(soundFinderMessage).foregroundStyle(.secondary) }
                if !soundCandidates.isEmpty {
                    VStack(spacing:4) {
                        ForEach(soundCandidates) { entry in
                            Button {
                                m.choose(entry.id)
                                showSoundFinder=false
                            } label: {
                                HStack(spacing:8) {
                                    VStack(alignment:.leading,spacing:2) {
                                        Text(entry.title).fontWeight(.medium)
                                        Text(ModelLabels.ampReference(entry.preset)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if entry.id == soundSuggestionID { Image(systemName:"sparkle") }
                                    Image(systemName:"chevron.right").foregroundStyle(.secondary)
                                }.contentShape(Rectangle()).padding(8)
                            }.buttonStyle(.plain)
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("Cancel") { showSoundFinder=false }
                    Button(soundFinding ? "Finding…":"Find sound",action:findSound)
                        .disabled(soundFinding || soundRequest.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width:440)
        }
        .toolbar {
            ToolbarItemGroup {
                Button(action:m.undo){Image(systemName:"arrow.uturn.backward")}.disabled(m.undoStack.isEmpty).help("Undo edit (⌘Z)")
                Button { showHistory.toggle() } label:{ Image(systemName:"clock.arrow.circlepath") }
                    .help("Tone history")
                    .popover(isPresented:$showHistory,arrowEdge:.bottom) { historyPanel }
                Button { m.save() } label:{Label("Save to Library",systemImage:"square.and.arrow.down")}.disabled(m.draft == nil || m.busy)
                Menu { Button("Preset JSON…"){m.exportPreset()};Button("THR Remote .thrl6p…"){m.exportPreset(thr:true)} } label:{Label("Export",systemImage:"square.and.arrow.up")}.disabled(m.draft == nil)
            }
            ToolbarItem(placement:.primaryAction) { connectionButton }
        }
        .sheet(isPresented:$m.showDiagnostics) {
            VStack(alignment:.leading,spacing:16) {
                Text("Connection diagnostics").font(.title2.weight(.semibold))
                Text("THR10II Wireless USB: identity, tone read, physical Gain updates, and a guarded Gain change/restore passed on firmware 1.50. Bluetooth MIDI pairing is experimental; onboard slot writes are disabled.").foregroundStyle(.secondary)
                ScrollView { Text(m.diagnosticsText()).font(.system(.caption,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }.background(.quaternary.opacity(0.3))
                HStack { Button("Export Log…",action:m.exportDiagnostics); Spacer(); Button("Done"){m.showDiagnostics=false}.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width:800,height:520)
        }
    }
    private func findSound() {
        soundFinding=true
        Task {
            let candidates=SoundFinder.shortlist(soundRequest,from:m.entries,limit:5)
            let suggestion=await SoundFinder.suggest(soundRequest,from:m.entries)
            soundFinding=false
            if let suggestion {
                soundCandidates=[suggestion.entry] + candidates.filter { $0.id != suggestion.entry.id }
                soundSuggestionID=suggestion.entry.id
                soundFinderMessage="\(suggestion.method): \(suggestion.reason). Choose a sound to inspect it."
            } else {
                soundCandidates=[]
                soundSuggestionID=nil
                soundFinderMessage="No matching sound in the library."
            }
        }
    }
    var connectionButton: some View {
        Button { showConnection.toggle() } label: {
            HStack(spacing:6) {
                if m.busy { ProgressView().controlSize(.small) }
                else { Circle().fill(m.connected ? .green:.secondary).frame(width:7,height:7) }
                Text(m.connected ? "THR connected":"Amp offline")
                Image(systemName:"chevron.down").font(.caption2).foregroundStyle(.secondary)
            }.fixedSize().padding(.horizontal,6)
        }.buttonStyle(.plain)
            .help(m.connected ? "\(m.deviceName) · \(m.status)":"Amplifier connection · \(m.status)")
            .popover(isPresented:$showConnection,arrowEdge:.bottom) { connectionDetails }
    }
    var historyPanel: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Text("Tone history").font(.headline)
                Spacer()
                Button("Undo amp change",action:m.undoAmpChange)
                    .disabled(!m.connected || m.busy || m.previousAmpHistoryID == nil)
            }
            Text("Amp changes and edited sounds are saved here as you work.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            if m.historyEntries.isEmpty {
                Text("No changes yet").foregroundStyle(.secondary).frame(maxWidth:.infinity,minHeight:80)
            } else {
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:3) {
                        ForEach(Array(m.historyEntries.reversed())) { entry in
                            Button {
                                showHistory=false
                                m.jumpToHistory(entry.id)
                            } label: {
                                HStack(spacing:10) {
                                    Image(systemName:entry.kind == .draft ? "slider.horizontal.3":"waveform")
                                        .frame(width:18).foregroundStyle(.secondary)
                                    VStack(alignment:.leading,spacing:2) {
                                        Text(entry.label).lineLimit(1).fontWeight(entry.id == m.activeAmpHistoryID ? .semibold:.regular)
                                        Text("\(entry.kind == .draft ? "Edit":"Amp") · \(entry.date.formatted(date:.abbreviated,time:.shortened))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength:0)
                                    if entry.id == m.activeAmpHistoryID { Image(systemName:"checkmark").foregroundStyle(.secondary) }
                                }.padding(.horizontal,8).padding(.vertical,7).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .disabled(m.busy || (entry.kind.isAmpState && !m.connected))
                        }
                    }
                }.frame(maxHeight:420)
            }
        }.padding(16).frame(width:340,alignment:.leading)
    }
    var connectionDetails: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack(spacing:10) {
                Image(systemName:m.connected ? "cable.connector":"cable.connector.slash")
                    .font(.title3).foregroundStyle(m.connected ? .primary:.secondary)
                VStack(alignment:.leading,spacing:3) {
                    Text(m.connected ? m.deviceName:"No amplifier connected").font(.headline)
                    Text(m.status).font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            if m.connected {
                Button("Read Current Tone",action:m.readTone).disabled(m.busy)
                Button("Edit Current Tone",action:m.editCurrentTone).disabled(m.liveTone == nil || m.busy)
            } else {
                if m.endpoints.count > 1 {
                    Picker("USB device",selection:$m.selectedEndpoint) {
                        ForEach(m.endpoints) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                HStack {
                    Button("Refresh",action:m.refreshEndpoints)
                    Button("Connect USB",action:m.connect).disabled(m.busy || m.selectedEndpoint == nil)
                }
            }
            Menu("Bluetooth MIDI · experimental") {
                Button("Pair LE_THRII…",action:m.showBluetoothMIDIPairing)
                Button("Connect Paired Device",action:m.connectPairedBluetoothMIDI).disabled(m.busy)
            }
            Button("Connection Diagnostics…") { showConnection=false; m.showDiagnostics=true }
        }.padding(16).frame(width:300,alignment:.leading)
    }
    var editor: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:22) {
                HStack(alignment:.top) {
                    VStack(alignment:.leading,spacing:8) {
                        if let entry=m.selectedEntry, let displayName=entry.displayName {
                            Text(displayName).font(.largeTitle.weight(.semibold))
                            Text(entry.subtitle).font(.caption).foregroundStyle(.secondary)
                                .help("Original: \(entry.source?.originalName ?? entry.preset.name)\n\(entry.source?.relationship ?? "")")
                        } else {
                            TextField("Preset name",text:Binding(get:{m.draft?.name ?? ""},set:{v in m.update{$0.name=v}})).textFieldStyle(.plain).font(.largeTitle.weight(.semibold))
                        }
                        if m.modified { Text("Unsaved changes").font(.caption).foregroundStyle(.orange) }
                    }
                    Spacer()
                    Button(action:m.applyCurrentPreset) { Label("Apply",systemImage:"arrow.down.to.line") }.buttonStyle(.borderedProminent).tint(.teal).disabled(!m.connected)
                }
                TextField("Describe this sound",text:Binding(get:{m.draft?.description ?? ""},set:{v in m.update{$0.description=v}}),axis:.vertical).textFieldStyle(.plain).foregroundStyle(.secondary)
                if let source=m.selectedEntry?.source {
                    HStack(spacing:8) {
                        Text("\(source.publisher) · \(source.relationship)")
                            .foregroundStyle(.secondary)
                        if let reference=source.reference, let url=URL(string:reference) {
                            Link("Source",destination:url)
                        }
                    }.font(.caption)
                }
                HStack {
                    Image(systemName:"tag").foregroundStyle(.secondary)
                    TextField("Tags, separated by commas",text:Binding(get:{m.draft?.tags.joined(separator:", ") ?? ""},set:{v in m.update{$0.tags=v.split(separator:",").map{$0.trimmingCharacters(in:.whitespaces)}}})).textFieldStyle(.plain)
                }.font(.callout)
                if !m.connected { Label("Offline editing. Tone changes will apply when the amp is connected and you edit or choose Apply.",systemImage:"info.circle").font(.caption).foregroundStyle(.secondary) }
                if let preset=m.draft {
                    let setup=GuitarSetupSuggestion.forEntry(m.selectedEntry,preset:preset)
                    VStack(alignment:.leading,spacing:8) {
                        HStack {
                            Text("GUITAR SETUP").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Spacer()
                            Text(setup.basis).font(.caption).foregroundStyle(.secondary)
                        }
                        HStack(spacing:24) {
                            VStack(alignment:.leading,spacing:3) { Text("Pickup").font(.caption).foregroundStyle(.secondary); Text(setup.pickup) }
                            VStack(alignment:.leading,spacing:3) { Text("Guitar tone").font(.caption).foregroundStyle(.secondary); Text(setup.tone) }
                            VStack(alignment:.leading,spacing:3) { Text("Guitar volume").font(.caption).foregroundStyle(.secondary); Text(setup.volume) }
                            Spacer(minLength:0)
                        }.font(.callout)
                    }.padding().background(.quaternary.opacity(0.3),in:RoundedRectangle(cornerRadius:12))
                }
                LazyVGrid(columns:[GridItem(.flexible(),alignment:.top),GridItem(.flexible(),alignment:.top)],alignment:.leading,spacing:16) {
                    ForEach(Catalogue.groups,id:\.self) { group in BlockEditor(group:group) }
                }
                VStack(alignment:.leading,spacing:8) {
                    Text("PLAYING NOTES").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    TextField("Pickup, guitar controls and playing suggestions",text:Binding(get:{m.draft?.suggestions ?? ""},set:{v in m.update{$0.suggestions=v}}),axis:.vertical).textFieldStyle(.plain)
                }.padding().background(.quaternary.opacity(0.3),in:RoundedRectangle(cornerRadius:12))
                Text("Patch master shapes the amp model. Set physical Guitar/Audio output levels on the THR. Presets never send those global controls. Onboard memory writes are unavailable in this milestone.").font(.caption).foregroundStyle(.secondary)
            }.padding(26).frame(maxWidth:1100)
        }.background(Color(nsColor:.windowBackgroundColor))
    }
}
struct BlockEditor: View {
    @EnvironmentObject var m:AppModel
    let group:String
    var block:ToneBlock? {m.draft?.tone[group]}
    var model:Model? {block.flatMap{Catalogue.shared.model($0,group:group)}}
    var title:String { ["amp":"Amplifier & EQ","cabinet":"Cabinet","compressor":"Compressor","gate":"Noise gate","modulation":"Modulation","delay":"Delay","reverb":"Reverb"][group]! }
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            Text(title).font(.headline)
            Picker("Model",selection:Binding(get:{block?.model ?? ""},set:{id in
                guard let new=Catalogue.shared.models[group]?.first(where:{$0.id == id}) else {return}
                m.update{$0.tone[group]=ToneBlock(model:id,parameters:new.defaults)}
            })) {
                ForEach(Catalogue.shared.models[group] ?? []) { option in
                    Text(group == "amp" ? ModelLabels.ampTitle(option) : option.name).tag(option.id)
                }
            }.labelsHidden()
            if group == "amp", let model {
                Text("Yamaha: \(model.name) · best-fit reference, not an exact replica")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let model {
                ForEach(model.parameters) { spec in
                    if spec.type == "boolean" {
                        Toggle(spec.name,isOn:Binding(get:{block?.parameters[spec.id]?.bool ?? false},set:{v in m.update{$0.tone[group]?.parameters[spec.id] = .boolean(v)}})).toggleStyle(.switch).controlSize(.small)
                    } else if group == "cabinet" {
                        Picker("Speaker",selection:Binding(get:{Int(block?.parameters[spec.id]?.number ?? 0)},set:{v in m.update{$0.tone[group]?.parameters[spec.id] = .number(Double(v))}})) {
                            ForEach(Array(Self.cabs.enumerated()),id:\.offset){i,_ in Text(ModelLabels.cabinetTitle(i)).tag(i)}
                        }
                        Text("Yamaha: \(Self.cabs[max(0,min(Self.cabs.count - 1,Int(block?.parameters[spec.id]?.number ?? 0)))])")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        VStack(spacing:4) {
                            HStack { Text(spec.name); Spacer(); Text(display(spec)).monospacedDigit().foregroundStyle(.secondary) }.font(.callout)
                            Slider(value:Binding(get:{block?.parameters[spec.id]?.number ?? spec.minimum},set:{v in m.update{$0.tone[group]?.parameters[spec.id] = .number(v)}}),in:spec.minimum...spec.maximum).accessibilityLabel(spec.name)
                        }
                    }
                }
            }
        }.padding(18).frame(maxWidth:.infinity,alignment:.leading).background(Color(nsColor:.controlBackgroundColor),in:RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).stroke(.quaternary))
    }
    func display(_ p:Parameter)->String { let n=block?.parameters[p.id]?.number ?? 0; return p.unit == "dB" ? String(format:"%.1f dB",n):String(format:"%.0f %%",n*100) }
    static let cabs=["British 4×12","American 4×12","Brown 4×12","Vintage 4×12","Fuel 4×12","Juicy 4×12","Mods 4×12","American 2×12","British 2×12","British Blues","Boutique 2×12","Yamaha 2×12","California 1×12","American 1×12","American 4×10","Boutique 1×12","Bypass"]
}
