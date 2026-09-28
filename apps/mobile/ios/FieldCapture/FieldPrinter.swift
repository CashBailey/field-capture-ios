import CoreBluetooth
import Foundation
import React

@objc(FieldPrinter)
final class FieldPrinter: NSObject, RCTBridgeModule {
  typealias Resolve = RCTPromiseResolveBlock
  typealias Reject = RCTPromiseRejectBlock

  fileprivate static let defaultTimeoutMs = 10_000
  fileprivate static let exactPrinterName = "PT-210_261D"
  fileprivate static let knownServiceUUIDs: Set<String> = [
    "18F0",
    "FEE7",
    "FF00",
    "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2",
    "49535343-FE7D-4AE5-8FA9-9FAFD205E455",
  ]
  fileprivate static let writableRanks: [String: Int] = [
    "18F0|2AF1": 0,
    "FF00|FF02": 1,
    "FEE7|FEC7": 2,
    "E7810A71-73AE-499D-8C15-FAA9AEF0C3F2|BEF8D6C9-9C21-4C9E-B632-BD58C1009F9F": 3,
    "49535343-FE7D-4AE5-8FA9-9FAFD205E455|49535343-8841-43F4-A8D4-ECBE34729BB3": 4,
    "49535343-FE7D-4AE5-8FA9-9FAFD205E455|49535343-ACA3-481C-91EC-D85E28A60318": 5,
  ]
  fileprivate static let likelyNameFragments = [
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

  static func moduleName() -> String! {
    "FieldPrinter"
  }

  static func requiresMainQueueSetup() -> Bool {
    false
  }

  @objc(discover:includeUnpaired:resolver:rejecter:)
  func discover(
    _ timeoutMs: NSNumber,
    includeUnpaired: Bool,
    resolver resolve: @escaping Resolve,
    rejecter reject: @escaping Reject
  ) {
    bluetoothQueue.async {
      self.withPoweredCentral(timeoutMs: timeoutMs.intValue, reject: reject) {
        self.beginDiscovery(timeoutMs: timeoutMs.intValue, resolve: resolve, reject: reject)
      }
    }
  }

  @objc(connect:timeoutMs:resolver:rejecter:)
  func connect(
    _ deviceId: String,
    timeoutMs: NSNumber,
    resolver resolve: @escaping Resolve,
    rejecter reject: @escaping Reject
  ) {
    bluetoothQueue.async {
      self.withPoweredCentral(timeoutMs: timeoutMs.intValue, reject: reject) {
        self.beginConnect(deviceId: deviceId, timeoutMs: timeoutMs.intValue, resolve: resolve, reject: reject)
      }
    }
  }

  @objc(disconnect:resolver:rejecter:)
  func disconnect(
    _ timeoutMs: NSNumber,
    resolver resolve: @escaping Resolve,
    rejecter reject: @escaping Reject
  ) {
    bluetoothQueue.async {
      _ = timeoutMs
      self.pendingWrite?.finish(
        code: "ERR_PT210_WRITE_FAILED",
        message: "PT-210 write canceled by disconnect"
      )
      self.pendingWrite = nil
      self.pendingConnect?.finish(
        code: "ERR_PT210_CONNECT_FAILED",
        message: "PT-210 connect canceled by disconnect"
      )
      self.pendingConnect = nil
      if let peripheral = self.connectedPeripheral {
        self.centralManager?.cancelPeripheralConnection(peripheral)
      }
      self.clearConnection(keepLastDevice: true)
      self.resolve(resolve, self.statusMap(state: "disconnected"))
    }
  }

  @objc(status:resolver:rejecter:)
  func status(
    _ timeoutMs: NSNumber,
    resolver resolve: @escaping Resolve,
    rejecter reject: @escaping Reject
  ) {
    bluetoothQueue.async {
      _ = timeoutMs
      _ = reject
      self.resolve(resolve, self.statusMap())
    }
  }

  @objc(reconnect:resolver:rejecter:)
  func reconnect(
    _ timeoutMs: NSNumber,
    resolver resolve: @escaping Resolve,
    rejecter reject: @escaping Reject
  ) {
    bluetoothQueue.async {
      guard let deviceId = self.lastDeviceId ?? self.currentDeviceId else {
        self.reject(reject, "ERR_PT210_NO_DEVICE", "No previous PT-210 device to reconnect")
        return
      }
      self.withPoweredCentral(timeoutMs: timeoutMs.intValue, reject: reject) {
        if let peripheral = self.connectedPeripheral,
           peripheral.identifier.uuidString.caseInsensitiveCompare(deviceId) == .orderedSame,
           peripheral.state == .connected {
          self.beginConnect(deviceId: deviceId, timeoutMs: timeoutMs.intValue, resolve: resolve, reject: reject)
          return
        }
        if let peripheral = self.connectedPeripheral {
          self.centralManager?.cancelPeripheralConnection(peripheral)
        }
        self.clearConnection(keepLastDevice: true)
        self.beginConnect(deviceId: deviceId, timeoutMs: timeoutMs.intValue, resolve: resolve, reject: reject)
      }
    }
  }

  @objc(writeBytes:timeoutMs:resolver:rejecter:)
  func writeBytes(
    _ bytes: NSArray,
    timeoutMs: NSNumber,
    resolver resolve: @escaping Resolve,
    rejecter reject: @escaping Reject
  ) {
    bluetoothQueue.async {
      self.beginWrite(bytes: bytes, timeoutMs: timeoutMs.intValue, resolve: resolve, reject: reject)
    }
  }

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
    reject: @escaping Reject,
    operation: @escaping () -> Void
  ) {
    let manager = central()
    switch manager.state {
    case .poweredOn:
      operation()
    case .unsupported:
      self.reject(reject, "ERR_PT210_BLUETOOTH_UNAVAILABLE", "Bluetooth LE is unavailable on this iPhone")
    case .unauthorized:
      self.reject(reject, "ERR_PT210_PERMISSION_DENIED", "Bluetooth permission denied for PT-210 printing")
    case .poweredOff:
      self.reject(reject, "ERR_PT210_BLUETOOTH_DISABLED", "Bluetooth is disabled")
    case .unknown, .resetting:
      let waiter = PendingPowerWaiter(
        timeoutMs: normalizedTimeout(timeoutMs),
        queue: bluetoothQueue,
        onReady: operation,
        onReject: { [weak self] code, message in
          self?.reject(reject, code, message)
        }
      )
      powerWaiters.append(waiter)
    @unknown default:
      self.reject(reject, "ERR_PT210_BLUETOOTH_UNAVAILABLE", "Bluetooth is in an unknown state")
    }
  }

  private func beginDiscovery(timeoutMs: Int, resolve: @escaping Resolve, reject: @escaping Reject) {
    if pendingDiscovery != nil {
      self.reject(reject, "ERR_PT210_DISCOVERY_FAILED", "PT-210 discovery is already running")
      return
    }

    let manager = central()
    discoveredDevices.removeAll()
    addRetrievedConnectedPrinters(manager)
    pendingDiscovery = PendingDiscovery(
      timeoutMs: normalizedTimeout(timeoutMs),
      queue: bluetoothQueue,
      onFinish: { [weak self] in
        guard let self else { return }
        manager.stopScan()
        let devices = self.sortedDiscoveredDevices().map { $0.asMap() }
        self.pendingDiscovery = nil
        self.resolve(resolve, devices)
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
      addDiscoveredPrinter(
        peripheral,
        advertisedServices: serviceIds,
        localName: peripheral.name,
        rssi: 0
      )
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
      identifier: peripheral.identifier,
      name: name,
      rssi: rssi,
      advertisedServiceUUIDs: advertisedServices.map { $0.uuidString.uppercased() }
    )
  }

  private func beginConnect(
    deviceId: String,
    timeoutMs: Int,
    resolve: @escaping Resolve,
    reject: @escaping Reject
  ) {
    guard pendingConnect == nil else {
      self.reject(reject, "ERR_PT210_CONNECT_FAILED", "PT-210 connect is already running")
      return
    }
    guard let uuid = UUID(uuidString: deviceId) else {
      self.reject(reject, "ERR_PT210_BAD_DEVICE_ID", "Invalid BLE device id for PT-210: \(deviceId)")
      return
    }

    let manager = central()
    let peripheral = knownPeripherals[uuid] ?? manager.retrievePeripherals(withIdentifiers: [uuid]).first
    guard let peripheral else {
      self.reject(reject, "ERR_PT210_BAD_DEVICE_ID", "No discovered PT-210 peripheral for id \(deviceId)")
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
      timeoutMs: normalizedTimeout(timeoutMs),
      queue: bluetoothQueue,
      onTimeout: { [weak self] in
        guard let self else { return }
        self.centralManager?.cancelPeripheralConnection(peripheral)
        self.clearConnection(keepLastDevice: true)
        self.pendingConnect = nil
        self.reject(reject, "ERR_PT210_TIMEOUT", "PT-210 connect timed out after \(self.normalizedTimeout(timeoutMs))ms")
      },
      onResolve: { [weak self] in
        guard let self else { return }
        self.resolve(resolve, self.statusMap(state: "connected"))
      },
      onReject: { [weak self] code, message in
        guard let self else { return }
        self.reject(reject, code, message)
      }
    )
    if peripheral.state == .connected {
      pendingConnect?.resetDiscoveryState()
      peripheral.discoverServices(nil)
    } else {
      manager.connect(peripheral, options: nil)
    }
  }

  private func beginWrite(bytes: NSArray, timeoutMs: Int, resolve: @escaping Resolve, reject: @escaping Reject) {
    guard pendingWrite == nil else {
      self.reject(reject, "ERR_PT210_WRITE_FAILED", "Another PT-210 write is already running")
      return
    }
    guard let peripheral = connectedPeripheral, peripheral.state == .connected,
          let characteristic = selectedCharacteristic else {
      self.reject(reject, "ERR_PT210_NOT_CONNECTED", "PT-210 is not connected")
      return
    }
    guard characteristic.properties.contains(.write) else {
      self.reject(
        reject,
        "ERR_PT210_NO_WRITABLE_CHARACTERISTIC",
        "Selected PT-210 characteristic does not support write-with-response"
      )
      return
    }

    let payload = data(from: bytes)
    if payload.isEmpty {
      self.resolve(resolve, statusMap(state: "connected"))
      return
    }

    let maxLength = max(20, min(512, peripheral.maximumWriteValueLength(for: .withResponse)))
    let chunks = payload.chunks(maxLength: maxLength)
    pendingWrite = PendingWrite(
      characteristic: characteristic,
      chunks: chunks,
      totalBytes: payload.count,
      timeoutMs: normalizedTimeout(timeoutMs),
      queue: bluetoothQueue,
      onTimeout: { [weak self] in
        guard let self else { return }
        self.pendingWrite = nil
        self.reject(reject, "ERR_PT210_TIMEOUT", "PT-210 write timed out after \(self.normalizedTimeout(timeoutMs))ms")
      },
      onResolve: { [weak self] in
        guard let self else { return }
        self.resolve(resolve, self.statusMap(state: "connected"))
      },
      onReject: { [weak self] code, message in
        guard let self else { return }
        self.reject(reject, code, message)
      }
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
      let details = pendingConnect.serviceSummaries.isEmpty
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

  private func statusMap(state: String? = nil, message: String? = nil, errorCode: String? = nil) -> [String: Any] {
    let connected = connectedPeripheral?.state == .connected
    let ready = connected && selectedCharacteristic != nil
    var map: [String: Any] = [
      "state": state ?? (connected ? "connected" : "disconnected"),
      "connected": connected,
      "ready": ready,
      "transport": "ble-gatt",
    ]
    if let currentDeviceId {
      map["deviceId"] = currentDeviceId
    }
    if let currentDeviceName {
      map["deviceName"] = currentDeviceName
    }
    if let errorCode {
      map["errorCode"] = errorCode
    }
    if let message {
      map["message"] = message
    } else if let characteristic = selectedCharacteristic,
              let service = characteristic.service {
      map["message"] = "BLE \(service.uuid.uuidString)/\(characteristic.uuid.uuidString) ready"
    }
    return map
  }

  private func data(from array: NSArray) -> Data {
    var data = Data(capacity: array.count)
    for value in array {
      if let number = value as? NSNumber {
        data.append(UInt8(truncating: number))
      }
    }
    return data
  }

  private func normalizedTimeout(_ timeoutMs: Int) -> Int {
    max(1, timeoutMs == 0 ? Self.defaultTimeoutMs : timeoutMs)
  }

  private func displayName(for peripheral: CBPeripheral) -> String {
    peripheral.name ?? discoveredDevices[peripheral.identifier]?.name ?? "Unnamed BLE Peripheral"
  }

  private func resolve(_ resolve: @escaping Resolve, _ value: Any) {
    DispatchQueue.main.async {
      resolve(value)
    }
  }

  private func reject(_ reject: @escaping Reject, _ code: String, _ message: String) {
    DispatchQueue.main.async {
      reject(code, message, nil)
    }
  }

  fileprivate static func isLikelyPrinterName(_ name: String) -> Bool {
    let normalized = name.lowercased()
    if normalized == exactPrinterName.lowercased() {
      return true
    }
    return likelyNameFragments.contains { normalized.contains($0) }
  }

  fileprivate static func isExactPrinterName(_ name: String) -> Bool {
    name.caseInsensitiveCompare(exactPrinterName) == .orderedSame
  }

  private static func rank(serviceUUID: String, characteristicUUID: String) -> Int {
    writableRanks["\(serviceUUID)|\(characteristicUUID)".uppercased()] ?? Int.max
  }
}

extension FieldPrinter: CBCentralManagerDelegate {
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    switch central.state {
    case .poweredOn:
      let waiters = powerWaiters
      powerWaiters.removeAll()
      waiters.forEach { $0.succeed() }
    case .unsupported:
      failPowerWaiters(code: "ERR_PT210_BLUETOOTH_UNAVAILABLE", message: "Bluetooth LE is unavailable on this iPhone")
    case .unauthorized:
      failPowerWaiters(code: "ERR_PT210_PERMISSION_DENIED", message: "Bluetooth permission denied for PT-210 printing")
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

  func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    let advertisedServices = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
    let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
    addDiscoveredPrinter(
      peripheral,
      advertisedServices: advertisedServices,
      localName: localName,
      rssi: RSSI.intValue
    )
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    guard let pendingConnect, pendingConnect.peripheralId == peripheral.identifier else {
      return
    }
    peripheral.delegate = self
    pendingConnect.resetDiscoveryState()
    peripheral.discoverServices(nil)
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    guard let pendingConnect, pendingConnect.peripheralId == peripheral.identifier else {
      return
    }
    clearConnection(keepLastDevice: true)
    pendingConnect.finish(
      code: "ERR_PT210_CONNECT_FAILED",
      message: "PT-210 connect failed: \(error?.localizedDescription ?? "unknown CoreBluetooth error")"
    )
    self.pendingConnect = nil
  }

  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
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

extension FieldPrinter: CBPeripheralDelegate {
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    guard let pendingConnect, pendingConnect.peripheralId == peripheral.identifier else {
      return
    }
    if let error {
      pendingConnect.finish(
        code: "ERR_PT210_CONNECT_FAILED",
        message: "PT-210 service discovery failed: \(error.localizedDescription)"
      )
      self.pendingConnect = nil
      return
    }

    let services = peripheral.services ?? []
    if services.isEmpty {
      pendingConnect.finish(
        code: "ERR_PT210_NO_WRITABLE_CHARACTERISTIC",
        message: "PT-210 exposed no BLE services"
      )
      self.pendingConnect = nil
      return
    }

    pendingConnect.remainingCharacteristicDiscoveries = services.count
    for service in services {
      peripheral.discoverCharacteristics(nil, for: service)
    }
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    guard let pendingConnect, pendingConnect.peripheralId == peripheral.identifier else {
      return
    }

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
        if pendingConnect.bestCharacteristic == nil || candidate.rank < pendingConnect.bestCharacteristic!.rank {
          pendingConnect.bestCharacteristic = candidate
        }
      }
    }

    pendingConnect.remainingCharacteristicDiscoveries -= 1
    finishConnectIfReady(for: peripheral)
  }

  func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
    guard let pendingWrite else { return }
    if let error {
      pendingWrite.finish(
        code: "ERR_PT210_WRITE_FAILED",
        message: "PT-210 write failed: \(error.localizedDescription)"
      )
      self.pendingWrite = nil
      return
    }
    writeNextChunk(to: peripheral)
  }
}

private final class PendingPowerWaiter {
  private var settled = false
  private let timeout: DispatchWorkItem
  private let onReady: () -> Void
  private let onReject: (String, String) -> Void

  init(timeoutMs: Int, queue: DispatchQueue, onReady: @escaping () -> Void, onReject: @escaping (String, String) -> Void) {
    self.onReady = onReady
    self.onReject = onReject
    timeout = DispatchWorkItem { }
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
    timeout = DispatchWorkItem { }
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
    timeout = DispatchWorkItem { }
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
  let totalBytes: Int
  var nextChunkIndex = 0

  private var settled = false
  private let timeout: DispatchWorkItem
  private let onResolve: () -> Void
  private let onReject: (String, String) -> Void

  init(
    characteristic: CBCharacteristic,
    chunks: [Data],
    totalBytes: Int,
    timeoutMs: Int,
    queue: DispatchQueue,
    onTimeout: @escaping () -> Void,
    onResolve: @escaping () -> Void,
    onReject: @escaping (String, String) -> Void
  ) {
    self.characteristic = characteristic
    self.chunks = chunks
    self.totalBytes = totalBytes
    self.onResolve = onResolve
    self.onReject = onReject
    timeout = DispatchWorkItem { }
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

private struct DiscoveredBlePrinter {
  let identifier: UUID
  let name: String
  let rssi: Int
  let advertisedServiceUUIDs: [String]

  var exactNameMatch: Bool {
    FieldPrinter.isExactPrinterName(name)
  }

  var nameHintMatch: Bool {
    FieldPrinter.isLikelyPrinterName(name)
  }

  var serviceHintMatch: Bool {
    advertisedServiceUUIDs.contains { FieldPrinter.knownServiceUUIDs.contains($0.uppercased()) }
  }

  var matchesPrinterHint: Bool {
    exactNameMatch || nameHintMatch || serviceHintMatch
  }

  func asMap() -> [String: Any] {
    [
      "deviceId": identifier.uuidString,
      "name": name,
      "paired": false,
      "transport": "ble-gatt",
      "rssi": rssi,
      "advertisedServiceUUIDs": advertisedServiceUUIDs,
    ]
  }
}

private extension Data {
  func chunks(maxLength: Int) -> [Data] {
    guard maxLength > 0, !isEmpty else { return [] }
    return stride(from: startIndex, to: endIndex, by: maxLength).map { start in
      let end = Swift.min(start + maxLength, endIndex)
      return self[start..<end]
    }
  }
}
