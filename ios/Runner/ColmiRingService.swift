import Foundation
@preconcurrency import CoreBluetooth
import HealthKit

private enum ColmiUUID {
  static let serviceV1 = CBUUID(string: "6e40fff0-b5a3-f393-e0a9-e50e24dcca9e")
  static let serviceV2 = CBUUID(string: "de5bf728-d711-4e47-af26-65e3012a5dc7")
  static let command = CBUUID(string: "de5bf72a-d711-4e47-af26-65e3012a5dc7")
  static let notifyV2 = CBUUID(string: "de5bf729-d711-4e47-af26-65e3012a5dc7")
}

private struct ColmiSleepStage {
  let value: Int
  let start: Date
  let end: Date
  let syncIdentifier: String
}

private enum ColmiSleepDecodeError: LocalizedError {
  case malformed
  case noStages

  var errorDescription: String? {
    switch self {
    case .malformed:
      return "The ring returned an invalid sleep packet."
    case .noStages:
      return "The ring returned no recent sleep stages."
    }
  }
}

private enum ColmiRingServiceError: LocalizedError {
  case ringNotFound

  var errorDescription: String? {
    "Scan and select the ring again."
  }
}

private enum ColmiSleepDecoder {
  private static func u16(_ low: UInt8, _ high: UInt8) -> Int {
    Int(low) | (Int(high) << 8)
  }

  static func decode(
    _ data: Data,
    peripheralID: String,
    now: Date = Date(),
    calendar: Calendar = .current
  ) throws -> [ColmiSleepStage] {
    let bytes = [UInt8](data)
    guard bytes.count > 7,
          bytes[0] == 0xbc,
          bytes[1] == 0x27
    else { throw ColmiSleepDecodeError.malformed }

    let packetLength = u16(bytes[2], bytes[3])
    guard packetLength >= 2, bytes.count >= packetLength + 6 else {
      throw ColmiSleepDecodeError.malformed
    }

    let daysInPacket = Int(bytes[6])
    guard daysInPacket <= 8 else { throw ColmiSleepDecodeError.malformed }

    var index = 7
    var stages: [ColmiSleepStage] = []
    let today = calendar.startOfDay(for: now)
    let oldestAllowed = calendar.date(byAdding: .day, value: -9, to: today) ?? today
    let latestAllowed = now.addingTimeInterval(5 * 60)

    for _ in 0..<daysInPacket {
      guard index + 5 < bytes.count else { throw ColmiSleepDecodeError.malformed }

      let daysAgo = Int(bytes[index])
      index += 1
      let dayBytes = Int(bytes[index])
      index += 1
      let sleepStart = u16(bytes[index], bytes[index + 1])
      index += 2
      let sleepEnd = u16(bytes[index], bytes[index + 1])
      index += 2

      guard daysAgo <= 7,
            dayBytes >= 4,
            dayBytes.isMultiple(of: 2),
            sleepStart < 1440,
            sleepEnd < 1440
      else { throw ColmiSleepDecodeError.malformed }

      let dayStart = calendar.date(byAdding: .day, value: -daysAgo, to: today) ?? today
      let startOffset = sleepStart > sleepEnd ? sleepStart - 1440 : sleepStart
      var cursor = calendar.date(byAdding: .minute, value: startOffset, to: dayStart) ?? dayStart
      var consumedDayBytes = 4
      var stageIndex = 0

      while consumedDayBytes < dayBytes {
        guard index + 1 < bytes.count else { throw ColmiSleepDecodeError.malformed }
        let stageType = bytes[index]
        let minutes = Int(bytes[index + 1])
        index += 2
        consumedDayBytes += 2

        guard minutes > 0, minutes <= 720 else { continue }
        guard let end = calendar.date(byAdding: .minute, value: minutes, to: cursor) else {
          continue
        }

        let value: Int?
        switch stageType {
        case 0x02:
          value = 3 // HKCategoryValueSleepAnalysis.asleepCore on iOS 16+
        case 0x03:
          value = 4 // asleepDeep
        case 0x04:
          value = 5 // asleepREM
        case 0x05:
          value = 2 // awake
        default:
          value = nil
        }

        if let value,
           cursor >= oldestAllowed,
           end <= latestAllowed,
           end > cursor {
          let healthValue = ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 16
            ? value
            : (value == 2 ? 2 : 1)
          let startSeconds = Int(cursor.timeIntervalSince1970)
          stages.append(
            ColmiSleepStage(
              value: healthValue,
              start: cursor,
              end: end,
              syncIdentifier: "daymark-colmi-\(peripheralID)-\(daysAgo)-\(stageIndex)-\(startSeconds)-\(healthValue)"
            )
          )
        }

        cursor = end
        stageIndex += 1
      }
    }

    guard !stages.isEmpty else { throw ColmiSleepDecodeError.noStages }
    return stages
  }
}

final class ColmiRingService: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
  private struct DiscoveredRing {
    let peripheral: CBPeripheral
    var name: String
    var rssi: Int
  }

  private let healthStore: HKHealthStore
  private let onSleepSaved: () -> Void
  private var central: CBCentralManager!
  private var rings: [UUID: DiscoveredRing] = [:]
  private var peripheral: CBPeripheral?
  private var commandCharacteristic: CBCharacteristic?
  private var notifyCharacteristic: CBCharacteristic?
  private var bigDataBuffer = Data()
  private var expectedBigDataLength: Int?
  private var scanTimeout: DispatchWorkItem?
  private var syncTimeout: DispatchWorkItem?

  private(set) var isScanning = false
  private(set) var isSyncing = false
  private(set) var status = "Ready to scan for a COLMI R04"

  init(healthStore: HKHealthStore, onSleepSaved: @escaping () -> Void) {
    self.healthStore = healthStore
    self.onSleepSaved = onSleepSaved
    super.init()
    central = CBCentralManager(delegate: self, queue: .main)
  }

  func snapshot() -> [String: Any] {
    let devices = rings.values
      .sorted { $0.rssi > $1.rssi }
      .map { ring in
        [
          "id": ring.peripheral.identifier.uuidString,
          "name": ring.name,
          "rssi": ring.rssi,
        ] as [String: Any]
      }

    return [
      "devices": devices,
      "connectedId": peripheral?.identifier.uuidString ?? NSNull(),
      "connectedName": peripheral?.name ?? NSNull(),
      "status": status,
      "isScanning": isScanning,
      "isConnected": peripheral?.state == .connected
        && commandCharacteristic != nil
        && notifyCharacteristic?.isNotifying == true,
      "isSyncing": isSyncing,
    ]
  }

  func startScan() {
    guard central.state == .poweredOn else {
      status = bluetoothStateMessage()
      return
    }

    rings.removeAll()
    isScanning = true
    status = "Scanning for R04 / QRing devices…"
    central.scanForPeripherals(
      withServices: nil,
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
    )

    scanTimeout?.cancel()
    let timeout = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.central.stopScan()
      self.isScanning = false
      if self.rings.isEmpty {
        self.status = "No QRing-compatible R04 found. Wake the ring, close QRing, and scan again. SmartHealth firmware uses a different protocol."
      } else {
        self.status = "Select your ring and tap Connect."
      }
    }
    scanTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: timeout)
  }

  func connect(id: String) throws {
    guard let uuid = UUID(uuidString: id), let ring = rings[uuid] else {
      throw ColmiRingServiceError.ringNotFound
    }

    scanTimeout?.cancel()
    central.stopScan()
    isScanning = false
    commandCharacteristic = nil
    notifyCharacteristic = nil
    bigDataBuffer.removeAll()
    peripheral = ring.peripheral
    peripheral?.delegate = self
    status = "Connecting to \(ring.name)…"
    central.connect(ring.peripheral, options: nil)
  }

  func disconnect() {
    syncTimeout?.cancel()
    isSyncing = false
    if let peripheral {
      central.cancelPeripheralConnection(peripheral)
    }
    commandCharacteristic = nil
    notifyCharacteristic = nil
    status = "Ring disconnected"
  }

  func syncSleep() {
    guard let peripheral,
          peripheral.state == .connected,
          let commandCharacteristic,
          notifyCharacteristic?.isNotifying == true
    else {
      status = "Connect a QRing-compatible R04 before syncing sleep."
      return
    }

    guard HKHealthStore.isHealthDataAvailable(),
          let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
    else {
      status = "Apple Health is unavailable on this device."
      return
    }

    isSyncing = true
    status = "Requesting Apple Health write permission…"
    healthStore.requestAuthorization(
      toShare: Set<HKSampleType>([sleepType]),
      read: Set<HKObjectType>([sleepType])
    ) { [weak self] success, error in
      DispatchQueue.main.async {
        guard let self else { return }
        guard success else {
          self.isSyncing = false
          self.status = "Apple Health did not allow sleep writes: \(error?.localizedDescription ?? "permission denied")"
          return
        }

        self.bigDataBuffer.removeAll()
        self.expectedBigDataLength = nil
        let request = Data([0xbc, 0x27, 0x01, 0x00, 0xff, 0x00, 0xff])
        let writeType: CBCharacteristicWriteType = commandCharacteristic.properties.contains(.write)
          ? .withResponse
          : .withoutResponse
        peripheral.writeValue(request, for: commandCharacteristic, type: writeType)
        self.status = "Downloading recent sleep from \(peripheral.name ?? "R04")…"
        self.startSyncTimeout()
      }
    }
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    if central.state != .poweredOn {
      isScanning = false
      status = bluetoothStateMessage()
    }
  }

  func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    let advertisedName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
      ?? peripheral.name
      ?? "COLMI ring"
    let normalizedName = advertisedName.uppercased()
    let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
    let hasQRingService = serviceUUIDs.contains(ColmiUUID.serviceV1)
      || serviceUUIDs.contains(ColmiUUID.serviceV2)
    let looksLikeR04 = normalizedName.contains("R04")

    guard hasQRingService || looksLikeR04 else { return }
    rings[peripheral.identifier] = DiscoveredRing(
      peripheral: peripheral,
      name: advertisedName,
      rssi: RSSI.intValue
    )
    status = "Found \(rings.count) possible ring\(rings.count == 1 ? "" : "s")."
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    status = "Connected; checking QRing services…"
    peripheral.delegate = self
    peripheral.discoverServices([ColmiUUID.serviceV1, ColmiUUID.serviceV2])
  }

  func centralManager(
    _ central: CBCentralManager,
    didFailToConnect peripheral: CBPeripheral,
    error: Error?
  ) {
    status = "Connection failed: \(error?.localizedDescription ?? "close QRing and try again")"
  }

  func centralManager(
    _ central: CBCentralManager,
    didDisconnectPeripheral peripheral: CBPeripheral,
    error: Error?
  ) {
    commandCharacteristic = nil
    notifyCharacteristic = nil
    isSyncing = false
    status = error == nil
      ? "Ring disconnected"
      : "Ring disconnected: \(error!.localizedDescription)"
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    if let error {
      status = "Could not read ring services: \(error.localizedDescription)"
      return
    }

    guard let services = peripheral.services,
          services.contains(where: { $0.uuid == ColmiUUID.serviceV2 })
    else {
      status = "This R04 did not expose the QRing sleep service. It may use SmartHealth firmware, which needs a different driver."
      return
    }

    for service in services where service.uuid == ColmiUUID.serviceV2 {
      peripheral.discoverCharacteristics(
        [ColmiUUID.command, ColmiUUID.notifyV2],
        for: service
      )
    }
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didDiscoverCharacteristicsFor service: CBService,
    error: Error?
  ) {
    if let error {
      status = "Could not read ring controls: \(error.localizedDescription)"
      return
    }

    for characteristic in service.characteristics ?? [] {
      switch characteristic.uuid {
      case ColmiUUID.command:
        commandCharacteristic = characteristic
      case ColmiUUID.notifyV2:
        notifyCharacteristic = characteristic
        peripheral.setNotifyValue(true, for: characteristic)
      default:
        break
      }
    }

    if commandCharacteristic == nil || notifyCharacteristic == nil {
      status = "The ring's QRing service is missing a sleep characteristic."
    }
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateNotificationStateFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard characteristic.uuid == ColmiUUID.notifyV2 else { return }
    if let error {
      status = "Could not enable ring sleep notifications: \(error.localizedDescription)"
    } else if characteristic.isNotifying, commandCharacteristic != nil {
      status = "Connected to \(peripheral.name ?? "R04"). Ready to sync sleep."
    }
  }

  func peripheral(
    _ peripheral: CBPeripheral,
    didUpdateValueFor characteristic: CBCharacteristic,
    error: Error?
  ) {
    guard characteristic.uuid == ColmiUUID.notifyV2 else { return }
    if let error {
      finishSync(error: "Ring transfer failed: \(error.localizedDescription)")
      return
    }
    guard let data = characteristic.value, !data.isEmpty else { return }
    ingestBigData(data, peripheral: peripheral)
  }

  private func ingestBigData(_ data: Data, peripheral: CBPeripheral) {
    if data.first == 0xbc {
      let bytes = [UInt8](data)
      guard bytes.count >= 4, bytes[1] == 0x27 else { return }
      bigDataBuffer = data
      expectedBigDataLength = (Int(bytes[2]) | (Int(bytes[3]) << 8)) + 6
    } else if expectedBigDataLength != nil {
      bigDataBuffer.append(data)
    } else {
      return
    }

    guard let expectedBigDataLength,
          bigDataBuffer.count >= expectedBigDataLength
    else { return }

    let packet = Data(bigDataBuffer.prefix(expectedBigDataLength))
    bigDataBuffer.removeAll()
    self.expectedBigDataLength = nil

    do {
      let stages = try ColmiSleepDecoder.decode(
        packet,
        peripheralID: peripheral.identifier.uuidString
      )
      saveToHealth(stages, peripheral: peripheral)
    } catch {
      finishSync(error: error.localizedDescription)
    }
  }

  private func saveToHealth(_ stages: [ColmiSleepStage], peripheral: CBPeripheral) {
    guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
      finishSync(error: "Apple Health sleep data is unavailable.")
      return
    }

    let device = HKDevice(
      name: peripheral.name ?? "COLMI R04",
      manufacturer: "COLMI",
      model: "R04",
      hardwareVersion: nil,
      firmwareVersion: nil,
      softwareVersion: nil,
      localIdentifier: peripheral.identifier.uuidString,
      udiDeviceIdentifier: nil
    )

    let samples = stages.map { stage in
      HKCategorySample(
        type: sleepType,
        value: stage.value,
        start: stage.start,
        end: stage.end,
        device: device,
        metadata: [
          HKMetadataKeySyncIdentifier: stage.syncIdentifier,
          HKMetadataKeySyncVersion: 1,
          "com.alwayspositive7.daymarkhealth.importSource": "COLMI R04 (QRing)",
        ]
      )
    }

    healthStore.save(samples) { [weak self] success, error in
      DispatchQueue.main.async {
        guard let self else { return }
        if success {
          self.syncTimeout?.cancel()
          self.isSyncing = false
          self.status = "Saved \(samples.count) COLMI sleep stages to Apple Health."
          self.onSleepSaved()
        } else {
          self.finishSync(error: "Apple Health save failed: \(error?.localizedDescription ?? "unknown error")")
        }
      }
    }
  }

  private func startSyncTimeout() {
    syncTimeout?.cancel()
    let timeout = DispatchWorkItem { [weak self] in
      guard let self, self.isSyncing else { return }
      self.finishSync(error: "The ring did not return sleep within 20 seconds. Keep it nearby, close QRing, and try again.")
    }
    syncTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
  }

  private func finishSync(error: String) {
    syncTimeout?.cancel()
    isSyncing = false
    status = error
  }

  private func bluetoothStateMessage() -> String {
    switch central.state {
    case .poweredOff:
      return "Turn on Bluetooth to connect the R04."
    case .unauthorized:
      return "Allow Bluetooth access for Daymark Health in iOS Settings."
    case .unsupported:
      return "Bluetooth Low Energy is unavailable on this device."
    case .resetting:
      return "Bluetooth is restarting; try again in a moment."
    default:
      return "Bluetooth is not ready yet."
    }
  }
}
