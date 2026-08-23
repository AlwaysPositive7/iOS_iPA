import 'package:flutter/services.dart';

class ColmiRingDevice {
  final String id;
  final String name;
  final int rssi;

  const ColmiRingDevice({
    required this.id,
    required this.name,
    required this.rssi,
  });

  factory ColmiRingDevice.fromMap(Map<Object?, Object?> map) {
    return ColmiRingDevice(
      id: map['id'] as String,
      name: (map['name'] as String?) ?? 'COLMI ring',
      rssi: (map['rssi'] as num?)?.toInt() ?? 0,
    );
  }
}

class ColmiRingState {
  final List<ColmiRingDevice> devices;
  final String? connectedId;
  final String? connectedName;
  final String status;
  final bool isScanning;
  final bool isConnected;
  final bool isSyncing;

  const ColmiRingState({
    required this.devices,
    required this.connectedId,
    required this.connectedName,
    required this.status,
    required this.isScanning,
    required this.isConnected,
    required this.isSyncing,
  });

  factory ColmiRingState.fromMap(Map<Object?, Object?> map) {
    final rawDevices = (map['devices'] as List<Object?>?) ?? const [];
    return ColmiRingState(
      devices: rawDevices
          .whereType<Map<Object?, Object?>>()
          .map(ColmiRingDevice.fromMap)
          .toList(),
      connectedId: map['connectedId'] as String?,
      connectedName: map['connectedName'] as String?,
      status: (map['status'] as String?) ?? 'Ring service ready',
      isScanning: (map['isScanning'] as bool?) ?? false,
      isConnected: (map['isConnected'] as bool?) ?? false,
      isSyncing: (map['isSyncing'] as bool?) ?? false,
    );
  }
}

class ColmiRingService {
  static const _channel = MethodChannel('daymark_health/colmi');

  Future<ColmiRingState> getState() async {
    final map = await _channel.invokeMapMethod<Object?, Object?>('getState');
    return ColmiRingState.fromMap(map ?? const {});
  }

  Future<void> startScan() => _channel.invokeMethod<void>('startScan');

  Future<void> connect(String id) =>
      _channel.invokeMethod<void>('connect', {'id': id});

  Future<void> disconnect() => _channel.invokeMethod<void>('disconnect');

  Future<void> syncSleep() => _channel.invokeMethod<void>('syncSleep');
}
