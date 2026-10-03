import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A captured point (location + optional photo).
class SavedPoint {
  final String id;
  final double lat, lng, acc;
  final String method; // gnss | hybrid | sensors
  final DateTime time;
  final String? photoPath;
  final String? address;
  final int steps;
  final double walked;
  String name;

  SavedPoint({
    required this.id,
    required this.lat,
    required this.lng,
    required this.acc,
    required this.method,
    required this.time,
    this.photoPath,
    this.address,
    this.steps = 0,
    this.walked = 0,
    required this.name,
  });

  String get mapsLink =>
      'https://maps.google.com/?q=${lat.toStringAsFixed(7)},${lng.toStringAsFixed(7)}';

  String get coords => '${lat.toStringAsFixed(7)}, ${lng.toStringAsFixed(7)}';

  Map<String, dynamic> toJson() => {
    'id': id,
    'lat': lat,
    'lng': lng,
    'acc': acc,
    'method': method,
    'time': time.toIso8601String(),
    'photo': photoPath,
    'address': address,
    'steps': steps,
    'walked': walked,
    'name': name,
  };

  static SavedPoint fromJson(Map<String, dynamic> j) => SavedPoint(
    id: j['id'] as String? ?? '',
    lat: (j['lat'] as num?)?.toDouble() ?? 0,
    lng: (j['lng'] as num?)?.toDouble() ?? 0,
    acc: (j['acc'] as num?)?.toDouble() ?? 0,
    method: j['method'] as String? ?? 'gnss',
    time: DateTime.tryParse(j['time'] as String? ?? '') ?? DateTime.now(),
    photoPath: j['photo'] as String?,
    address: j['address'] as String?,
    steps: (j['steps'] as num?)?.toInt() ?? 0,
    walked: (j['walked'] as num?)?.toDouble() ?? 0,
    name: j['name'] as String? ?? 'نقطة',
  );
}

class Store {
  static const _kPoints = 'points_v1';
  static const _kStepK = 'step_k';
  static const _kBias = 'heading_bias';
  static const _kCal = 'calibrations';
  static const _kMode = 'fusion_mode';

  static Future<List<SavedPoint>> loadPoints() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getString(_kPoints);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .map((e) => SavedPoint.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> savePoints(List<SavedPoint> pts) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(
      _kPoints,
      jsonEncode(pts.map((e) => e.toJson()).toList()),
    );
  }

  static Future<(double, double, int, String)> loadCalibration() async {
    final p = await SharedPreferences.getInstance();
    return (
      p.getDouble(_kStepK) ?? 0.5,
      p.getDouble(_kBias) ?? 0.0,
      p.getInt(_kCal) ?? 0,
      p.getString(_kMode) ?? 'hybrid',
    );
  }

  static Future<void> saveCalibration(
    double k,
    double bias,
    int cal,
    String mode,
  ) async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_kStepK, k);
    await p.setDouble(_kBias, bias);
    await p.setInt(_kCal, cal);
    await p.setString(_kMode, mode);
  }
}
