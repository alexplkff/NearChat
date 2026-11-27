import Foundation
import CoreBluetooth
import NearChatCore

/// Both GATT roles, with bounded queues and per-link stream framing.
final class BLETransport: NSObject, CBCentralManagerDelegate, CBPeripheralManagerDelegate, CBPeripheralDelegate {
    var onOpen: ((String, String) -> Void)?
    var onClose: ((String) -> Void)?
    var onFrame: ((Data, String) -> Void)?
    var onStatus: ((String) -> Void)?
    private let serviceID = CBUUID(string: "81FA6001-27A0-4C29-A176-A7D0C6E93001")
    private let characteristicID = CBUUID(string: "81FA6002-27A0-4C29-A176-A7D0C6E93001")
    private var centralManager: CBCentralManager!
    private var peripheralManager: CBPeripheralManager!
    private var characteristic: CBMutableCharacteristic?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var remoteCharacteristics: [UUID: CBCharacteristic] = [:]
    private var subscribers: [UUID: CBCentral] = [:]
    private var decoders: [String: FrameDecoder] = [:]
    private var queues: [String: Data] = [:]
    private var awaitingWrite: Set<UUID> = []
    private var opened: Set<String> = []
    private var enabled = false
    private var generation = UUID()

    func start() {
        guard !enabled else { return }
        enabled = true; generation = UUID()
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: .main)
            peripheralManager = CBPeripheralManager(delegate: self, queue: .main)
        } else { activateCentral(); activatePeripheral() }
    }
    func stop() {
        enabled = false; generation = UUID()
        centralManager?.stopScan(); peripheralManager?.stopAdvertising()
        if let manager = centralManager {
            for peripheral in peripherals.values { manager.cancelPeripheralConnection(peripheral) }
        }
        peripheralManager?.removeAllServices(); characteristic = nil
        for id in Array(opened) { close(id) }
        peripherals.removeAll(); remoteCharacteristics.removeAll(); subscribers.removeAll(); awaitingWrite.removeAll()
        onStatus?("Bluetooth: остановлен")
    }
    func send(_ data: Data, on link: String) {
        guard enabled, opened.contains(link) else { return }
        let framed = FrameDecoder.frame(data)
        guard (queues[link]?.count ?? 0) + framed.count <= 131_072 else {
            onStatus?("BLE: очередь переполнена, связь сброшена")
            if let item = peripherals.values.first(where: { centralLink($0.identifier) == link }) {
                centralManager.cancelPeripheralConnection(item)
            }
            invalidate(link); return
        }
        queues[link, default: Data()].append(framed)
        if let peripheral = peripherals.values.first(where: { centralLink($0.identifier) == link }) {
            drainWrites(peripheral)
        } else { drainNotifications() }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onStatus?("Bluetooth central: \(stateName(central.state))")
        if central.state == .poweredOn { activateCentral() }
        else {
            for id in Array(opened).filter({ $0.hasPrefix("ble-c-") }) { close(id) }
            peripherals.removeAll(); remoteCharacteristics.removeAll(); awaitingWrite.removeAll()
        }
    }
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        onStatus?("Bluetooth peripheral: \(stateName(peripheral.state))")
        if peripheral.state == .poweredOn { activatePeripheral() }
        else {
            characteristic = nil; subscribers.removeAll()
            for id in Array(opened).filter({ $0.hasPrefix("ble-p-") }) { close(id) }
        }
    }
    private func activateCentral() {
        guard enabled, centralManager?.state == .poweredOn else { return }
        centralManager.scanForPeripherals(withServices: [serviceID], options: nil)
    }
    private func activatePeripheral() {
        guard enabled, peripheralManager?.state == .poweredOn, characteristic == nil else { return }
        let value = CBMutableCharacteristic(type: characteristicID, properties: [.notify, .write],
            value: nil, permissions: [.writeable])
        let service = CBMutableService(type: serviceID, primary: true)
        service.characteristics = [value]; characteristic = value
        peripheralManager.add(service)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard enabled else { return }
        if let error { onStatus?("BLE service: \(error.localizedDescription)"); characteristic = nil; return }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceID]])
    }
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        onStatus?(error.map { "BLE advertising: \($0.localizedDescription)" } ?? "Bluetooth: обнаружение включено")
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard enabled, peripherals[peripheral.identifier] == nil, peripherals.count < 8 else { return }
        peripherals[peripheral.identifier] = peripheral; peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard enabled else { central.cancelPeripheralConnection(peripheral); return }
        peripheral.discoverServices([serviceID])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        disconnected(peripheral)
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        disconnected(peripheral)
    }
    private func disconnected(_ peripheral: CBPeripheral) {
        close(centralLink(peripheral.identifier))
        remoteCharacteristics.removeValue(forKey: peripheral.identifier)
        peripherals.removeValue(forKey: peripheral.identifier); awaitingWrite.remove(peripheral.identifier)
        let epoch = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.enabled, self.generation == epoch else { return }
            self.centralManager.stopScan(); self.activateCentral()
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard enabled, error == nil else { centralManager.cancelPeripheralConnection(peripheral); return }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceID }) else {
            centralManager.cancelPeripheralConnection(peripheral); return
        }
        peripheral.discoverCharacteristics([characteristicID], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        // The other phone may stop/restart its session without terminating the physical BLE link.
        if invalidatedServices.contains(where: { $0.uuid == serviceID }) {
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard enabled, error == nil, let value = service.characteristics?.first(where: { $0.uuid == characteristicID }),
              value.properties.contains(.write), value.properties.contains(.notify) else {
            centralManager.cancelPeripheralConnection(peripheral); return
        }
        remoteCharacteristics[peripheral.identifier] = value
        peripheral.setNotifyValue(true, for: value)
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard enabled, error == nil, characteristic.isNotifying else {
            centralManager.cancelPeripheralConnection(peripheral); return
        }
        open(centralLink(peripheral.identifier), label: "Bluetooth BLE")
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard enabled, error == nil, let data = characteristic.value else { return }
        _ = receive(data, link: centralLink(peripheral.identifier))
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        awaitingWrite.remove(peripheral.identifier)
        guard error == nil else { centralManager.cancelPeripheralConnection(peripheral); return }
        drainWrites(peripheral)
    }
    private func drainWrites(_ peripheral: CBPeripheral) {
        let id = centralLink(peripheral.identifier)
        guard enabled, opened.contains(id), !awaitingWrite.contains(peripheral.identifier),
              let value = remoteCharacteristics[peripheral.identifier], let pending = queues[id], !pending.isEmpty else { return }
        let size = max(1, min(512, peripheral.maximumWriteValueLength(for: .withResponse)))
        let chunk = Data(pending.prefix(size)); queues[id] = Data(pending.dropFirst(chunk.count))
        awaitingWrite.insert(peripheral.identifier)
        peripheral.writeValue(chunk, for: value, type: .withResponse)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard enabled, subscribers.count < 8 else { return }
        subscribers[central.identifier] = central
        open(peripheralLink(central.identifier), label: "Bluetooth BLE")
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribers.removeValue(forKey: central.identifier); close(peripheralLink(central.identifier))
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        guard enabled, requests.allSatisfy({ $0.characteristic.uuid == characteristicID && $0.offset == 0 &&
            $0.value != nil && subscribers[$0.central.identifier] != nil }) else {
            peripheral.respond(to: first, withResult: .requestNotSupported); return
        }
        for request in requests {
            if let value = request.value, !receive(value, link: peripheralLink(request.central.identifier)) {
                peripheral.respond(to: first, withResult: .invalidAttributeValueLength); return
            }
        }
        peripheral.respond(to: first, withResult: .success)
    }
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) { drainNotifications() }
    private func drainNotifications() {
        guard enabled, peripheralManager?.state == .poweredOn, let characteristic else { return }
        for central in Array(subscribers.values) {
            let id = peripheralLink(central.identifier)
            while let pending = queues[id], !pending.isEmpty {
                let chunk = Data(pending.prefix(max(1, min(512, central.maximumUpdateValueLength))))
                guard peripheralManager.updateValue(chunk, for: characteristic, onSubscribedCentrals: [central]) else { return }
                queues[id] = Data(pending.dropFirst(chunk.count))
            }
        }
    }
    private func receive(_ data: Data, link: String) -> Bool {
        guard opened.contains(link) else { return false }
        do {
            var decoder = decoders[link] ?? FrameDecoder()
            let frames = try decoder.append(data); decoders[link] = decoder
            for frame in frames { onFrame?(frame, link) }
            return true
        } catch { invalidate(link); onStatus?("BLE: некорректный поток"); return false }
    }
    private func invalidate(_ id: String) {
        if let peripheral = peripherals.values.first(where: { centralLink($0.identifier) == id }) {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        for central in Array(subscribers.values) where peripheralLink(central.identifier) == id {
            subscribers.removeValue(forKey: central.identifier)
        }
        close(id)
    }
    private func open(_ id: String, label: String) {
        guard opened.insert(id).inserted else { return }
        decoders[id] = FrameDecoder(); onOpen?(id, label)
    }
    private func close(_ id: String) {
        decoders.removeValue(forKey: id); queues.removeValue(forKey: id)
        if opened.remove(id) != nil { onClose?(id) }
    }
    private func centralLink(_ id: UUID) -> String { "ble-c-" + id.uuidString }
    private func peripheralLink(_ id: UUID) -> String { "ble-p-" + id.uuidString }
    private func stateName(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn: return "включён"
        case .poweredOff: return "выключен"
        case .unauthorized: return "доступ запрещён"
        case .unsupported: return "не поддерживается"
        case .resetting: return "перезапуск"
        default: return "определение состояния"
        }
    }
}
