import 'package:flutter/services.dart';
import 'package:health/health.dart';

class NativeBackgroundService {
  static const _channel = MethodChannel('daymark_health/background');

  Future<void> configure({
    required String webhookUrl,
    required String bearerToken,
    required List<HealthDataType> types,
    required int minimumIntervalMinutes,
    required bool appleWatchOnly,
  }) async {
    await _channel.invokeMethod<void>('configure', {
      'webhookUrl': webhookUrl.trim(),
      'bearerToken': bearerToken.trim(),
      'types': types.map((e) => e.name).toList(),
      'minimumIntervalMinutes': minimumIntervalMinutes,
      'appleWatchOnly': appleWatchOnly,
    });
  }

  Future<void> disable() async {
    await _channel.invokeMethod<void>('disable');
  }
}
