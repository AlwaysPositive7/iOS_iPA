import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:health/health.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'services/colmi_ring_service.dart';
import 'services/health_service.dart';
import 'services/native_background_service.dart';
import 'services/webhook_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DaymarkHealthApp());
}

class DaymarkHealthApp extends StatelessWidget {
  const DaymarkHealthApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Daymark Health',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
      ),
      home: const HealthSettingsPage(),
    );
  }
}

class HealthSettingsPage extends StatefulWidget {
  const HealthSettingsPage({super.key});

  @override
  State<HealthSettingsPage> createState() => _HealthSettingsPageState();
}

class _HealthSettingsPageState extends State<HealthSettingsPage> {
  static const _defaultWebhookUrl =
      'https://daymark-eight-sepia.vercel.app/api/health';

  final _health = HealthService();
  final _webhook = WebhookService();
  final _background = NativeBackgroundService();
  final _ring = ColmiRingService();

  final _urlController = TextEditingController();
  final _tokenController = TextEditingController();

  final Set<HealthDataType> _selected = {
    HealthDataType.STEPS,
    HealthDataType.ACTIVE_ENERGY_BURNED,
    HealthDataType.HEART_RATE,
    HealthDataType.RESTING_HEART_RATE,
    HealthDataType.HEART_RATE_VARIABILITY_SDNN,
    ...sleepMetricTypes,
  };

  bool _appleWatchOnly = true;
  int _intervalMinutes = 15;
  bool _busy = false;
  bool _ringBusy = false;
  String _status = 'Ready to connect Apple Health';
  ColmiRingState? _ringState;
  String? _selectedRingId;
  Timer? _ringPollTimer;

  @override
  void initState() {
    super.initState();
    _init();
    if (Platform.isIOS) {
      _refreshRingState();
      _ringPollTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _refreshRingState(),
      );
    }
  }

  Future<void> _refreshRingState() async {
    try {
      final state = await _ring.getState();
      if (!mounted) return;
      setState(() {
        _ringState = state;
        if (_selectedRingId == null ||
            !state.devices.any((device) => device.id == _selectedRingId)) {
          _selectedRingId = state.connectedId ??
              (state.devices.isEmpty ? null : state.devices.first.id);
        }
      });
    } catch (_) {
      // Native channel is iOS-only. The rest of the app can still render.
    }
  }

  Future<void> _runRing(Future<void> Function() action) async {
    if (_ringBusy) return;
    setState(() => _ringBusy = true);
    try {
      await action();
      await _refreshRingState();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _ringState = ColmiRingState(
          devices: _ringState?.devices ?? const [],
          connectedId: _ringState?.connectedId,
          connectedName: _ringState?.connectedName,
          status: 'Ring error: $e',
          isScanning: false,
          isConnected: _ringState?.isConnected ?? false,
          isSyncing: false,
        );
      });
    } finally {
      if (mounted) setState(() => _ringBusy = false);
    }
  }

  Future<void> _init() async {
    await _health.configure();

    final prefs = SharedPreferencesAsync();
    final url = await prefs.getString('webhookUrl');
    final token = await prefs.getString('bearerToken');
    final interval = await prefs.getInt('intervalMinutes');
    final watchOnly = await prefs.getBool('appleWatchOnly');
    final selectedNames = await prefs.getStringList('selectedTypes');
    final sleepMetricIntroduced =
        await prefs.getBool('sleepMetricIntroduced') ?? false;

    if (!mounted) return;
    setState(() {
      _urlController.text = url ?? _defaultWebhookUrl;
      _tokenController.text = token ?? '';
      _intervalMinutes = interval ?? 15;
      _appleWatchOnly = watchOnly ?? true;

      if (selectedNames != null && selectedNames.isNotEmpty) {
        _selected
          ..clear()
          ..addAll(
            supportedMetrics
                .expand((metric) => metric.types)
                .where((type) => selectedNames.contains(type.name)),
          );
      }

      // Add sleep on the first launch of the sleep-enabled build, including
      // when upgrading over the original IPA with saved settings.
      if (!sleepMetricIntroduced) {
        _selected.addAll(sleepMetricTypes);
      }
    });

    if (!sleepMetricIntroduced) {
      await prefs.setBool('sleepMetricIntroduced', true);
      await prefs.setStringList(
        'selectedTypes',
        _selected.map((type) => type.name).toList(),
      );
    }
  }

  Future<void> _saveSettings() async {
    final prefs = SharedPreferencesAsync();
    await prefs.setString('webhookUrl', _urlController.text.trim());
    await prefs.setString('bearerToken', _tokenController.text.trim());
    await prefs.setInt('intervalMinutes', _intervalMinutes);
    await prefs.setBool('appleWatchOnly', _appleWatchOnly);
    await prefs.setStringList(
      'selectedTypes',
      _selected.map((e) => e.name).toList(),
    );
  }

  Future<void> _authorize() async {
    await _run(() async {
      if (!Platform.isIOS) {
        throw UnsupportedError('This starter is configured for iPhone/HealthKit.');
      }

      final ok = await _health.requestReadPermission(_selected.toList());
      await _saveSettings();

      setState(() {
        _status = ok
            ? 'HealthKit permission request completed'
            : 'HealthKit permission was not granted';
      });
    });
  }

  Future<void> _syncNow() async {
    await _run(() async {
      _validateSettings();
      await _saveSettings();

      final payload = await _health.buildTodayPayload(
        types: _selected.toList(),
        appleWatchOnly: _appleWatchOnly,
      );

      await _webhook.send(
        webhookUrl: _urlController.text,
        bearerToken: _tokenController.text,
        payload: payload,
      );

      setState(() {
        _status = 'Sent today\'s HealthKit data at ${TimeOfDay.now().format(context)}';
      });
    });
  }

  Future<void> _enableBackground() async {
    await _run(() async {
      _validateSettings();
      await _saveSettings();

      await _background.configure(
        webhookUrl: _urlController.text,
        bearerToken: _tokenController.text,
        types: _selected.toList(),
        minimumIntervalMinutes: _intervalMinutes,
        appleWatchOnly: _appleWatchOnly,
      );

      setState(() {
        _status =
            'Background HealthKit delivery enabled; webhook throttled to $_intervalMinutes min';
      });
    });
  }

  Future<void> _disableBackground() async {
    await _run(() async {
      await _background.disable();
      setState(() {
        _status = 'Background delivery disabled';
      });
    });
  }

  void _validateSettings() {
    if (_selected.isEmpty) {
      throw StateError('Select at least one metric.');
    }
    final uri = Uri.tryParse(_urlController.text.trim());
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw StateError('Enter a valid HTTPS webhook URL.');
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);

    try {
      await action();
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'Error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _ringPollTimer?.cancel();
    _urlController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Daymark Health')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'Health data to sync',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          ...supportedMetrics.map(
            (metric) => CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(metric.label),
              subtitle: metric.label.startsWith('Sleep')
                  ? const Text(
                      'Includes total asleep, core, deep, REM, awake, and time in bed.',
                    )
                  : null,
              value: metric.types.every(_selected.contains),
              onChanged: _busy
                  ? null
                  : (value) {
                      setState(() {
                        if (value == true) {
                          _selected.addAll(metric.types);
                        } else {
                          _selected.removeAll(metric.types);
                        }
                      });
                    },
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Apple Watch samples only'),
            subtitle: const Text(
              'Keeps Apple Watch samples plus COLMI sleep imported by Daymark.',
            ),
            value: _appleWatchOnly,
            onChanged: _busy ? null : (v) => setState(() => _appleWatchOnly = v),
          ),
          const SizedBox(height: 12),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'COLMI R04 sleep import',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'For R04 rings that use the QRing Bluetooth protocol. Sleep stages are saved into Apple Health, then included in Daymark syncs.',
                  ),
                  const SizedBox(height: 14),
                  if ((_ringState?.devices ?? const []).isNotEmpty)
                    DropdownButtonFormField<String>(
                      initialValue: _selectedRingId,
                      decoration: const InputDecoration(
                        labelText: 'Discovered ring',
                        border: OutlineInputBorder(),
                      ),
                      items: _ringState!.devices
                          .map(
                            (device) => DropdownMenuItem(
                              value: device.id,
                              child: Text(
                                '${device.name}${device.isLikelyRing ? ' • likely ring' : ''} (${device.rssi} dBm)',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: _ringBusy
                          ? null
                          : (id) => setState(() => _selectedRingId = id),
                    ),
                  if ((_ringState?.devices ?? const []).isNotEmpty)
                    const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _ringBusy || (_ringState?.isScanning ?? false)
                            ? null
                            : () => _runRing(_ring.startScan),
                        icon: const Icon(Icons.bluetooth_searching),
                        label: Text(
                          (_ringState?.isScanning ?? false) ? 'Scanning…' : 'Scan',
                        ),
                      ),
                      OutlinedButton(
                        onPressed: _ringBusy || _selectedRingId == null
                            ? null
                            : () => _runRing(
                                  () => _ring.connect(_selectedRingId!),
                                ),
                        child: const Text('Connect'),
                      ),
                      FilledButton(
                        onPressed: _ringBusy ||
                                !(_ringState?.isConnected ?? false) ||
                                (_ringState?.isSyncing ?? false)
                            ? null
                            : () => _runRing(_ring.syncSleep),
                        child: Text(
                          (_ringState?.isSyncing ?? false)
                              ? 'Syncing…'
                              : 'Sync Sleep to Apple Health',
                        ),
                      ),
                      TextButton(
                        onPressed: _ringBusy ||
                                !(_ringState?.isConnected ?? false)
                            ? null
                            : () => _runRing(_ring.disconnect),
                        child: const Text('Disconnect'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _ringState?.status ?? 'Bluetooth ring service is starting…',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'The R04 may appear under a generic name such as SMART_RING. Connecting is safe: Daymark verifies the QRing sleep service before sending a command.',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 36),
          TextField(
            controller: _urlController,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Webhook URL',
              hintText: 'https://your-domain.com/api/health/ingest',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _tokenController,
            obscureText: true,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: 'Bearer token (optional)',
              helperText: 'Leave blank for your current Daymark endpoint.',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          DropdownButtonFormField<int>(
            initialValue: _intervalMinutes,
            decoration: const InputDecoration(
              labelText: 'Minimum webhook interval',
              border: OutlineInputBorder(),
            ),
            items: const [5, 15, 30, 60]
                .map(
                  (m) => DropdownMenuItem(
                    value: m,
                    child: Text('$m minutes'),
                  ),
                )
                .toList(),
            onChanged: _busy
                ? null
                : (v) => setState(() => _intervalMinutes = v ?? 15),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy ? null : _authorize,
            child: const Text('1. Request HealthKit Permission'),
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: _busy ? null : _syncNow,
            child: const Text('2. Send Today Now'),
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: _busy ? null : _enableBackground,
            child: const Text('3. Enable Background Sync'),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: _busy ? null : _disableBackground,
            child: const Text('Disable Background Sync'),
          ),
          const SizedBox(height: 24),
          Text(
            _busy ? 'Working…' : _status,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}
