import Foundation
import Compression

/// A portable tone only: provenance, AI prompts, access keys, and local history are excluded.
public enum PresetShareLink {
    private static let scheme = "ampworkbench"
    private static let maxPresetBytes = 64_000
    private static let maxLinkCharacters = 40_000

    public static func make(for preset: Preset) throws -> URL {
        let source = try preset.encoded()
        guard source.count <= maxPresetBytes else { throw AmpError("Sound is too large to share.") }
        var compressed = Data(count: maxPresetBytes)
        let count = compressed.withUnsafeMutableBytes { destination in
            source.withUnsafeBytes { input in
                compression_encode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, destination.count,
                                          input.bindMemory(to: UInt8.self).baseAddress!, input.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard count > 0 else { throw AmpError("Could not compress this sound.") }
        compressed.count = count
        let payload = compressed.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var components = URLComponents()
        components.scheme = scheme
        components.host = "sound"
        components.queryItems = [URLQueryItem(name: "v", value: "1"), URLQueryItem(name: "p", value: payload)]
        guard let url = components.url, url.absoluteString.count <= maxLinkCharacters else {
            throw AmpError("Sound is too large to share.")
        }
        return url
    }

    public static func read(_ url: URL) throws -> Preset {
        guard url.absoluteString.count <= maxLinkCharacters,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == scheme, components.host == "sound", components.path.isEmpty,
              let items = components.queryItems, items.count == 2,
              items.first(where: { $0.name == "v" })?.value == "1",
              let payload = items.first(where: { $0.name == "p" })?.value,
              payload.count <= maxLinkCharacters,
              payload.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw AmpError("This sound link is invalid or uses an unsupported version.")
        }
        let padded = payload.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .padding(toLength: ((payload.count + 3) / 4) * 4, withPad: "=", startingAt: 0)
        guard let compressed = Data(base64Encoded: padded), compressed.count <= maxPresetBytes else {
            throw AmpError("This sound link is invalid.")
        }
        var decoded = Data(count: maxPresetBytes)
        let count = decoded.withUnsafeMutableBytes { destination in
            compressed.withUnsafeBytes { input in
                compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, destination.count,
                                          input.bindMemory(to: UInt8.self).baseAddress!, input.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard count > 0, count < maxPresetBytes else { throw AmpError("This sound link could not be decoded.") }
        decoded.count = count
        return try Preset.decode(decoded)
    }
}
