import Foundation
import AmpCore

public struct DeviceStatus: Sendable {
    public var message: String
    public var model: UInt8?
    public var firmware: UInt32?
    public var tone: Preset?
    public var revision: Int
    public var connected: Bool
}
private struct THRResponseTimeout: LocalizedError {
    let seconds: Double
    var errorDescription: String? { "THR response timed out after \(Int(seconds)) seconds." }
}
/// One transaction at a time; protocol work never blocks the main actor.
public actor THRSession: ToneDevice {
    public nonisolated let transport: MIDITransport
    private let captureDirectory: URL
    private var model:UInt8=2, firmware:UInt32?, symbols:SymbolTable?
    private var counter=CommandCounter()
    private var busy=false, ready=false
    private var deviceKey="", message="Disconnected", current:Preset?, revision=0
    public init(transport: MIDITransport, captureDirectory: URL) { self.transport=transport; self.captureDirectory=captureDirectory }
    private func begin() throws { guard !busy else { throw AmpError("The amp is busy. Wait for the current operation.") }; busy=true }
    public func status() -> DeviceStatus { .init(message:message,model:ready ? model:nil,firmware:firmware,tone:current,revision:revision,connected:ready) }
    public func identityKey() async throws -> String { guard ready else { throw AmpError("Connect and complete the THR handshake first.") }; return deviceKey }
    public func connect(source: MIDIEndpoint, destination: MIDIEndpoint) async throws {
        try begin(); defer { busy=false }; ready=false; current=nil; firmware=nil; symbols=nil
        do {
            try transport.connect(source:source,destination:destination)
            message="Identifying amp…"; try transport.send(THRCommands.identity)
            let identity=try await wait { b in b.count >= 17 && Array(b.prefix(9)) == [0xf0,0x7e,0x7f,6,2,0,1,0x0c,0x24] }
            guard identity[9] == 0, [1,2].contains(identity[10]), identity[11] == 0 else { throw AmpError("This adapter requires a THR10II Wireless or THR30II Wireless (family 0x24, model 1 or 2).") }
            model=identity[10]; deviceKey="thr-ii-\(model):\(source.id):\(destination.id)"
            message="Reading firmware…"
            try send(THRCommands.firmware(model:model))
            let version=try await waitFrame { $0.payload.count == 12 && $0.words.prefix(2) == [1,4] }
            let f=version.words[2]; firmware=f
            let known:[UInt32:UInt32]=[0x01300063:0x686fbeeb,0x0131006b:0x9809eb24,0x01400061:0x7986615c,0x01420067:0xdd54cd72,0x01430062:0xdd54cd72,0x01440061:0xdd54cd72]
            let local = (try? SymbolTable.localRemoteTable()) ?? (model == 1 && f == 0x01500062 ? (try? THRCompactSymbols.firmware150()) : nil)
            // Activation tokens are firmware-specific and unrelated to the
            // symbol-table CRC. Unknown firmware must fail closed.
            let activationToken:UInt32
            if let token=known[f] { activationToken=token }
            else if model == 1 && f == 0x01500062, let local, local.crc == 0xdd54cd72 {
                // hnikolov derives activation from the symbol-table CRC32. The
                // installed THR Remote table is SHA-256 pinned by AmpCore.
                activationToken=local.crc
                transport.log.append("system","THR10II firmware 1.50: activation token derived from SHA-256-pinned local symbol table CRC32. Session outcome remains hardware-unverified.")
            } else { throw AmpError("Firmware \(String(format:"%08x",f)) has no known activation token. Identity was read; no activation or tone writes sent.") }
            message="Activating MIDI session…"
            try send(.init(model:model,mode:0,counter:1,payload:Binary.words([4,4])))
            try await Task.sleep(nanoseconds:30_000_000)
            try send(.init(model:model,mode:0,counter:2,payload:Binary.words([activationToken])))
            _ = try await waitFrame { frame in
                if frame.words.prefix(2) == [1,4], frame.words.count == 3, frame.words[2] >= 0xfffffff0 { throw AmpError("THR rejected activation (\(String(format:"%08x",frame.words[2]))). No tone writes sent.") }
                return frame.isAck
            }
            try send(THRCommands.firmware(model:model,mode:1)); _ = try await waitFrame { $0.words == [1,4,f] }
            if model == 1 && f == 0x01500062, let local {
                // Firmware 1.50 omits the beginning of the symbol dump. The
                // audited compact map avoids an eight-second doomed request.
                symbols = local
            }
            if symbols == nil {
                do { symbols=try await requestSymbols() }
                catch {
                    // Firmware 1.44+ reportedly truncates table responses. Only
                    // recognized firmware may use the installed app's table.
                    guard let local else { throw error }
                    symbols=local
                    transport.log.append("system","Device symbol request failed; using installed THR Remote symbol table CRC \(String(format:"%08x",local.crc)). Hardware readback is still required before any edit.")
                }
            }
            // Complete source-derived boot sequence without querying or writing onboard slots.
            try send(.init(model:model,mode:1,counter:1,payload:Binary.words([5,0])))
            _ = try await waitFrame { $0.words == [1,4,128] }
            try send(.init(model:model,mode:0,counter:3,payload:Binary.words([15,0])))
            _ = try await waitFrame { $0.payload.count == 9 && $0.words.prefix(2) == [1,1] }
            ready=true; message="Session activated · reading tone…"
            do { _ = try await readInternal(); message="Connected · current tone read" }
            catch { message="Session activated; tone decoder needs capture review: \(error.localizedDescription)"; throw error }
        } catch {
            ready=false; message=error.localizedDescription; transport.disconnect()
            throw error
        }
    }
    private func requestSymbols() async throws -> SymbolTable {
        try send(.init(model:model,mode:0,counter:3,payload:Binary.words([3,0])))
        let data=try await receiveDump(mode:0); try capture(data,name:"symbols")
        return try SymbolTable(bytes:data)
    }
    private func send(_ frame: THRFrame) throws { try transport.send(frame.encoded()) }
    private func wait(_ predicate: ([UInt8]) throws -> Bool, seconds:Double=4) async throws -> [UInt8] {
        let deadline=Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try Task.checkCancellation()
            var match:[UInt8]?
            for raw in transport.drain() {
                if match == nil, try predicate(raw) { match=raw }
                if let frame=try? THRFrame(decoding:raw) { updateFromDevice(frame) }
            }
            if let match { return match }
            try await Task.sleep(nanoseconds:10_000_000)
        }
        throw THRResponseTimeout(seconds:seconds)
    }
    private func waitFrame(_ predicate:(THRFrame)throws->Bool) async throws -> THRFrame {
        let b=try await wait { raw in guard let f=try? THRFrame(decoding:raw), f.model == self.model else { return false }; return try predicate(f) }
        return try THRFrame(decoding:b)
    }
    private func receiveDump(mode: UInt8, seconds: Double = 8) async throws -> [UInt8] {
        var assembler=DumpAssembler(); var result:[UInt8]?, fragments=0
        do { _ = try await wait({ raw in
            guard let frame=try? THRFrame(decoding:raw), frame.model == self.model, frame.mode == mode else { return false }
            // Dump frames may have short final payloads; do not classify only by length.
            fragments += 1
            if result == nil { result=try assembler.consume(frame) }
            return result != nil
        },seconds:seconds) }
        catch {
            transport.log.append("system","Dump mode \(mode) failed after \(fragments) fragments: \(error.localizedDescription)")
            try? captureFailure()
            throw error
        }
        return result!
    }
    private func captureFailure() throws {
        try FileManager.default.createDirectory(at:captureDirectory,withIntermediateDirectories:true)
        let stamp=String(Int(Date().timeIntervalSince1970*1000))
        try transport.log.export().write(to:captureDirectory.appendingPathComponent("failure-\(stamp).json"),options:.atomic)
    }
    private func capture(_ data:[UInt8], name:String) throws {
        try FileManager.default.createDirectory(at:captureDirectory,withIntermediateDirectories:true)
        let stamp=String(Int(Date().timeIntervalSince1970*1000))
        try Data(data).write(to:captureDirectory.appendingPathComponent("\(name)-\(stamp).bin"),options:.atomic)
        try transport.log.export().write(to:captureDirectory.appendingPathComponent("session.json"),options:.atomic)
    }
    public func readTone() async throws -> Preset { try begin(); defer { busy=false }; return try await readInternal() }
    public func validateToneChange(from current: Preset, to desired: Preset) async throws {
        guard let symbols, let firmware, ready else { throw AmpError("Connect the THR first.") }
        try desired.validate(firmware:firmware)
        if Catalogue.groups.contains(where:{ current.tone[$0]?.model != desired.tone[$0]?.model }) {
            let data=try THRToneUpload.data(desired,symbols:symbols)
            let decoded=try THRToneDecoder.decode(Binary.words([0,0,1,0])+data,symbols:symbols)
            guard ToneComparison.equivalent(decoded,desired) else { throw AmpError("Tone upload did not round-trip before sending; no write made.") }
        } else { _ = try THRWritePlan.make(from:current,to:desired,symbols:symbols) }
    }
    private func readInternal() async throws -> Preset {
        guard ready, let symbols else { throw AmpError("THR session is not activated.") }
        var bytes:[UInt8]?
        for attempt in 1...2 {
            if attempt == 2 {
                // This is a read-only request. Never resend the preceding tone write.
                try await Task.sleep(nanoseconds:350_000_000)
                transport.clear()
            }
            transport.log.append("system","Requesting current tone (read attempt \(attempt)/2)")
            try send(THRCommands.currentTone(model:model,counter:counter.single()))
            do { bytes=try await receiveDump(mode:1,seconds:attempt == 1 ? 3:5); break }
            catch is THRResponseTimeout where attempt == 1 {
                transport.log.append("system","First read timed out; retrying the read-only request once")
            } catch is THRResponseTimeout {
                throw AmpError("The amp did not answer two current-tone reads. Check its USB connection. No tone write was retried; the selected preset may already be active. A diagnostic capture was saved.")
            }
        }
        guard let bytes else { throw AmpError("The amp did not return its current tone.") }
        try capture(bytes,name:"tone")
        let decoded=try THRToneDecoder.decode(bytes,symbols:symbols); current=decoded; revision += 1
        return decoded
    }
    public func applyTone(_ preset: Preset) async throws {
        try begin(); defer { busy=false }
        guard let symbols, let firmware, ready else { throw AmpError("Connect the THR first.") }
        try preset.validate(firmware:firmware)
        let original=try await readInternal()
        try await validateToneChange(from:original,to:preset)
        if Catalogue.groups.contains(where:{ original.tone[$0]?.model != preset.tone[$0]?.model }) {
            let data=try THRToneUpload.data(preset,symbols:symbols)
            let frames=try THRToneUpload.frames(data,model:model,counters:counter.pair())
            for frame in frames {
                try Task.checkCancellation()
                // THR upload frames require complete eight-byte bitbucket
                // groups, including zero padding after a short final group.
                // Without it, uploads whose raw payload is not divisible by
                // seven can leave the amp's MIDI endpoint unresponsive.
                try transport.send(frame.encoded())
                try await Task.sleep(nanoseconds:40_000_000)
            }
            do { _=try await waitFrame { $0.isAck } }
            catch is THRResponseTimeout {
                transport.log.append("system","No acknowledgement after full tone upload; session marked unresponsive. No write retry.")
                try? captureFailure()
                ready=false; current=nil; revision += 1
                message="Amp stopped answering after a preset upload · power cycle and reconnect USB"
                throw AmpError("The amp did not acknowledge this preset upload and stopped answering MIDI. The sound may have changed. Power cycle the amp and reconnect USB; no write was retried. A diagnostic capture was saved.")
            }
            try await Task.sleep(nanoseconds:500_000_000)
        } else {
            let plan=try THRWritePlan.make(from:original,to:preset,symbols:symbols)
            for write in plan {
                try Task.checkCancellation()
                for frame in THRCommands.setParameter(model:model,counters:counter.pair(),unit:write.unit,key:write.key,type:write.type,bits:write.bits) {
                    try send(frame); try await Task.sleep(nanoseconds:30_000_000)
                }
                _ = try await waitFrame { $0.isAck }
                try await Task.sleep(nanoseconds:80_000_000)
            }
        }
        let after=try await readInternal()
        guard ToneComparison.equivalent(after,preset) else { throw AmpError("Tone readback differs. Restore the previous tone; recovery snapshot is retained.") }
    }
    /// Consume idle notifications without echoing them back through bindings.
    public func poll() {
        guard !busy, ready else { return }
        for raw in transport.drain() { if let frame=try? THRFrame(decoding:raw) { updateFromDevice(frame) } }
    }
    private func updateFromDevice(_ frame:THRFrame) {
        let w=frame.words
        guard let symbols, var tone=current, frame.model == model, w.count == 6, w[0] == 4, w[1] == 16 else { return }
        for group in Catalogue.groups {
            guard var block=tone.tone[group] else { continue }
            for key in block.parameters.keys {
                var candidate=tone
                let v=block.parameters[key]!
                candidate.tone[group]?.parameters[key] = v.bool.map { .boolean(!$0) } ?? .number(v.number == 0 ? 0.1:0)
                guard let plan=try? THRWritePlan.make(from:tone,to:candidate,symbols:symbols), let write=plan.first, write.unit == w[2], write.key == w[3], write.type == w[4] else { continue }
                block.parameters[key] = v.bool != nil ? .boolean(w[5] != 0):.number(Double(Float(bitPattern:w[5])))
                tone.tone[group]=block
                if (try? tone.validate()) != nil { current=tone; revision += 1 }
            }
        }
    }
    public func disconnect() throws {
        guard !busy else { throw AmpError("Wait for the device operation to finish before disconnecting.") }
        transport.disconnect(); ready=false; current=nil; message="Disconnected"; revision += 1
    }
}
