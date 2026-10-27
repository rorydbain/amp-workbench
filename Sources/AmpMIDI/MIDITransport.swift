import Foundation
import CoreMIDI
import AmpCore

public struct MIDIEndpoint: Identifiable, Sendable {
    public let id: Int32
    public let name: String
    public let entity: UInt32
    public let reference: MIDIEndpointRef
    public let isSource: Bool
    public let offline: Bool
    public let driverOwner: String
}
public final class MIDITransport: @unchecked Sendable {
    private var client: MIDIClientRef=0, input: MIDIPortRef=0, output: MIDIPortRef=0
    private var destination: MIDIEndpointRef=0, source: MIDIEndpointRef=0
    private let lock=NSLock()
    private var assembler=SysExAssembler()
    private var messages:[[UInt8]]=[]
    public let log: DiagnosticLog
    public init(log: DiagnosticLog = DiagnosticLog()) throws {
        self.log=log
        try check(MIDIClientCreateWithBlock("Amp Workbench" as CFString,&client) { [weak log] _ in log?.append("system","MIDI configuration changed; refresh endpoints or reconnect.") })
        try check(MIDIInputPortCreateWithBlock(client,"Amp input" as CFString,&input) { [weak self] list, _ in
            guard let self else { return }
            var packet = UnsafeRawPointer(list).advanced(by: MemoryLayout<MIDIPacketList>.offset(of: \.packet)!).assumingMemoryBound(to: MIDIPacket.self)
            for _ in 0..<list.pointee.numPackets {
                let data = UnsafeRawPointer(packet).advanced(by: MemoryLayout<MIDIPacket>.offset(of: \.data)!).assumingMemoryBound(to: UInt8.self)
                let bytes = Array(UnsafeBufferPointer(start: data, count: Int(packet.pointee.length)))
                self.receive(bytes); packet = UnsafePointer(MIDIPacketNext(packet))
            }
        })
        try check(MIDIOutputPortCreate(client,"Amp output" as CFString,&output))
    }
    deinit { if client != 0 { MIDIClientDispose(client) } }
    private func check(_ status: OSStatus) throws { if status != noErr { throw AmpError("CoreMIDI error \(status). Check Audio MIDI Setup and USB connection.") } }
    public static func endpoints() -> [MIDIEndpoint] {
        func property(_ object:MIDIObjectRef,_ key:CFString)->String { var s:Unmanaged<CFString>?; guard MIDIObjectGetStringProperty(object,key,&s) == noErr else { return "" }; return s?.takeRetainedValue() as String? ?? "" }
        var result:[MIDIEndpoint]=[]
        for isSource in [true,false] {
            for i in 0..<(isSource ? MIDIGetNumberOfSources():MIDIGetNumberOfDestinations()) {
                let ref=isSource ? MIDIGetSource(i):MIDIGetDestination(i)
                var unique:Int32=0, offline:Int32=0; var entity:MIDIEntityRef=0
                MIDIObjectGetIntegerProperty(ref,kMIDIPropertyUniqueID,&unique); MIDIObjectGetIntegerProperty(ref,kMIDIPropertyOffline,&offline); MIDIEndpointGetEntity(ref,&entity)
                var device:MIDIDeviceRef=0
                if entity != 0 { MIDIEntityGetDevice(entity,&device) }
                let endpointName=property(ref,kMIDIPropertyDisplayName)
                let entityName=entity == 0 ? "" : property(entity,kMIDIPropertyName)
                let deviceName=device == 0 ? "" : property(device,kMIDIPropertyName)
                let name=[deviceName,entityName,endpointName,property(ref,kMIDIPropertyName)].first { !$0.isEmpty } ?? "Unknown MIDI endpoint"
                let stableID=unique != 0 ? unique : Int32(bitPattern:ref)
                let driverOwner=device == 0 ? "" : property(device,kMIDIPropertyDriverOwner)
                result.append(.init(id:stableID,name:name,entity:entity,reference:ref,isSource:isSource,offline:offline != 0,driverOwner:driverOwner))
            }
        }; return result
    }
    public func connect(source: MIDIEndpoint, destination: MIDIEndpoint) throws {
        disconnect()
        guard source.isSource, !destination.isSource, source.entity != 0, source.entity == destination.entity, !source.offline, !destination.offline else { throw AmpError("Choose input and output from the same online THR MIDI entity.") }
        try check(MIDIPortConnectSource(input,source.reference,nil))
        self.source=source.reference; self.destination=destination.reference
        log.append("system","Connected \(source.name) [\(source.id)] ↔ \(destination.name) [\(destination.id)]")
    }
    public func disconnect() { if source != 0 { MIDIPortDisconnectSource(input,source) }; source=0; destination=0; clear() }
    public func clear() { lock.lock(); messages=[]; assembler=SysExAssembler(); lock.unlock() }
    private func receive(_ bytes:[UInt8]) {
        lock.lock(); let complete=assembler.consume(bytes); messages += complete
        if messages.count > 5000 { messages.removeFirst(messages.count-5000) }; lock.unlock()
        for b in complete { log.append("rx",Binary.hex(b)) }
    }
    public func drain() -> [[UInt8]] { lock.lock(); defer { lock.unlock() }; let result=messages; messages=[]; return result }
    public func send(_ bytes:[UInt8]) throws {
        guard destination != 0 else { throw AmpError("No connected MIDI destination.") }
        guard bytes.count <= 65535 else { throw AmpError("SysEx message too large.") }
        // CoreMIDI handles USB-MIDI packets. We pass plain MIDI SysEx, never USB packet headers.
        let size=MemoryLayout<MIDIPacketList>.size + bytes.count + 64
        let storage=UnsafeMutableRawPointer.allocate(byteCount:size,alignment:16); defer { storage.deallocate() }
        let list=storage.bindMemory(to:MIDIPacketList.self,capacity:1)
        let first=MIDIPacketListInit(list)
        _=bytes.withUnsafeBufferPointer { MIDIPacketListAdd(list,size,first,0,$0.count,$0.baseAddress!) }
        guard list.pointee.numPackets == 1 else { throw AmpError("CoreMIDI could not queue a \(bytes.count)-byte SysEx message; nothing was sent.") }
        try check(MIDISend(output,destination,list)); log.append("tx",Binary.hex(bytes))
    }
}
