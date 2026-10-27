import Foundation

/// Independent decoder for state records (key:u16, type:u32, bits:u32).
/// The unit-header search passed one THR10II Wireless / firmware 1.50 capture;
/// other THR II models and firmware still require independent validation.
/// It rejects missing/ambiguous blocks instead of substituting default values.
public enum THRToneDecoder {
    static let unit = ["amp":"Amp", "compressor":"FX1", "modulation":"FX2", "delay":"FX3", "reverb":"FX4", "gate":"GuitarProc"]
    static func u16(_ b:[UInt8],_ i:Int)->UInt32 { UInt32(b[i]) | UInt32(b[i+1])<<8 }
    public static func decode(_ bytes: [UInt8], symbols: SymbolTable) throws -> Preset {
        guard bytes.count >= 100, bytes.count < 100_000 else { throw AmpError("Tone dump length is invalid.") }
        var p = try Preset.sample(); p.name="Current amp tone"; p.tags=[]; p.description="Read from the connected THR II"; p.suggestions=""
        // The memory read envelope has four words 0,0,1,0 before the tone data.
        guard Array(bytes.prefix(16)) == Binary.words([0,0,1,0]) else { throw AmpError("Unknown tone read envelope. Raw dump retained; no writes enabled.") }
        let raw=Array(bytes.dropFirst(16))
        var root: [UInt32:(UInt32,UInt32)] = [:]
        for g in ["gate","compressor","amp","modulation","delay","reverb"] {
            let unitKey=try symbols.key(unit[g]!)
            let models=Catalogue.shared.models[g]!
            let assets = try models.map { ($0, try symbols.key(g == "gate" ? "Y2GuitarFlow" : $0.id)) }
            var candidates: [ToneBlock] = []
            for i in 30..<(raw.count-9) {
                let recordType=try Binary.u32(raw,i+2)
                guard [0x10000,0x20000,0x30000].contains(recordType) else { continue }
                let headerStart=i-30
                // Unit headers contain a 16-bit unit key followed by a model key.
                let unitPositions=(headerStart..<(i-1)).filter { u16(raw,$0) == unitKey }
                guard !unitPositions.isEmpty else { continue }
                let matchingAssets=assets.filter { item in unitPositions.contains { u in (u+2..<(i-1)).contains { u16(raw,$0) == item.1 } } }
                guard matchingAssets.count == 1 else { continue }
                let model=matchingAssets[0].0
                var records: [UInt32:(UInt32,UInt32)] = [:]; var cursor=i
                while cursor+10 <= raw.count {
                    let k=u16(raw,cursor), t=try Binary.u32(raw,cursor+2), v=try Binary.u32(raw,cursor+6)
                    guard [0x10000,0x20000,0x30000].contains(t), k < symbols.names.count, records[k] == nil else { break }
                    records[k]=(t,v); cursor += 10
                }
                var params: [String:Value] = [:]
                var valid=true
                for spec in model.parameters {
                    let stateName: String
                    if spec.id == "@enabled" { stateName = "FX\(g == "compressor" ? "1" : g == "modulation" ? "2" : g == "delay" ? "3" : "4")EnableState" }
                    else if spec.id == "@wetDry" { stateName = g == "reverb" ? "FX4WetSendState" : "FX\(g == "modulation" ? "2" : "3")MixState" }
                    else { stateName=spec.id+"State" }
                    let key=try symbols.key(g == "gate" && spec.id == "@enabled" ? "GateEnableState" : stateName)
                    guard let record=(spec.id.hasPrefix("@") && g != "gate" ? root[key] : records[key]) else { valid=false; break }
                    if spec.type == "boolean" {
                        guard record.0 == 0x10000, record.1 <= 1 else { valid=false; break }; params[spec.id] = .boolean(record.1 != 0)
                    } else { guard record.0 == 0x30000 else { valid=false; break }; params[spec.id] = .number(Double(Float(bitPattern:record.1))) }
                }
                if valid { candidates.append(ToneBlock(model:model.id,parameters:params)); if g == "gate" { root=records } }
            }
            let unique=candidates.reduce(into:[ToneBlock]()) { if !$0.contains($1) { $0.append($1) } }
            guard unique.count == 1 else { throw AmpError("Cannot uniquely decode \(g) from this firmware's tone dump (\(unique.count) candidates). Raw capture retained. Live edits are unavailable until the decoder is verified.") }
            p.tone[g]=unique[0]
        }
        let cabKey=try symbols.key("SpkSimTypeState")
        guard let cab=root[cabKey], cab.0 == 0x20000, cab.1 <= 16 else { throw AmpError("Missing cabinet state; no complete tone snapshot.") }
        p.tone["cabinet"] = ToneBlock(model:"speakerSimulator",parameters:["SpkSimType":.number(Double(cab.1))])
        try p.validate(); return p
    }
}
public struct ParameterWrite: Sendable, Equatable {
    public let group: String
    public let parameter: String
    public let unit: UInt32
    public let key: UInt32
    public let type: UInt32
    public let bits: UInt32
}
public enum THRWritePlan {
    /// First version deliberately requires unchanged effect/amp models. Full patch upload
    /// needs captured read/upload trees; a dump is never replayed as an upload.
    public static func make(from current: Preset, to desired: Preset, symbols: SymbolTable) throws -> [ParameterWrite] {
        try current.validate(); try desired.validate()
        var plan:[ParameterWrite]=[]
        for group in Catalogue.groups {
            let old=current.tone[group]!, new=desired.tone[group]!
            guard old.model == new.model else { throw AmpError("Live model switching is awaiting hardware validation: \(group) is \(old.model), requested \(new.model). You can edit and save all models offline.") }
            for key in new.parameters.keys.sorted() where old.parameters[key] != new.parameters[key] {
                let value=new.parameters[key]!
                var unitName=THRToneDecoder.unit[group] ?? "GuitarProc", parameter=key
                if key == "@enabled" {
                    unitName="GuitarProc"
                    parameter=["compressor":"FX1Enable","gate":"GateEnable","modulation":"FX2Enable","delay":"FX3Enable","reverb":"FX4Enable"][group]!
                } else if key == "@wetDry" {
                    unitName="GuitarProc"; parameter=["modulation":"FX2Mix","delay":"FX3Mix","reverb":"FX4WetSend"][group]!
                }
                // The cabinet command is an enum (type 0x02, integer bits),
                // unlike continuous controls (type 0x04, float bits). Sending
                // it as a float is ACKed but leaves the previous cabinet on
                // the amp, so readback must verify this distinction.
                let isCabinet = group == "cabinet" && key == "SpkSimType"
                let type:UInt32 = isCabinet ? 2 : key == "@enabled" ? 3 : 4
                let bits:UInt32 = isCabinet ? UInt32(value.number!) : (value.bool.map { $0 ? 1:0 } ?? Float(value.number!).bitPattern)
                plan.append(.init(group:group,parameter:key,unit:try symbols.key(unitName),key:try symbols.key(parameter),type:type,bits:bits))
            }
        }
        return plan
    }
}
