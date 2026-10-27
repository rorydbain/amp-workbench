import Foundation
import CryptoKit

public enum Binary {
    public static func words(_ values: [UInt32]) -> [UInt8] { values.flatMap { v in (0..<4).map { UInt8(truncatingIfNeeded: v >> ($0 * 8)) } } }
    public static func u32(_ b: [UInt8], _ offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + 4 <= b.count else { throw AmpError("Truncated 32-bit field at \(offset).") }
        return (0..<4).reduce(0) { $0 | UInt32(b[offset+$1]) << ($1*8) }
    }
    public static func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined(separator: " ") }
    public static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for b in bytes { crc ^= UInt32(b); for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) != 0 ? 0xedb88320 : 0) } }; return ~crc
    }
}
public enum Bitbucket {
    // Source ParseSysEx.cpp: first raw byte's MSB occupies bit 6, not bit 0.
    public static func encode(_ raw: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        for start in stride(from: 0, to: raw.count, by: 7) {
            let chunk = Array(raw[start..<min(start+7, raw.count)])
            let bucket = chunk.enumerated().reduce(UInt8(0)) { $0 | (($1.element >> 7) << (6-$1.offset)) }
            out.append(bucket); out += chunk.map { $0 & 0x7f }
        }; return out
    }
    public static func decode(_ encoded: [UInt8], count: Int) throws -> [UInt8] {
        guard count >= 0, count <= 4096, encoded.count == count + (count+6)/7, encoded.allSatisfy({ $0 < 128 }) else { throw AmpError("Invalid bitbucket size or non-MIDI data byte.") }
        var out: [UInt8] = []; var i = 0
        while out.count < count {
            let bucket = encoded[i]; i += 1
            for j in 0..<min(7, count-out.count) { out.append(encoded[i] | (((bucket >> (6-j)) & 1) << 7)); i += 1 }
        }; return out
    }
}
public struct THRFrame: Equatable, Sendable {
    public let deviceID: UInt8
    public let model: UInt8
    public let mode: UInt8
    public let counter: UInt8
    public let sequence: UInt8
    public let payload: [UInt8]
    public init(deviceID: UInt8 = 0x24, model: UInt8 = 2, mode: UInt8, counter: UInt8, sequence: UInt8 = 0, payload: [UInt8]) { self.deviceID=deviceID; self.model=model; self.mode=mode; self.counter=counter; self.sequence=sequence; self.payload=payload }
    public func encoded(padToEight:Bool = true) throws -> [UInt8] {
        guard model < 128, mode < 128, counter < 128, sequence < 128, (1...256).contains(payload.count) else { throw AmpError("Invalid THR frame fields.") }
        var packed = Bitbucket.encode(payload)
        if padToEight { while packed.count % 8 != 0 { packed.append(0) } }
        return [0xf0,0,1,0x0c,deviceID,model,0x4d,mode,counter,sequence,UInt8((payload.count-1)/16),UInt8((payload.count-1)%16)] + packed + [0xf7]
    }
    public init(decoding b: [UInt8]) throws {
        guard b.count >= 15, Array(b.prefix(4)) == [0xf0,0,1,0x0c], [0x22,0x24].contains(b[4]), b[6] == 0x4d, b.last == 0xf7,
              b[1..<(b.count-1)].allSatisfy({ $0 < 128 }), b[10] <= 15, b[11] <= 15 else { throw AmpError("Not a valid THR II SysEx frame.") }
        deviceID=b[4]; model=b[5]; mode=b[7]; counter=b[8]; sequence=b[9]
        let count = Int(b[10])*16+Int(b[11])+1
        let compact = count+(count+6)/7
        let packed = Array(b[12..<(b.count-1)])
        guard packed.count == compact || (packed.count == ((count+6)/7)*8 && packed.dropFirst(compact).allSatisfy({ $0 == 0 })) else { throw AmpError("Invalid THR payload padding.") }
        payload = try Bitbucket.decode(Array(packed.prefix(compact)), count: count)
    }
    public var words: [UInt32] { stride(from: 0, through: max(-1,payload.count-4), by: 4).compactMap { try? Binary.u32(payload,$0) } }
    public var isAck: Bool { words == [1,4,0] }
}
public struct SysExAssembler: Sendable {
    private var buffer: [UInt8] = []
    public init() {}
    public mutating func consume(_ bytes: [UInt8]) -> [[UInt8]] {
        var messages: [[UInt8]] = []
        for b in bytes {
            if b >= 0xf8 { continue } // Interleaved real-time messages are legal MIDI.
            if b == 0xf0 { buffer = [b] }
            else if b == 0xf7 { if !buffer.isEmpty { buffer.append(b); messages.append(buffer); buffer=[] } }
            else if b >= 0x80 { buffer=[] }
            else if !buffer.isEmpty { buffer.append(b); if buffer.count > 1_000_000 { buffer=[] } }
        }; return messages
    }
}
public struct CommandCounter: Sendable {
    private var next: UInt8 = 3
    public init() {}
    public mutating func pair() -> (UInt8,UInt8) {
        if next >= 126 { next = 3 }
        let first=next; next += 2; return (first,first+1)
    }
    public mutating func single() -> UInt8 { if next >= 126 { next=3 }; defer { next += 1 }; return next }
}
public struct DumpAssembler: Sendable {
    private var expected = 0
    private var nextSequence: UInt8 = 0
    private var nextCounter: UInt8?
    private var collected: [UInt8] = []
    public init() {}
    public mutating func consume(_ frame: THRFrame) throws -> [UInt8]? {
        if expected == 0 {
            let w=frame.words
            guard frame.sequence == 0, w.count >= 4, w[0] == 1, w[1] > 0, w[1] <= 1_000_000 else { throw AmpError("Missing first dump fragment or invalid declared length.") }
            expected = Int(w[1]); nextSequence = 0; nextCounter=frame.counter; collected=[]
        }
        guard frame.sequence == nextSequence, frame.counter == nextCounter else { throw AmpError("Out-of-order or unrelated dump fragment; refusing partial state.") }
        nextSequence = (nextSequence+1) & 0x7f
        nextCounter = (frame.counter+1) & 0x7f
        collected += frame.sequence == 0 ? Array(frame.payload.dropFirst(8)) : frame.payload
        guard collected.count <= expected else { throw AmpError("Dump exceeds declared size.") }
        if collected.count == expected { let result=collected; self=DumpAssembler(); return result }; return nil
    }
}
public struct SymbolTable: Sendable {
    public let names: [String]
    public let crc: UInt32
    /// Sparse protocol keys observed for the THR II tone schema. Unknown slots
    /// remain unusable; this does not embed the manufacturer's symbol resource.
    public init(knownIndices: [String: Int], count: Int, crc: UInt32) throws {
        guard count > 0, count < 10_000,
              knownIndices.values.allSatisfy({ $0 >= 0 && $0 < count }),
              Set(knownIndices.values).count == knownIndices.count else {
            throw AmpError("Invalid compact THR symbol map.")
        }
        var slots = (0..<count).map { "__unknown_\($0)" }
        for (name, index) in knownIndices { slots[index] = name }
        self.names = slots
        self.crc = crc
    }
    public init(bytes: [UInt8]) throws {
        let count = Int(try Binary.u32(bytes,0)); let length = Int(try Binary.u32(bytes,4))
        guard count > 0, count < 10000, length == bytes.count, 8+12*count < bytes.count else { throw AmpError("Invalid or truncated THR symbol table.") }
        var pos=8+12*count; var names: [String]=[]
        for _ in 0..<count {
            guard pos < bytes.count, let end=bytes[pos...].firstIndex(of: 0), end > pos, let name=String(bytes: bytes[pos..<end], encoding:.utf8) else { throw AmpError("Truncated symbol name.") }
            names.append(name); pos=end+1
        }
        self.names=names; crc=Binary.crc32(bytes)
    }
    public func key(_ name: String) throws -> UInt32 { guard let i=names.firstIndex(of:name) else { throw AmpError("Symbol '\(name)' is missing. Firmware table mismatch.") }; return UInt32(i) }
    public static func localRemoteTable() throws -> SymbolTable {
        let data = try Data(contentsOf: URL(fileURLWithPath:"/Applications/THR Remote.app/Contents/Resources/Y2MainSymTab.dat"))
        let digest = SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
        guard digest == "02c93891e3e107e83ba6e0aaf7beb931baf7a92b5217851c8765f2ab97d2e9f3" else {
            throw AmpError("Installed THR Remote symbol table differs from the audited resource. Capture a full device table before editing.")
        }
        return try SymbolTable(bytes: Array(data))
    }
}
public enum THRCommands {
    public static let identity: [UInt8] = [0xf0,0x7e,0x7f,6,1,0xf7]
    public static func firmware(model: UInt8, mode: UInt8 = 0) -> THRFrame { .init(deviceID:model == 1 ? 0x24:0x22,model:model,mode:mode,counter:0,payload:Binary.words([1,0])) }
    public static func currentTone(model: UInt8, counter: UInt8) -> THRFrame { .init(deviceID:model == 1 ? 0x24:0x22,model:model,mode:1,counter:counter,payload:Binary.words([12,4,0xffffffff])) }
    public static func setParameter(model: UInt8, counters: (UInt8,UInt8), unit: UInt32, key: UInt32, type: UInt32, bits: UInt32) -> [THRFrame] {
        [.init(model:model,mode:0,counter:counters.0,payload:Binary.words([10,16])), .init(model:model,mode:0,counter:counters.1,payload:Binary.words([unit,key,type,bits]))]
    }
}
