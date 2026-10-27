import Foundation
import AmpCore
import AmpMIDI

/// A USB feasibility probe. It never activates a THR session or writes tone data.
struct USBProbeResult: Sendable {
    let model: String
    let firmware: String
    let source: String
    let destination: String
}

enum USBProbeError: LocalizedError {
    case timeout(String)
    case unexpectedIdentity
    var errorDescription: String? {
        switch self {
        case .timeout(let stage): return "No MIDI reply to the \(stage) request. USB audio may work even when USB MIDI control does not."
        case .unexpectedIdentity: return "The selected MIDI device did not identify as a supported THR II."
        }
    }
}

actor USBIdentityProbe {
    private let transport: MIDITransport
    init(transport: MIDITransport) { self.transport = transport }

    func probe(source: MIDIEndpoint, destination: MIDIEndpoint) async throws -> USBProbeResult {
        try transport.connect(source: source, destination: destination)
        defer { transport.disconnect() }
        transport.clear()
        try transport.send(THRCommands.identity)
        let identity = try await response(stage: "identity") { bytes in
            bytes.count >= 17 && Array(bytes.prefix(9)) == [0xf0, 0x7e, 0x7f, 6, 2, 0, 1, 0x0c, 0x24]
        }
        guard identity[9] == 0, [1, 2].contains(identity[10]), identity[11] == 0 else {
            throw USBProbeError.unexpectedIdentity
        }
        let model = identity[10]
        transport.clear()
        try transport.send(THRCommands.firmware(model: model).encoded())
        let firmwareReply = try await response(stage: "firmware") { bytes in
            guard let frame = try? THRFrame(decoding: bytes) else { return false }
            return frame.model == model && frame.words.count == 3 && frame.words.prefix(2) == [1, 4]
        }
        guard let frame = try? THRFrame(decoding: firmwareReply) else { throw USBProbeError.timeout("firmware") }
        return USBProbeResult(
            model: model == 1 ? "THR10II Wireless" : "THR30II Wireless",
            firmware: String(format: "%08x", frame.words[2]),
            source: source.name,
            destination: destination.name
        )
    }

    private func response(stage: String, matching: ([UInt8]) -> Bool) async throws -> [UInt8] {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            try Task.checkCancellation()
            if let reply = transport.drain().first(where: matching) { return reply }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw USBProbeError.timeout(stage)
    }
}
