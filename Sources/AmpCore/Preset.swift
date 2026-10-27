import Foundation

public struct AmpError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public enum Value: Codable, Equatable, Sendable {
    case number(Double), boolean(Bool)
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .boolean(b) }
        else { self = .number(try c.decode(Double.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .number(let n): try c.encode(n); case .boolean(let b): try c.encode(b) }
    }
    public var number: Double? { if case .number(let n) = self { return n }; return nil }
    public var bool: Bool? { if case .boolean(let b) = self { return b }; return nil }
}
public struct Parameter: Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let type: String
    public let minimum: Double
    public let maximum: Double
    public let `default`: Value
    public let unit: String
    enum CodingKeys: String, CodingKey { case id, name, type, minimum, maximum, `default`, unit }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        type = try c.decode(String.self, forKey: .type); unit = try c.decode(String.self, forKey: .unit)
        `default` = try c.decode(Value.self, forKey: .default)
        if type == "boolean" { minimum = 0; maximum = 1 }
        else { minimum = try c.decode(Double.self, forKey: .minimum); maximum = try c.decode(Double.self, forKey: .maximum) }
    }
}
public struct Model: Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let parameters: [Parameter]
    public var defaults: [String: Value] { Dictionary(uniqueKeysWithValues: parameters.map { ($0.id, $0.default) }) }
}
public struct Catalogue: Codable, Sendable {
    public let version: Int
    public let target: String
    public let models: [String: [Model]]
    public static let groups = ["amp", "cabinet", "compressor", "gate", "modulation", "delay", "reverb"]
    public static let shared: Catalogue = {
        do { return try JSONDecoder().decode(Catalogue.self, from: Data(contentsOf: Bundle.module.url(forResource: "capabilities", withExtension: "json")!)) }
        catch { fatalError("Invalid bundled catalogue: \(error)") }
    }()
    public func model(_ block: ToneBlock, group: String) -> Model? { models[group]?.first { $0.id == block.model } }
}
public struct ToneBlock: Codable, Equatable, Sendable {
    public var model: String
    public var parameters: [String: Value]
    public init(model: String, parameters: [String: Value]) { self.model = model; self.parameters = parameters }
}
public struct Preset: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var target: String
    public var name: String
    public var description: String
    public var tags: [String]
    public var suggestions: String
    public var firmwareConstraints: [String]
    public var tone: [String: ToneBlock]
    public static func sample() throws -> Preset {
        try decode(Data(contentsOf: Bundle.module.url(forResource: "sample", withExtension: "json")!))
    }
    public static func decode(_ data: Data) throws -> Preset {
        guard data.count < 1_000_000 else { throw AmpError("Preset exceeds 1 MB.") }
        let root = try JSONSerialization.jsonObject(with: data)
        try strictKeys(root, allowed: ["schemaVersion", "target", "name", "description", "tags", "suggestions", "firmwareConstraints", "tone"], path: "preset")
        if let r = root as? [String: Any], let tone = r["tone"] as? [String: Any] {
            for (g,b) in tone { try strictKeys(b, allowed: ["model", "parameters"], path: "tone.\(g)") }
        }
        let p = try JSONDecoder().decode(Preset.self, from: data)
        try p.validate(); return p
    }
    public func validate(firmware: UInt32? = nil) throws {
        guard schemaVersion == 1 else { throw AmpError("Unsupported schema version \(schemaVersion); expected 1.") }
        guard target == "yamaha.thr-ii" else { throw AmpError("Target \(target) is incompatible with the Yamaha THR II adapter.") }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 64 else { throw AmpError("Name must contain 1–64 UTF-8 bytes.") }
        guard tags.count <= 32, tags.allSatisfy({ $0.utf8.count <= 128 }) else { throw AmpError("Use at most 32 tags of 128 bytes each.") }
        for f in firmwareConstraints {
            guard f.count == 8, UInt32(f, radix: 16) != nil else { throw AmpError("Firmware constraints must be eight hexadecimal digits.") }
        }
        if let f = firmware, !firmwareConstraints.isEmpty, !firmwareConstraints.contains(where: { UInt32($0, radix: 16) == f }) {
            throw AmpError("Preset requires firmware \(firmwareConstraints.joined(separator: ", ")); connected version is \(String(format: "%08x", f)).")
        }
        guard Set(tone.keys) == Set(Catalogue.groups) else { throw AmpError("Tone must contain exactly: \(Catalogue.groups.joined(separator: ", ")). Global/output settings are forbidden.") }
        for g in Catalogue.groups {
            let b = tone[g]!
            guard let m = Catalogue.shared.model(b, group: g) else { throw AmpError("tone.\(g): unsupported model '\(b.model)'.") }
            guard Set(b.parameters.keys) == Set(m.parameters.map(\.id)) else { throw AmpError("tone.\(g).parameters: expected \(m.parameters.map(\.id).joined(separator: ", ")).") }
            for spec in m.parameters {
                let v = b.parameters[spec.id]!
                if spec.type == "boolean" {
                    guard v.bool != nil else { throw AmpError("\(g).\(spec.id) must be a JSON boolean.") }
                } else {
                    guard let n = v.number, n.isFinite, n >= spec.minimum, n <= spec.maximum,
                          spec.type != "integer" || n.rounded() == n else { throw AmpError("\(g).\(spec.id) must be \(spec.type) in \(spec.minimum)…\(spec.maximum) \(spec.unit).") }
                }
            }
        }
    }
    public func encoded() throws -> Data { try validate(); return try jsonEncoder().encode(self) }
}
func strictKeys(_ value: Any, allowed: Set<String>, path: String) throws {
    guard let obj = value as? [String: Any] else { throw AmpError("\(path) must be an object.") }
    let unknown = Set(obj.keys).subtracting(allowed)
    guard unknown.isEmpty else { throw AmpError("\(path): unknown fields \(unknown.sorted().joined(separator: ", ")).") }
}
public func jsonEncoder() -> JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]; return e }

/// File conversion is intentionally independent from the MIDI wire format.
public enum THRRemoteFile {
    static let groups = ["amp": "THRGroupAmp", "cabinet": "THRGroupCab", "compressor": "THRGroupFX1Compressor", "gate": "THRGroupGate", "modulation": "THRGroupFX2Effect", "delay": "THRGroupFX3EffectEcho", "reverb": "THRGroupFX4EffectReverb"]
    public static func decode(_ data: Data, ignoringInactiveParameters: Bool = false) throws -> Preset {
        guard data.count < 1_000_000 else { throw AmpError("File exceeds 1 MB.") }
        guard let r = try JSONSerialization.jsonObject(with: data) as? [String: Any], r["schema"] as? String == "L6Preset", (r["version"] as? Int) == 5,
              let d = r["data"] as? [String: Any], let device = d["device"] as? Int, [0x240000,0x240001,0x240002].contains(device),
              let meta = d["meta"] as? [String: Any], let name = meta["name"] as? String, let t = d["tone"] as? [String: Any] else { throw AmpError("Expected THR II guitar L6Preset version 5 (.thrl6p). Acoustic/TM/FX100 formats are incompatible.") }
        let unknown = Set(t.keys).subtracting(Set(groups.values).union(["global"]))
        guard unknown.isEmpty else { throw AmpError("Unsupported THR tone groups: \(unknown.sorted()).") }
        var p = try Preset.sample(); p.name = name; p.description = "Imported from THR Remote"; p.tags = ["imported"]; p.suggestions = ""; p.firmwareConstraints = []
        for (g, key) in groups {
            guard var b = t[key] as? [String: Any], let asset = b.removeValue(forKey: "@asset") as? String else { throw AmpError("Missing \(key).@asset") }
            if ignoringInactiveParameters {
                guard let model = Catalogue.shared.models[g]?.first(where: { $0.id == asset }) else {
                    throw AmpError("\(key): unsupported model \(asset).")
                }
                let active = Set(model.parameters.map(\.id))
                guard active.isSubset(of: Set(b.keys)) else {
                    throw AmpError("\(key): missing active parameters \(active.subtracting(b.keys).sorted()).")
                }
                // Some community generators put parameters for several possible
                // effect models in one block. Only those used by @asset are active.
                b = b.filter { active.contains($0.key) }
            }
            let encoded = try JSONSerialization.data(withJSONObject: b)
            p.tone[g] = ToneBlock(model: asset, parameters: try JSONDecoder().decode([String: Value].self, from: encoded))
        }
        try p.validate(); return p
    }
    public static func encode(_ preset: Preset) throws -> Data {
        try preset.validate(); var tone: [String: Any] = [:]
        for (g, key) in groups {
            let b = preset.tone[g]!
            var values = try JSONSerialization.jsonObject(with: jsonEncoder().encode(b.parameters)) as! [String: Any]
            values["@asset"] = b.model; tone[key] = values
        }
        // File-only tempo metadata; never converted to a live global command.
        tone["global"] = ["THRPresetParamTempo": 110]
        return try JSONSerialization.data(withJSONObject: ["schema": "L6Preset", "version": 5, "meta": ["original":0,"pbn":0,"premium":0], "data": ["device":0x240002, "device_version":0x01440061, "meta":["name":preset.name,"tnid":0], "tone":tone]], options: [.prettyPrinted, .sortedKeys])
    }
    public static func importFile(_ url: URL) throws -> Preset {
        let data = try Data(contentsOf: url)
        return url.pathExtension.lowercased() == "thrl6p" ? try decode(data) : try Preset.decode(data)
    }
}
