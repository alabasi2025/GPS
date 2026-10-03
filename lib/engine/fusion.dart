// Positioning fusion engine (pure Dart, unit-tested).
//
// Pipeline
//  1. ACQUIRING  – Google Fused + raw GNSS fixes are fused with a 2-D Kalman
//     filter (inverse-variance weighting) until a precise initial lock.
//  2. TRACKING   – Pedestrian Dead Reckoning drives the state:
//       step length  L = K · Δa^(1/4)        (Weinberg 2002, K auto-calibrated)
//       heading      Google Fused Orientation (true north) − learned bias
//     Each step is a Kalman prediction with anisotropic noise
//       along-track σ = 8 % L, cross-track σ = L · σθ.
//     Mode HYBRID  : good GNSS fixes correct the drift (χ² gated).
//     Mode SENSORS : after the lock only phone sensors are used.
//
// Android "accuracy" is the 68 % horizontal radius  ⇒ σ(axis) = acc / 1.515.

import 'dart:math' as math;

const double kEarthR = 6378137.0;
const double kAcc68 = 1.515; // r68 = 1.515 σ for a circular 2-D Gaussian

enum Phase { idle, acquiring, tracking }

enum FusionMode { hybrid, sensors }

class GeoPoint {
  final double lat, lng;
  const GeoPoint(this.lat, this.lng);
}

class Fix {
  final double lat, lng, acc;
  final String source; // fused | gps | web
  final DateTime time;
  final bool mock;
  final double? speed;
  const Fix({
    required this.lat,
    required this.lng,
    required this.acc,
    required this.source,
    required this.time,
    this.mock = false,
    this.speed,
  });
}

class StepEvent {
  final double w; // Δa^(1/4)
  final double headingDeg; // true north
  final double headingErrDeg;
  const StepEvent(this.w, this.headingDeg, this.headingErrDeg);
}

class FusionEngine {
  FusionEngine({this.mode = FusionMode.hybrid, double k = 0.5, double bias = 0})
    : stepK = k,
      headingBiasDeg = bias;

  FusionMode mode;

  // calibration (persisted by the app)
  double stepK;
  double headingBiasDeg;
  int calibrations = 0;

  // lock criteria
  double lockTargetAcc = 5.0; // m (68 %)
  int lockMinSamples = 5;

  Phase phase = Phase.idle;
  GeoPoint? _origin;
  double _x = 0, _y = 0; // east / north metres from origin
  double _pxx = 0, _pxy = 0, _pyy = 0;
  DateTime? _acqStart;
  DateTime? _lastUpdate;
  double _lastUsedAcc = 1e9;
  int acqSamples = 0;
  double bestFixAcc = 1e9;
  int rejected = 0;
  int _consecutiveRejects = 0;
  int steps = 0;
  double walked = 0; // metres by PDR since lock
  double pdrSinceFix = 0; // metres of PDR since last accepted GNSS correction
  Fix? lastFix;
  bool mockDetected = false;

  // calibration segment
  double? _segX, _segY;
  double _segW = 0, _segSin = 0, _segCos = 0;
  int _segSteps = 0;

  bool get hasPosition => _origin != null;

  /// 68 % horizontal radius of the current estimate (metres).
  double get accuracy {
    if (!hasPosition) return double.infinity;
    final tr = (_pxx + _pyy) / 2;
    return kAcc68 * math.sqrt(math.max(tr, 0));
  }

  GeoPoint get position {
    final o = _origin!;
    final lat = o.lat + (_y / kEarthR) * 180 / math.pi;
    final lng =
        o.lng +
        (_x / (kEarthR * math.cos(o.lat * math.pi / 180))) * 180 / math.pi;
    return GeoPoint(lat, lng);
  }

  void start(DateTime now) {
    phase = Phase.acquiring;
    _acqStart = now;
    acqSamples = 0;
    bestFixAcc = 1e9;
  }

  /// Re-acquire a precise lock (keeps calibration).
  void relock(DateTime now) {
    _origin = null;
    _segX = null;
    steps = 0;
    walked = 0;
    pdrSinceFix = 0;
    start(now);
  }

  void forceLock() {
    if (hasPosition && phase == Phase.acquiring) _lock();
  }

  Duration acquiringFor(DateTime now) =>
      _acqStart == null ? Duration.zero : now.difference(_acqStart!);

  void _toXY(double lat, double lng, List<double> out) {
    final o = _origin!;
    out[0] =
        (lng - o.lng) *
        math.pi /
        180 *
        kEarthR *
        math.cos(o.lat * math.pi / 180);
    out[1] = (lat - o.lat) * math.pi / 180 * kEarthR;
  }

  /// Returns true if the fix was used.
  bool addFix(Fix f) {
    if (phase == Phase.idle) start(f.time);
    lastFix = f;
    if (f.mock) mockDetected = true;
    if (f.acc <= 0 || f.acc > 100) return false;
    final r = math.pow(f.acc / kAcc68, 2).toDouble();

    if (_origin == null) {
      _origin = GeoPoint(f.lat, f.lng);
      _x = 0;
      _y = 0;
      _pxx = r;
      _pyy = r;
      _pxy = 0;
      _lastUpdate = f.time;
      _lastUsedAcc = f.acc;
      acqSamples = 1;
      bestFixAcc = f.acc;
      return true;
    }

    if (phase == Phase.tracking && mode == FusionMode.sensors) return false;
    if (phase == Phase.tracking && f.acc > 20) return false;

    // Fused & raw GPS are correlated: at most one update per ~0.9 s,
    // unless the new fix is clearly better.
    if (_lastUpdate != null &&
        f.time.difference(_lastUpdate!).inMilliseconds < 900 &&
        f.acc >= _lastUsedAcc * 0.8) {
      return false;
    }

    // Time-correlated GNSS error: inflate covariance slowly while static so
    // the filter never becomes over-confident (floor ≈ 0.35·σfix).
    if (_lastUpdate != null) {
      final dt = f.time.difference(_lastUpdate!).inMilliseconds / 1000.0;
      final q = 0.02 * dt.clamp(0, 10);
      _pxx += q;
      _pyy += q;
    }

    final z = [0.0, 0.0];
    _toXY(f.lat, f.lng, z);
    final ix = z[0] - _x, iy = z[1] - _y;
    final sxx = _pxx + r, sxy = _pxy, syy = _pyy + r;
    final det = sxx * syy - sxy * sxy;
    if (det <= 0) return false;
    final ixx = syy / det, ixy = -sxy / det, iyy = sxx / det;
    final d2 = ix * (ixx * ix + ixy * iy) + iy * (ixy * ix + iyy * iy);

    // χ²(2 dof) 99.9 % = 13.8 – reject outliers (multipath jumps)
    if (d2 > 13.8 && acqSamples > 2) {
      rejected++;
      _consecutiveRejects++;
      // Persistent disagreement with good GNSS ⇒ PDR drifted: reset to GNSS.
      if (_consecutiveRejects >= 4 && f.acc <= 12) {
        _x = z[0];
        _y = z[1];
        _pxx = r;
        _pyy = r;
        _pxy = 0;
        _consecutiveRejects = 0;
        _lastUpdate = f.time;
        _lastUsedAcc = f.acc;
        pdrSinceFix = 0;
        _segX = null;
        return true;
      }
      return false;
    }
    _consecutiveRejects = 0;

    // K = P S⁻¹
    final kxx = _pxx * ixx + _pxy * ixy;
    final kxy = _pxx * ixy + _pxy * iyy;
    final kyx = _pxy * ixx + _pyy * ixy;
    final kyy = _pxy * ixy + _pyy * iyy;
    _x += kxx * ix + kxy * iy;
    _y += kyx * ix + kyy * iy;
    // P = (I − K) P
    final nxx = (1 - kxx) * _pxx - kxy * _pxy;
    final nxy = (1 - kxx) * _pxy - kxy * _pyy;
    final nyy = -kyx * _pxy + (1 - kyy) * _pyy;
    _pxx = nxx;
    _pxy = nxy;
    _pyy = nyy;

    // floor: never claim better than 35 % of the fix sigma
    final floor = math.pow(0.35 * f.acc / kAcc68, 2).toDouble();
    if (_pxx < floor) _pxx = floor;
    if (_pyy < floor) _pyy = floor;

    _lastUpdate = f.time;
    _lastUsedAcc = f.acc;
    pdrSinceFix = 0;
    if (phase == Phase.acquiring) {
      acqSamples++;
      if (f.acc < bestFixAcc) bestFixAcc = f.acc;
      _checkLock(f.time);
    } else {
      _calibrate(z[0], z[1], f.acc);
    }
    return true;
  }

  void _checkLock(DateTime now) {
    final t = acquiringFor(now).inSeconds;
    final enough = acqSamples >= lockMinSamples;
    if ((enough && accuracy <= lockTargetAcc) ||
        (enough && t >= 25 && accuracy <= 10) ||
        (t >= 60 && accuracy <= 25)) {
      _lock();
    }
  }

  void _lock() {
    phase = Phase.tracking;
    walked = 0;
    _segX = null;
  }

  void addStep(StepEvent s) {
    if (!hasPosition) return;
    steps++;
    final l = (stepK * s.w).clamp(0.25, 1.3);
    final h = (s.headingDeg - headingBiasDeg) * math.pi / 180;
    final sh = math.sin(h), ch = math.cos(h);
    _x += l * sh;
    _y += l * ch;
    if (phase == Phase.tracking) walked += l;
    pdrSinceFix += l;

    // anisotropic process noise in (along, cross) rotated to (east, north)
    final sa = 0.08 * l + 0.03;
    final sc = l * (s.headingErrDeg.clamp(2, 60) * math.pi / 180);
    final qa = sa * sa, qc = sc * sc;
    // along = (sh, ch), cross = (ch, −sh)
    _pxx += qa * sh * sh + qc * ch * ch;
    _pyy += qa * ch * ch + qc * sh * sh;
    _pxy += (qa - qc) * sh * ch;

    if (_segX != null) {
      _segW += s.w;
      _segSin += math.sin(s.headingDeg * math.pi / 180);
      _segCos += math.cos(s.headingDeg * math.pi / 180);
      _segSteps++;
    }
  }

  /// Online calibration of K and heading bias from straight GNSS segments.
  void _calibrate(double gx, double gy, double acc) {
    if (acc > 8) return;
    if (_segX == null) {
      _segX = gx;
      _segY = gy;
      _segW = 0;
      _segSin = 0;
      _segCos = 0;
      _segSteps = 0;
      return;
    }
    final dx = gx - _segX!, dy = gy - _segY!;
    final dist = math.sqrt(dx * dx + dy * dy);
    if (dist < 30 || _segSteps < 20) return;
    final straight =
        math.sqrt(_segSin * _segSin + _segCos * _segCos) / _segSteps;
    if (straight >= 0.92 && _segW > 0) {
      final kObs = dist / _segW;
      if (kObs > 0.2 && kObs < 1.0) {
        final a = calibrations == 0 ? 0.6 : 0.3;
        stepK = (1 - a) * stepK + a * kObs;
        final gb = math.atan2(dx, dy) * 180 / math.pi;
        final sb = math.atan2(_segSin, _segCos) * 180 / math.pi;
        var b = sb - gb;
        while (b > 180) {
          b -= 360;
        }
        while (b < -180) {
          b += 360;
        }
        if (b.abs() < 35) {
          headingBiasDeg = (1 - a) * headingBiasDeg + a * b;
        }
        calibrations++;
      }
    }
    _segX = gx;
    _segY = gy;
    _segW = 0;
    _segSin = 0;
    _segCos = 0;
    _segSteps = 0;
  }
}
