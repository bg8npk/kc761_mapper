class Measurement {
  Measurement({
    required this.timestamp,
    required this.latitude,
    required this.longitude,
    required this.cps,
    required this.doseEqRateUvh,
    required this.sensorType,
    required this.accuracy,
  });

  final DateTime timestamp;
  final double latitude;
  final double longitude;
  final double? cps;
  final double? doseEqRateUvh;
  final SensorType sensorType;
  final double? accuracy;
}

class TrackSession {
  TrackSession({
    required this.id,
    required this.startedAt,
    required this.endedAt,
    required this.pointsCount,
    required this.points,
  });

  final int id;
  final DateTime startedAt;
  final DateTime? endedAt;
  final int pointsCount;
  final List<Measurement> points;
}

enum SensorType { gamma, neutron, pin }
