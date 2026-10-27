import Foundation
import AmpCore
import AmpMIDI

private struct HardwareAuditResult: Codable {
    let index: Int
    let name: String
    let seconds: Double
    let passed: Bool
    let error: String?
}

@main struct AmpCLI {
    static func main() async {
        do { try await run(Array(CommandLine.arguments.dropFirst())) }
        catch { FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8)); exit(1) }
    }
    static func run(_ args:[String]) async throws {
        let command=args.first ?? "help"
        switch command {
        case "suggest-model":
            guard args.count >= 2 else { throw AmpError("Usage: ampctl suggest-model ARTIST, SONG, OR SOUND") }
            let request=args.dropFirst().joined(separator:" ")
            let entries=try await PresetLibrary(directory:PresetLibrary.defaultDirectory).entries()
            if let result=await SoundFinder.suggest(request,from:entries) {
                print("\(result.method): \(result.entry.title)")
                print(result.reason)
            } else { print("No library match for \(request)") }
        case "suggest":
            guard args.count >= 2 else { throw AmpError("Usage: ampctl suggest ARTIST, SONG, OR SOUND") }
            let request=args.dropFirst().joined(separator:" ")
            let entries=try await PresetLibrary(directory:PresetLibrary.defaultDirectory).entries()
            let candidates=SoundFinder.shortlist(request,from:entries,limit:5)
            if candidates.isEmpty { print("No library match for \(request)") }
            for (index,entry) in candidates.enumerated() {
                print("\(index + 1). \(entry.title) · \(ModelLabels.ampReference(entry.preset))")
            }
        case "snapshot-mac-library":
            guard args.count == 2 else { throw AmpError("Usage: ampctl snapshot-mac-library OUTPUT.json") }
            let entries = try await PresetLibrary(directory: PresetLibrary.defaultDirectory).entries()
            let items = entries.map { entry in
                HostedPreset(id: entry.source?.id ?? "amp-workbench/local/\(entry.id.uuidString.lowercased())",
                             displayName: entry.displayName,
                             originalName: entry.source?.originalName,
                             publisher: entry.source?.publisher ?? "Amp Workbench",
                             reference: entry.source?.reference,
                             relationship: entry.source?.relationship ?? "Saved locally in the Mac library",
                             preset: entry.preset)
            }
            let output = URL(fileURLWithPath: args[1])
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try jsonEncoder().encode(items).write(to: output, options: .atomic)
            print("Snapshotted \(items.count) Mac library sounds")
        case "build-hosted-catalog":
            guard args.count == 3 else { throw AmpError("Usage: ampctl build-hosted-catalog OUTPUT_DIRECTORY REVISION") }
            let directory = URL(fileURLWithPath: args[1], isDirectory: true)
            let extras = directory.deletingLastPathComponent().appendingPathComponent("presets", isDirectory: true)
            var items = try CuratedPresets.load().map { entry -> HostedPreset in
                let source = entry.source!
                return HostedPreset(id: source.id, publisher: source.publisher,
                                    reference: source.reference, relationship: source.relationship,
                                    preset: entry.preset)
            }
            if FileManager.default.fileExists(atPath: extras.path) {
                for url in try FileManager.default.contentsOfDirectory(at: extras, includingPropertiesForKeys: nil)
                    .filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let data = try Data(contentsOf: url)
                    let incoming = if let batch = try? JSONDecoder().decode([HostedPreset].self, from: data) {
                        batch
                    } else { [try JSONDecoder().decode(HostedPreset.self, from: data)] }
                    for item in incoming {
                        if let index = items.firstIndex(where: { $0.id == item.id }) {
                            items[index] = item
                        } else if !items.contains(where: { $0.preset.name == item.preset.name && $0.preset == item.preset }) {
                            items.append(item)
                        }
                    }
                }
            }
            let catalog = HostedCatalog(revision: args[2], presets: items)
            try catalog.validate()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try jsonEncoder().encode(catalog)
            guard data.count <= 2_000_000, let json = String(data: data, encoding: .utf8) else {
                throw AmpError("Hosted catalogue exceeds 2 MB or is not UTF-8.")
            }
            try data.write(to: directory.appendingPathComponent("catalog.json"), options: .atomic)
            try Data("export const catalog = \(json);\n".utf8)
                .write(to: directory.appendingPathComponent("catalog.generated.js"), options: .atomic)
            print("Built hosted catalogue \(catalog.revision): \(items.count) presets, \(data.count) bytes")
        case "ble-scan":
            let scan=BLEMIDIDiscovery(); scan.start()
            try await Task.sleep(nanoseconds:10_000_000_000)
            scan.stop()
            let (state,devices)=scan.snapshot()
            print("\(state) · \(scan.totalSeen()) nearby advertisements")
            if devices.isEmpty { print("No LE_THRII MIDI advertisement seen. The THR10II WIRELESS Bluetooth audio connection is separate; check that the amp is powered on and THR Remote is closed.") }
            for d in devices { print("\(d.name)  \(d.identifier)  RSSI \(d.rssi)  services \(d.services.joined(separator:","))") }
        case "ble-candidates":
            let scan=BLEMIDIDiscovery(); scan.start()
            try await Task.sleep(nanoseconds:10_000_000_000)
            scan.stop()
            print("\(scan.totalSeen()) advertisements; strongest peripherals (names withheld):")
            for d in scan.strongestCandidates() { print("\(d.identifier) RSSI \(d.rssi) manufacturer \(d.manufacturer) services \(d.services.joined(separator:","))") }
        case "ble-connect":
            let before=Set(MIDITransport.endpoints().map(\.id))
            let scan=BLEMIDIDiscovery(); scan.start()
            try await Task.sleep(nanoseconds:10_000_000_000)
            let (_,devices)=scan.snapshot()
            guard let target=devices.first(where:{$0.name.localizedCaseInsensitiveContains("THR")}) ?? (devices.count == 1 ? devices.first:nil) else {
                scan.stop(); throw AmpError("No unambiguous LE_THRII BLE-MIDI advertisement. The 4+5 pairing shortcut is for Bluetooth audio, not this MIDI connection.")
            }
            print("Connecting to \(target.name) (\(target.identifier))")
            scan.connect(target.identifier)
            let deadline=Date().addingTimeInterval(10)
            while Date() < deadline {
                let (state,_)=scan.snapshot()
                if state.contains("connected · CoreMIDI") || state.contains("failed") || state.contains("missing") { break }
                try await Task.sleep(nanoseconds:100_000_000)
            }
            let (state,_)=scan.snapshot(); print(state)
            let new=MIDITransport.endpoints().filter{ !before.contains($0.id) }
            for e in new { print("\(e.isSource ? "IN ":"OUT") \(e.id) entity=\(e.entity) \(e.name)") }
            if new.isEmpty { print("No new CoreMIDI endpoint appeared; Bluetooth tone control is not yet verified.") }
        case "scan":
            let endpoints=MIDITransport.endpoints()
            if endpoints.isEmpty { print("No CoreMIDI endpoints. Connect and power on the THR by USB, then scan again.") }
            for e in endpoints { print("\(e.isSource ? "IN ":"OUT") \(e.id) entity=\(e.entity) \(e.offline ? "OFFLINE":"online") \(e.name) driver=\(e.driverOwner)") }
        case "validate":
            guard args.count == 2 else { throw AmpError("Usage: ampctl validate FILE.json|FILE.thrl6p") }
            let p=try THRRemoteFile.importFile(URL(fileURLWithPath:args[1])); print("Valid: \(p.name) · \(p.target) · \(p.tone.count) blocks")
        case "render-intent":
            guard args.count == 4 else { throw AmpError("Usage: ampctl render-intent INTENT.json OUTPUT.json NAME") }
            let intent = try JSONDecoder().decode(SoundDesignIntent.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
            let preset = try SoundDesigner.create(args[3], cloudIntent: intent).preset
            let output = URL(fileURLWithPath: args[2])
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try jsonEncoder().encode(preset).write(to: output, options: .atomic)
            print("Rendered validated tone: \(preset.name)")
        case "upload-shape":
            guard args.count == 2 else { throw AmpError("Usage: ampctl upload-shape FILE.json|FILE.thrl6p") }
            let p=try THRRemoteFile.importFile(URL(fileURLWithPath:args[1]))
            let data=try THRToneUpload.data(p,symbols:SymbolTable.localRemoteTable())
            let frames=try THRToneUpload.frames(data,model:1,counters:(3,4))
            print("\(p.name): \(data.count) raw bytes; frame payloads \(frames.map { String($0.payload.count) }.joined(separator:", "))")
        case "validate-community":
            guard args.count == 2 else { throw AmpError("Usage: ampctl validate-community FILE.thrl6p") }
            let p=try THRRemoteFile.decode(Data(contentsOf: URL(fileURLWithPath:args[1])), ignoringInactiveParameters:true)
            print("Valid community tone: \(p.name) · \(p.tone.count) blocks; inactive template parameters omitted")
        case "decode-capture":
            guard args.count == 2 else { throw AmpError("Usage: ampctl decode-capture TONE.bin") }
            let symbols=try SymbolTable.localRemoteTable()
            let preset=try THRToneDecoder.decode(Array(Data(contentsOf:URL(fileURLWithPath:args[1]))),symbols:symbols)
            print(String(data:try preset.encoded(),encoding:.utf8)!)
        case "verify-mobile":
            let full = try SymbolTable.localRemoteTable()
            let compact = try THRCompactSymbols.firmware150()
            let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/AmpWorkbench/Captures")
            let captures = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("tone-") && $0.pathExtension == "bin" }
            var checked = 0
            for url in captures {
                let bytes = Array(try Data(contentsOf: url))
                guard let reference = try? THRToneDecoder.decode(bytes, symbols: full) else { continue }
                let mobile = try THRToneDecoder.decode(bytes, symbols: compact)
                guard ToneComparison.equivalent(reference, mobile) else { throw AmpError("Mobile decode differs for \(url.lastPathComponent)") }
                checked += 1
            }
            let entries = try await PresetLibrary(directory: PresetLibrary.defaultDirectory).entries()
            var tones = 0
            for entry in entries {
                let data = try THRToneUpload.data(entry.preset, symbols: compact)
                let roundTrip = try THRToneDecoder.decode(Binary.words([0,0,1,0]) + data, symbols: compact)
                guard ToneComparison.equivalent(roundTrip, entry.preset) else { throw AmpError("Mobile upload differs for \(entry.title)") }
                _ = try THRToneUpload.frames(data, model: 1, counters: (3,4)).map { try $0.encoded() }
                tones += 1
            }
            print("Mobile protocol verified: \(checked) recorded tone dumps; \(tones) library presets encode/decode and frame successfully")
        case "match-upload":
            guard args.count == 2 else { throw AmpError("Usage: ampctl match-upload DIAGNOSTIC.json") }
            let records=try JSONDecoder().decode([DiagnosticRecord].self,from:Data(contentsOf:URL(fileURLWithPath:args[1])))
            let frames=records.compactMap { record -> THRFrame? in
                guard record.direction == "tx" else { return nil }
                let bytes=record.message.split(separator:" ").compactMap { UInt8($0,radix:16) }
                return try? THRFrame(decoding:bytes)
            }
            let symbols=try SymbolTable.localRemoteTable()
            let entries=try await PresetLibrary(directory:PresetLibrary.defaultDirectory).entries()
            for (index,header) in frames.enumerated() where header.mode == 1 && header.words.first == 13 {
                guard header.words.count >= 2, header.words[1] >= 20 else { continue }
                let length=Int(header.words[1]-20)
                var upload:[UInt8]=[], sequence:UInt8=0
                for part in frames.dropFirst(index+1) where part.mode == 1 && part.counter == header.counter+1 {
                    guard part.sequence == sequence else { break }
                    upload += part.payload; sequence += 1
                    if upload.count >= length { break }
                }
                guard upload.count == length else { print("Incomplete upload: \(upload.count)/\(length) bytes"); continue }
                let matches=try entries.filter { try THRToneUpload.data($0.preset,symbols:symbols) == upload }
                print("Upload \(length) bytes: \(matches.map(\.title).joined(separator:", "))")
            }
        case "check-library-uploads":
            let symbols=try SymbolTable.localRemoteTable()
            let library=try PresetLibrary(directory:PresetLibrary.defaultDirectory)
            let entries=try await library.entries()
            var failures:[String]=[]
            for entry in entries {
                do {
                    let payload=try THRToneUpload.data(entry.preset,symbols:symbols)
                    let decoded=try THRToneDecoder.decode(Binary.words([0,0,1,0])+payload,symbols:symbols)
                    guard ToneComparison.equivalent(decoded,entry.preset) else { throw AmpError("roundtrip differs") }
                    let frames=try THRToneUpload.frames(payload,model:1,counters:(3,4))
                    guard Array(frames.dropFirst()).flatMap(\.payload) == payload,
                          try frames.allSatisfy({ try $0.encoded().count <= 256 })
                    else { throw AmpError("upload frames are oversized or incomplete") }
                } catch { failures.append("\(entry.title): \(error.localizedDescription)") }
            }
            for failure in failures { print(failure) }
            print("\(entries.count-failures.count)/\(entries.count) local presets have a round-tripping full-tone upload")
            if !failures.isEmpty { throw AmpError("Some local presets cannot be uploaded yet.") }
        case "audit-library":
            guard args.count == 4, args[1] == "--temporary-write",
                  let start=Int(args[2]), let limit=Int(args[3]), start >= 0, limit > 0, limit <= 30
            else { throw AmpError("Usage: ampctl audit-library --temporary-write START LIMIT (LIMIT at most 30). Verifies each current-tone upload; stops on first failure and leaves the last tone active.") }
            let directory=PresetLibrary.defaultDirectory
            let entries=try await PresetLibrary(directory:directory).entries().sorted {
                ($0.source?.id ?? $0.title).localizedStandardCompare($1.source?.id ?? $1.title) == .orderedAscending
            }
            guard start < entries.count, start+limit <= entries.count else { throw AmpError("Audit range exceeds the \(entries.count)-preset library.") }
            let endpoints=MIDITransport.endpoints().filter { !$0.offline && $0.name.localizedCaseInsensitiveContains("THR") }
            let sources=endpoints.filter(\.isSource)
            guard sources.count == 1, let source=sources.first,
                  let destination=endpoints.first(where:{ !$0.isSource && $0.entity == source.entity && $0.entity != 0 })
            else { throw AmpError("Expected one online THR USB MIDI pair. Close Amp Workbench and THR Remote, then run ampctl scan.") }
            let transport=try MIDITransport()
            let session=THRSession(transport:transport,captureDirectory:directory.appendingPathComponent("Captures"))
            try await session.connect(source:source,destination:destination)
            let firmware=(await session.status()).firmware.map { String(format:"%08x",$0) } ?? "unknown"
            let report=directory.appendingPathComponent("hardware-audit-\(start)-\(start+limit-1)-\(Int(Date().timeIntervalSince1970)).json")
            let original=try await session.readTone()
            try original.encoded().write(to:directory.appendingPathComponent("hardware-audit-original-\(start)-\(Int(Date().timeIntervalSince1970)).json"),options:.atomic)
            var results:[HardwareAuditResult]=[]
            for index in start..<(start+limit) {
                let entry=entries[index], began=Date()
                do {
                    try await session.applyTone(entry.preset)
                    results.append(.init(index:index,name:entry.title,seconds:Date().timeIntervalSince(began),passed:true,error:nil))
                    print("PASS \(index+1)/\(entries.count) \(entry.title)")
                } catch {
                    results.append(.init(index:index,name:entry.title,seconds:Date().timeIntervalSince(began),passed:false,error:error.localizedDescription))
                    print("FAIL \(index+1)/\(entries.count) \(entry.title): \(error.localizedDescription)")
                }
                try jsonEncoder().encode(results).write(to:report,options:.atomic)
                if !results.last!.passed { throw AmpError("Hardware audit stopped at preset \(index+1). Firmware \(firmware). Report: \(report.path)") }
            }
            print("Verified \(results.count) presets on firmware \(firmware). Report: \(report.path). Last tone remains active.")
        case "install-community":
            guard args.count == 1 else { throw AmpError("Usage: ampctl install-community") }
            let root=PresetLibrary.defaultDirectory
            let library=try PresetLibrary(directory:root)
            let directory=root.appendingPathComponent("CommunitySources",isDirectory:true)
            let collection=try await CommunityPresets.download(into:directory)
            let featured=try await CommunityPresets.downloadFeatured(into:directory)
            let entries=collection + featured
            let changed=try await library.syncCatalog(entries)
            print("\(entries.count) community presets validated; \(changed) new or updated library entries.")
        case "convert":
            guard args.count == 3 else { throw AmpError("Usage: ampctl convert INPUT OUTPUT.json|OUTPUT.thrl6p") }
            let p=try THRRemoteFile.importFile(URL(fileURLWithPath:args[1])); let out=URL(fileURLWithPath:args[2])
            let data=try out.pathExtension == "thrl6p" ? THRRemoteFile.encode(p):p.encoded()
            let temporary=out.deletingLastPathComponent().appendingPathComponent(".amp-convert-\(UUID().uuidString)")
            try data.write(to:temporary,options:.atomic)
            defer { try? FileManager.default.removeItem(at:temporary) }
            try FileManager.default.linkItem(at:temporary,to:out)
            print("Exported \(out.path)")
        case "capabilities":
            print(String(data:try jsonEncoder().encode(Catalogue.shared),encoding:.utf8)!)
        case "identify":
            let endpoints=MIDITransport.endpoints().filter { !$0.offline && $0.name.localizedCaseInsensitiveContains("THR") }
            guard let source=endpoints.first(where: \.isSource), let dest=endpoints.first(where:{ !$0.isSource && $0.entity == source.entity && $0.entity != 0 }) else { throw AmpError("No THR input/output pair. Run ampctl scan.") }
            let transport=try MIDITransport(); try transport.connect(source:source,destination:dest)
            try transport.send(THRCommands.identity)
            let deadline=Date().addingTimeInterval(2)
            var replies:[[UInt8]]=[]
            while Date() < deadline {
                replies += transport.drain()
                if replies.contains(where:{ $0.starts(with:[0xf0,0x7e,0x7f,6,2]) }) { break }
                try await Task.sleep(nanoseconds:20_000_000)
            }
            print("MIDI endpoint: \(source.name) (entity \(source.entity), driver \(source.driverOwner))")
            if replies.isEmpty { print("No identity response. No vendor-specific command was sent.") }
            for reply in replies { print(Binary.hex(reply)) }
        case "firmware-read":
            let endpoints=MIDITransport.endpoints().filter { !$0.offline && $0.name == "THR10II WIRELESS" }
            guard let source=endpoints.first(where: \.isSource), let dest=endpoints.first(where:{ !$0.isSource && $0.entity == source.entity }) else { throw AmpError("THR10II Wireless MIDI pair not found. Run ampctl scan.") }
            let transport=try MIDITransport(); try transport.connect(source:source,destination:dest)
            try transport.send(THRCommands.identity)
            let identityDeadline=Date().addingTimeInterval(2)
            var identitySeen=false
            while Date() < identityDeadline {
                for raw in transport.drain() where raw.starts(with:[0xf0,0x7e,0x7f,6,2]) && raw.count >= 12 {
                    guard raw[10] == 1 else { throw AmpError("Connected model is not THR10II Wireless; no firmware command sent.") }
                    identitySeen=true
                }
                if identitySeen { break }
                try await Task.sleep(nanoseconds:20_000_000)
            }
            guard identitySeen else { throw AmpError("No matching universal identity response; no firmware command sent.") }
            // THR10II-W source-derived read request from hnikolov/thr_ii/thr_ii.ino S2.
            try transport.send(THRFrame(deviceID:0x24,model:1,mode:0,counter:0,payload:Binary.words([1,0])).encoded())
            let deadline=Date().addingTimeInterval(2)
            var firmware:UInt32?
            while Date() < deadline {
                for raw in transport.drain() {
                    if let frame=try? THRFrame(decoding:raw), frame.model == 1, frame.words.prefix(2) == [1,4], frame.words.count == 3 {
                        firmware=frame.words[2]; print("Firmware response: \(Binary.hex(raw))")
                    }
                }
                if firmware != nil { break }
                try await Task.sleep(nanoseconds:20_000_000)
            }
            if let firmware { print(String(format:"THR10II firmware word: %08x",firmware)) }
            else { print("No firmware response. No activation or tone write was sent.") }
        case "probe", "read", "watch", "gain-test", "audition-test":
            if command == "gain-test", !args.contains("--temporary-write") { throw AmpError("Usage: ampctl gain-test --temporary-write. Reads, snapshots, adjusts gain by 0.01, verifies, restores and verifies. Never writes onboard slots.") }
            if command == "audition-test", (args.count != 3 || args[2] != "--temporary-write") { throw AmpError("Usage: ampctl audition-test FILE.thrl6p --temporary-write. Temporarily uploads the current tone, verifies, restores and verifies. Never writes onboard slots.") }
            let dir=PresetLibrary.defaultDirectory
            let transport=try MIDITransport(); let session=THRSession(transport:transport,captureDirectory:dir.appendingPathComponent("Captures"))
            let endpoints=MIDITransport.endpoints().filter { !$0.offline && $0.name.localizedCaseInsensitiveContains("THR") }
            let sources=endpoints.filter(\.isSource)
            guard sources.count == 1, let source=sources.first, let dest=endpoints.first(where:{ !$0.isSource && $0.entity == source.entity && $0.entity != 0 }) else { throw AmpError("Expected exactly one THR MIDI input/output pair; found \(sources.count) inputs. Run ampctl scan. Connect one powered THR via USB and quit THR Remote.") }
            do { try await session.connect(source:source,destination:dest) }
            catch { try? transport.log.export().write(to:dir.appendingPathComponent("last-diagnostics.json"),options:.atomic); throw error }
            let status=await session.status(); print(status.message); print("Firmware: \(status.firmware.map { String(format:"%08x",$0) } ?? "unknown")")
            if command == "probe" { return }
            let original=try await session.readTone()
            print(String(data:try original.encoded(),encoding:.utf8)!)
            if command == "watch" {
                print("Turn a physical gain/EQ knob. Ctrl-C to finish. No writes are sent.")
                var revision=(await session.status()).revision
                var previous=original
                while !Task.isCancelled {
                    await session.poll(); let state=await session.status()
                    if state.revision != revision {
                        revision=state.revision
                        if let p=state.tone {
                            for group in Catalogue.groups {
                                guard let before=previous.tone[group], let after=p.tone[group] else { continue }
                                for key in after.parameters.keys.sorted() where before.parameters[key] != after.parameters[key] {
                                    print("\(group).\(key): \(String(describing:before.parameters[key]!)) → \(String(describing:after.parameters[key]!))")
                                }
                            }
                            previous=p
                        }
                    }
                    try await Task.sleep(nanoseconds:100_000_000)
                }
            }
            if command == "gain-test" {
                let service=AuditionService(device:session,journal:dir.appendingPathComponent("recovery.json"))
                var changed=original; let gain=original.tone["amp"]!.parameters["Drive"]!.number!
                changed.tone["amp"]?.parameters["Drive"] = .number(gain > 0.98 ? gain-0.01:gain+0.01)
                do { try await service.preview(changed); print("Gain change verified.") }
                catch {
                    if await service.hasRecovery() { do { try await service.restore(); print("Original tone restored after test failure.") } catch { print("RESTORE FAILED; retained recovery.json: \(error.localizedDescription)") } }
                    throw error
                }
                try await service.restore(); print("Original tone restored and verified. No onboard writes.")
            }
            if command == "audition-test" {
                let desired=try THRRemoteFile.importFile(URL(fileURLWithPath:args[1]))
                let service=AuditionService(device:session,journal:dir.appendingPathComponent("recovery.json"))
                do { try await service.preview(desired); print("Full tone upload and readback verified: \(desired.name)") }
                catch {
                    if await service.hasRecovery() {
                        do { try await service.restore(); print("Original tone restored after failed test.") }
                        catch { print("RESTORE FAILED; retained recovery.json: \(error.localizedDescription)") }
                    }
                    throw error
                }
                try await service.restore(); print("Original tone restored and verified. No onboard writes.")
            }
        default:
            print("""
            Amp Workbench diagnostic tool (no onboard-write command)
              scan                         Enumerate real CoreMIDI endpoints
              ble-scan                     Discover nearby THR BLE advertisements; read-only
              ble-candidates               Show anonymised nearby BLE metadata for diagnosis
              ble-connect                  Connect BLE-MIDI service and list new MIDI endpoints
              identify                     Send universal MIDI identity request only
              firmware-read                Read THR10II firmware word; no activation or writes
              probe                        Identify, activate, capture and decode THR II tone
              read                         Read current tone JSON and save raw capture
              watch                        Stream physical knob notifications; read-only
              gain-test --temporary-write  Snapshot, change gain +0.01, verify, restore, verify
              audition-test FILE --temporary-write  Upload current tone, verify, restore, verify
              validate FILE                Validate JSON or THR Remote .thrl6p
              render-intent INTENT.json OUTPUT.json NAME
                                           Render bounded AI output to a THR preset offline
              decode-capture TONE.bin      Decode a saved current-tone dump without connecting
              upload-shape FILE            Show encoded upload and USB-MIDI frame sizes offline
              check-library-uploads       Validate all local preset upload encodings and frames offline
              audit-library --temporary-write START LIMIT
                                           Verify up to 30 library presets on the connected amp; stop on failure
              convert INPUT OUTPUT         Convert JSON ↔ .thrl6p without overwriting
              capabilities                 Print model/parameter catalogue
            Live decoder is provisional until hardware acceptance. Failure saves raw diagnostics.
            """)
        }
    }
}
