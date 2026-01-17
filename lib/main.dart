import 'dart:async';
import 'dart:io';
import 'dart:math' show Point;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:file_saver/file_saver.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'models/track_models.dart';
import 'storage/local_db.dart';

const String _osmCacheStore = 'osm_standard_cache';
const int _osmCacheMaxDbKb = 512000; // 500 MB
const String _osmStandardUrl =
    'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

bool _tileCacheReady = false;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _initTileCache();
  runApp(const Kc761App());
}

Future<void> _initTileCache() async {
  try {
    await FMTCObjectBoxBackend().initialise(maxDatabaseSize: _osmCacheMaxDbKb);
    const store = FMTCStore(_osmCacheStore);
    if (!await store.manage.ready) {
      await store.manage.create();
    }
    await store.metadata.set(key: 'sourceURL', value: _osmStandardUrl);
    await store.metadata.setBulk(
      kvs: {
        'validDuration': '0',
        'maxLength': '0',
        'behaviour': 'cacheFirst',
      },
    );
    _tileCacheReady = true;
  } catch (_) {
    _tileCacheReady = false;
  }
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
  static const double _clusterCellPx = 32.0;

  final LocalDb _db = LocalDb.instance;
  final MapController _mapController = MapController();
  StreamSubscription<Position>? _posSub;
  Timer? _recordTimer;
  Timer? _aggregateDebounce;
  Timer? _locationFallbackTimer;
  DateTime? _lastPositionAt;
  double? _lastPositionAccuracy;
  LatLng? _currentLatLng;
  bool _locationReady = false;
  int _tileIndex = 0;
  bool _autoFollow = true;

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
  List<Measurement> _aggregatedPoints = [];
  bool _aggregationReady = false;

  @override
  void initState() {
    super.initState();
    _startLocationUpdates();
    _loadSessions();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduleAggregateRebuild();
    });
  }

  @override
  void dispose() {
    _notifySub?.cancel();
    _connSub?.cancel();
    _posSub?.cancel();
    _recordTimer?.cancel();
    _aggregateDebounce?.cancel();
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
        _lastPositionAccuracy = position.accuracy;
        _locationReady = true;
      });
      if (_autoFollow) {
        _mapController.move(next, _mapController.camera.zoom);
      }
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
      _lastPositionAccuracy = position.accuracy;
      _locationReady = true;
    });
    if (_autoFollow) {
      _mapController.move(next, _mapController.camera.zoom);
    }
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
      _scheduleAggregateRebuild();
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
      _aggregatedPoints = [];
      _aggregationReady = false;
      _selectedPoint = null;
    });
    _startRecordTimer();
    _scheduleAggregateRebuild();
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
        accuracy: _lastPositionAccuracy,
      );
      _currentSession!.points.add(measurement);
      final sessionId = _currentSession?.id;
      if (sessionId != null) {
        _db.insertPoint(sessionId, measurement);
      }
      setState(() {});
      _scheduleAggregateRebuild();
    });
  }

  void _stopRecordTimer() {
    _recordTimer?.cancel();
    _recordTimer = null;
  }

  void _showOptions() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final neutronEnabled = _hasNeutron != false;
            final pinEnabled = _hasPin != false;
            final bottomPad = MediaQuery.of(context).padding.bottom;
            return SafeArea(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottomPad),
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
                    const SizedBox(height: 8),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Clear map cache'),
                      enabled: _tileCacheReady,
                      onTap: () async {
                        final confirmed = await _confirmClearCache();
                        if (!confirmed) {
                          return;
                        }
                        Navigator.of(context).pop();
                        try {
                          await const FMTCStore(_osmCacheStore).manage.reset();
                          _showMessage('Map cache cleared.');
                        } catch (error) {
                          _showMessage('Cache clear failed: $error');
                        }
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
                          _scheduleAggregateRebuild();
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
                              _scheduleAggregateRebuild();
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
                            _scheduleAggregateRebuild();
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
    buffer.writeln('timestamp,latitude,longitude,sensor,cps,dose_eq_usv_h,accuracy_m');
      for (final point in points) {
      final sensor = _sensorLabelCsv(point.sensorType);
      final cps = point.cps?.toStringAsFixed(2) ?? '';
      final dose = point.doseEqRateUvh?.toStringAsFixed(6) ?? '';
      final acc = point.accuracy?.toStringAsFixed(1) ?? '';
      buffer.writeln(
        '${point.timestamp.toIso8601String()},'
        '${point.latitude.toStringAsFixed(6)},'
        '${point.longitude.toStringAsFixed(6)},'
        '$sensor,$cps,$dose,$acc',
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

  void _scheduleAggregateRebuild() {
    _aggregateDebounce?.cancel();
    _aggregateDebounce = Timer(
      const Duration(milliseconds: 200),
      _rebuildAggregates,
    );
  }

  void _rebuildAggregates() {
    if (!mounted) {
      return;
    }
    final points = _visiblePoints;
    final camera = _mapController.camera;
    final size = camera.nonRotatedSize;
    if (size.x <= 0 || size.y <= 0) {
      return;
    }
    if (points.isEmpty) {
      if (_aggregatedPoints.isNotEmpty) {
        setState(() {
          _aggregatedPoints = [];
          _selectedPoint = null;
          _aggregationReady = true;
        });
      } else if (!_aggregationReady) {
        setState(() {
          _aggregationReady = true;
        });
      }
      return;
    }

    final buckets = <String, List<Measurement>>{};
    for (final point in points) {
      final screen =
          camera.latLngToScreenPoint(LatLng(point.latitude, point.longitude));
      if (screen.x < -_clusterCellPx ||
          screen.y < -_clusterCellPx ||
          screen.x > size.x + _clusterCellPx ||
          screen.y > size.y + _clusterCellPx) {
        continue;
      }
      final cellX = (screen.x / _clusterCellPx).floor();
      final cellY = (screen.y / _clusterCellPx).floor();
      final key = '$cellX:$cellY';
      buckets.putIfAbsent(key, () => []).add(point);
    }

    final aggregated = <Measurement>[];
    for (final bucket in buckets.values) {
      aggregated.add(_aggregateBucket(bucket));
    }

    final nextSelected = _selectedPoint == null
        ? null
        : _matchSelectedPoint(_selectedPoint!, aggregated, camera);

    setState(() {
      _aggregatedPoints = aggregated;
      _selectedPoint = nextSelected;
      _aggregationReady = true;
    });
  }

  Measurement _aggregateBucket(List<Measurement> points) {
    if (points.length == 1) {
      return points.first;
    }
    final lat = _median(points.map((p) => p.latitude).toList()) ??
        points.first.latitude;
    final lng = _median(points.map((p) => p.longitude).toList()) ??
        points.first.longitude;
    final cps = _medianNullable(points.map((p) => p.cps));
    final dose = _medianNullable(points.map((p) => p.doseEqRateUvh));
    final acc = _medianNullable(points.map((p) => p.accuracy));
    final timestampMs =
        _medianInt(points.map((p) => p.timestamp.millisecondsSinceEpoch).toList());
    final timestamp = timestampMs == null
        ? points.first.timestamp
        : DateTime.fromMillisecondsSinceEpoch(timestampMs);
    final sensor = _modeSensor(points);

    return Measurement(
      timestamp: timestamp,
      latitude: lat,
      longitude: lng,
      cps: cps,
      doseEqRateUvh: dose,
      sensorType: sensor,
      accuracy: acc,
    );
  }

  double? _medianNullable(Iterable<double?> values) {
    return _median(values.whereType<double>().toList());
  }

  double? _median(List<double> values) {
    if (values.isEmpty) {
      return null;
    }
    values.sort();
    final mid = values.length ~/ 2;
    if (values.length.isOdd) {
      return values[mid];
    }
    return (values[mid - 1] + values[mid]) / 2.0;
  }

  int? _medianInt(List<int> values) {
    if (values.isEmpty) {
      return null;
    }
    values.sort();
    final mid = values.length ~/ 2;
    if (values.length.isOdd) {
      return values[mid];
    }
    return ((values[mid - 1] + values[mid]) / 2).round();
  }

  SensorType _modeSensor(List<Measurement> points) {
    final counts = <SensorType, int>{};
    for (final point in points) {
      counts[point.sensorType] = (counts[point.sensorType] ?? 0) + 1;
    }
    return counts.entries
        .reduce((a, b) => a.value >= b.value ? a : b)
        .key;
  }

  Measurement? _matchSelectedPoint(
    Measurement selected,
    List<Measurement> aggregated,
    MapCamera camera,
  ) {
    if (aggregated.isEmpty) {
      return null;
    }
    final target = camera
        .latLngToScreenPoint(LatLng(selected.latitude, selected.longitude));
    final maxDist = _clusterCellPx;
    final maxDistSq = maxDist * maxDist;
    Measurement? best;
    double bestSq = double.infinity;
    for (final point in aggregated) {
      final screen =
          camera.latLngToScreenPoint(LatLng(point.latitude, point.longitude));
      final dx = screen.x - target.x;
      final dy = screen.y - target.y;
      final distSq = dx * dx + dy * dy;
      if (distSq <= maxDistSq && distSq < bestSq) {
        bestSq = distSq;
        best = point;
      }
    }
    return best;
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

  List<Measurement> get _displayPoints {
    if (_aggregationReady) {
      return _aggregatedPoints;
    }
    return _visiblePoints;
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
          urlTemplate: _osmStandardUrl,
          attribution: '© OpenStreetMap contributors',
          cacheable: true,
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

  Future<bool> _confirmClearCache() async {
    final cacheSizeText = await _getCacheSizeText();
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Clear map cache?'),
          content: Text('Cache size: $cacheSizeText\nThis will remove all cached map tiles.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Clear'),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  Future<String> _getCacheSizeText() async {
    try {
      final sizeKb = await const FMTCStore(_osmCacheStore).stats.size;
      return _formatBytes(sizeKb * 1024);
    } catch (_) {
      return '--';
    }
  }

  String _formatBytes(double bytes) {
    const kb = 1024.0;
    const mb = kb * 1024.0;
    const gb = mb * 1024.0;
    if (bytes >= gb) {
      return '${(bytes / gb).toStringAsFixed(2)} GB';
    }
    if (bytes >= mb) {
      return '${(bytes / mb).toStringAsFixed(1)} MB';
    }
    if (bytes >= kb) {
      return '${(bytes / kb).toStringAsFixed(1)} KB';
    }
    return '${bytes.toStringAsFixed(0)} B';
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

  String _sensorLabelCsv(SensorType type) {
    switch (type) {
      case SensorType.gamma:
        return 'gamma';
      case SensorType.neutron:
        return 'neutron';
      case SensorType.pin:
        return 'pin';
    }
  }

  @override
  Widget build(BuildContext context) {
    final deviceName = _device?.platformName.isNotEmpty == true
        ? _device!.platformName
        : (_device?.remoteId.str ?? '-');
    final deviceInfo = _statusText == 'Connected' ? deviceName : '';
    final tile = _tileLayers[_tileIndex];
    final visiblePoints = _displayPoints;
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
    final media = MediaQuery.of(context);
    final bottomPad = media.padding.bottom;
    final leftPad = media.padding.left;
    final rightPad = media.padding.right;
    final isLandscape = media.orientation == Orientation.landscape;
    final overlayBottom = bottomPad + (isLandscape ? 96 : 200);

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
              onPositionChanged: (position, hasGesture) {
                if (hasGesture && _autoFollow) {
                  setState(() {
                    _autoFollow = false;
                  });
                }
                _scheduleAggregateRebuild();
              },
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
                tileProvider: tile.cacheable && _tileCacheReady
                    ? const FMTCStore(_osmCacheStore).getTileProvider(
                        settings: FMTCTileProviderSettings(
                          behavior: CacheBehavior.cacheFirst,
                          cachedValidDuration: Duration.zero,
                          maxStoreLength: 0,
                        ),
                      )
                    : null,
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
                          offset: const Offset(0, -34),
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
            left: 16 + leftPad,
            right: 16 + rightPad,
            top: 8,
            child: SafeArea(
              child: _TopStatusBar(
                cps: _rawCps,
                doseEqRateUvh: _rawDoseEqRateUvh,
                deviceName: deviceInfo,
                batteryPercent: _batteryPercent,
                airPressureHpa: _airPressureHpa,
                deviceTempC: _deviceTempC,
                compact: isLandscape,
              ),
            ),
          ),
          Positioned(
            right: 16 + rightPad,
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
                      : () {
                          setState(() {
                            _autoFollow = true;
                          });
                          _mapController.move(
                            _currentLatLng!,
                            _mapController.camera.zoom,
                          );
                        },
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
    required this.deviceName,
    required this.batteryPercent,
    required this.airPressureHpa,
    required this.deviceTempC,
    this.compact = false,
  });

  final double? cps;
  final double? doseEqRateUvh;
  final String deviceName;
  final int? batteryPercent;
  final double? airPressureHpa;
  final double? deviceTempC;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final cpsValue = cps?.toStringAsFixed(2) ?? '--';
    final doseValue = doseEqRateUvh?.toStringAsFixed(4) ?? '--';
    final valueStyle = TextStyle(
      color: Colors.white,
      fontWeight: FontWeight.w600,
      fontSize: compact ? 12 : 14,
    );
    final labelStyle = TextStyle(
      color: Colors.white70,
      fontSize: compact ? 11 : 12,
    );
    final infoWidgets = <Widget>[];
    if (deviceName.isNotEmpty) {
      infoWidgets.add(Text(deviceName, style: labelStyle));
    }
    if (batteryPercent != null) {
      infoWidgets.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.battery_full,
              size: compact ? 12 : 14,
              color: Colors.white70,
            ),
            const SizedBox(width: 4),
            Text('${batteryPercent!}%', style: labelStyle),
          ],
        ),
      );
    }
    if (airPressureHpa != null) {
      infoWidgets.add(
        Text(
          '${airPressureHpa!.toStringAsFixed(0)} hPa',
          style: labelStyle,
        ),
      );
    }
    if (deviceTempC != null) {
      infoWidgets.add(
        Text(
          '${deviceTempC!.toStringAsFixed(1)} C',
          style: labelStyle,
        ),
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 10 : 14,
          vertical: compact ? 6 : 10,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('CPS', style: labelStyle),
                const SizedBox(width: 8),
                Text(
                  cpsValue,
                  style: valueStyle,
                ),
                const SizedBox(width: 16),
                Text('Dose Eq', style: labelStyle),
                const SizedBox(width: 8),
                Text(
                  doseValue,
                  style: valueStyle,
                ),
                const SizedBox(width: 6),
                Text('μSv/h', style: labelStyle),
              ],
            ),
            if (infoWidgets.isNotEmpty) ...[
              SizedBox(height: compact ? 4 : 6),
              Wrap(
                spacing: compact ? 8 : 12,
                runSpacing: compact ? 2 : 4,
                children: infoWidgets,
              ),
            ],
          ],
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
    this.cacheable = false,
  });

  final String name;
  final String urlTemplate;
  final String attribution;
  final bool cacheable;
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
    final acc = measurement.accuracy?.toStringAsFixed(1) ?? '--';
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
              const SizedBox(height: 2),
              Text(
                'Accuracy: ±$acc m',
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
