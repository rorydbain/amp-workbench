import Foundation
import AmpCore
import AmpMIDI

actor CheckToneDevice: ToneDevice {
    private var tone:Preset
    init(_ tone:Preset) { self.tone=tone }
    func readTone() async throws -> Preset { tone }
    func applyTone(_ preset:Preset) async throws { tone=preset }
    func identityKey() async throws -> String { "offline-check" }
}

var checks = 0
func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
    guard try condition() else { throw AmpError("Check failed: \(name)") }
    checks += 1
}
func expectFailure(_ name: String, _ action: () throws -> Void) throws {
    do { try action(); throw AmpError("Check failed: \(name) accepted invalid input") }
    catch let e as AmpError where e.message.hasPrefix("Check failed:") { throw e }
    catch { checks += 1 }
}
@MainActor func run() async throws {
    for count in 1...64 {
        let raw = (0..<count).map { UInt8(truncatingIfNeeded: $0 * 37 + 128) }
        try check(Bitbucket.decode(Bitbucket.encode(raw), count: count) == raw, "bitbucket \(count)")
    }
    let frame = THRFrame(mode: 1, counter: 17, payload: Binary.words([0x12345678, 0xdeadbeef]))
    try check(THRFrame(decoding: frame.encoded()) == frame, "frame roundtrip")
    let shortUploadFrame=THRFrame(model:1,mode:1,counter:18,sequence:2,payload:[0x80,0x01,0x02])
    let paddedUpload=try shortUploadFrame.encoded()
    try check(Array(paddedUpload[12..<20]) == [0x40,0x00,0x01,0x02,0,0,0,0] && paddedUpload.count == 21 && THRFrame(decoding:paddedUpload) == shortUploadFrame, "upload pads an incomplete seven-byte group")
    let sourceFirmwareRequest: [UInt8] = [0xf0,0,1,0x0c,0x22,2,0x4d,0,0,0,0,7,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0xf7]
    try check(THRCommands.firmware(model:2).encoded() == sourceFirmwareRequest, "source firmware request fixture")
    let sourceToneRequest: [UInt8] = [0xf0,0,1,0x0c,0x22,2,0x4d,1,2,0,0,0x0b,0,0x0c,0,0,0,4,0,0,0x3c,0,0x7f,0x7f,0x7f,0x7f,0,0,0xf7]
    try check(THRCommands.currentTone(model:2,counter:2).encoded() == sourceToneRequest, "source tone request fixture")
    let activation = try THRFrame(model:2,mode:0,counter:2,payload:Binary.words([0xdd54cd72])).encoded()
    try check(Array(activation[12..<17]) == [0x28,0x72,0x4d,0x54,0x5d], "1.44 activation token encoding")
    try expectFailure("truncated frame") { _ = try THRFrame(decoding: Array(frame.encoded().dropLast())) }
    var assembler = SysExAssembler()
    try check(assembler.consume([0xf0,0x7e,0xf8]).isEmpty, "fragment hold")
    try check(assembler.consume([0x7f,0xf7]) == [[0xf0,0x7e,0x7f,0xf7]], "fragment reassembly")
    let dump = (0..<1114).map { UInt8(truncatingIfNeeded:$0) }
    var joined=DumpAssembler()
    try check(joined.consume(.init(model:1,mode:1,counter:2,sequence:0,payload:Binary.words([1,1114])+Array(dump[..<248]))) == nil, "tone dump first fragment")
    for sequence in 1...3 {
        let lower=248+(sequence-1)*256
        try check(joined.consume(.init(model:1,mode:1,counter:UInt8(2+sequence),sequence:UInt8(sequence),payload:Array(dump[lower..<(lower+256)]))) == nil, "tone dump middle fragment \(sequence)")
    }
    try check(joined.consume(.init(model:1,mode:1,counter:6,sequence:4,payload:Array(dump[1016...]))) == dump, "tone dump final fragment")
    var missing=DumpAssembler()
    _=try missing.consume(.init(model:1,mode:1,counter:2,sequence:0,payload:Binary.words([1,1114])+Array(dump[..<248])))
    try expectFailure("dropped tone fragment") { _=try missing.consume(.init(model:1,mode:1,counter:4,sequence:2,payload:Array(dump[504..<760]))) }
    let p = try Preset.sample()
    try check(Preset.decode(p.encoded()) == p, "preset roundtrip")
    var changedCabinet=p
    changedCabinet.tone["cabinet"]?.parameters["SpkSimType"] = .number(6)
    let cabinetWrites=try THRWritePlan.make(from:p,to:changedCabinet,symbols:SymbolTable.localRemoteTable())
    try check(cabinetWrites.count == 1 && cabinetWrites[0].group == "cabinet" && cabinetWrites[0].type == 2 && cabinetWrites[0].bits == 6, "cabinet live command uses integer enum")
    var bad = p; bad.tone["amp"]?.parameters["Drive"] = .number(1.5)
    try expectFailure("range validation") { try bad.validate() }
    bad = p; bad.target = "line6.fx100"
    try expectFailure("wrong device") { try bad.validate() }
    let imported = try THRRemoteFile.decode(THRRemoteFile.encode(p))
    try check(ToneComparison.equivalent(p, imported), "THR Remote file roundtrip")
    var templated=try JSONSerialization.jsonObject(with:THRRemoteFile.encode(p)) as! [String:Any]
    var data=templated["data"] as! [String:Any]
    var tone=data["tone"] as! [String:Any]
    var modulation=tone["THRGroupFX2Effect"] as! [String:Any]
    modulation["inactiveCommunityTemplateField"]=0.73
    tone["THRGroupFX2Effect"]=modulation; data["tone"]=tone; templated["data"]=data
    let extraField=try JSONSerialization.data(withJSONObject:templated)
    try expectFailure("strict THR importer rejects extra parameters") { _=try THRRemoteFile.decode(extraField) }
    let normalized=try THRRemoteFile.decode(extraField,ignoringInactiveParameters:true)
    try check(ToneComparison.equivalent(normalized,p), "community import omits only inactive parameters")
    try check(Set(ModelLabels.ampTitles.keys) == Set(Catalogue.shared.models["amp"]!.map(\.id)), "all amp references covered")
    try check(ModelLabels.cabinetTitles.count == 17, "all cabinet references covered")
    try check(CommunityPresetTitles.format("ACDC") == "AC/DC", "community AC/DC label")
    try check(CommunityPresetTitles.format("AC/DC Live") == "AC/DC Live", "community slash acronym preserved")
    try check(CommunityPresetTitles.format("Vox Ac30 Breakup") == "Vox AC30 Breakup", "community amp acronym")
    try check(CommunityPresetTitles.format("Still Got The Blues") == "Still Got the Blues", "community title casing")
    try check(CommunityPresetTitles.format("Marshall 1987X Plexi EOB (2x12)") == "Marshall 1987X Plexi EOB (2x12)", "community model designation preserved")
    try check(CommunityPresetTitles.format("Plexi Sh_t") == "Plexi Sh_t", "contributor spelling preserved")
    try check(CommunityPresetTitles.format("Gilmour Shine On Tou Crazy Diamond THRii") == "Gilmour · Shine On You Crazy Diamond · THR II", "reviewed song title")
    let curated=try CuratedPresets.load()
    try check(curated.count == 3 && Set(curated.map(\.title)) == Set(["John Mayer Trio · Come When I Call", "Stevie Ray Vaughan · Pride and Joy", "Chris Stapleton · Tennessee Whiskey"]), "curated titles")
    try check(PresetStyle.classify(curated[0].preset) == .warm, "Mayer clean blues patch receives warm browsing cue")
    var highGainStyle=curated[0].preset
    highGainStyle.tone["amp"]?.model="THR10_Modern"
    try check(PresetStyle.classify(highGainStyle) == .highGain, "high-gain model takes priority over blues tags")
    var soloStyle=curated[0].preset
    soloStyle.tags=["solo"]
    try check(PresetStyle.classify(soloStyle) == .lead, "solo tag receives lead browsing cue")
    try check(curated[0].preset.tone["amp"]?.model == "THR10C_Deluxe" && curated[0].preset.tone["cabinet"]?.parameters["SpkSimType"] == .number(13), "curated amp and cab")
    try check(ToneComparison.equivalent(try THRRemoteFile.decode(THRRemoteFile.encode(curated[0].preset)), curated[0].preset), "curated THR Remote export roundtrip")
    for entry in curated {
        try check(ToneComparison.equivalent(try THRRemoteFile.decode(THRRemoteFile.encode(entry.preset)), entry.preset), "\(entry.title) THR Remote export roundtrip")
    }
    let bareEntry = try JSONDecoder().decode(LibraryEntry.self, from: jsonEncoder().encode(LibraryEntry(preset:p)))
    try check(bareEntry.title == p.name && bareEntry.source == nil, "older library entries remain readable")
    let factoryPath = URL(fileURLWithPath:"/Applications/THR Remote.app/Contents/Resources",isDirectory:true)
    if FileManager.default.fileExists(atPath:factoryPath.path) {
        let factory = try FactoryPresets.load(from:factoryPath)
        try check(factory.count == 46, "all installed Yamaha guitar presets classified")
        try check(Set(factory.map { $0.source!.id }).count == factory.count, "factory source ids unique")
        try check(factory.allSatisfy { $0.displayName != nil && $0.preset.name == $0.source?.originalName }, "display titles preserve Yamaha names")
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent("amp-catalog-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:temp) }
        let library=try PresetLibrary(directory:temp)
        let firstImport=try await library.syncCatalog(factory)
        try check(firstImport == 46, "catalog first import")
        let secondImport=try await library.syncCatalog(factory)
        try check(secondImport == 0, "catalog import idempotent")
        var retained=try await library.entries().first(where: { $0.source?.id == factory[0].source?.id })!
        retained.favourite=true
        retained.preset.description="user-edited tone metadata"
        try await library.save(retained)
        var revised=factory
        revised[0].displayName="Editorial revision"
        let revisionCount=try await library.syncCatalog(revised)
        try check(revisionCount == 1, "catalog title revision")
        let after=try await library.entries().first(where: { $0.id == retained.id })!
        try check(after.favourite && after.preset.description == "user-edited tone metadata" && after.displayName == "Editorial revision", "catalog revision preserves user data")
    }
    let table = try SymbolTable.localRemoteTable()
    try check(table.names.count > 100, "installed symbol table")
    try check(table.key("Amp") != table.key("GuitarProc"), "distinct symbols")
    let uploadPresets = curated.map(\.preset) + (FileManager.default.fileExists(atPath:factoryPath.path) ? try FactoryPresets.load(from:factoryPath).map(\.preset) : [])
    for preset in uploadPresets {
        let payload=try THRToneUpload.data(preset,symbols:table)
        let decoded=try THRToneDecoder.decode(Binary.words([0,0,1,0])+payload,symbols:table)
        try check(ToneComparison.equivalent(decoded,preset), "full tone upload roundtrip: \(preset.name)")
        let frames=try THRToneUpload.frames(payload,model:1,counters:(13,14))
        try check(frames[0].words.prefix(3) == [13,UInt32(payload.count+20),0xffffffff] && frames.allSatisfy({ (try? THRFrame(decoding:$0.encoded())) == $0 }) && Array(frames.dropFirst()).flatMap(\.payload) == payload && frames.allSatisfy({ ((try? $0.encoded().count) ?? Int.max) <= 256 }), "full tone upload frames: \(preset.name)")
    }
    let journalDirectory=FileManager.default.temporaryDirectory.appendingPathComponent("amp-audition-check-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at:journalDirectory) }
    let device=CheckToneDevice(p)
    let service=AuditionService(device:device,journal:journalDirectory.appendingPathComponent("recovery.json"))
    try await service.preview(curated[0].preset)
    try await service.preview(p)
    let retained=await service.hasRecovery()
    try check(retained, "consecutive auditions retain original snapshot")
    try await service.restore()
    let restored=try await device.readTone()
    let cleared=await service.hasRecovery()
    try check(ToneComparison.equivalent(restored,p) && !cleared, "restore returns to first tone after multiple auditions")
    let historyDirectory=FileManager.default.temporaryDirectory.appendingPathComponent("amp-history-check-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at:historyDirectory) }
    let history=try ToneHistoryArchive(url:historyDirectory.appendingPathComponent("tone-history.json"))
    let baseline=try history.record(p,label:"Amp when connected",kind:.baseline,deviceKey:"fixture",at:Date(timeIntervalSince1970:100))
    var knob=p;knob.tone["amp"]?.parameters["Drive"] = .number(0.61)
    let firstKnob=try history.record(knob,label:"Amp controls",kind:.ampControls,deviceKey:"fixture",coalesceWithin:2,at:Date(timeIntervalSince1970:105))
    knob.tone["amp"]?.parameters["Drive"] = .number(0.68)
    let settledKnob=try history.record(knob,label:"Amp controls",kind:.ampControls,deviceKey:"fixture",coalesceWithin:2,at:Date(timeIntervalSince1970:106))
    try check(firstKnob.id == settledKnob.id && history.entries.count == 2 && ToneComparison.equivalent(history.entries[0].tone,p), "amp control changes coalesce without losing baseline")
    try history.record(knob,label:"Edited first",kind:.draft,deviceKey:nil,coalesceWithin:2,at:Date(timeIntervalSince1970:107))
    try history.record(p,label:"Edited second",kind:.draft,deviceKey:nil,coalesceWithin:2,at:Date(timeIntervalSince1970:108))
    try check(history.entries.count == 4, "different edited sounds remain separate")
    try history.activate(baseline.id,deviceKey:"fixture")
    let reopened=try ToneHistoryArchive(url:historyDirectory.appendingPathComponent("tone-history.json"))
    try check(reopened.activeAmpID == baseline.id && reopened.entries.count == 4 && ToneComparison.equivalent(reopened.activeAmpTone!,p), "older amp state can be selected after restart")
    print("Passed \(checks) offline checks. No physical-device behavior was asserted.")
}
do { try await run() } catch { fputs("ampcheck: \(error.localizedDescription)\n", stderr); exit(1) }
