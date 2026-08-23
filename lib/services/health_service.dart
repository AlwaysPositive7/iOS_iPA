import 'package:health/health.dart';

class HealthMetric {
  final String label;
  final HealthDataType type;

  const HealthMetric(this.label, this.type);
}

const supportedMetrics = <HealthMetric>[
  HealthMetric('Steps', HealthDataType.STEPS),
  HealthMetric('Active calories', HealthDataType.ACTIVE_ENERGY_BURNED),
  HealthMetric('Heart rate', HealthDataType.HEART_RATE),
  HealthMetric('Resting heart rate', HealthDataType.RESTING_HEART_RATE),
  HealthMetric('HRV (SDNN)', HealthDataType.HEART_RATE_VARIABILITY_SDNN),
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

    var points = await _health.getHealthDataFromTypes(
      types: types,
      startTime: start,
      endTime: now,
    );

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

    return summary;
  }

  String _localDate(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)}';
  }
}
