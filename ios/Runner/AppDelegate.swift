import Flutter
import HealthKit
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let healthStore = HKHealthStore()
  private let channelName = "daymark_health/background"
  private var observerQueries: [HKObserverQuery] = []

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

    for name in typeNames {
      guard let type = quantityType(for: name) else { continue }

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
    let appleWatchOnly = defaults.bool(forKey: watchOnlyKey)

    let now = Date()
    let start = Calendar.current.startOfDay(for: now)
    let predicate = HKQuery.predicateForSamples(
      withStart: start,
      end: now,
      options: [.strictStartDate]
    )

    let group = DispatchGroup()
    let lock = NSLock()
    var allSamples: [[String: Any]] = []

    for name in typeNames {
      guard let type = quantityType(for: name) else { continue }

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

    group.notify(queue: .global(qos: .utility)) {
      let formatter = DateFormatter()
      formatter.calendar = Calendar.current
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.dateFormat = "yyyy-MM-dd"

      completion([
        "date": formatter.string(from: now),
        "generatedAt": ISO8601DateFormatter().string(from: now),
        "startTime": ISO8601DateFormatter().string(from: start),
        "endTime": ISO8601DateFormatter().string(from: now),
        "appleWatchOnly": appleWatchOnly,
        "selectedTypes": typeNames,
        "samples": allSamples,
        "source": "healthkit-background",
      ])
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

  private func looksLikeAppleWatch(_ sample: HKQuantitySample) -> Bool {
    let source = sample.sourceRevision.source.name.lowercased()
    let model = (sample.device?.model ?? "").lowercased()
    return source.contains("watch") || model.contains("watch")
  }
}
