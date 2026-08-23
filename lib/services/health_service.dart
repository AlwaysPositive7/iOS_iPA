import 'package:health/health.dart';

class HealthMetric {
  final String label;
  final List<HealthDataType> types;

  const HealthMetric(this.label, this.types);
}

const sleepMetricTypes = <HealthDataType>[
  HealthDataType.SLEEP_ASLEEP,
  HealthDataType.SLEEP_AWAKE,
  HealthDataType.SLEEP_DEEP,
  HealthDataType.SLEEP_IN_BED,
  HealthDataType.SLEEP_LIGHT,
  HealthDataType.SLEEP_REM,
];

const supportedMetrics = <HealthMetric>[
  HealthMetric('Steps', [HealthDataType.STEPS]),
  HealthMetric('Active calories', [HealthDataType.ACTIVE_ENERGY_BURNED]),
  HealthMetric('Heart rate', [HealthDataType.HEART_RATE]),
  HealthMetric('Resting heart rate', [HealthDataType.RESTING_HEART_RATE]),
  HealthMetric('HRV (SDNN)', [HealthDataType.HEART_RATE_VARIABILITY_SDNN]),
  HealthMetric('Sleep (total + stages)', sleepMetricTypes),
];

class HealthService {
  final Health _health = Health();

  Future<void> configure() => _health.configure();

  Future<bool> requestReadPermission(List<HealthDataType> types) async {
    if (types.isEmpty) return false;
    return _health.requestAuthorization(
      types,
      permissions: List.filled(types.length, HealthDataAccess.READ),
    );
  }

  Future<Map<String, dynamic>> buildTodayPayload({
    required List<HealthDataType> types,
    required bool appleWatchOnly,
  }) async {
    if (types.isEmpty) {
      throw StateError('Select at least one health metric.');
    }

    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    final sleepWindowStart = start.subtract(const Duration(hours: 6));

    final sleepTypes = types.where(_isSleepType).toList();
    final regularTypes = types.where((type) => !_isSleepType(type)).toList();

    var points = <HealthDataPoint>[];

    if (regularTypes.isNotEmpty) {
      points.addAll(
        await _health.getHealthDataFromTypes(
          types: regularTypes,
          startTime: start,
          endTime: now,
        ),
      );
    }

    // A sleep session normally starts before midnight and ends today. Query
    // from 6 PM yesterday so the payload contains the whole overnight session.
    if (sleepTypes.isNotEmpty) {
      points.addAll(
        await _health.getHealthDataFromTypes(
          types: sleepTypes,
          startTime: sleepWindowStart,
          endTime: now,
        ),
      );
    }

    points = _health.removeDuplicates(points);

    if (appleWatchOnly) {
      points = points.where(_looksLikeAppleWatch).toList();
    }

    final raw = points.map((p) => p.toJson()).toList();

    return {
      'date': _localDate(now),
      'generatedAt': now.toIso8601String(),
      'startTime': start.toIso8601String(),
      'endTime': now.toIso8601String(),
      if (sleepTypes.isNotEmpty)
        'sleepWindowStart': sleepWindowStart.toIso8601String(),
      'appleWatchOnly': appleWatchOnly,
      'selectedTypes': types.map((t) => t.name).toList(),
      'summary': _makeSummary(points),
      'samples': raw,
    };
  }

  bool _looksLikeAppleWatch(HealthDataPoint p) {
    final source = p.sourceName.toLowerCase();
    final model = (p.deviceModel ?? '').toLowerCase();
    return source.contains('watch') || model.contains('watch');
  }

  Map<String, dynamic> _makeSummary(List<HealthDataPoint> points) {
    final byType = <String, List<Map<String, dynamic>>>{};

    for (final p in points) {
      final json = p.toJson();
      final type = p.type.name;
      byType.putIfAbsent(type, () => []).add(json);
    }

    final summary = <String, dynamic>{};

    double? numericValue(Map<String, dynamic> point) {
      final value = point['value'];
      if (value is Map) {
        final n = value['numeric_value'];
        if (n is num) return n.toDouble();
      }
      return null;
    }

    for (final entry in byType.entries) {
      if (_isSleepTypeName(entry.key)) {
        final minutes = _unionMinutes(
          points.where((point) => point.type.name == entry.key).toList(),
        );
        summary[entry.key] = {
          'totalMinutes': minutes,
          'samples': entry.value.length,
        };
        continue;
      }

      final values = entry.value
          .map(numericValue)
          .whereType<double>()
          .toList();

      if (values.isEmpty) {
        summary[entry.key] = {'samples': entry.value.length};
        continue;
      }

      values.sort();
      final sum = values.fold<double>(0, (a, b) => a + b);
      final last = numericValue(entry.value.last);

      switch (entry.key) {
        case 'STEPS':
        case 'ACTIVE_ENERGY_BURNED':
          summary[entry.key] = {
            'total': sum,
            'samples': values.length,
          };
          break;

        case 'HEART_RATE':
          summary[entry.key] = {
            'latest': last,
            'average': sum / values.length,
            'min': values.first,
            'max': values.last,
            'samples': values.length,
          };
          break;

        case 'RESTING_HEART_RATE':
        case 'HEART_RATE_VARIABILITY_SDNN':
          summary[entry.key] = {
            'latest': last,
            'average': sum / values.length,
            'samples': values.length,
          };
          break;

        default:
          summary[entry.key] = {
            'latest': last,
            'average': sum / values.length,
            'samples': values.length,
          };
      }
    }

    final sleepPoints = points.where((point) => _isSleepType(point.type)).toList();
    if (sleepPoints.isNotEmpty) {
      final asleepPoints = sleepPoints
          .where(
            (point) => const {
              HealthDataType.SLEEP_ASLEEP,
              HealthDataType.SLEEP_LIGHT,
              HealthDataType.SLEEP_DEEP,
              HealthDataType.SLEEP_REM,
            }.contains(point.type),
          )
          .toList();

      summary['SLEEP'] = {
        'totalAsleepMinutes': _unionMinutes(asleepPoints),
        'coreMinutes': _unionMinutes(
          sleepPoints.where((p) => p.type == HealthDataType.SLEEP_LIGHT).toList(),
        ),
        'deepMinutes': _unionMinutes(
          sleepPoints.where((p) => p.type == HealthDataType.SLEEP_DEEP).toList(),
        ),
        'remMinutes': _unionMinutes(
          sleepPoints.where((p) => p.type == HealthDataType.SLEEP_REM).toList(),
        ),
        'awakeMinutes': _unionMinutes(
          sleepPoints.where((p) => p.type == HealthDataType.SLEEP_AWAKE).toList(),
        ),
        'inBedMinutes': _unionMinutes(
          sleepPoints.where((p) => p.type == HealthDataType.SLEEP_IN_BED).toList(),
        ),
        'samples': sleepPoints.length,
      };
    }

    return summary;
  }

  bool _isSleepType(HealthDataType type) => sleepMetricTypes.contains(type);

  bool _isSleepTypeName(String name) =>
      sleepMetricTypes.any((type) => type.name == name);

  double _unionMinutes(List<HealthDataPoint> points) {
    if (points.isEmpty) return 0;

    final intervals = points
        .map((point) => (start: point.dateFrom, end: point.dateTo))
        .where((interval) => interval.end.isAfter(interval.start))
        .toList()
      ..sort((a, b) => a.start.compareTo(b.start));

    if (intervals.isEmpty) return 0;

    var currentStart = intervals.first.start;
    var currentEnd = intervals.first.end;
    var total = Duration.zero;

    for (final interval in intervals.skip(1)) {
      if (!interval.start.isAfter(currentEnd)) {
        if (interval.end.isAfter(currentEnd)) currentEnd = interval.end;
      } else {
        total += currentEnd.difference(currentStart);
        currentStart = interval.start;
        currentEnd = interval.end;
      }
    }

    total += currentEnd.difference(currentStart);
    return total.inSeconds / 60;
  }

  String _localDate(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)}';
  }
}
