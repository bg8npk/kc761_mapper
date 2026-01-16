import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/track_models.dart';

class LocalDb {
  LocalDb._();

  static final LocalDb instance = LocalDb._();
  Database? _db;

  Future<Database> get database async {
    if (_db != null) {
      return _db!;
    }
    _db = await _openDb();
    return _db!;
  }

  Future<Database> _openDb() async {
    final docs = await getApplicationDocumentsDirectory();
    final dbPath = p.join(docs.path, 'kc761_mapper.db');
    return openDatabase(
      dbPath,
      version: 3,
      onCreate: (db, version) async {
        await db.execute(
          '''
          CREATE TABLE sessions(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            started_at INTEGER NOT NULL,
            ended_at INTEGER,
            points_count INTEGER NOT NULL DEFAULT 0
          )
          ''',
        );
        await db.execute(
          '''
          CREATE TABLE points(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id INTEGER NOT NULL,
            timestamp INTEGER NOT NULL,
            latitude REAL NOT NULL,
            longitude REAL NOT NULL,
            cps REAL,
            dose_eq REAL,
            sensor INTEGER NOT NULL,
            accuracy REAL
          )
          ''',
        );
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE points ADD COLUMN sensor INTEGER');
        }
        if (oldVersion < 3) {
          await db.execute('ALTER TABLE points ADD COLUMN accuracy REAL');
        }
      },
    );
  }

  Future<int> createSession(DateTime startedAt) async {
    final db = await database;
    return db.insert('sessions', {
      'started_at': startedAt.millisecondsSinceEpoch,
      'points_count': 0,
    });
  }

  Future<void> endSession(int sessionId, DateTime endedAt) async {
    final db = await database;
    await db.update(
      'sessions',
      {'ended_at': endedAt.millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }

  Future<void> insertPoint(int sessionId, Measurement measurement) async {
    final db = await database;
    await db.insert('points', {
      'session_id': sessionId,
      'timestamp': measurement.timestamp.millisecondsSinceEpoch,
      'latitude': measurement.latitude,
      'longitude': measurement.longitude,
      'cps': measurement.cps,
      'dose_eq': measurement.doseEqRateUvh,
      'sensor': measurement.sensorType.index,
      'accuracy': measurement.accuracy,
    });
    await db.rawUpdate(
      'UPDATE sessions SET points_count = points_count + 1 WHERE id = ?',
      [sessionId],
    );
  }

  Future<List<TrackSession>> fetchSessions() async {
    final db = await database;
    final rows = await db.query(
      'sessions',
      orderBy: 'started_at DESC',
    );
    return rows
        .map(
          (row) => TrackSession(
            id: row['id'] as int,
            startedAt:
                DateTime.fromMillisecondsSinceEpoch(row['started_at'] as int),
            endedAt: row['ended_at'] == null
                ? null
                : DateTime.fromMillisecondsSinceEpoch(row['ended_at'] as int),
            pointsCount: (row['points_count'] as int?) ?? 0,
            points: const [],
          ),
        )
        .toList();
  }

  Future<List<Measurement>> fetchPoints(int sessionId) async {
    final db = await database;
    final rows = await db.query(
      'points',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'timestamp ASC',
    );
    return rows
        .map(
          (row) => Measurement(
            timestamp:
                DateTime.fromMillisecondsSinceEpoch(row['timestamp'] as int),
            latitude: row['latitude'] as double,
            longitude: row['longitude'] as double,
            cps: row['cps'] as double?,
            doseEqRateUvh: row['dose_eq'] as double?,
            sensorType: _sensorFromDb(row['sensor'] as int?),
            accuracy: row['accuracy'] as double?,
          ),
        )
        .toList();
  }

  SensorType _sensorFromDb(int? value) {
    if (value == null) {
      return SensorType.gamma;
    }
    if (value >= 0 && value < SensorType.values.length) {
      return SensorType.values[value];
    }
    return SensorType.gamma;
  }

  Future<void> deleteSession(int sessionId) async {
    final db = await database;
    await db.delete('points', where: 'session_id = ?', whereArgs: [sessionId]);
    await db.delete('sessions', where: 'id = ?', whereArgs: [sessionId]);
  }
}
