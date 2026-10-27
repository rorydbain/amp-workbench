import XCTest
@testable import AmpCore
@testable import AmpMIDI

private final class OpenAIRequestStub: URLProtocol {
    static var inspect: ((URLRequest) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.inspect?(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 401,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class AmpCoreTests: XCTestCase {
    func testDirectOpenAIResponseKeepsSourcesAndRejectsInvalidIntent() throws {
        let intent = """
        {"style":"warm","ampVoice":"THR10C_Deluxe","gain":5,"bass":5,"middle":7,"treble":5,
        "ambience":3,"echo":0,"movement":0,"modulationType":"none","ampMaster":7,
        "cabinetStyle":"american1x12","compression":2,"noiseGate":0,"delayType":"none",
        "delayTime":4,"delayFeedback":3,"reverbType":"spring","reverbDecay":4,
        "modulationSpeed":3,"modulationDepth":5}
        """.replacingOccurrences(of: "\n", with: "")
        func response(_ value: String) -> Data {
            let payload: [String: Any] = ["status": "completed", "output": [
                ["type": "web_search_call", "action": ["type": "search", "sources": [
                    ["url": "https://example.org/rig", "title": "Rig notes"]]]],
                ["type": "message", "content": [["type": "output_text", "text": value,
                    "annotations": [["type": "url_citation", "url": "https://example.org/rig", "title": "Rig notes"]]]]]
            ]]
            return try! JSONSerialization.data(withJSONObject: payload)
        }
        let parsed = try DirectOpenAI.decode(response(intent), system: "system", user: "user")
        XCTAssertEqual(parsed.intent.ampVoice, "THR10C_Deluxe")
        XCTAssertTrue(parsed.usedWebSearch)
        XCTAssertEqual(parsed.sources.map(\.url.absoluteString), ["https://example.org/rig"])
        XCTAssertThrowsError(try DirectOpenAI.decode(response(intent.replacingOccurrences(of: "\"gain\":5", with: "\"gain\":99")), system: "", user: ""))
        XCTAssertThrowsError(try DirectOpenAI.decode(response(intent.replacingOccurrences(of: "THR10C_Deluxe", with: "UnknownAmp")), system: "", user: ""))
    }
    func testDirectOpenAIRequestUsesUserKeyAndBoundedStructuredOutput() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenAIRequestStub.self]
        let session = URLSession(configuration: configuration)
        OpenAIRequestStub.inspect = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-only")
            let sent: Data
            if let data = request.httpBody { sent = data }
            else if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var bytes: [UInt8] = []
                var chunk = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&chunk, maxLength: chunk.count)
                    if count <= 0 { break }
                    bytes.append(contentsOf: chunk.prefix(count))
                }
                sent = Data(bytes)
            } else { XCTFail("Missing HTTP body"); return }
            let body = try! XCTUnwrap(JSONSerialization.jsonObject(with: sent) as? [String: Any])
            XCTAssertEqual(body["store"] as? Bool, false)
            XCTAssertEqual((body["tools"] as? [[String: Any]])?.first?["type"] as? String, "web_search")
            let text = try! XCTUnwrap(body["text"] as? [String: Any])
            let format = try! XCTUnwrap(text["format"] as? [String: Any])
            XCTAssertEqual(format["type"] as? String, "json_schema")
            XCTAssertEqual(format["strict"] as? Bool, true)
            XCTAssertFalse(String(data: sent, encoding: .utf8)!.contains("sk-test-only"))
        }
        defer { OpenAIRequestStub.inspect = nil }
        do {
            _ = try await DirectOpenAI.design("A warm blues sound", key: "sk-test-only", session: session)
            XCTFail("Stub should return an authorization failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("rejected this API key"))
        }
    }
    func testOnDeviceModesDoNotSilentlySubstituteRulesForAppleModel() async throws {
        let rules = try await SoundDesigner.create("Warm blues guitar", policy: .localRules)
        XCTAssertEqual(rules.method, "On-device tone rules")
        if !SoundDesigner.appleIntelligenceAvailable {
            do {
                _ = try await SoundDesigner.create("Warm blues guitar", policy: .appleIntelligence)
                XCTFail("Apple Intelligence mode must report unavailability")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("Apple Intelligence is unavailable"))
            }
        }
    }
    func testAppleIntelligenceModeRejectsResearchInput() async throws {
        let research = SoundResearchResponse(query: "blues", sources: [], basis: "web")
        do {
            _ = try await SoundDesigner.create("Warm blues guitar", research: research, policy: .appleIntelligence)
            XCTFail("On-device mode must reject web research even if a caller passes it")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("cannot use cloud or web research"))
        }
    }
    func testCloudIntentIsRenderedAsSupportedTone() throws {
        let intent = SoundDesignIntent(style: "warm", ampVoice: "THR10C_Deluxe", gain: 5, bass: 6,
                                       middle: 7, treble: 5, ambience: 2, echo: 0, movement: 0)
        let result = try SoundDesigner.create("A warm blues sound", cloudIntent: intent)
        try result.preset.validate()
        XCTAssertEqual(result.preset.tone["amp"]?.model, "THR10C_Deluxe")
        XCTAssertEqual(result.method, "Cloudflare AI")
    }
    func testSoundDesignerRendersStructuredInternalControlsAndUploadRoundTrip() throws {
        let intent = SoundDesignIntent(style: "lead", ampVoice: "THR10_Lead", gain: 6, bass: 5,
                                       middle: 6, treble: 5, ambience: 5, echo: 4, movement: 6,
                                       modulationType: "flanger", ampMaster: 8,
                                       cabinetStyle: "british4x12", compression: 5, noiseGate: 2,
                                       delayType: "digital", delayTime: 7, delayFeedback: 6,
                                       reverbType: "plate", reverbDecay: 8,
                                       modulationSpeed: 4, modulationDepth: 7)
        let sound = try SoundDesigner.create("A spacious lead", cloudIntent: intent).preset
        try sound.validate()
        XCTAssertEqual(sound.tone["amp"]?.model, "THR10_Lead")
        XCTAssertEqual(try XCTUnwrap(sound.tone["amp"]?.parameters["Master"]?.number), 0.84, accuracy: 0.001)
        XCTAssertEqual(sound.tone["cabinet"]?.parameters["SpkSimType"]?.number, 0)
        XCTAssertEqual(sound.tone["compressor"]?.parameters["@enabled"]?.bool, true)
        XCTAssertEqual(sound.tone["gate"]?.parameters["@enabled"]?.bool, true)
        XCTAssertEqual(sound.tone["modulation"]?.model, "L6Flanger")
        XCTAssertEqual(sound.tone["delay"]?.model, "L6DigitalDelay")
        XCTAssertEqual(sound.tone["reverb"]?.model, "LargePlate1")
        XCTAssertEqual(try XCTUnwrap(sound.tone["delay"]?.parameters["Time"]?.number), 0.675, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(sound.tone["reverb"]?.parameters["Decay"]?.number), 0.7, accuracy: 0.001)
        let symbols = try THRCompactSymbols.firmware150()
        let encoded = try THRToneUpload.data(sound, symbols: symbols)
        let decoded = try THRToneDecoder.decode(Binary.words([0, 0, 1, 0]) + encoded, symbols: symbols)
        XCTAssertTrue(ToneComparison.equivalent(decoded, sound))
    }
    func testLegacyIntentStillRendersWithoutNewFields() throws {
        let old = """
            {"style":"clean","ampVoice":"","gain":3,"bass":5,"middle":5,"treble":5,"ambience":2,"echo":0,"movement":0}
            """
        let intent = try JSONDecoder().decode(SoundDesignIntent.self, from: Data(old.utf8))
        let preset = try SoundDesigner.create("Old app request", cloudIntent: intent).preset
        try preset.validate()
        XCTAssertEqual(preset.tone["compressor"]?.parameters["@enabled"]?.bool, false)
        XCTAssertEqual(preset.tone["delay"]?.parameters["@enabled"]?.bool, false)
    }
    func testRefinementChangesOnlyRequestedToneParameters() throws {
        let original = SoundDesignIntent(style: "crunch", ampVoice: "THR10_Lead", gain: 6,
            bass: 5, middle: 5, treble: 6, ambience: 2, echo: 0, movement: 0)
        var current = try SoundDesigner.create("Rhythm sound", cloudIntent: original).preset
        current.tone["amp"]?.parameters["Treble"] = .number(0.73) // manually edited
        var next = original
        next.middle = 8
        let result = try SoundDesigner.refine("More midrange", current: current, from: original, to: next)
        XCTAssertEqual(result.preset.tone["amp"]?.parameters["Mid"]?.number, 0.8)
        XCTAssertEqual(result.preset.tone["amp"]?.parameters["Treble"]?.number, 0.73)
        XCTAssertEqual(result.preset.tone["delay"], current.tone["delay"])
        XCTAssertEqual(result.intent.middle, 8)
        let unchanged = try SoundDesigner.refine("Keep this", current: current, from: original, to: original)
        XCTAssertTrue(ToneComparison.equivalent(unchanged.preset, current))
    }
    func testOffEffectsRetainAudibleDefaultsForManualEnable() throws {
        let intent = SoundDesignIntent(style: "highGain", ampVoice: "THR10_Lead", gain: 8,
            bass: 5, middle: 4, treble: 7, ambience: 3, echo: 0, movement: 0,
            modulationType: "none", delayType: "none", delayTime: 0,
            delayFeedback: 0, modulationSpeed: 0, modulationDepth: 0)
        let preset = try SoundDesigner.create("American Idiot rhythm guitar", cloudIntent: intent).preset
        XCTAssertEqual(preset.tone["delay"]?.parameters["@enabled"]?.bool, false)
        XCTAssertEqual(preset.tone["modulation"]?.parameters["@enabled"]?.bool, false)
        XCTAssertGreaterThan(try XCTUnwrap(preset.tone["delay"]?.parameters["@wetDry"]?.number), 0.1)
        XCTAssertGreaterThan(try XCTUnwrap(preset.tone["modulation"]?.parameters["@wetDry"]?.number), 0.1)
        XCTAssertGreaterThan(try XCTUnwrap(preset.tone["delay"]?.parameters["Time"]?.number), 0.3)
    }
    func testSavedSoundCanBeDeletedWithoutChangingOtherEntries() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("amp-library-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try PresetLibrary(directory: directory)
        let first = LibraryEntry(preset: try .sample())
        let second = LibraryEntry(preset: try .sample())
        try await library.save(first)
        try await library.save(second)
        try await library.delete(first.id)
        let remaining = try await library.entries()
        XCTAssertEqual(remaining.map(\.id), [second.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("library.previous.json").path))
    }
    func testArchivingPreservesSoundAndCanRestoreIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("amp-archive-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try PresetLibrary(directory: directory)
        let entry = LibraryEntry(preset: try .sample())
        try await library.save(entry)
        try await library.archive(entry)
        var saved = try await library.entries()
        XCTAssertNotNil(saved.first?.archivedAt)
        XCTAssertEqual(saved.first?.id, entry.id)
        try await library.restore(entry.id)
        saved = try await library.entries()
        XCTAssertNil(saved.first?.archivedAt)
        XCTAssertEqual(saved.first?.preset, entry.preset)
    }
    func testShareLinkRoundTripRejectsTampering() throws {
        let preset = try Preset.sample()
        let link = try PresetShareLink.make(for: preset)
        XCTAssertEqual(try PresetShareLink.read(link), preset)
        XCTAssertThrowsError(try PresetShareLink.read(URL(string: "ampworkbench://sound?v=2&p=AAAA")!))
        XCTAssertThrowsError(try PresetShareLink.read(URL(string: "ampworkbench://evil?v=1&p=AAAA")!))
    }
    func testOlderLibraryEntriesDecodeWithoutResearchMetadata() throws {
        let entry = LibraryEntry(preset: try .sample())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        json.removeValue(forKey: "researchSources")
        json.removeValue(forKey: "researchNote")
        json.removeValue(forKey: "generationMethod")
        let old = try JSONSerialization.data(withJSONObject: json)
        let restored = try JSONDecoder().decode(LibraryEntry.self, from: old)
        XCTAssertNil(restored.researchSources)
        XCTAssertEqual(restored.id, entry.id)
    }
    func testSoundDesignerCreatesDistinctValidTones() async throws {
        let clean = try await SoundDesigner.create("A dry bright clean rhythm guitar with no delay or reverb")
        let lead = try await SoundDesigner.create("A heavy singing lead with echo and huge reverb")
        try clean.preset.validate()
        try lead.preset.validate()
        XCTAssertNotEqual(clean.preset.tone["amp"]?.model, lead.preset.tone["amp"]?.model)
        XCTAssertEqual(clean.preset.tone["delay"]?.parameters["@enabled"]?.bool, false)
        XCTAssertEqual(clean.preset.tone["reverb"]?.parameters["@enabled"]?.bool, false)
        XCTAssertEqual(lead.preset.tone["delay"]?.parameters["@enabled"]?.bool, true)
        XCTAssertEqual(lead.preset.tone["reverb"]?.parameters["@enabled"]?.bool, true)
        let chime = try await SoundDesigner.create("A dry Vox AC30 chime with bright treble")
        XCTAssertEqual(chime.preset.tone["amp"]?.model, "THR10C_DC30")
    }
    func testSoundFinderGroundsSuggestionsInLibrary() async throws {
        let entries = try CuratedPresets.load()
        let target = try XCTUnwrap(entries.first { $0.title.localizedCaseInsensitiveContains("Come When I Call") })
        let shortlist = SoundFinder.shortlist("John Mayer Come When I Call", from: entries)
        XCTAssertEqual(shortlist.first?.id, target.id)
        let result = await SoundFinder.suggest("John Mayer Come When I Call", from: entries)
        XCTAssertEqual(result?.entry.id, target.id)
        let missing = await SoundFinder.suggest("zzzxxyy unlisted", from: entries)
        XCTAssertNil(missing)
    }
    func testSoundFinderIndexesEditorialAmpReferences() throws {
        let deluxe = try Preset.sample()
        var plexi = deluxe
        let model = try XCTUnwrap(Catalogue.shared.models["amp"]?.first { $0.id == "THR10_Lead" })
        plexi.tone["amp"] = ToneBlock(model: model.id, parameters: model.defaults)
        let deluxeEntry = LibraryEntry(preset: deluxe)
        let plexiEntry = LibraryEntry(preset: plexi)
        XCTAssertTrue(ModelLabels.ampReference(deluxe).contains("Fender Deluxe"))
        XCTAssertEqual(SoundFinder.shortlist("Fender Deluxe", from: [plexiEntry, deluxeEntry]).first?.id, deluxeEntry.id)
        XCTAssertEqual(SoundFinder.shortlist("Marshall Plexi", from: [deluxeEntry, plexiEntry]).first?.id, plexiEntry.id)
    }
    func testHostedCatalogValidationAndVersionedReplacement() throws {
        let original = try CuratedPresets.load()[0]
        let source = try XCTUnwrap(original.source)
        let item = HostedPreset(id: source.id, publisher: source.publisher,
                                reference: source.reference, relationship: source.relationship,
                                preset: original.preset)
        let first = try HostedCatalog.decode(JSONEncoder().encode(HostedCatalog(revision: "test.1", presets: [item])))
        XCTAssertEqual(first.entries()[0].source?.id, source.id)
        var revisedTone = original.preset
        revisedTone.tone["amp"]?.parameters["Drive"] = .number(0.41)
        let revised = HostedPreset(id: source.id, publisher: source.publisher,
                                   reference: source.reference, relationship: source.relationship,
                                   preset: revisedTone)
        let second = try HostedCatalog.decode(JSONEncoder().encode(HostedCatalog(revision: "test.2", presets: [revised])))
        XCTAssertNotEqual(first.entries()[0].preset, second.entries()[0].preset)
        XCTAssertThrowsError(try HostedCatalog(revision: "test.3", presets: [item, item]).validate())
        XCTAssertThrowsError(try HostedCatalog(revision: "test.3", presets: [HostedPreset(id: "bad\npath", publisher: "x", reference: nil, relationship: "", preset: original.preset)]).validate())
        XCTAssertThrowsError(try HostedCatalog.decode(Data(repeating: 32, count: 2_000_001)))
    }
    func testCompactMobileSymbolsRoundTripAllCuratedTones() throws {
        let compact = try THRCompactSymbols.firmware150()
        XCTAssertEqual(compact.crc, 0xdd54cd72)
        for entry in try CuratedPresets.load() {
            let encoded = try THRToneUpload.data(entry.preset, symbols: compact)
            let decoded = try THRToneDecoder.decode(Binary.words([0,0,1,0]) + encoded, symbols: compact)
            XCTAssertTrue(ToneComparison.equivalent(decoded, entry.preset), entry.title)
        }
    }
    func testBitbucketKnownVectorAndEveryLength() throws {
        // Upstream ParseSysEx uses MSB first (bit 6 of bucket).
        XCTAssertEqual(Bitbucket.encode([0xa5,0x3c,0xff,0x10,0xc7,8,0xe1]),[0x55,0x25,0x3c,0x7f,0x10,0x47,8,0x61])
        for length in 0...256 {
            let raw=(0..<length).map{UInt8(truncatingIfNeeded:$0*37+193)}
            XCTAssertEqual(try Bitbucket.decode(Bitbucket.encode(raw),count:raw.count),raw)
        }
        XCTAssertThrowsError(try Bitbucket.decode([0,128],count:1))
    }
    func testSourceDerivedFirmwareRequest() throws {
        // Transcribed from martinzw ParseSysEx.cpp S5, model THR30II=2.
        let fixture:[UInt8]=[0xf0,0,1,0x0c,0x22,2,0x4d,1,0,0,0,7,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0xf7]
        XCTAssertEqual(try THRCommands.firmware(model:2,mode:1).encoded(),fixture)
        XCTAssertEqual(try THRFrame(decoding:fixture).payload,Binary.words([1,0]))
        var bad=fixture; bad[11]=0x80; XCTAssertThrowsError(try THRFrame(decoding:bad))
    }
    func testSourceDerivedCurrentToneRequest() throws {
        let fixture:[UInt8]=[0xf0,0,1,0x0c,0x22,2,0x4d,1,2,0,0,0x0b,0,0x0c,0,0,0,4,0,0,0x3c,0,0x7f,0x7f,0x7f,0x7f,0,0,0xf7]
        XCTAssertEqual(try THRCommands.currentTone(model:2,counter:2).encoded(),fixture)
    }
    func testFrameRejectsTruncatedExcessAndWrongFamily() throws {
        let f=THRFrame(mode:0,counter:127,payload:[0xff,0,0x80,1])
        let bytes=try f.encoded(); XCTAssertEqual(try THRFrame(decoding:bytes),f)
        for i in 0..<bytes.count { XCTAssertThrowsError(try THRFrame(decoding:Array(bytes.prefix(i)))) }
        var extra=bytes;extra.insert(1,at:extra.count-1);XCTAssertThrowsError(try THRFrame(decoding:extra))
        var bad=bytes;bad[4]=0x23;XCTAssertThrowsError(try THRFrame(decoding:bad))
    }
    func testAssemblerFragmentationRealtimeAndResynchronisation() {
        var a=SysExAssembler()
        XCTAssertEqual(a.consume([0x90,60,127,0xf0,0,1,0xf8]),[])
        XCTAssertEqual(a.consume([2,0xf7,0xf0,3]),[[0xf0,0,1,2,0xf7]])
        XCTAssertEqual(a.consume([0xf0,4,0xf7]),[[0xf0,4,0xf7]])
        XCTAssertEqual(a.consume([0xf0,3,0x90,4,0xf7]),[])
    }
    func testCounterNeverSplitsPairAtRollover() {
        var c=CommandCounter()
        for _ in 0..<500 { let (h,b)=c.pair(); XCTAssertLessThan(h,126); XCTAssertEqual(b,h+1); XCTAssertLessThan(b,128) }
    }
    func testDumpReassemblyAndDroppedFragments() throws {
        let payload=(0..<600).map{UInt8(truncatingIfNeeded:$0)}
        var d=DumpAssembler()
        XCTAssertNil(try d.consume(.init(mode:0,counter:4,sequence:0,payload:Binary.words([1,600])+Array(payload.prefix(202)))))
        XCTAssertNil(try d.consume(.init(mode:0,counter:5,sequence:1,payload:Array(payload[202..<458]))))
        XCTAssertEqual(try d.consume(.init(mode:0,counter:6,sequence:2,payload:Array(payload[458...]))),payload)
        var broken=DumpAssembler()
        _=try broken.consume(.init(mode:0,counter:4,sequence:0,payload:Binary.words([1,600])+Array(payload.prefix(100))))
        XCTAssertThrowsError(try broken.consume(.init(mode:0,counter:4,sequence:2,payload:[0])))
    }
    func testPresetValidationAndUnknownGlobalRejection() throws {
        let p=try Preset.sample(); try p.validate(); XCTAssertEqual(try Preset.decode(p.encoded()),p)
        var bad=p; bad.tone["amp"]?.parameters["Drive"] = .number(1.1); XCTAssertThrowsError(try bad.validate())
        bad=p; bad.tone["amp"]?.parameters["Drive"] = .boolean(true); XCTAssertThrowsError(try bad.validate())
        bad=p; bad.tone["cabinet"]?.parameters["SpkSimType"] = .number(2.5); XCTAssertThrowsError(try bad.validate())
        bad=p; bad.target="line6.fx100";XCTAssertThrowsError(try bad.validate())
        bad=p;bad.tone["amp"]?.parameters["MasterVolume"] = .number(1);XCTAssertThrowsError(try bad.validate())
        var obj=try JSONSerialization.jsonObject(with:p.encoded()) as! [String:Any]; obj["outputVolume"]=1
        XCTAssertThrowsError(try Preset.decode(JSONSerialization.data(withJSONObject:obj)))
        bad=p;bad.firmwareConstraints=["01440061"];XCTAssertThrowsError(try bad.validate(firmware:0x01500062))
    }
    func testRemoteConversionPreservesToneAndRejectsDifferentDevice() throws {
        let p=try Preset.sample(), data=try THRRemoteFile.encode(p), after=try THRRemoteFile.decode(data)
        XCTAssertEqual(after.tone,p.tone)
        var root=try JSONSerialization.jsonObject(with:data) as! [String:Any];var d=root["data"] as! [String:Any];d["device"]=0x240003;root["data"]=d
        XCTAssertThrowsError(try THRRemoteFile.decode(JSONSerialization.data(withJSONObject:root)))
    }
    func testLibraryPersistenceDoesNotConfuseNameWithIdentity() async throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)}
        let library=try PresetLibrary(directory:dir);var entry=LibraryEntry(preset:try .sample())
        try await library.save(entry); entry.favourite=true;try await library.save(entry)
        let entries=try await library.entries();XCTAssertEqual(entries.count,1);XCTAssertTrue(entries[0].favourite)
        try await library.save(LibraryEntry(preset:try .sample()));let two=try await library.entries();XCTAssertEqual(two.count,2)
    }
    func testWritePlanExcludesGlobalsAndRejectsTypeChangeBeforeWriting() throws {
        // Synthetic symbols, not vendor table redistribution or a hardware capture.
        let table=try fixtureSymbols(["Amp","Drive","Master","GuitarProc","SpkSimType"])
        let p=try Preset.sample(); var desired=p;desired.tone["amp"]?.parameters["Drive"] = .number(0.5)
        let plan=try THRWritePlan.make(from:p,to:desired,symbols:table)
        XCTAssertEqual(plan.count,1);XCTAssertEqual(plan[0].bits,Float(0.5).bitPattern)
        desired.tone["amp"]?.model="THR10C_DC30";XCTAssertThrowsError(try THRWritePlan.make(from:p,to:desired,symbols:table))
    }
    func testMalformedSymbolAndToneDumpsFailClosed() throws {
        XCTAssertThrowsError(try SymbolTable(bytes:[0,0]))
        let table=try fixtureSymbols(["Amp"])
        XCTAssertThrowsError(try THRToneDecoder.decode(Array(repeating:0,count:500),symbols:table))
    }
    func fixtureSymbols(_ names:[String]) throws -> SymbolTable {
        var bytes=Binary.words([UInt32(names.count),0])+Array(repeating:UInt8(0),count:names.count*12)
        bytes += names.flatMap{Array($0.utf8)+[0]}; let size=Binary.words([UInt32(bytes.count)]);bytes.replaceSubrange(4..<8,with:size)
        return try SymbolTable(bytes:bytes)
    }
}
actor FixtureDevice: ToneDevice {
    var preset:Preset;var failApply=false;var failRead=false;var writes=0
    init() throws { preset=try .sample() }
    func setFailure(_ value:Bool) {failApply=value}
    func readTone() async throws -> Preset {if failRead{throw AmpError("read failure")};return preset}
    func applyTone(_ p:Preset) async throws {writes += 1; if failApply {throw AmpError("fixture disconnect")};preset=p}
    func identityKey() async throws -> String {"fixture-only"}
}
final class RestorationTests:XCTestCase {
    func testFailedPreviewRetainsJournalUntilVerifiedRestore() async throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)}
        let device=try FixtureDevice();let service=AuditionService(device:device,journal:dir.appendingPathComponent("recovery.json"))
        var desired=try Preset.sample();desired.tone["amp"]?.parameters["Drive"] = .number(0.5)
        await device.setFailure(true)
        do{try await service.preview(desired);XCTFail("Should fail")}catch{}
        let retained=await service.hasRecovery();XCTAssertTrue(retained)
        do{try await service.preview(desired);XCTFail("Retry should fail while device fails")}catch{}
        let writes=await device.writes;XCTAssertEqual(writes,2)
        do{try await service.restore();XCTFail("Should fail")}catch{}
        let stillRetained=await service.hasRecovery();XCTAssertTrue(stillRetained)
        await device.setFailure(false)
        // Simulate restart: new service uses the existing recovery file.
        let restarted=AuditionService(device:device,journal:dir.appendingPathComponent("recovery.json"))
        try await restarted.restore();let cleared=await restarted.hasRecovery();XCTAssertFalse(cleared)
    }
    func testConsecutiveAuditionsKeepFirstRecoveryTone() async throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString);defer{try? FileManager.default.removeItem(at:dir)}
        let device=try FixtureDevice();let original=try await device.readTone()
        let service=AuditionService(device:device,journal:dir.appendingPathComponent("recovery.json"))
        var first=original;first.tone["amp"]?.parameters["Drive"] = .number(0.4)
        var second=original;second.tone["amp"]?.parameters["Drive"] = .number(0.7)
        try await service.preview(first)
        try await service.preview(second)
        let current=try await device.readTone()
        XCTAssertTrue(ToneComparison.equivalent(current,second))
        try await service.restore()
        let restored=try await device.readTone()
        let hasRecovery=await service.hasRecovery()
        XCTAssertTrue(ToneComparison.equivalent(restored,original))
        XCTAssertFalse(hasRecovery)
    }
}

final class ToneHistoryTests:XCTestCase {
    func testHistoryPreservesBaselineDebouncesEditsAndCanJumpToEarlierTone() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let url=dir.appendingPathComponent("tone-history.json")
        let history=try ToneHistoryArchive(url:url)
        let original=try Preset.sample()
        let start=Date(timeIntervalSince1970:1_000)
        let baseline=try history.record(original,label:"Amp when connected",kind:.baseline,deviceKey:"amp-1",at:start)
        var knob=original;knob.tone["amp"]?.parameters["Drive"] = .number(0.6)
        let first=try history.record(knob,label:"Amp controls",kind:.ampControls,deviceKey:"amp-1",coalesceWithin:2,at:start.addingTimeInterval(5))
        knob.tone["amp"]?.parameters["Drive"] = .number(0.7)
        let settled=try history.record(knob,label:"Amp controls",kind:.ampControls,deviceKey:"amp-1",coalesceWithin:2,at:start.addingTimeInterval(6))
        XCTAssertEqual(first.id,settled.id)
        XCTAssertEqual(history.entries.count,2)
        XCTAssertTrue(ToneComparison.equivalent(history.entries[0].tone,original))
        var draft=original;draft.tone["amp"]?.parameters["Drive"] = .number(0.8)
        try history.record(draft,label:"Edited A",kind:.draft,deviceKey:nil,coalesceWithin:2,at:start.addingTimeInterval(7))
        try history.record(knob,label:"Edited B",kind:.draft,deviceKey:nil,coalesceWithin:2,at:start.addingTimeInterval(8))
        XCTAssertEqual(history.entries.count,4,"Different edited sounds must not coalesce")
        try history.activate(baseline.id,deviceKey:"amp-1")
        XCTAssertTrue(ToneComparison.equivalent(history.activeAmpTone!,original))
        XCTAssertThrowsError(try history.activate(settled.id,deviceKey:"another-amp"))
        let reopened=try ToneHistoryArchive(url:url)
        XCTAssertEqual(reopened.entries.count,4)
        XCTAssertEqual(reopened.activeAmpID,baseline.id)
    }
    func testLegacyRecoveryMovesIntoHistoryWithoutDeletingSnapshot() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        let journal=dir.appendingPathComponent("recovery.json")
        let original=try Preset.sample()
        try jsonEncoder().encode(RecoverySnapshot(device:"amp-1",original:original,created:Date())).write(to:journal)
        let history=try ToneHistoryArchive(url:dir.appendingPathComponent("tone-history.json"))
        try history.migrateRecovery(at:journal)
        XCTAssertEqual(history.entries.count,1)
        XCTAssertEqual(history.entries[0].kind,.earlierTone)
        XCTAssertFalse(FileManager.default.fileExists(atPath:journal.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:dir.path).contains(where:{$0.hasPrefix("recovery.archived-in-history-")}))
    }
}
