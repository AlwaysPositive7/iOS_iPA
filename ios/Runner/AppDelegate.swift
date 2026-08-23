import Flutter
import HealthKit
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let healthStore = HKHealthStore()
  private let channelName = "daymark_health/background"
  private let colmiChannelName = "daymark_health/colmi"
  private var observerQueries: [HKObserverQuery] = []
  private var colmiRingService: ColmiRingService?

  private let webhookKey = "daymark.webhookUrl"
  private let tokenKey = "daymark.bearerToken"
  private let typesKey = "daymark.healthTypes"
  private let intervalKey = "daymark.intervalMinutes"
  private let watchOnlyKey = "daymark.appleWatchOnly"
  private let enabledKey = "daymark.backgroundEnabled"
  private let lastSentKey = "daymark.lastBackgroundSent"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)

    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: channelName,
        binaryMessenger: controller.binaryMessenger
      )

      channel.setMethodCallHandler { [weak self] call, result in
        guard let self else {
          result(FlutterError(code: "NO_APP", message: "App unavailable", details: nil))
          return
        }

        switch call.method {
        case "configure":
          guard
            let args = call.arguments as? [String: Any],
            let webhookUrl = args["webhookUrl"] as? String,
            let bearerToken = args["bearerToken"] as? String,
            let typeNames = args["types"] as? [String],
            let interval = args["minimumIntervalMinutes"] as? Int,
            let appleWatchOnly = args["appleWatchOnly"] as? Bool
          else {
            result(FlutterError(code: "BAD_ARGS", message: "Invalid background config", details: nil))
            return
          }

          let defaults = UserDefaults.standard
          defaults.set(webhookUrl, forKey: self.webhookKey)
          defaults.set(bearerToken, forKey: self.tokenKey)
          defaults.set(typeNames, forKey: self.typesKey)
          defaults.set(interval, forKey: self.intervalKey)
          defaults.set(appleWatchOnly, forKey: self.watchOnlyKey)
          defaults.set(true, forKey: self.enabledKey)

          self.startObservers()
          result(nil)

        case "disable":
          UserDefaults.standard.set(false, forKey: self.enabledKey)
          self.stopObservers()
          result(nil)

        default:
          result(FlutterMethodNotImplemented)
        }
      }

      let ringService = ColmiRingService(healthStore: healthStore) { [weak self] in
        self?.handleHealthKitChange(completion: {})
      }
      colmiRingService = ringService

      let colmiChannel = FlutterMethodChannel(
        name: colmiChannelName,
        binaryMessenger: controller.binaryMessenger
      )

      colmiChannel.setMethodCallHandler { call, result in
        switch call.method {
        case "getState":
          result(ringService.snapshot())

        case "startScan":
          ringService.startScan()
          result(nil)

        case "connect":
          guard
            let args = call.arguments as? [String: Any],
            let id = args["id"] as? String
          else {
            result(FlutterError(code: "BAD_ARGS", message: "Select a ring first.", details: nil))
            return
          }

          do {
            try ringService.connect(id: id)
            result(nil)
          } catch {
            result(
              FlutterError(
                code: "CONNECT_FAILED",
                message: error.localizedDescription,
                details: nil
              )
            )
          }

        case "disconnect":
          ringService.disconnect()
          result(nil)

        case "syncSleep":
          ringService.syncSleep()
          result(nil)

        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

    // Apple recommends registering observer queries as early as possible at launch.
    startObserversIfConfigured()

    return result
  }

  private func startObserversIfConfigured() {
    guard UserDefaults.standard.bool(forKey: enabledKey) else { return }
    startObservers()
  }

  private func stopObservers() {
    for query in observerQueries {
      healthStore.stop(query)
    }
    observerQueries.removeAll()
  }

  private func startObservers() {
    stopObservers()

    guard HKHealthStore.isHealthDataAvailable() else { return }

    let typeNames = UserDefaults.standard.stringArray(forKey: typesKey) ?? []
    var observedIdentifiers = Set<String>()

    for name in typeNames {
      guard let type = sampleType(for: name) else { continue }
      guard observedIdentifiers.insert(type.identifier).inserted else { continue }

      let query = HKObserverQuery(
        sampleType: type,
        predicate: nil
      ) { [weak self] _, completionHandler, error in
        guard let self else {
          completionHandler()
          return
        }

        if error != nil {
          completionHandler()
          return
        }

        self.handleHealthKitChange(completion: completionHandler)
      }

      observerQueries.append(query)
      healthStore.execute(query)

      healthStore.enableBackgroundDelivery(
        for: type,
        frequency: .immediate
      ) { success, error in
        if !success {
          print("HealthKit background delivery failed for \(name): \(String(describing: error))")
        }
      }
    }
  }

  private func handleHealthKitChange(completion: @escaping () -> Void) {
    let defaults = UserDefaults.standard
    guard defaults.bool(forKey: enabledKey) else {
      completion()
      return
    }

    let minimumMinutes = max(defaults.integer(forKey: intervalKey), 1)
    let lastSent = defaults.object(forKey: lastSentKey) as? Date

    if let lastSent,
       Date().timeIntervalSince(lastSent) < Double(minimumMinutes * 60) {
      completion()
      return
    }

    buildTodayPayload { [weak self] payload in
      guard let self, let payload else {
        completion()
        return
      }

      self.postPayload(payload) { success in
        if success {
          UserDefaults.standard.set(Date(), forKey: self.lastSentKey)
        }
        completion()
      }
    }
  }

  private func buildTodayPayload(
    completion: @escaping ([String: Any]?) -> Void
  ) {
    let defaults = UserDefaults.standard
    let typeNames = defaults.stringArray(forKey: typesKey) ?? []
    let sleepTypeNames = Set(typeNames.filter(isSleepTypeName))
    let appleWatchOnly = defaults.bool(forKey: watchOnlyKey)

    let now = Date()
    let start = Calendar.current.startOfDay(for: now)
    let sleepWindowStart = Calendar.current.date(
      byAdding: .hour,
      value: -6,
      to: start
    ) ?? start

    let group = DispatchGroup()
    let lock = NSLock()
    var allSamples: [[String: Any]] = []

    for name in typeNames where !isSleepTypeName(name) {
      guard let type = quantityType(for: name) else { continue }

      let predicate = HKQuery.predicateForSamples(
        withStart: start,
        end: now,
        options: [.strictStartDate]
      )

      group.enter()
      let query = HKSampleQuery(
        sampleType: type,
        predicate: predicate,
        limit: HKObjectQueryNoLimit,
        sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
      ) { [weak self] _, samples, _ in
        defer { group.leave() }
        guard let self, let quantitySamples = samples as? [HKQuantitySample] else { return }

        let serialized = quantitySamples.compactMap { sample -> [String: Any]? in
          if appleWatchOnly && !self.looksLikeAppleWatch(sample) {
            return nil
          }

          let unit = self.unit(for: name)
          let value = sample.quantity.doubleValue(for: unit)

          return [
            "uuid": sample.uuid.uuidString,
            "type": name,
            "value": value,
            "unit": self.unitLabel(for: name),
            "dateFrom": ISO8601DateFormatter().string(from: sample.startDate),
            "dateTo": ISO8601DateFormatter().string(from: sample.endDate),
            "sourceName": sample.sourceRevision.source.name,
            "sourceBundle": sample.sourceRevision.source.bundleIdentifier,
            "deviceModel": sample.device?.model ?? "",
          ]
        }

        lock.lock()
        allSamples.append(contentsOf: serialized)
        lock.unlock()
      }

      healthStore.execute(query)
    }

    // Sleep is a category sample, not a quantity sample. Query it once even
    // though the Flutter UI selects several stage names that all map to the
    // same HealthKit sleepAnalysis type.
    if !sleepTypeNames.isEmpty,
       let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
      let sleepPredicate = HKQuery.predicateForSamples(
        withStart: sleepWindowStart,
        end: now,
        options: [.strictStartDate]
      )

      group.enter()
      let query = HKSampleQuery(
        sampleType: sleepType,
        predicate: sleepPredicate,
        limit: HKObjectQueryNoLimit,
        sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
      ) { [weak self] _, samples, _ in
        defer { group.leave() }
        guard let self, let categorySamples = samples as? [HKCategorySample] else { return }

        let serialized = categorySamples.compactMap { sample -> [String: Any]? in
          guard let typeName = self.sleepTypeName(for: sample.value) else { return nil }
          guard sleepTypeNames.contains(typeName) else { return nil }

          if appleWatchOnly && !self.looksLikeAppleWatch(sample) {
            return nil
          }

          return [
            "uuid": sample.uuid.uuidString,
            "type": typeName,
            "stage": self.sleepStageLabel(for: sample.value),
            "value": sample.value,
            "durationMinutes": sample.endDate.timeIntervalSince(sample.startDate) / 60,
            "unit": "category",
            "dateFrom": ISO8601DateFormatter().string(from: sample.startDate),
            "dateTo": ISO8601DateFormatter().string(from: sample.endDate),
            "sourceName": sample.sourceRevision.source.name,
            "sourceBundle": sample.sourceRevision.source.bundleIdentifier,
            "deviceModel": sample.device?.model ?? "",
          ]
        }

        lock.lock()
        allSamples.append(contentsOf: serialized)
        lock.unlock()
      }

      healthStore.execute(query)
    }

    group.notify(queue: .global(qos: .utility)) {
      let formatter = DateFormatter()
      formatter.calendar = Calendar.current
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.dateFormat = "yyyy-MM-dd"

      var payload: [String: Any] = [
        "date": formatter.string(from: now),
        "generatedAt": ISO8601DateFormatter().string(from: now),
        "startTime": ISO8601DateFormatter().string(from: start),
        "endTime": ISO8601DateFormatter().string(from: now),
        "appleWatchOnly": appleWatchOnly,
        "selectedTypes": typeNames,
        "samples": allSamples,
        "source": "healthkit-background",
      ]

      if !sleepTypeNames.isEmpty {
        payload["sleepWindowStart"] = ISO8601DateFormatter().string(from: sleepWindowStart)
        payload["summary"] = ["SLEEP": self.makeSleepSummary(from: allSamples)]
      }

      completion(payload)
    }
  }

  private func postPayload(
    _ payload: [String: Any],
    completion: @escaping (Bool) -> Void
  ) {
    let defaults = UserDefaults.standard

    guard
      let urlString = defaults.string(forKey: webhookKey),
      let url = URL(string: urlString),
      url.scheme?.lowercased() == "https"
    else {
      completion(false)
      return
    }

    guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
      completion(false)
      return
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    if let token = defaults.string(forKey: tokenKey), !token.isEmpty {
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    request.httpBody = body

    URLSession.shared.dataTask(with: request) { _, response, error in
      guard
        error == nil,
        let http = response as? HTTPURLResponse,
        (200..<300).contains(http.statusCode)
      else {
        completion(false)
        return
      }

      completion(true)
    }.resume()
  }

  private func sampleType(for name: String) -> HKSampleType? {
    if isSleepTypeName(name) {
      return HKObjectType.categoryType(forIdentifier: .sleepAnalysis)
    }

    return quantityType(for: name)
  }

  private func isSleepTypeName(_ name: String) -> Bool {
    switch name {
    case "SLEEP_ASLEEP", "SLEEP_AWAKE", "SLEEP_DEEP", "SLEEP_IN_BED", "SLEEP_LIGHT", "SLEEP_REM":
      return true
    default:
      return false
    }
  }

  private func sleepTypeName(for value: Int) -> String? {
    switch value {
    case 0:
      return "SLEEP_IN_BED"
    case 1:
      return "SLEEP_ASLEEP"
    case 2:
      return "SLEEP_AWAKE"
    case 3:
      return "SLEEP_LIGHT"
    case 4:
      return "SLEEP_DEEP"
    case 5:
      return "SLEEP_REM"
    default:
      return nil
    }
  }

  private func sleepStageLabel(for value: Int) -> String {
    switch value {
    case 0:
      return "inBed"
    case 1:
      return "asleepUnspecified"
    case 2:
      return "awake"
    case 3:
      return "core"
    case 4:
      return "deep"
    case 5:
      return "rem"
    default:
      return "unknown"
    }
  }

  private func makeSleepSummary(from samples: [[String: Any]]) -> [String: Any] {
    var minutesByType: [String: Double] = [:]
    var sleepSampleCount = 0

    for sample in samples {
      guard
        let type = sample["type"] as? String,
        isSleepTypeName(type),
        let minutes = sample["durationMinutes"] as? Double
      else { continue }

      minutesByType[type, default: 0] += minutes
      sleepSampleCount += 1
    }

    let totalAsleep =
      minutesByType["SLEEP_ASLEEP", default: 0]
      + minutesByType["SLEEP_LIGHT", default: 0]
      + minutesByType["SLEEP_DEEP", default: 0]
      + minutesByType["SLEEP_REM", default: 0]

    return [
      "totalAsleepMinutes": totalAsleep,
      "coreMinutes": minutesByType["SLEEP_LIGHT", default: 0],
      "deepMinutes": minutesByType["SLEEP_DEEP", default: 0],
      "remMinutes": minutesByType["SLEEP_REM", default: 0],
      "awakeMinutes": minutesByType["SLEEP_AWAKE", default: 0],
      "inBedMinutes": minutesByType["SLEEP_IN_BED", default: 0],
      "samples": sleepSampleCount,
    ]
  }

  private func quantityType(for name: String) -> HKQuantityType? {
    switch name {
    case "STEPS":
      return HKQuantityType.quantityType(forIdentifier: .stepCount)
    case "ACTIVE_ENERGY_BURNED":
      return HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)
    case "HEART_RATE":
      return HKQuantityType.quantityType(forIdentifier: .heartRate)
    case "RESTING_HEART_RATE":
      return HKQuantityType.quantityType(forIdentifier: .restingHeartRate)
    case "HEART_RATE_VARIABILITY_SDNN":
      return HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN)
    default:
      return nil
    }
  }

  private func unit(for name: String) -> HKUnit {
    switch name {
    case "STEPS":
      return .count()
    case "ACTIVE_ENERGY_BURNED":
      return .kilocalorie()
    case "HEART_RATE", "RESTING_HEART_RATE":
      return HKUnit.count().unitDivided(by: .minute())
    case "HEART_RATE_VARIABILITY_SDNN":
      return HKUnit.secondUnit(with: .milli)
    default:
      return .count()
    }
  }

  private func unitLabel(for name: String) -> String {
    switch name {
    case "STEPS":
      return "count"
    case "ACTIVE_ENERGY_BURNED":
      return "kcal"
    case "HEART_RATE", "RESTING_HEART_RATE":
      return "bpm"
    case "HEART_RATE_VARIABILITY_SDNN":
      return "ms"
    default:
      return ""
    }
  }

  private func looksLikeAppleWatch(_ sample: HKSample) -> Bool {
    let source = sample.sourceRevision.source.name.lowercased()
    let bundle = sample.sourceRevision.source.bundleIdentifier.lowercased()
    let model = (sample.device?.model ?? "").lowercased()
    let ownBundle = Bundle.main.bundleIdentifier?.lowercased()
    return source.contains("watch")
      || model.contains("watch")
      || (ownBundle != nil && bundle == ownBundle)
  }
}
