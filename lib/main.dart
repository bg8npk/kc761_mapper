import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:file_saver/file_saver.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'models/track_models.dart';
import 'storage/local_db.dart';

void main() {
  runApp(const Kc761App());
}

class Kc761App extends StatelessWidget {
  const Kc761App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KC761 Mapper',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1E88E5)),
        useMaterial3: true,
      ),
      home: const BleMapPage(),
    );
  }
}

class BleMapPage extends StatefulWidget {
  const BleMapPage({super.key});

  @override
  State<BleMapPage> createState() => _BleMapPageState();
}

class _BleMapPageState extends State<BleMapPage> {
  static final Guid _rxUuid = Guid('6e400002-b5a3-f393-e0a9-e50e24dcca9e');
  static final Guid _txUuid = Guid('6e400003-b5a3-f393-e0a9-e50e24dcca9e');

  final LocalDb _db = LocalDb.instance;
  final MapController _mapController = MapController();
  StreamSubscription<Position>? _posSub;
  Timer? _recordTimer;
  Timer? _locationFallbackTimer;
  DateTime? _lastPositionAt;
  LatLng? _currentLatLng;
  bool _locationReady = false;
  int _tileIndex = 0;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _rxChar;
  BluetoothCharacteristic? _txChar;
  StreamSubscription<List<int>>? _notifySub;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  bool _isConnecting = false;
  String _statusText = 'Disconnected';

  double? _rawCps;
  double? _rawDoseEqRateUvh;
  int? _batteryPercent;
  double? _airPressureHpa;
  double? _deviceTempC;

  bool _isRecording = false;
  MapMetric _mapMetric = MapMetric.cps;
  SensorType _sensorType = SensorType.gamma;
  bool? _hasNeutron;
  bool? _hasPin;

  final List<TrackSession> _sessions = [];
  TrackSession? _currentSession;
  TrackSession? _selectedSession;
  Measurement? _selectedPoint;

  @override
  void initState() {
    super.initState();
    _startLocationUpdates();
    _loadSessions();
  }

  @override
  void dispose() {
    _notifySub?.cancel();
    _connSub?.cancel();
    _posSub?.cancel();
    _recordTimer?.cancel();
    _locationFallbackTimer?.cancel();
    _device?.disconnect();
    super.dispose();
  }

  Future<void> _loadSessions() async {
    final sessions = await _db.fetchSessions();
    if (!mounted) {
      return;
    }
    setState(() {
      _sessions
        ..clear()
        ..addAll(sessions);
    });
  }

  Future<void> _startLocationUpdates() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _showMessage('Location service is disabled.');
      return;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      _showMessage('Location permission is required.');
      return;
    }

    _posSub?.cancel();
    final settings = AndroidSettings(
      accuracy: LocationAccuracy.bestForNavigation,
      distanceFilter: 0,
      intervalDuration: Duration(milliseconds: 600),
      forceLocationManager: true,
    );
    _posSub = Geolocator.getPositionStream(
      locationSettings: settings,
    ).listen((position) {
      _lastPositionAt = DateTime.now();
      final next = LatLng(position.latitude, position.longitude);
      if (!mounted) {
        return;
      }
      setState(() {
        _currentLatLng = next;
        _locationReady = true;
      });
      _mapController.move(next, _mapController.camera.zoom);
    });

    await _fetchSingleFix();
    _locationFallbackTimer?.cancel();
    _locationFallbackTimer =
        Timer.periodic(const Duration(seconds: 5), (_) async {
      final last = _lastPositionAt;
      if (last != null &&
          DateTime.now().difference(last) < const Duration(seconds: 8)) {
        return;
      }
      await _fetchSingleFix();
    });
  }

  Future<void> _fetchSingleFix() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.bestForNavigation,
        timeLimit: const Duration(seconds: 5),
      );
      _applyPosition(position);
    } catch (_) {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) {
        _applyPosition(last);
      }
    }
  }

  void _applyPosition(Position position) {
    _lastPositionAt = DateTime.now();
    final next = LatLng(position.latitude, position.longitude);
    if (!mounted) {
      return;
    }
    setState(() {
      _currentLatLng = next;
      _locationReady = true;
    });
    _mapController.move(next, _mapController.camera.zoom);
  }

  Future<void> _onConnectPressed() async {
    if (_device != null && _statusText == 'Connected') {
      await _disconnect();
      return;
    }

    final ok = await _ensurePermissions();
    if (!ok) {
      _showMessage('Bluetooth permissions are required.');
      return;
    }

    setState(() {
      _isConnecting = true;
      _statusText = 'Scanning...';
    });

    final picked = await _pickDevice();
    if (picked == null) {
      setState(() {
        _isConnecting = false;
        _statusText = 'Disconnected';
      });
      return;
    }

    await _connectToDevice(picked);
  }

  Future<bool> _ensurePermissions() async {
    final permissions = <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
    ];
    final statuses = await permissions.request();
    return statuses.values.every((status) => status.isGranted);
  }

  Future<BluetoothDevice?> _pickDevice() async {
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 6));
    final device = await showModalBottomSheet<BluetoothDevice>(
      context: context,
      builder: (context) {
        return StreamBuilder<List<ScanResult>>(
          stream: FlutterBluePlus.scanResults,
          builder: (context, snapshot) {
            final results = _dedupeResults(snapshot.data ?? []);
            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'Select KC761 device',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (results.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 16),
                      child: Text('No KC761 devices found yet.'),
                    ),
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: results.length,
                      itemBuilder: (context, index) {
                        final result = results[index];
                        final name = result.device.platformName.isNotEmpty
                            ? result.device.platformName
                            : '(unknown)';
                        return ListTile(
                          title: Text(name),
                          subtitle: Text(result.device.remoteId.str),
                          onTap: () => Navigator.of(context).pop(result.device),
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
    await FlutterBluePlus.stopScan();
    return device;
  }

  List<ScanResult> _dedupeResults(List<ScanResult> results) {
    final map = <String, ScanResult>{};
    for (final result in results) {
      final id = result.device.remoteId.str;
      final name = result.device.platformName;
      if (name.toUpperCase().startsWith('KC761')) {
        map[id] = result;
      }
    }
    return map.values.toList()
      ..sort((a, b) => a.device.platformName.compareTo(b.device.platformName));
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    try {
      setState(() {
        _device = device;
        _statusText = 'Connecting...';
      });

      await device.connect(timeout: const Duration(seconds: 12));
      _connSub?.cancel();
      _connSub = device.connectionState.listen((state) {
        if (!mounted) {
          return;
        }
        setState(() {
          _statusText =
              state == BluetoothConnectionState.connected ? 'Connected' : 'Disconnected';
        });
      });

      await device.requestMtu(517);
      final services = await device.discoverServices();
      _rxChar = _findCharacteristic(services, _rxUuid);
      _txChar = _findCharacteristic(services, _txUuid);

      if (_txChar == null || _rxChar == null) {
        throw StateError('RX/TX characteristics not found.');
      }

      await _txChar!.setNotifyValue(true);
      _notifySub?.cancel();
      _notifySub = _txChar!.value.listen(_handleNotification);

      await _enableAutoUpload();
      await _requestDeviceInfo();
    } catch (error) {
      _showMessage('BLE error: $error');
      await _disconnect();
    } finally {
      if (mounted) {
        setState(() {
          _isConnecting = false;
        });
      }
    }
  }

  Future<void> _enableAutoUpload() async {
    if (_rxChar == null) {
      return;
    }
    const sync = 0x00;
    final payload = Uint8List.fromList([
      0x00,
      0x62,
      sync,
      0xFF,
      0xFF,
      0xFF,
      0x01,
      0x00,
    ]);
    await _rxChar!.write(payload, withoutResponse: false);
  }

  Future<void> _requestDeviceInfo() async {
    if (_rxChar == null) {
      return;
    }
    const sync = 0x00;
    final payload = Uint8List.fromList([
      0x00,
      0x54,
      sync,
      0x00,
    ]);
    await _rxChar!.write(payload, withoutResponse: false);
  }

  Future<void> _setSensorType(SensorType type) async {
    if (_rxChar == null) {
      return;
    }
    int sensorValue = 0x00;
    if (type == SensorType.neutron) {
      sensorValue = 0x01;
    } else if (type == SensorType.pin) {
      sensorValue = 0x02;
    }
    const sync = 0x00;
    final payload = Uint8List.fromList([
      0x00,
      0x62,
      sync,
      sensorValue,
      0xFF,
      0xFF,
      0xFF,
      0x00,
    ]);
    await _rxChar!.write(payload, withoutResponse: false);
    setState(() {
      _sensorType = type;
    });
  }

  Future<void> _disconnect() async {
    _notifySub?.cancel();
    _notifySub = null;
    if (_device != null) {
      await _device!.disconnect();
    }
    if (mounted) {
      setState(() {
        _device = null;
        _rxChar = null;
        _txChar = null;
        _statusText = 'Disconnected';
        _rawCps = null;
        _rawDoseEqRateUvh = null;
        _batteryPercent = null;
        _airPressureHpa = null;
        _deviceTempC = null;
        _hasNeutron = null;
        _hasPin = null;
        _isConnecting = false;
      });
    }
  }

  BluetoothCharacteristic? _findCharacteristic(
    List<BluetoothService> services,
    Guid uuid,
  ) {
    for (final service in services) {
      for (final characteristic in service.characteristics) {
        if (characteristic.uuid == uuid) {
          return characteristic;
        }
      }
    }
    return null;
  }

  void _handleNotification(List<int> data) {
    if (data.length < 2) {
      return;
    }
    final flag = data[1];
    if (flag == 0xA2 || flag == 0xA3) {
      _handleStatusData(data);
    } else if (flag == 0xA5) {
      _handleDeviceInfo(data);
    }
  }

  void _handleStatusData(List<int> data) {
    if (data.length < 81) {
      return;
    }
    final bytes = Uint8List.fromList(data);
    final view = ByteData.sublistView(bytes);

    final rawCps = view.getInt32(33, Endian.little).toDouble();
    final rawDoseEqRate = _fp16ToDouble(view.getUint16(39, Endian.little));
    final battery = view.getUint8(8);
    final airPressure = view.getUint16(9, Endian.little).toDouble();
    final tempRaw = view.getInt16(11, Endian.little);
    final tempC = tempRaw / 10.0;
    final sensorBits = view.getUint8(4) & 0x03;

    setState(() {
      _rawCps = _sanitize(rawCps);
      _rawDoseEqRateUvh =
          _sanitize(rawDoseEqRate) == null ? null : rawDoseEqRate * 1000.0;
      _batteryPercent = battery;
      _airPressureHpa = airPressure;
      _deviceTempC = tempC;
      _sensorType = _sensorFromBits(sensorBits);

    });
  }

  void _handleDeviceInfo(List<int> data) {
    if (data.length < 16) {
      return;
    }
    final bytes = Uint8List.fromList(data);
    final view = ByteData.sublistView(bytes);
    final rad1 = view.getUint8(9);
    final rad2 = view.getUint8(10);
    final hasNeutron = rad1 != 0x00 && rad1 != 0xFF;
    final hasPin = rad2 != 0x00 && rad2 != 0xFF;
    if (!mounted) {
      return;
    }
    setState(() {
      _hasNeutron = hasNeutron;
      _hasPin = hasPin;
      if (_hasNeutron == false && _sensorType == SensorType.neutron) {
        _sensorType = SensorType.gamma;
      }
      if (_hasPin == false && _sensorType == SensorType.pin) {
        _sensorType = SensorType.gamma;
      }
    });
  }

  void _toggleRecording() {
    if (_isRecording) {
      final session = _currentSession;
      if (session != null) {
        _db.endSession(session.id, DateTime.now());
      }
      setState(() {
        _isRecording = false;
        if (session != null) {
          _selectedSession = session;
        }
        _currentSession = null;
      });
      _stopRecordTimer();
      _loadSessions();
      return;
    }

    _startSession();
  }

  Future<void> _startSession() async {
    final id = await _db.createSession(DateTime.now());
    if (!mounted) {
      return;
    }
    setState(() {
      _isRecording = true;
      _currentSession = TrackSession(
        id: id,
        startedAt: DateTime.now(),
        endedAt: null,
        pointsCount: 0,
        points: [],
      );
      _selectedSession = null;
    });
    _startRecordTimer();
  }

  void _startRecordTimer() {
    _recordTimer?.cancel();
    _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_isRecording || _currentSession == null || _currentLatLng == null) {
        return;
      }
      final measurement = Measurement(
        timestamp: DateTime.now(),
        latitude: _currentLatLng!.latitude,
        longitude: _currentLatLng!.longitude,
        cps: _rawCps,
        doseEqRateUvh: _rawDoseEqRateUvh,
        sensorType: _sensorType,
      );
      _currentSession!.points.add(measurement);
      final sessionId = _currentSession?.id;
      if (sessionId != null) {
        _db.insertPoint(sessionId, measurement);
      }
      setState(() {});
    });
  }

  void _stopRecordTimer() {
    _recordTimer?.cancel();
    _recordTimer = null;
  }

  void _showOptions() {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final neutronEnabled = _hasNeutron != false;
            final pinEnabled = _hasPin != false;
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _OptionRow(
                      label: 'Map metric',
                      child: _OptionSegmented(
                        options: const ['CPS', 'μSv/h'],
                        selectedIndex: _mapMetric == MapMetric.cps ? 0 : 1,
                        onChanged: (index) {
                          setState(() {
                            _mapMetric = index == 0 ? MapMetric.cps : MapMetric.doseEq;
                          });
                          setModalState(() {});
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    _OptionRow(
                      label: 'Sensor',
                      child: _OptionSegmented(
                        options: const ['γ', 'n', 'PIN'],
                        selectedIndex: _sensorType.index,
                        enabled: [
                          true,
                          neutronEnabled,
                          pinEnabled,
                        ],
                        onChanged: (index) {
                          if (index == 1 && !neutronEnabled) {
                            return;
                          }
                          if (index == 2 && !pinEnabled) {
                            return;
                          }
                          final next = SensorType.values[index];
                          _setSensorType(next);
                          setModalState(() {});
                        },
                      ),
                    ),
                    const SizedBox(height: 12),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('View history'),
                      onTap: () {
                        Navigator.of(context).pop();
                        _showHistory();
                      },
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showHistory() {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Track sessions',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
              if (_sessions.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 16),
                  child: Text('No sessions recorded yet.'),
                ),
              if (_sessions.isNotEmpty)
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _sessions.length,
                    itemBuilder: (context, index) {
                      final session = _sessions[index];
                      final isSelected = session.id == _selectedSession?.id;
                      return Dismissible(
                        key: ValueKey(session.id),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          color: Colors.redAccent,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: const Icon(Icons.delete, color: Colors.white),
                        ),
                        onDismissed: (_) async {
                          await _db.deleteSession(session.id);
                          if (!mounted) {
                            return;
                          }
                          setState(() {
                            _sessions.removeWhere((item) => item.id == session.id);
                            if (_selectedSession?.id == session.id) {
                              _selectedSession = null;
                            }
                          });
                        },
                        child: ListTile(
                          title: Text(_formatTime(session.startedAt)),
                          subtitle: Text('${session.pointsCount} points'),
                          trailing: isSelected ? const Icon(Icons.check) : null,
                          onLongPress: () => _showSessionActions(session),
                          onTap: () async {
                            if (isSelected) {
                              setState(() {
                                _selectedSession = null;
                              });
                              Navigator.of(context).pop();
                              return;
                            }
                            final points = await _db.fetchPoints(session.id);
                            if (!mounted) {
                              return;
                            }
                            setState(() {
                              _selectedSession = TrackSession(
                                id: session.id,
                                startedAt: session.startedAt,
                                endedAt: session.endedAt,
                                pointsCount: session.pointsCount,
                                points: points,
                              );
                              _isRecording = false;
                              _currentSession = null;
                            });
                            Navigator.of(context).pop();
                          },
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  void _showSessionActions(TrackSession session) {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: const Text('Export CSV'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await _exportSessionCsv(session);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _exportSessionCsv(TrackSession session) async {
    try {
      final points = await _db.fetchPoints(session.id);
      if (points.isEmpty) {
        _showExportDialog('No points to export.', null);
        return;
      }
      final timestamp = _formatFileTime(session.startedAt);
      final filename = 'kc_mapper_$timestamp.csv';
      final buffer = StringBuffer();
      buffer.writeln('timestamp,latitude,longitude,sensor,cps,dose_eq_usv_h');
      for (final point in points) {
        final sensor = _sensorLabel(point.sensorType);
        final cps = point.cps?.toStringAsFixed(2) ?? '';
        final dose = point.doseEqRateUvh?.toStringAsFixed(6) ?? '';
        buffer.writeln(
          '${point.timestamp.toIso8601String()},'
          '${point.latitude.toStringAsFixed(6)},'
          '${point.longitude.toStringAsFixed(6)},'
          '$sensor,$cps,$dose',
        );
      }
      final csv = buffer.toString();

      final savedPath = await _saveWithPicker(filename, csv);
      if (savedPath != null) {
        _showExportDialog('Exported CSV', savedPath);
        return;
      }

      final downloadDir = await _getDownloadDirectory();
      if (downloadDir != null) {
        final path = p.join(downloadDir.path, filename);
        try {
          await File(path).writeAsString(csv);
          _showExportDialog('Exported CSV', path);
          return;
        } catch (_) {
          // Fall back to app documents directory.
        }
      }
      final docs = await getApplicationDocumentsDirectory();
      final fallbackPath = p.join(docs.path, filename);
      await File(fallbackPath).writeAsString(csv);
      _showExportDialog('Exported CSV (app storage)', fallbackPath);
    } catch (error) {
      _showExportDialog('Export failed', error.toString());
    }
  }

  Future<String?> _saveWithPicker(String filename, String content) async {
    try {
      final bytes = Uint8List.fromList(content.codeUnits);
      final result = await FileSaver.instance.saveAs(
        name: filename,
        bytes: bytes,
        ext: 'csv',
        mimeType: MimeType.csv,
      );
      return result;
    } catch (_) {
      return null;
    }
  }

  Future<Directory?> _getDownloadDirectory() async {
    if (!Platform.isAndroid) {
      return null;
    }
    try {
      final dir = await getDownloadsDirectory();
      if (dir == null) {
        return null;
      }
      await dir.create(recursive: true);
      return dir;
    } catch (_) {
      return null;
    }
  }

  void _showExportDialog(String title, String? detail) {
    if (!mounted) {
      return;
    }
    showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: detail == null ? null : Text(detail),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        );
      },
    );
  }

  List<Measurement> get _visiblePoints {
    if (_isRecording && _currentSession != null) {
      return _currentSession!.points;
    }
    if (_selectedSession != null) {
      return _selectedSession!.points;
    }
    return const [];
  }

  _Range? _rangeForMetric(List<Measurement> points) {
    double? minValue;
    double? maxValue;
    for (final point in points) {
      final value = _mapMetric == MapMetric.cps
          ? point.cps
          : point.doseEqRateUvh;
      if (value == null) {
        continue;
      }
      minValue = minValue == null ? value : (value < minValue ? value : minValue);
      maxValue = maxValue == null ? value : (value > maxValue ? value : maxValue);
    }
    if (minValue == null || maxValue == null) {
      return null;
    }
    return _Range(minValue, maxValue);
  }

  Color _colorForMeasurement(Measurement measurement, _Range? range) {
    final value = _mapMetric == MapMetric.cps
        ? measurement.cps
        : measurement.doseEqRateUvh;
    if (value == null || range == null) {
      return Colors.grey.withOpacity(0.6);
    }
    final minValue = range.min;
    final maxValue = range.max;
    if (maxValue <= minValue) {
      return Colors.green.withOpacity(0.8);
    }
    final t = ((value - minValue) / (maxValue - minValue)).clamp(0.0, 1.0);
    if (t < 0.33) {
      return Color.lerp(Colors.green, Colors.yellow, t / 0.33)!.withOpacity(0.85);
    }
    if (t < 0.66) {
      return Color.lerp(Colors.yellow, Colors.orange, (t - 0.33) / 0.33)!
          .withOpacity(0.85);
    }
    return Color.lerp(Colors.orange, Colors.red, (t - 0.66) / 0.34)!
        .withOpacity(0.85);
  }

  double? _sanitize(double value) {
    if (value.isNaN || value.isInfinite || value < 0) {
      return null;
    }
    return value;
  }

  double _fp16ToDouble(int half) {
    final sign = (half >> 15) & 0x1;
    final exponent = (half >> 10) & 0x1F;
    final mantissa = half & 0x3FF;

    if (exponent == 0) {
      if (mantissa == 0) {
        return sign == 1 ? -0.0 : 0.0;
      }
      final value = mantissa / 1024.0;
      final result = value * (1 / (1 << 14));
      return sign == 1 ? -result : result;
    }
    if (exponent == 31) {
      return mantissa == 0 ? (sign == 1 ? double.negativeInfinity : double.infinity) : double.nan;
    }

    final value = 1 + mantissa / 1024.0;
    final exp = exponent - 15;
    final result = exp >= 0 ? value * (1 << exp) : value / (1 << -exp);
    return sign == 1 ? -result : result;
  }

  void _cycleTileLayer() {
    setState(() {
      _tileIndex = (_tileIndex + 1) % _tileLayers.length;
    });
  }

  List<_TileLayerDef> get _tileLayers => const [
        _TileLayerDef(
          name: 'OSM Standard',
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          attribution: '© OpenStreetMap contributors',
        ),
        _TileLayerDef(
          name: 'OpenTopo',
          urlTemplate: 'https://a.tile.opentopomap.org/{z}/{x}/{y}.png',
          attribution: '© OpenTopoMap (CC-BY-SA)',
        ),
        _TileLayerDef(
          name: 'Carto Light',
          urlTemplate: 'https://basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png',
          attribution: '© CARTO',
        ),
      ];

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  SensorType _sensorFromBits(int bits) {
    if (bits == 0x01) {
      return SensorType.neutron;
    }
    if (bits == 0x02) {
      return SensorType.pin;
    }
    return SensorType.gamma;
  }

  String _formatTime(DateTime time) {
    final t = time.toLocal();
    final y = t.year.toString().padLeft(4, '0');
    final m = t.month.toString().padLeft(2, '0');
    final d = t.day.toString().padLeft(2, '0');
    final h = t.hour.toString().padLeft(2, '0');
    final min = t.minute.toString().padLeft(2, '0');
    final s = t.second.toString().padLeft(2, '0');
    return '$y-$m-$d $h:$min:$s';
  }

  String _formatFileTime(DateTime time) {
    final t = time.toLocal();
    final y = t.year.toString().padLeft(4, '0');
    final m = t.month.toString().padLeft(2, '0');
    final d = t.day.toString().padLeft(2, '0');
    final h = t.hour.toString().padLeft(2, '0');
    final min = t.minute.toString().padLeft(2, '0');
    final s = t.second.toString().padLeft(2, '0');
    return '${y}${m}${d}_${h}${min}${s}';
  }

  String _sensorLabel(SensorType type) {
    switch (type) {
      case SensorType.gamma:
        return 'γ';
      case SensorType.neutron:
        return 'n';
      case SensorType.pin:
        return 'PIN';
    }
  }

  @override
  Widget build(BuildContext context) {
    final deviceName = _device?.platformName.isNotEmpty == true
        ? _device!.platformName
        : (_device?.remoteId.str ?? '-');
    final tile = _tileLayers[_tileIndex];
    final visiblePoints = _visiblePoints;
    final range = _rangeForMetric(visiblePoints);
    final circles = visiblePoints
        .map(
          (point) => CircleMarker(
            point: LatLng(point.latitude, point.longitude),
            radius: 6,
            color: _colorForMeasurement(point, range),
            borderColor: Colors.black.withOpacity(0.2),
            borderStrokeWidth: 1,
          ),
        )
        .toList();
    final bottomPad = MediaQuery.of(context).padding.bottom;
    final overlayBottom = bottomPad + 200;

    return Scaffold(
      appBar: AppBar(
        title: const Text('KC761 Mapper'),
        actions: [
          TextButton(
            onPressed: _isConnecting ? null : _onConnectPressed,
            child: Text(
              _statusText == 'Connected' ? 'Disconnect' : 'Connect',
              style: TextStyle(
                color: _statusText == 'Connected'
                    ? Theme.of(context).colorScheme.error
                    : Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _currentLatLng ?? const LatLng(39.9042, 116.4074),
              initialZoom: 14,
              onTap: (_, __) {
                setState(() {
                  _selectedPoint = null;
                });
              },
            ),
            children: [
              TileLayer(
                urlTemplate: tile.urlTemplate,
                userAgentPackageName: 'com.example.kc761_mapper',
              ),
              if (circles.isNotEmpty) CircleLayer(circles: circles),
              if (visiblePoints.isNotEmpty)
                MarkerLayer(
                  markers: [
                    for (final point in visiblePoints)
                      Marker(
                        point: LatLng(point.latitude, point.longitude),
                        width: 36,
                        height: 36,
                        alignment: Alignment.center,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            setState(() {
                              _selectedPoint = point;
                            });
                          },
                          child: const SizedBox.expand(),
                        ),
                      ),
                    if (_selectedPoint != null)
                      Marker(
                        point: LatLng(
                          _selectedPoint!.latitude,
                          _selectedPoint!.longitude,
                        ),
                        width: 220,
                        height: 120,
                        rotate: false,
                        child: Transform.translate(
                          offset: const Offset(0, -18),
                          child: _PointBubble(
                            measurement: _selectedPoint!,
                          ),
                        ),
                      ),
                  ],
                ),
              if (_currentLatLng != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _currentLatLng!,
                      width: 28,
                      height: 28,
                      child: const Icon(Icons.my_location, color: Colors.blueAccent),
                    ),
                  ],
                ),
              RichAttributionWidget(
                attributions: [
                  TextSourceAttribution(tile.attribution),
                ],
              ),
            ],
          ),
          Positioned(
            left: 16,
            right: 16,
            top: 8,
            child: SafeArea(
              child: _TopStatusBar(
                cps: _rawCps,
                doseEqRateUvh: _rawDoseEqRateUvh,
              ),
            ),
          ),
          Positioned(
            left: 16,
            bottom: overlayBottom,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _StatusBadge(text: 'BLE: $_statusText'),
                const SizedBox(height: 6),
                _StatusBadge(text: 'Device: $deviceName'),
                const SizedBox(height: 6),
                _StatusBadge(text: _locationReady ? 'GPS: ready' : 'GPS: waiting'),
                if (_batteryPercent != null) ...[
                  const SizedBox(height: 6),
                  _StatusBadge(text: 'Battery: $_batteryPercent%'),
                ],
                if (_airPressureHpa != null) ...[
                  const SizedBox(height: 6),
                  _StatusBadge(text: 'Pressure: ${_airPressureHpa!.toStringAsFixed(0)} hPa'),
                ],
                if (_deviceTempC != null) ...[
                  const SizedBox(height: 6),
                  _StatusBadge(text: 'Temp: ${_deviceTempC!.toStringAsFixed(1)} C'),
                ],
              ],
            ),
          ),
          Positioned(
            right: 16,
            bottom: overlayBottom,
            child: Column(
              children: [
                FloatingActionButton.small(
                  heroTag: 'layerBtn',
                  onPressed: _cycleTileLayer,
                  child: const Icon(Icons.layers_outlined),
                ),
                const SizedBox(height: 8),
                FloatingActionButton.small(
                  heroTag: 'centerBtn',
                  onPressed: _currentLatLng == null
                      ? null
                      : () => _mapController.move(
                            _currentLatLng!,
                            _mapController.camera.zoom,
                          ),
                  child: const Icon(Icons.my_location),
                ),
              ],
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 16 + bottomPad,
            child: Row(
              children: [
                SizedBox(
                  width: 140,
                  child: ElevatedButton(
                    onPressed: _toggleRecording,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isRecording ? Colors.redAccent : null,
                      foregroundColor: _isRecording ? Colors.white : null,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    child: Text(_isRecording ? 'Stop' : 'Start'),
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton(
                  onPressed: _showOptions,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
                  ),
                  child: const Icon(Icons.more_horiz),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TopStatusBar extends StatelessWidget {
  const _TopStatusBar({
    required this.cps,
    required this.doseEqRateUvh,
  });

  final double? cps;
  final double? doseEqRateUvh;

  @override
  Widget build(BuildContext context) {
    final cpsValue = cps?.toStringAsFixed(2) ?? '--';
    final doseValue = doseEqRateUvh?.toStringAsFixed(4) ?? '--';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            const Text('CPS', style: TextStyle(color: Colors.white70)),
            const SizedBox(width: 8),
            Text(
              cpsValue,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 16),
            const Text('Dose Eq', style: TextStyle(color: Colors.white70)),
            const SizedBox(width: 8),
            Text(
              doseValue,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 6),
            const Text('μSv/h', style: TextStyle(color: Colors.white70)),
          ],
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Text(
          text,
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),
      ),
    );
  }
}

class _TileLayerDef {
  const _TileLayerDef({
    required this.name,
    required this.urlTemplate,
    required this.attribution,
  });

  final String name;
  final String urlTemplate;
  final String attribution;
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.label,
    required this.child,
  });

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 100,
          child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        Expanded(child: child),
      ],
    );
  }
}

class _OptionSegmented extends StatelessWidget {
  const _OptionSegmented({
    required this.options,
    required this.selectedIndex,
    required this.onChanged,
    this.enabled,
  });

  final List<String> options;
  final int selectedIndex;
  final List<bool>? enabled;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 8,
      children: List.generate(options.length, (index) {
        final isEnabled = enabled == null ? true : enabled![index];
        return ChoiceChip(
          label: Text(options[index]),
          selected: selectedIndex == index,
          onSelected: isEnabled ? (_) => onChanged(index) : null,
          selectedColor: colors.primary,
          labelStyle: TextStyle(
            color: selectedIndex == index
                ? colors.onPrimary
                : (isEnabled ? colors.onSurface : colors.onSurface.withOpacity(0.4)),
            fontWeight: FontWeight.w600,
          ),
          backgroundColor: colors.surfaceVariant,
          disabledColor: colors.surfaceVariant.withOpacity(0.4),
          showCheckmark: false,
        );
      }),
    );
  }
}

enum MapMetric { cps, doseEq }

class _Range {
  const _Range(this.min, this.max);

  final double min;
  final double max;
}

class _PointBubble extends StatelessWidget {
  const _PointBubble({required this.measurement});

  final Measurement measurement;

  @override
  Widget build(BuildContext context) {
    final cps = measurement.cps?.toStringAsFixed(2) ?? '--';
    final dose = measurement.doseEqRateUvh?.toStringAsFixed(4) ?? '--';
    final sensor = _sensorLabel(measurement.sensorType);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.8),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${measurement.latitude.toStringAsFixed(5)}, '
                '${measurement.longitude.toStringAsFixed(5)}',
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
              const SizedBox(height: 4),
              Text(
                'CPS: $cps   Dose: $dose μSv/h',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
              const SizedBox(height: 2),
              Text(
                'Sensor: $sensor',
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
            ],
          ),
        ),
        CustomPaint(
          size: const Size(12, 6),
          painter: _BubbleArrowPainter(
            color: Colors.black.withOpacity(0.8),
          ),
        ),
      ],
    );
  }

  String _sensorLabel(SensorType type) {
    switch (type) {
      case SensorType.gamma:
        return 'γ';
      case SensorType.neutron:
        return 'n';
      case SensorType.pin:
        return 'PIN';
    }
  }
}

class _BubbleArrowPainter extends CustomPainter {
  const _BubbleArrowPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width / 2, size.height)
      ..lineTo(size.width, 0)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _BubbleArrowPainter oldDelegate) {
    return oldDelegate.color != color;
  }
}
