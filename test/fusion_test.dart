import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:mawqi_now/engine/fusion.dart';

const lat0 = 15.3694, lng0 = 44.1910; // Sana'a

double gauss(math.Random r) {
  final u1 = r.nextDouble().clamp(1e-12, 1.0), u2 = r.nextDouble();
  return math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
}

GeoPoint offset(double e, double n) => GeoPoint(
  lat0 + n / kEarthR * 180 / math.pi,
  lng0 + e / (kEarthR * math.cos(lat0 * math.pi / 180)) * 180 / math.pi,
);

double distM(GeoPoint a, GeoPoint b) {
  final dn = (a.lat - b.lat) * math.pi / 180 * kEarthR;
  final de =
      (a.lng - b.lng) *
      math.pi /
      180 *
      kEarthR *
      math.cos(lat0 * math.pi / 180);
  return math.sqrt(dn * dn + de * de);
}

Fix noisyFix(math.Random r, double e, double n, double acc, DateTime t) {
  final s = acc / kAcc68;
  final p = offset(e + gauss(r) * s, n + gauss(r) * s);
  return Fix(lat: p.lat, lng: p.lng, acc: acc, source: 'gps', time: t);
}

void main() {
  test('acquisition: averaging beats single fixes and locks', () {
    final errs = <double>[];
    for (var seed = 0; seed < 200; seed++) {
      final r = math.Random(seed);
      final eng = FusionEngine();
      var t = DateTime(2026);
      eng.start(t);
      for (var i = 0; i < 30 && eng.phase != Phase.tracking; i++) {
        t = t.add(const Duration(seconds: 1));
        eng.addFix(noisyFix(r, 0, 0, 6, t));
      }
      eng.forceLock();
      errs.add(distM(eng.position, offset(0, 0)));
    }
    errs.sort();
    final median = errs[errs.length ~/ 2];
    // single 6 m (68 %) fix has median error ≈ 4.7 m
    expect(median, lessThan(3.0));
  });

  test('outlier (multipath jump) is rejected', () {
    final r = math.Random(1);
    final eng = FusionEngine();
    var t = DateTime(2026);
    eng.start(t);
    for (var i = 0; i < 10; i++) {
      t = t.add(const Duration(seconds: 1));
      eng.addFix(noisyFix(r, 0, 0, 4, t));
    }
    final before = eng.position;
    t = t.add(const Duration(seconds: 1));
    final used = eng.addFix(
      Fix(
        lat: offset(80, 0).lat,
        lng: offset(80, 0).lng,
        acc: 5,
        source: 'gps',
        time: t,
      ),
    );
    expect(used, isFalse);
    expect(distM(before, eng.position), lessThan(0.01));
  });

  test('sensors-only PDR: 100 m square walk, error < 5 % of distance', () {
    final errs = <double>[];
    for (var seed = 0; seed < 100; seed++) {
      final r = math.Random(seed);
      final eng = FusionEngine(mode: FusionMode.sensors, k: 0.5);
      var t = DateTime(2026);
      eng.start(t);
      for (var i = 0; i < 20 && eng.phase != Phase.tracking; i++) {
        t = t.add(const Duration(seconds: 1));
        eng.addFix(noisyFix(r, 0, 0, 3, t));
      }
      eng.forceLock();
      final start = eng.position;
      // true walk: 4 legs × 25 m, true step 0.7 m → w = 1.4 with K = 0.5
      double e = 0, n = 0;
      for (final hdg in [0.0, 90.0, 180.0, 270.0]) {
        for (var s = 0; s < 36; s++) {
          final trueL = 0.7;
          e += trueL * math.sin(hdg * math.pi / 180);
          n += trueL * math.cos(hdg * math.pi / 180);
          // measurement noise: 5 % step length, 3° heading
          final w = (trueL / 0.5) * (1 + 0.05 * gauss(r));
          eng.addStep(StepEvent(w, hdg + 3 * gauss(r), 5));
        }
      }
      final truth = GeoPoint(
        start.lat + n / kEarthR * 180 / math.pi,
        start.lng +
            e / (kEarthR * math.cos(start.lat * math.pi / 180)) * 180 / math.pi,
      );
      errs.add(distM(eng.position, truth));
    }
    errs.sort();
    final median = errs[errs.length ~/ 2];
    expect(median, lessThan(5.0)); // walked ≈ 100.8 m
  });

  test('hybrid: auto-calibrates step length K from GNSS', () {
    final r = math.Random(7);
    final eng = FusionEngine(k: 0.40); // wrong initial K (true 0.5)
    var t = DateTime(2026);
    eng.start(t);
    for (var i = 0; i < 20 && eng.phase != Phase.tracking; i++) {
      t = t.add(const Duration(seconds: 1));
      eng.addFix(noisyFix(r, 0, 0, 3, t));
    }
    eng.forceLock();
    double n = 0;
    for (var s = 0; s < 400; s++) {
      n += 0.7;
      eng.addStep(StepEvent(1.4 * (1 + 0.03 * gauss(r)), 2 * gauss(r), 5));
      if (s % 2 == 1) {
        t = t.add(const Duration(seconds: 1));
        eng.addFix(noisyFix(r, 0, n, 3, t));
      }
    }
    expect(eng.calibrations, greaterThan(0));
    expect((eng.stepK - 0.5).abs(), lessThan(0.05));
  });

  test('hybrid: learns constant heading bias', () {
    final r = math.Random(3);
    final eng = FusionEngine(k: 0.5);
    var t = DateTime(2026);
    eng.start(t);
    for (var i = 0; i < 20 && eng.phase != Phase.tracking; i++) {
      t = t.add(const Duration(seconds: 1));
      eng.addFix(noisyFix(r, 0, 0, 3, t));
    }
    eng.forceLock();
    double n = 0;
    for (var s = 0; s < 400; s++) {
      n += 0.7;
      // sensor says 10° while truly walking north
      eng.addStep(StepEvent(1.4, 10 + 1.5 * gauss(r), 5));
      if (s % 2 == 1) {
        t = t.add(const Duration(seconds: 1));
        eng.addFix(noisyFix(r, 0, n, 3, t));
      }
    }
    expect((eng.headingBiasDeg - 10).abs(), lessThan(3));
  });
}
