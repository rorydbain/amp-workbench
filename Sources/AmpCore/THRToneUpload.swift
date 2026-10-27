import Foundation

/// Complete current-tone upload (slot FFFFFFFF), based on the THR II wire
/// format documented by martinzw/THRII-direct-USB-pedalboard. This never
/// addresses one of the five onboard user memories.
public enum THRToneUpload {
    private static let structOpen:[UInt8] = [0,0,0,0x80,2,0]
    private static let structClose:[UInt8] = [2,0,0,0x80,0,0]
    private static let unitOpen:[UInt8] = [3,0,0,0x80,7,0]
    private static let unitClose:[UInt8] = [4,0,0,0x80,0,0]
    private static let unitType:[UInt8] = [0,0,5,0,0,0x80,7,0]
    private static let parCount:[UInt8] = [0,0,6,0,0,0x80,2,0]

    public static func data(_ preset:Preset, symbols:SymbolTable) throws -> [UInt8] {
        try preset.validate()
        var out:[UInt8]=[]
        func word(_ value:UInt32) { out += Binary.words([value]) }
        func symbol(_ name:String) throws {
            let key=try symbols.key(name)
            guard key <= UInt16.max else { throw AmpError("THR symbol index exceeds 16 bits: \(name)") }
            out += [UInt8(truncatingIfNeeded:key),UInt8(truncatingIfNeeded:key >> 8)]
        }
        func record(_ name:String, _ type:UInt32, _ bits:UInt32) throws {
            try symbol(name); word(type); word(bits)
        }
        func number(_ group:String, _ key:String) throws -> UInt32 {
            guard let value=preset.tone[group]?.parameters[key]?.number else { throw AmpError("Missing \(group).\(key) in tone upload.") }
            return Float(value).bitPattern
        }
        func enabled(_ group:String) throws -> UInt32 {
            guard let value=preset.tone[group]?.parameters["@enabled"]?.bool else { throw AmpError("Missing \(group).@enabled in tone upload.") }
            return value ? 1:0
        }
        func unit(_ name:String, _ asset:String, _ fields:[(String,UInt32,UInt32)]) throws {
            out += unitOpen; try symbol(name); out += unitType; try symbol(asset)
            out += parCount; word(UInt32(fields.count))
            for (name,type,bits) in fields { try record(name,type,bits) }
            out += unitClose
        }
        func fields(_ group:String, _ order:[String]) throws -> [(String,UInt32,UInt32)] {
            try order.map { key in (key+"State",0x30000,try number(group,key)) }
        }

        // The metadata precedes the data tree in THR Remote's current-tone
        // upload. A short ASCII name avoids firmware-specific UTF-8 limits.
        out += structOpen
        out += [2,0,0,0,1,0,0,0x80,2,0,0x50,0x53,0x52,0x50]
        let name=Array("Amp Workbench".utf8)+[0]
        out += [0,0,0,0,4,0]; word(UInt32(name.count)); out += name
        out += [1,0,0,0,2,0]; word(0)
        out += [2,0,0,0,2,0]; word(0)
        out += [3,0,0,0,3,0]; word(0)
        out += structClose

        out += structOpen
        out += [1,0,0,0,1,0,0,0x80,2,0,0x54,0x52,0x54,0x47]
        out += unitOpen; try symbol("GuitarProc"); out += unitType; try symbol("Y2GuitarFlow")
        out += parCount; word(11)
        try record("FX1EnableState",0x10000,enabled("compressor"))
        try record("FX2EnableState",0x10000,enabled("modulation"))
        try record("FX2MixState",0x30000,number("modulation","@wetDry"))
        try record("FX3EnableState",0x10000,enabled("delay"))
        try record("FX3MixState",0x30000,number("delay","@wetDry"))
        try record("FX4EnableState",0x10000,enabled("reverb"))
        try record("FX4WetSendState",0x30000,number("reverb","@wetDry"))
        try record("GateEnableState",0x10000,enabled("gate"))
        guard let cabinet=preset.tone["cabinet"]?.parameters["SpkSimType"]?.number else { throw AmpError("Missing cabinet selection.") }
        try record("SpkSimTypeState",0x20000,UInt32(cabinet))
        try record("DecayState",0x30000,number("gate","Decay"))
        try record("ThreshState",0x30000,number("gate","Thresh"))

        try unit("FX1",preset.tone["compressor"]!.model,fields("compressor",["Level","Sustain"]))
        try unit("Amp",preset.tone["amp"]!.model,fields("amp",["Bass","Drive","Master","Mid","Treble"]))
        let modulation=preset.tone["modulation"]!.model
        let modulationOrder:[String]
        switch modulation {
        case "StereoSquareChorus": modulationOrder=["Depth","Feedback","Freq","Pre"]
        case "L6Flanger": modulationOrder=["Depth","Freq"]
        case "Phaser": modulationOrder=["Feedback","Speed"]
        case "BiasTremolo": modulationOrder=["Depth","Speed"]
        default: throw AmpError("Unsupported modulation upload model: \(modulation)")
        }
        try unit("FX2",modulation,fields("modulation",modulationOrder))
        try unit("FX3",preset.tone["delay"]!.model,fields("delay",["Bass","Feedback","Time","Treble"]))
        let reverb=preset.tone["reverb"]!.model
        let reverbOrder = reverb == "StandardSpring" ? ["Time","Tone"]:["Decay","PreDelay","Tone"]
        try unit("FX4",reverb,fields("reverb",reverbOrder))
        out += unitClose
        out += structClose
        return out
    }

    public static func frames(_ data:[UInt8], model:UInt8, counters:(UInt8,UInt8)) throws -> [THRFrame] {
        guard !data.isEmpty, data.count <= 210*128 else { throw AmpError("Invalid THR tone upload length.") }
        let header=THRFrame(deviceID:0x24,model:model,mode:1,counter:counters.0,payload:Binary.words([13,UInt32(data.count+20),0xffffffff,UInt32(data.count+12),0,1,0]))
        var result=[header]
        // Match the 210-byte slices used by the independently documented THR
        // uploader. THRFrame.encoded() must pad the final bitbucket group.
        let sliceSize=210
        for start in stride(from:0,to:data.count,by:sliceSize) {
            let slice=Array(data[start..<min(start+sliceSize,data.count)])
            result.append(THRFrame(deviceID:0x24,model:model,mode:1,counter:counters.1,sequence:UInt8(start/sliceSize),payload:slice))
        }
        return result
    }
}
