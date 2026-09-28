// Port of apps/mobile/src/adapters/printer/Pt210Module.ts (`Pt210PrinterTransport`) fused with
// its native backing, apps/mobile/ios/FieldCapture/FieldPrinter.swift (the CoreBluetooth
// implementation behind the React Native module `FieldPrinter`).
//
// In the RN app these were two layers: a JS wrapper (`Pt210PrinterTransport` /
// `ReactNativePt210NativeBinding` in Pt210Module.ts) that added timeouts and normalized errors,
// sitting in front of the native module (FieldPrinter.swift) that spoke CoreBluetooth and
// rejected with raw `ERR_PT210_*` string codes. There is no bridge here, so this file collapses
// both into one Swift class: the discovery filtering, service/characteristic ranking, chunked
// writes, and reconnect-by-last-device-id are FieldPrinter.swift's logic verbatim; the
// timeout/error normalization (`Pt210NativeError.make`, `normalizedPt210Timeout`) is the former
// JS wrapper's, now applied at the point of the CoreBluetooth call instead of after a bridge
// round-trip. Every CoreBluetooth delegate callback resolves or rejects through exactly one
// `CheckedContinuation`, guarded by the same `settled` flag discipline FieldPrinter.swift used to
// resolve/reject its RN promises exactly once.
import CoreBluetooth
import Foundation
import FieldContracts

public final class Pt210PrinterTransport: NSObject, PrinterTransport, @unchecked Sendable {
    public let kind: PrinterTransportKind = .bleGatt

    static let exactPrinterName = "PT-210_261D"
    static let knownServiceUUIDs: Set<String> = [
        "18F0",
        "FEE7",
        "FF00",
        "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2",
        "49535343-FE7D-4AE5-8FA9-9FAFD205E455",
    ]
    static let writableRanks: [String: Int] = [
        "18F0|2AF1": 0,
        "FF00|FF02": 1,
        "FEE7|FEC7": 2,
        "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2|BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F": 3,
        "49535343-FE7D-4AE5-8FA9-9FAFD205E455|49535343-8841-43F4-A8D4-ECBE34729BB3": 4,
        "49535343-FE7D-4AE5-8FA9-9FAFD205E455|49535343-ACA3-481C-91EC-D85E28A60318": 5,
    ]
    static let likelyNameFragments = [
        "goojprt",
        "pt210",
        "pt-210",
        "pt200",
        "pt-200",
        "mtp-ii",
        "mtp ii",
    ]

    private let bluetoothQueue = DispatchQueue(label: "com.example.fieldcapture.pt210.bluetooth")
    private var centralManager: CBCentralManager?
    private var powerWaiters: [PendingPowerWaiter] = []
    private var pendingDiscovery: PendingDiscovery?
    private var pendingConnect: PendingConnect?
    private var pendingWrite: PendingWrite?
    private var knownPeripherals: [UUID: CBPeripheral] = [:]
    private var discoveredDevices: [UUID: DiscoveredBlePrinter] = [:]
    private var connectedPeripheral: CBPeripheral?
    private var selectedCharacteristic: CBCharacteristic?
    private var currentDeviceId: String?
    private var currentDeviceName: String?
    private var lastDeviceId: String?

    // ponytail: isConnected() must stay a cheap synchronous read (protocol requirement, and
    // callers must never block on the bluetooth queue for it) — a lock-guarded cache updated
    // every time a status is produced, matching the TS `ReactNativePt210NativeBinding`'s
    // `rememberStatus`/`isConnected` cache-only contract instead of touching CoreBluetooth state
    // from an arbitrary calling thread.
    private let cacheLock = NSLock()
    private var cachedConnected = false

    public override init() {
        super.init()
    }

    // MARK: - Public async API (mirrors Pt210Module.ts's `Pt210PrinterTransport` + native binding)

    /// Port of `Pt210NativeBinding.discover` / FieldPrinter.swift's `discover`.
    ///
    // ponytail: `includeUnpaired` is accepted for API parity with the TS signature but — exactly
    // as in FieldPrinter.swift, which received the same flag over the RN bridge and never read
    // it — is not consulted below; BLE discovery has no paired/unpaired distinction to filter on.
    public func discover(timeoutMs: Int? = nil, includeUnpaired: Bool = false) async throws -> [DiscoveredBlePrinter] {
        let t = normalizedPt210Timeout(timeoutMs)
        return try await withCheckedThrowingContinuation { continuation in
            bluetoothQueue.async {
                self.withPoweredCentral(
                    timeoutMs: t,
                    reject: { code, message in
                        continuation.resume(throwing: Pt210NativeError.make(code, message))
                    }
                ) {
                    self.beginDiscovery(
                        timeoutMs: t,
                        resolve: { devices in continuation.resume(returning: devices) },
                        reject: { code, message in continuation.resume(throwing: Pt210NativeError.make(code, message)) }
                    )
                }
            }
        }
    }

    /// Port of `PrinterTransport.connect` (protocol conformance — no timeout parameter, so this
    /// uses the same default the TS binding falls back to).
    public func connect(_ deviceId: String) async throws {
        _ = try await connect(deviceId, timeoutMs: nil)
    }

    /// Port of `Pt210NativeBinding.connect` / FieldPrinter.swift's `connect`.
    public func connect(_ deviceId: String, timeoutMs: Int?) async throws -> Pt210Status {
        let t = normalizedPt210Timeout(timeoutMs)
        return try await withCheckedThrowingContinuation { continuation in
            bluetoothQueue.async {
                let reject: (String, String) -> Void = { code, message in
                    self.invalidateCachedConnection()
                    continuation.resume(throwing: Pt210NativeError.make(code, message))
                }
                self.withPoweredCentral(
                    timeoutMs: t,
                    reject: reject
                ) {
                    self.beginConnect(
                        deviceId: deviceId,
                        timeoutMs: t,
                        resolve: { status in
                            self.updateCachedConnected(status)
                            continuation.resume(returning: status)
                        },
                        reject: reject
                    )
                }
            }
        }
    }

    /// Port of `PrinterTransport.disconnect` — always safe, never throws (matches
    /// FieldPrinter.swift's `disconnect`, which unconditionally tears down and resolves).
    public func disconnect() async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            bluetoothQueue.async {
                self.pendingWrite?.finish(
                    code: "ERR_PT210_WRITE_FAILED", message: "PT-210 write canceled by disconnect")
                self.pendingWrite = nil
                self.pendingConnect?.finish(
                    code: "ERR_PT210_CONNECT_FAILED", message: "PT-210 connect canceled by disconnect")
                self.pendingConnect = nil
                if let peripheral = self.connectedPeripheral {
                    self.centralManager?.cancelPeripheralConnection(peripheral)
                }
                self.clearConnection(keepLastDevice: true)
                continuation.resume()
            }
        }
    }

    /// Port of `PrinterTransport.isConnected` — cache-only, see `cachedConnected` above.
    public func isConnected() -> Bool {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cachedConnected
    }

    /// Port of `Pt210NativeBinding.status` / FieldPrinter.swift's `status`.
    public func status(timeoutMs: Int? = nil) async throws -> Pt210Status {
        // FieldPrinter.swift's status ignores the timeout too; keep it for signature parity.
        _ = normalizedPt210Timeout(timeoutMs)
        let status: Pt210Status = await withCheckedContinuation { continuation in
            bluetoothQueue.async {
                let status = self.currentStatus()
                self.updateCachedConnected(status)
                continuation.resume(returning: status)
            }
        }
        return status
    }

    /// Port of `Pt210NativeBinding.reconnect` / FieldPrinter.swift's `reconnect`.
    public func reconnect(timeoutMs: Int? = nil) async throws -> Pt210Status {
        let t = normalizedPt210Timeout(timeoutMs)
        return try await withCheckedThrowingContinuation { continuation in
            bluetoothQueue.async {
                let reject: (String, String) -> Void = { code, message in
                    self.invalidateCachedConnection()
                    continuation.resume(throwing: Pt210NativeError.make(code, message))
                }
                guard let deviceId = self.lastDeviceId ?? self.currentDeviceId else {
                    reject("ERR_PT210_NO_DEVICE", "No previous PT-210 device to reconnect")
                    return
                }
                self.withPoweredCentral(
                    timeoutMs: t,
                    reject: reject
                ) {
                    let resolve: (Pt210Status) -> Void = { status in
                        self.updateCachedConnected(status)
                        continuation.resume(returning: status)
                    }
                    if let peripheral = self.connectedPeripheral,
                        peripheral.identifier.uuidString.caseInsensitiveCompare(deviceId) == .orderedSame,
                        peripheral.state == .connected
                    {
                        self.beginConnect(deviceId: deviceId, timeoutMs: t, resolve: resolve, reject: reject)
                        return
                    }
                    if let peripheral = self.connectedPeripheral {
                        self.centralManager?.cancelPeripheralConnection(peripheral)
                    }
                    self.clearConnection(keepLastDevice: true)
                    self.beginConnect(deviceId: deviceId, timeoutMs: t, resolve: resolve, reject: reject)
                }
            }
        }
    }

    /// Port of `PrinterTransport.writeBytes` (protocol conformance — no timeout parameter; the
    /// richer status-returning write lives at `writeBytes(_:timeoutMs:)`).
    public func writeBytes(_ bytes: Data) async throws {
        _ = try await writeBytes(bytes, timeoutMs: nil)
    }

    /// Port of `Pt210NativeBinding.writeBytes` / FieldPrinter.swift's `writeBytes`.
    public func writeBytes(_ bytes: Data, timeoutMs: Int?) async throws -> Pt210Status {
        let t = normalizedPt210Timeout(timeoutMs)
        return try await withCheckedThrowingContinuation { continuation in
            bluetoothQueue.async {
                let reject: (String, String) -> Void = { code, message in
                    self.invalidateCachedConnection()
                    continuation.resume(throwing: Pt210NativeError.make(code, message))
                }
                self.beginWrite(
                    bytes: bytes,
                    timeoutMs: t,
                    resolve: { status in
                        self.updateCachedConnected(status)
                        continuation.resume(returning: status)
                    },
                    reject: reject
                )
            }
        }
    }

    func updateCachedConnected(_ status: Pt210Status) {
        cacheLock.lock()
        cachedConnected = status.connected && status.ready
        cacheLock.unlock()
    }

    private func invalidateCachedConnection() {
        cacheLock.lock()
        cachedConnected = false
        cacheLock.unlock()
    }

    // MARK: - CoreBluetooth engine (ported from FieldPrinter.swift; runs on `bluetoothQueue`)

    private func central() -> CBCentralManager {
        if let centralManager {
            return centralManager
        }
        let manager = CBCentralManager(
            delegate: self,
            queue: bluetoothQueue,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
        centralManager = manager
        return manager
    }

    private func withPoweredCentral(
        timeoutMs: Int,
        reject: @escaping (String, String) -> Void,
        operation: @escaping () -> Void
    ) {
        let manager = central()
        switch manager.state {
        case .poweredOn:
            operation()
        case .unsupported:
            reject("ERR_PT210_BLUETOOTH_UNAVAILABLE", "Bluetooth LE is unavailable on this iPhone")
        case .unauthorized:
            reject("ERR_PT210_PERMISSION_DENIED", "Bluetooth permission denied for PT-210 printing")
        case .poweredOff:
            reject("ERR_PT210_BLUETOOTH_DISABLED", "Bluetooth is disabled")
        case .unknown, .resetting:
            let waiter = PendingPowerWaiter(
                timeoutMs: timeoutMs,
                queue: bluetoothQueue,
                onReady: operation,
                onReject: reject
            )
            powerWaiters.append(waiter)
        @unknown default:
            reject("ERR_PT210_BLUETOOTH_UNAVAILABLE", "Bluetooth is in an unknown state")
        }
    }

    private func beginDiscovery(
        timeoutMs: Int,
        resolve: @escaping ([DiscoveredBlePrinter]) -> Void,
        reject: @escaping (String, String) -> Void
    ) {
        if pendingDiscovery != nil {
            reject("ERR_PT210_DISCOVERY_FAILED", "PT-210 discovery is already running")
            return
        }

        let manager = central()
        discoveredDevices.removeAll()
        addRetrievedConnectedPrinters(manager)
        pendingDiscovery = PendingDiscovery(
            timeoutMs: timeoutMs,
            queue: bluetoothQueue,
            onFinish: { [weak self] in
                guard let self else { return }
                manager.stopScan()
                let devices = self.sortedDiscoveredDevices()
                self.pendingDiscovery = nil
                resolve(devices)
            }
        )
        manager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    private func addRetrievedConnectedPrinters(_ manager: CBCentralManager) {
        let serviceIds = Self.knownServiceUUIDs.map { CBUUID(string: $0) }
        for peripheral in manager.retrieveConnectedPeripherals(withServices: serviceIds) {
            addDiscoveredPrinter(peripheral, advertisedServices: serviceIds, localName: peripheral.name, rssi: 0)
        }
    }

    private func addDiscoveredPrinter(
        _ peripheral: CBPeripheral,
        advertisedServices: [CBUUID],
        localName: String?,
        rssi: Int
    ) {
        knownPeripherals[peripheral.identifier] = peripheral
        let name = localName ?? peripheral.name ?? "Unnamed BLE Peripheral"
        discoveredDevices[peripheral.identifier] = DiscoveredBlePrinter(
            deviceId: peripheral.identifier.uuidString,
            name: name,
            rssi: rssi,
            advertisedServiceUUIDs: advertisedServices.map { $0.uuidString.uppercased() }
        )
    }

    private func beginConnect(
        deviceId: String,
        timeoutMs: Int,
        resolve: @escaping (Pt210Status) -> Void,
        reject: @escaping (String, String) -> Void
    ) {
        guard pendingConnect == nil else {
            reject("ERR_PT210_CONNECT_FAILED", "PT-210 connect is already running")
            return
        }
        guard let uuid = UUID(uuidString: deviceId) else {
            reject("ERR_PT210_BAD_DEVICE_ID", "Invalid BLE device id for PT-210: \(deviceId)")
            return
        }

        let manager = central()
        let peripheral = knownPeripherals[uuid] ?? manager.retrievePeripherals(withIdentifiers: [uuid]).first
        guard let peripheral else {
            reject("ERR_PT210_BAD_DEVICE_ID", "No discovered PT-210 peripheral for id \(deviceId)")
            return
        }

        if manager.isScanning {
            manager.stopScan()
            pendingDiscovery?.finish()
            pendingDiscovery = nil
        }
        if let current = connectedPeripheral, current.identifier != peripheral.identifier {
            manager.cancelPeripheralConnection(current)
        }

        clearConnection(keepLastDevice: true)
        connectedPeripheral = peripheral
        currentDeviceId = peripheral.identifier.uuidString
        currentDeviceName = displayName(for: peripheral)
        peripheral.delegate = self
        pendingConnect = PendingConnect(
            peripheralId: peripheral.identifier,
            timeoutMs: timeoutMs,
            queue: bluetoothQueue,
            onTimeout: { [weak self] in
                guard let self else { return }
                self.centralManager?.cancelPeripheralConnection(peripheral)
                self.clearConnection(keepLastDevice: true)
                self.pendingConnect = nil
                reject("ERR_PT210_TIMEOUT", "PT-210 connect timed out after \(timeoutMs)ms")
            },
            onResolve: { [weak self] in
                guard let self else { return }
                resolve(self.currentStatus(state: .connected))
            },
            onReject: reject
        )
        if peripheral.state == .connected {
            pendingConnect?.resetDiscoveryState()
            peripheral.discoverServices(nil)
        } else {
            manager.connect(peripheral, options: nil)
        }
    }

    private func beginWrite(
        bytes: Data,
        timeoutMs: Int,
        resolve: @escaping (Pt210Status) -> Void,
        reject: @escaping (String, String) -> Void
    ) {
        guard pendingWrite == nil else {
            reject("ERR_PT210_WRITE_FAILED", "Another PT-210 write is already running")
            return
        }
        guard let peripheral = connectedPeripheral, peripheral.state == .connected,
            let characteristic = selectedCharacteristic
        else {
            reject("ERR_PT210_NOT_CONNECTED", "PT-210 is not connected")
            return
        }
        guard characteristic.properties.contains(.write) else {
            reject(
                "ERR_PT210_NO_WRITABLE_CHARACTERISTIC",
                "Selected PT-210 characteristic does not support write-with-response")
            return
        }

        if bytes.isEmpty {
            resolve(currentStatus(state: .connected))
            return
        }

        let maxLength = max(20, min(512, peripheral.maximumWriteValueLength(for: .withResponse)))
        let chunks = bytes.chunks(maxLength: maxLength)
        pendingWrite = PendingWrite(
            characteristic: characteristic,
            chunks: chunks,
            timeoutMs: timeoutMs,
            queue: bluetoothQueue,
            onTimeout: { [weak self] in
                self?.pendingWrite = nil
                reject("ERR_PT210_TIMEOUT", "PT-210 write timed out after \(timeoutMs)ms")
            },
            onResolve: { [weak self] in
                guard let self else { return }
                resolve(self.currentStatus(state: .connected))
            },
            onReject: reject
        )
        writeNextChunk(to: peripheral)
    }

    private func writeNextChunk(to peripheral: CBPeripheral) {
        guard let pendingWrite else { return }
        if pendingWrite.nextChunkIndex >= pendingWrite.chunks.count {
            pendingWrite.finish()
            self.pendingWrite = nil
            return
        }

        let chunk = pendingWrite.chunks[pendingWrite.nextChunkIndex]
        pendingWrite.nextChunkIndex += 1
        peripheral.writeValue(chunk, for: pendingWrite.characteristic, type: .withResponse)
    }

    private func finishConnectIfReady(for peripheral: CBPeripheral) {
        guard let pendingConnect, pendingConnect.peripheralId == peripheral.identifier else { return }
        guard pendingConnect.remainingCharacteristicDiscoveries == 0 else { return }

        if let candidate = pendingConnect.bestCharacteristic {
            selectedCharacteristic = candidate.characteristic
            currentDeviceId = peripheral.identifier.uuidString
            currentDeviceName = displayName(for: peripheral)
            lastDeviceId = peripheral.identifier.uuidString
            pendingConnect.finish()
            self.pendingConnect = nil
        } else {
            let details =
                pendingConnect.serviceSummaries.isEmpty
                ? "no services discovered"
                : pendingConnect.serviceSummaries.joined(separator: "; ")
            pendingConnect.finish(
                code: "ERR_PT210_NO_WRITABLE_CHARACTERISTIC",
                message: "No PT-210 write-with-response characteristic found (\(details))"
            )
            self.pendingConnect = nil
        }
    }

    private func clearConnection(keepLastDevice: Bool) {
        invalidateCachedConnection()
        selectedCharacteristic = nil
        connectedPeripheral = nil
        if !keepLastDevice {
            lastDeviceId = nil
        }
    }

    private func sortedDiscoveredDevices() -> [DiscoveredBlePrinter] {
        discoveredDevices.values
            .filter { $0.matchesPrinterHint }
            .sorted {
                if $0.exactNameMatch != $1.exactNameMatch { return $0.exactNameMatch }
                if $0.nameHintMatch != $1.nameHintMatch { return $0.nameHintMatch }
                if $0.serviceHintMatch != $1.serviceHintMatch { return $0.serviceHintMatch }
                return $0.rssi > $1.rssi
            }
    }

    private func currentStatus(state: Pt210ConnectionState? = nil, message: String? = nil, errorCode: String? = nil)
        -> Pt210Status
    {
        let connected = connectedPeripheral?.state == .connected
        let ready = connected && selectedCharacteristic != nil
        var resolvedMessage = message
        if resolvedMessage == nil, let characteristic = selectedCharacteristic, let service = characteristic.service {
            resolvedMessage = "BLE \(service.uuid.uuidString)/\(characteristic.uuid.uuidString) ready"
        }
        return Pt210Status(
            state: state ?? (connected ? .connected : .disconnected),
            connected: connected,
            ready: ready,
            deviceId: currentDeviceId,
            deviceName: currentDeviceName,
            transport: .bleGatt,
            errorCode: errorCode,
            message: resolvedMessage
        )
    }

    private func displayName(for peripheral: CBPeripheral) -> String {
        peripheral.name ?? discoveredDevices[peripheral.identifier]?.name ?? "Unnamed BLE Peripheral"
    }

    static func isLikelyPrinterName(_ name: String) -> Bool {
        let normalized = name.lowercased()
        if normalized == exactPrinterName.lowercased() {
            return true
        }
        return likelyNameFragments.contains { normalized.contains($0) }
    }

    static func isExactPrinterName(_ name: String) -> Bool {
        name.caseInsensitiveCompare(exactPrinterName) == .orderedSame
    }

    private static func rank(serviceUUID: String, characteristicUUID: String) -> Int {
        writableRanks["\(serviceUUID)|\(characteristicUUID)".uppercased()] ?? Int.max
    }
}

// MARK: - CBCentralManagerDelegate

extension Pt210PrinterTransport: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            let waiters = powerWaiters
            powerWaiters.removeAll()
            waiters.forEach { $0.succeed() }
        case .unsupported:
            failPowerWaiters(
                code: "ERR_PT210_BLUETOOTH_UNAVAILABLE", message: "Bluetooth LE is unavailable on this iPhone")
        case .unauthorized:
            failPowerWaiters(
                code: "ERR_PT210_PERMISSION_DENIED", message: "Bluetooth permission denied for PT-210 printing")
        case .poweredOff:
            failPowerWaiters(code: "ERR_PT210_BLUETOOTH_DISABLED", message: "Bluetooth is disabled")
        case .unknown, .resetting:
            break
        @unknown default:
            failPowerWaiters(code: "ERR_PT210_BLUETOOTH_UNAVAILABLE", message: "Bluetooth is in an unknown state")
        }
    }

    private func failPowerWaiters(code: String, message: String) {
        let waiters = powerWaiters
        powerWaiters.removeAll()
        waiters.forEach { $0.fail(code: code, message: message) }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertisedServices = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        addDiscoveredPrinter(
            peripheral, advertisedServices: advertisedServices, localName: localName, rssi: RSSI.intValue)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let pendingConnect, pendingConnect.peripheralId == peripheral.identifier else { return }
        peripheral.delegate = self
        pendingConnect.resetDiscoveryState()
        peripheral.discoverServices(nil)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard let pendingConnect, pendingConnect.peripheralId == peripheral.identifier else { return }
        clearConnection(keepLastDevice: true)
        pendingConnect.finish(
            code: "ERR_PT210_CONNECT_FAILED",
            message: "PT-210 connect failed: \(error?.localizedDescription ?? "unknown CoreBluetooth error")"
        )
        self.pendingConnect = nil
    }

    public func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        if connectedPeripheral?.identifier == peripheral.identifier {
            pendingWrite?.finish(
                code: "ERR_PT210_WRITE_FAILED",
                message: "PT-210 disconnected during write: \(error?.localizedDescription ?? "connection closed")"
            )
            pendingWrite = nil
            clearConnection(keepLastDevice: true)
        }
    }
}

// MARK: - CBPeripheralDelegate

extension Pt210PrinterTransport: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let pendingConnect, pendingConnect.peripheralId == peripheral.identifier else { return }
        if let error {
            pendingConnect.finish(
                code: "ERR_PT210_CONNECT_FAILED",
                message: "PT-210 service discovery failed: \(error.localizedDescription)")
            self.pendingConnect = nil
            return
        }

        let services = peripheral.services ?? []
        if services.isEmpty {
            pendingConnect.finish(
                code: "ERR_PT210_NO_WRITABLE_CHARACTERISTIC", message: "PT-210 exposed no BLE services")
            self.pendingConnect = nil
            return
        }

        pendingConnect.remainingCharacteristicDiscoveries = services.count
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?)
    {
        guard let pendingConnect, pendingConnect.peripheralId == peripheral.identifier else { return }

        let serviceUUID = service.uuid.uuidString.uppercased()
        if let error {
            pendingConnect.serviceSummaries.append("\(serviceUUID): error \(error.localizedDescription)")
        } else {
            let characteristics = service.characteristics ?? []
            pendingConnect.serviceSummaries.append(
                "\(serviceUUID): \(characteristics.map { $0.uuid.uuidString }.joined(separator: ","))"
            )
            for characteristic in characteristics where characteristic.properties.contains(.write) {
                let characteristicUUID = characteristic.uuid.uuidString.uppercased()
                let candidate = WritableCandidate(
                    characteristic: characteristic,
                    rank: Self.rank(serviceUUID: serviceUUID, characteristicUUID: characteristicUUID)
                )
                if let best = pendingConnect.bestCharacteristic {
                    if candidate.rank < best.rank { pendingConnect.bestCharacteristic = candidate }
                } else {
                    pendingConnect.bestCharacteristic = candidate
                }
            }
        }

        pendingConnect.remainingCharacteristicDiscoveries -= 1
        finishConnectIfReady(for: peripheral)
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?)
    {
        guard let pendingWrite else { return }
        if let error {
            pendingWrite.finish(
                code: "ERR_PT210_WRITE_FAILED", message: "PT-210 write failed: \(error.localizedDescription)")
            self.pendingWrite = nil
            return
        }
        writeNextChunk(to: peripheral)
    }
}

// MARK: - Pending operation state machines (ported from FieldPrinter.swift)
//
// Each of these settles (resolves/rejects/times out) exactly once, guarded by `settled` — the
// same discipline FieldPrinter.swift used to resolve/reject its RN promises exactly once, kept
// here so the `CheckedContinuation`s above can never be resumed twice.

private final class PendingPowerWaiter {
    private var settled = false
    private let timeout: DispatchWorkItem
    private let onReady: () -> Void
    private let onReject: (String, String) -> Void

    init(
        timeoutMs: Int, queue: DispatchQueue, onReady: @escaping () -> Void,
        onReject: @escaping (String, String) -> Void
    ) {
        self.onReady = onReady
        self.onReject = onReject
        timeout = DispatchWorkItem {}
        timeout.notify(queue: queue) { [weak self] in
            self?.fail(code: "ERR_PT210_TIMEOUT", message: "Bluetooth did not become ready after \(timeoutMs)ms")
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(timeoutMs), execute: timeout)
    }

    func succeed() {
        guard !settled else { return }
        settled = true
        timeout.cancel()
        onReady()
    }

    func fail(code: String, message: String) {
        guard !settled else { return }
        settled = true
        timeout.cancel()
        onReject(code, message)
    }
}

private final class PendingDiscovery {
    private var settled = false
    private let timeout: DispatchWorkItem
    private let onFinish: () -> Void

    init(timeoutMs: Int, queue: DispatchQueue, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        timeout = DispatchWorkItem {}
        timeout.notify(queue: queue) { [weak self] in
            self?.finish()
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(timeoutMs), execute: timeout)
    }

    func finish() {
        guard !settled else { return }
        settled = true
        timeout.cancel()
        onFinish()
    }
}

private final class PendingConnect {
    let peripheralId: UUID
    var remainingCharacteristicDiscoveries = 0
    var bestCharacteristic: WritableCandidate?
    var serviceSummaries: [String] = []

    private var settled = false
    private let timeout: DispatchWorkItem
    private let onResolve: () -> Void
    private let onReject: (String, String) -> Void

    init(
        peripheralId: UUID,
        timeoutMs: Int,
        queue: DispatchQueue,
        onTimeout: @escaping () -> Void,
        onResolve: @escaping () -> Void,
        onReject: @escaping (String, String) -> Void
    ) {
        self.peripheralId = peripheralId
        self.onResolve = onResolve
        self.onReject = onReject
        timeout = DispatchWorkItem {}
        timeout.notify(queue: queue) { [weak self] in
            guard let self, !self.settled else { return }
            self.settled = true
            onTimeout()
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(timeoutMs), execute: timeout)
    }

    func resetDiscoveryState() {
        remainingCharacteristicDiscoveries = 0
        bestCharacteristic = nil
        serviceSummaries.removeAll()
    }

    func finish() {
        guard !settled else { return }
        settled = true
        timeout.cancel()
        onResolve()
    }

    func finish(code: String, message: String) {
        guard !settled else { return }
        settled = true
        timeout.cancel()
        onReject(code, message)
    }
}

private final class PendingWrite {
    let characteristic: CBCharacteristic
    let chunks: [Data]
    var nextChunkIndex = 0

    private var settled = false
    private let timeout: DispatchWorkItem
    private let onResolve: () -> Void
    private let onReject: (String, String) -> Void

    init(
        characteristic: CBCharacteristic,
        chunks: [Data],
        timeoutMs: Int,
        queue: DispatchQueue,
        onTimeout: @escaping () -> Void,
        onResolve: @escaping () -> Void,
        onReject: @escaping (String, String) -> Void
    ) {
        self.characteristic = characteristic
        self.chunks = chunks
        self.onResolve = onResolve
        self.onReject = onReject
        timeout = DispatchWorkItem {}
        timeout.notify(queue: queue) { [weak self] in
            guard let self, !self.settled else { return }
            self.settled = true
            onTimeout()
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(timeoutMs), execute: timeout)
    }

    func finish() {
        guard !settled else { return }
        settled = true
        timeout.cancel()
        onResolve()
    }

    func finish(code: String, message: String) {
        guard !settled else { return }
        settled = true
        timeout.cancel()
        onReject(code, message)
    }
}

private struct WritableCandidate {
    let characteristic: CBCharacteristic
    let rank: Int
}

// ponytail: `internal` (not `fileprivate`, as FieldPrinter.swift had it) so the pure chunking
// logic is directly unit-testable from FieldAdaptersTests via `@testable import` without
// touching CoreBluetooth.
extension Data {
    func chunks(maxLength: Int) -> [Data] {
        guard maxLength > 0, !isEmpty else { return [] }
        return stride(from: startIndex, to: endIndex, by: maxLength).map { start in
            let end = Swift.min(start + maxLength, endIndex)
            return self[start..<end]
        }
    }
}
