import Foundation
import CoreBluetooth
import CoreMIDI

public struct BLEAmpAdvertisement: Sendable {
    public let name: String
    public let identifier: UUID
    public let rssi: Int
    public let services: [String]
}
public struct BLEScanCandidate: Sendable {
    public let identifier: UUID
    public let rssi: Int
    public let manufacturer: String
    public let services: [String]
}

/// Read-only discovery. Connection and CoreMIDI promotion are separate steps.
public final class BLEMIDIDiscovery: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    public static let midiService = CBUUID(string:"03B80E5A-EDE8-4B33-A751-6CE34EC4C700")
    public static let midiCharacteristic = CBUUID(string:"7772E5DB-3868-4112-A1A9-F2669D106BF3")
    private let lock=NSLock()
    private var manager:CBCentralManager!
    private var found:[UUID:BLEAmpAdvertisement]=[:]
    private var peripherals:[UUID:CBPeripheral]=[:]
    private var candidates:[UUID:BLEScanCandidate]=[:]
    private var totalAdvertisements=0
    private var state="Starting Bluetooth…"
    public override init() {
        super.init()
        manager=CBCentralManager(delegate:self,queue:DispatchQueue.main,options:[CBCentralManagerOptionShowPowerAlertKey:false])
    }
    public func start() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.manager.state == .poweredOn {
                self.manager.scanForPeripherals(withServices:nil,options:[CBCentralManagerScanOptionAllowDuplicatesKey:false])
                self.setState("Scanning for THR BLE advertisements…")
            }
        }
    }
    public func stop() { DispatchQueue.main.async { [weak self] in self?.manager.stopScan() } }
    public func connect(_ identifier:UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let peripheral=self.peripherals[identifier] else { return }
            self.manager.stopScan()
            peripheral.delegate=self
            self.setState("Connecting to \(peripheral.name ?? "BLE-MIDI peripheral")…")
            self.manager.connect(peripheral)
        }
    }
    public func snapshot() -> (String,[BLEAmpAdvertisement]) {
        lock.lock(); defer { lock.unlock() }
        return (state,found.values.sorted { $0.name < $1.name })
    }
    public func totalSeen() -> Int { lock.lock(); defer { lock.unlock() }; return totalAdvertisements }
    public func strongestCandidates() -> [BLEScanCandidate] {
        lock.lock(); defer { lock.unlock() }
        return Array(candidates.values.sorted { $0.rssi > $1.rssi }.prefix(25))
    }
    private func setState(_ value:String) { lock.lock(); state=value; lock.unlock() }
    public func centralManagerDidUpdateState(_ central:CBCentralManager) {
        switch central.state {
        case .poweredOn: start()
        case .poweredOff: setState("Bluetooth is off")
        case .unauthorized: setState("Bluetooth permission denied")
        case .unsupported: setState("Bluetooth LE is unavailable")
        default: setState("Bluetooth state \(central.state.rawValue)")
        }
    }
    public func centralManager(_ central:CBCentralManager, didDiscover peripheral:CBPeripheral, advertisementData:[String:Any], rssi RSSI:NSNumber) {
        lock.lock(); totalAdvertisements += 1; lock.unlock()
        let name=(advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        let listed=(advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
        let manufacturer=advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let company=manufacturer.map { $0.prefix(2).map { String(format:"%02x",$0) }.joined() } ?? "none"
        let candidate=BLEScanCandidate(identifier:peripheral.identifier,rssi:RSSI.intValue,manufacturer:company,services:listed.map(\.uuidString))
        lock.lock(); candidates[candidate.identifier]=candidate; lock.unlock()
        let yamaha=manufacturer?.prefix(2).elementsEqual([0x99,0x04]) == true
        guard name.localizedCaseInsensitiveContains("THR") || name.localizedCaseInsensitiveContains("Yamaha") || listed.contains(Self.midiService) || yamaha else { return }
        let displayName=name.isEmpty ? (yamaha ? "Yamaha BLE peripheral":"BLE-MIDI peripheral") : name
        let item=BLEAmpAdvertisement(name:displayName,identifier:peripheral.identifier,rssi:RSSI.intValue,services:listed.map(\.uuidString))
        lock.lock(); found[item.identifier]=item; peripherals[item.identifier]=peripheral; lock.unlock()
    }
    public func centralManager(_ central:CBCentralManager, didConnect peripheral:CBPeripheral) {
        setState("Discovering MIDI service on \(peripheral.name ?? "peripheral")…")
        peripheral.discoverServices([Self.midiService])
    }
    public func centralManager(_ central:CBCentralManager, didFailToConnect peripheral:CBPeripheral, error:Error?) {
        setState("Bluetooth connection failed: \(error?.localizedDescription ?? "unknown error")")
    }
    public func centralManager(_ central:CBCentralManager, didDisconnectPeripheral peripheral:CBPeripheral, error:Error?) {
        setState("Bluetooth disconnected: \(error?.localizedDescription ?? "peripheral closed the connection")")
    }
    public func peripheral(_ peripheral:CBPeripheral, didDiscoverServices error:Error?) {
        if let error { setState("MIDI service discovery failed: \(error.localizedDescription)"); return }
        guard let service=peripheral.services?.first(where:{$0.uuid == Self.midiService}) else { setState("Connected peripheral does not expose the BLE-MIDI service"); return }
        peripheral.discoverCharacteristics([Self.midiCharacteristic],for:service)
    }
    public func peripheral(_ peripheral:CBPeripheral, didDiscoverCharacteristicsFor service:CBService, error:Error?) {
        if let error { setState("MIDI characteristic discovery failed: \(error.localizedDescription)"); return }
        guard service.characteristics?.contains(where:{$0.uuid == Self.midiCharacteristic}) == true else { setState("BLE-MIDI characteristic is missing"); return }
        let result=MIDIBluetoothDriverActivateAllConnections()
        setState(result == noErr ? "BLE-MIDI connected · CoreMIDI activation requested" : "CoreMIDI Bluetooth activation failed (\(result))")
    }
}
