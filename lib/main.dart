import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

void main() => runApp(const MawqiApp());

const kPrimary = Color(0xFF0B7A5A);

class MawqiApp extends StatelessWidget {
  const MawqiApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'موقعي الآن',
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: kPrimary,
        scaffoldBackgroundColor: const Color(0xFFF4F7F6),
      ),
      home: const LocationScreen(),
    );
  }
}

class LocationScreen extends StatefulWidget {
  const LocationScreen({super.key});

  @override
  State<LocationScreen> createState() => _LocationScreenState();
}

class _LocationScreenState extends State<LocationScreen> {
  final MapController _map = MapController();
  StreamSubscription<Position>? _sub;
  StreamSubscription<dynamic>? _gpsSub;
  static const _gpsEvents = EventChannel('mawqi/gps');
  Position? _pos;
  Position? _raw; // latest raw fix from the GPS chip
  final List<Position> _samples = []; // stationary samples for averaging
  int _satUsed = 0;
  int _satVisible = 0;
  double _avgCn0 = 0;
  Map<String, List<int>> _constellations = {};
  bool get _nativeGps =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  String? _address;
  bool _loadingAddress = false;
  String? _error;
  bool _searching = false;
  LatLng? _lastGeocoded;
  bool _mapReady = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _sub?.cancel();
    _gpsSub?.cancel();
    super.dispose();
  }

  LocationSettings get _settings {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return AndroidSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
        intervalDuration: const Duration(seconds: 1),
        forceLocationManager: false,
      );
    }
    return const LocationSettings(
      accuracy: LocationAccuracy.best,
      distanceFilter: 0,
    );
  }

  Future<void> _start() async {
    setState(() {
      _error = null;
      _searching = true;
    });
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        setState(() {
          _error = 'خدمة الموقع (GPS) مقفلة. فعّلها ثم اضغط "إعادة المحاولة".';
          _searching = false;
        });
        if (!kIsWeb) await Geolocator.openLocationSettings();
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied) {
        setState(() {
          _error = 'لازم تسمح للتطبيق بالوصول إلى الموقع.';
          _searching = false;
        });
        return;
      }
      if (perm == LocationPermission.deniedForever) {
        setState(() {
          _error = 'صلاحية الموقع مرفوضة نهائياً. افتح الإعدادات واسمح بها.';
          _searching = false;
        });
        if (!kIsWeb) await Geolocator.openAppSettings();
        return;
      }

      await _sub?.cancel();
      await _gpsSub?.cancel();
      if (_nativeGps) {
        _listenNativeGps();
        return;
      }
      _sub = Geolocator.getPositionStream(locationSettings: _settings).listen(
        _onPosition,
        onError: (e) {
          if (!mounted) return;
          setState(() {
            _error = 'تعذر تحديد الموقع: $e';
            _searching = false;
          });
        },
      );
    } catch (e) {
      setState(() {
        _error = 'حدث خطأ: $e';
        _searching = false;
      });
    }
  }

  /// Android: raw GPS chip (LocationManager.GPS_PROVIDER) + GNSS satellites.
  void _listenNativeGps() {
    _gpsSub = _gpsEvents.receiveBroadcastStream().listen(
      (e) {
        final m = Map<String, dynamic>.from(e as Map);
        switch (m['type']) {
          case 'gnss':
            if (!mounted) return;
            setState(() {
              _satVisible = (m['visible'] as num?)?.toInt() ?? 0;
              _satUsed = (m['used'] as num?)?.toInt() ?? 0;
              _avgCn0 = (m['avgCn0'] as num?)?.toDouble() ?? 0;
              _constellations = (m['constellations'] as Map? ?? {}).map(
                (k, v) => MapEntry(
                  k as String,
                  (v as List).map((x) => (x as num).toInt()).toList(),
                ),
              );
            });
          case 'location':
            final acc = (m['acc'] as num?)?.toDouble() ?? 9999;
            final p = Position(
              latitude: (m['lat'] as num).toDouble(),
              longitude: (m['lng'] as num).toDouble(),
              timestamp: DateTime.fromMillisecondsSinceEpoch(
                (m['time'] as num).toInt(),
              ),
              accuracy: acc,
              altitude: (m['alt'] as num?)?.toDouble() ?? 0,
              altitudeAccuracy: (m['vAcc'] as num?)?.toDouble() ?? 0,
              heading: (m['bearing'] as num?)?.toDouble() ?? 0,
              headingAccuracy: 0,
              speed: (m['speed'] as num?)?.toDouble() ?? 0,
              speedAccuracy: 0,
              isMocked: m['mock'] == true,
            );
            _onPosition(p, fromCache: m['cached'] == true);
          case 'disabled':
            if (!mounted) return;
            setState(() {
              _error = 'تم إيقاف GPS. فعّله ثم اضغط "إعادة المحاولة".';
              _searching = false;
            });
        }
      },
      onError: (e) {
        if (!mounted) return;
        final code = e is PlatformException ? e.code : '';
        setState(() {
          _error = code == 'GPS_DISABLED'
              ? 'GPS مقفل. افتح الإعدادات وفعّل "الموقع" ثم اضغط "إعادة المحاولة".'
              : 'تعذر تشغيل GPS: $e';
          _searching = false;
        });
        if (code == 'GPS_DISABLED') Geolocator.openLocationSettings();
      },
    );
  }

  /// Inverse-variance weighted mean of stationary fixes -> more precise point.
  Position _averaged() {
    double w = 0, lat = 0, lng = 0;
    for (final s in _samples) {
      final wi = 1 / (s.accuracy * s.accuracy);
      w += wi;
      lat += s.latitude * wi;
      lng += s.longitude * wi;
    }
    final last = _samples.last;
    final best = _samples
        .map((s) => s.accuracy)
        .reduce((a, b) => a < b ? a : b);
    return Position(
      latitude: lat / w,
      longitude: lng / w,
      timestamp: last.timestamp,
      accuracy: best,
      altitude: last.altitude,
      altitudeAccuracy: last.altitudeAccuracy,
      heading: last.heading,
      headingAccuracy: 0,
      speed: last.speed,
      speedAccuracy: 0,
      isMocked: last.isMocked,
    );
  }

  void _onPosition(Position p, {bool fromCache = false}) {
    if (!mounted) return;
    final first = _pos == null;
    _raw = p;
    if (fromCache) {
      setState(() {
        _pos = p;
        _searching = true;
      });
    } else {
      // Reset averaging when the user is moving or jumped away.
      if (_samples.isNotEmpty) {
        final mean = _averaged();
        final d = Geolocator.distanceBetween(
          mean.latitude,
          mean.longitude,
          p.latitude,
          p.longitude,
        );
        final moving = p.speed > 1.0;
        if (moving || d > (p.accuracy * 1.5).clamp(8, 60)) _samples.clear();
      }
      if (p.accuracy <= 50) {
        _samples.add(p);
        if (_samples.length > 60) _samples.removeAt(0);
      }
      final shown = _samples.isNotEmpty ? _averaged() : p;
      setState(() {
        _pos = shown;
        _searching = p.accuracy > 10;
      });
    }
    final p2 = _pos!;
    p = p2;
    final ll = LatLng(p.latitude, p.longitude);
    if (_mapReady) {
      _map.move(ll, first ? 17 : _map.camera.zoom);
    }
    final needGeo =
        _lastGeocoded == null ||
        const Distance().as(LengthUnit.Meter, _lastGeocoded!, ll) > 40;
    if (needGeo) _reverseGeocode(ll);
  }

  Future<void> _reverseGeocode(LatLng ll) async {
    _lastGeocoded = ll;
    setState(() => _loadingAddress = true);
    try {
      final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {
        'format': 'jsonv2',
        'lat': ll.latitude.toString(),
        'lon': ll.longitude.toString(),
        'zoom': '18',
        'addressdetails': '1',
        'accept-language': 'ar,en',
      });
      final res = await http
          .get(
            uri,
            headers: {
              if (!kIsWeb)
                'User-Agent': 'MawqiNow/1.0 (com.mawqianow.location)',
            },
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode == 200) {
        final data = jsonDecode(utf8.decode(res.bodyBytes));
        setState(() => _address = _formatAddress(data));
      }
    } catch (_) {
      // Address is optional; coordinates remain available.
    } finally {
      if (mounted) setState(() => _loadingAddress = false);
    }
  }

  String? _formatAddress(dynamic data) {
    final a = data['address'] as Map<String, dynamic>?;
    if (a == null) return data['display_name'] as String?;
    final parts = <String>[];
    void add(String? v) {
      if (v != null && v.trim().isNotEmpty && !parts.contains(v)) parts.add(v);
    }

    final road = a['road'] as String?;
    final house = a['house_number'] as String?;
    add(house != null && road != null ? '$road $house' : road);
    add(a['neighbourhood'] as String? ?? a['suburb'] as String?);
    add(
      a['city'] as String? ??
          a['town'] as String? ??
          a['village'] as String? ??
          a['county'] as String?,
    );
    add(a['state'] as String?);
    add(a['country'] as String?);
    if (parts.isEmpty) return data['display_name'] as String?;
    return parts.join('، ');
  }

  String get _coords =>
      '${_pos!.latitude.toStringAsFixed(6)}, ${_pos!.longitude.toStringAsFixed(6)}';

  String get _mapsLink =>
      'https://maps.google.com/?q=${_pos!.latitude.toStringAsFixed(6)},${_pos!.longitude.toStringAsFixed(6)}';

  String get _shareText {
    final b = StringBuffer('📍 موقعي الحالي\n');
    if (_address != null) b.writeln(_address);
    b.writeln('الإحداثيات: $_coords');
    b.writeln('الدقة: ±${_pos!.accuracy.round()} متر');
    b.write(_mapsLink);
    return b.toString();
  }

  Future<void> _share() async {
    if (_pos == null) return;
    await SharePlus.instance.share(ShareParams(text: _shareText));
  }

  Future<void> _whatsapp() async {
    if (_pos == null) return;
    final uri = Uri.parse(
      'https://wa.me/?text=${Uri.encodeComponent(_shareText)}',
    );
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      await _share();
    }
  }

  Future<void> _openMaps() async {
    if (_pos == null) return;
    await launchUrl(Uri.parse(_mapsLink), mode: LaunchMode.externalApplication);
  }

  void _copy(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('تم نسخ $label'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Color _accColor(double acc) {
    if (acc <= 10) return const Color(0xFF16A34A);
    if (acc <= 30) return const Color(0xFF65A30D);
    if (acc <= 100) return const Color(0xFFF59E0B);
    return const Color(0xFFDC2626);
  }

  String _accLabel(double acc) {
    if (acc <= 10) return 'دقة ممتازة';
    if (acc <= 30) return 'دقة جيدة';
    if (acc <= 100) return 'دقة متوسطة';
    return 'دقة ضعيفة';
  }

  @override
  Widget build(BuildContext context) {
    final p = _pos;
    final ll = p == null
        ? const LatLng(24.7136, 46.6753)
        : LatLng(p.latitude, p.longitude);
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: FlutterMap(
              mapController: _map,
              options: MapOptions(
                initialCenter: ll,
                initialZoom: p == null ? 5 : 17,
                onMapReady: () {
                  _mapReady = true;
                  if (_pos != null) {
                    _map.move(LatLng(_pos!.latitude, _pos!.longitude), 17);
                  }
                },
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.mawqianow.location',
                ),
                if (p != null)
                  CircleLayer(
                    circles: [
                      CircleMarker(
                        point: ll,
                        radius: p.accuracy,
                        useRadiusInMeter: true,
                        color: kPrimary.withValues(alpha: 0.15),
                        borderColor: kPrimary.withValues(alpha: 0.5),
                        borderStrokeWidth: 1.5,
                      ),
                    ],
                  ),
                if (p != null)
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: ll,
                        width: 28,
                        height: 28,
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF2563EB),
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 4),
                            boxShadow: const [
                              BoxShadow(color: Colors.black26, blurRadius: 6),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  _pill(
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.my_location, color: kPrimary, size: 20),
                        SizedBox(width: 6),
                        Text(
                          'موقعي الآن',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  if (p != null)
                    _pill(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.gps_fixed,
                            size: 16,
                            color: _accColor(p.accuracy),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '±${p.accuracy.round()} م',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: _accColor(p.accuracy),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          Positioned(
            left: 16,
            bottom: 330,
            child: FloatingActionButton.small(
              heroTag: 'center',
              backgroundColor: Colors.white,
              onPressed: () {
                if (_pos != null) {
                  _map.move(LatLng(_pos!.latitude, _pos!.longitude), 17);
                } else {
                  _start();
                }
              },
              child: const Icon(Icons.my_location, color: kPrimary),
            ),
          ),
          Align(alignment: Alignment.bottomCenter, child: _panel()),
        ],
      ),
    );
  }

  Widget _pill({required Widget child}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(30),
      boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 8)],
    ),
    child: child,
  );

  Widget _panel() {
    final p = _pos;
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 600),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 16)],
      ),
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.black12,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (_error != null)
              ..._errorView()
            else if (p == null)
              ..._loadingView()
            else
              ..._infoView(p),
          ],
        ),
      ),
    );
  }

  List<Widget> _errorView() => [
    const Icon(Icons.location_off, size: 44, color: Color(0xFFDC2626)),
    const SizedBox(height: 8),
    Text(
      _error!,
      textAlign: TextAlign.center,
      style: const TextStyle(fontSize: 15),
    ),
    const SizedBox(height: 14),
    FilledButton.icon(
      onPressed: _start,
      icon: const Icon(Icons.refresh),
      label: const Text('إعادة المحاولة'),
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(50),
        backgroundColor: kPrimary,
      ),
    ),
  ];

  List<Widget> _loadingView() => [
    if (_nativeGps) ...[_gnssBar(), const SizedBox(height: 10)],
    const SizedBox(height: 8),
    const Center(child: CircularProgressIndicator(color: kPrimary)),
    const SizedBox(height: 14),
    const Text(
      'جاري تحديد موقعك بدقة...',
      textAlign: TextAlign.center,
      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
    ),
    const SizedBox(height: 4),
    const Text(
      'للحصول على أفضل دقة، كن في مكان مفتوح',
      textAlign: TextAlign.center,
      style: TextStyle(color: Colors.black54),
    ),
    const SizedBox(height: 16),
  ];

  List<Widget> _infoView(Position p) => [
    Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: _accColor(p.accuracy).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            '${_accLabel(p.accuracy)} • ±${p.accuracy.round()} متر',
            style: TextStyle(
              color: _accColor(p.accuracy),
              fontWeight: FontWeight.bold,
              fontSize: 12.5,
            ),
          ),
        ),
        const Spacer(),
        if (_searching)
          const Row(
            children: [
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 6),
              Text('يحسّن الدقة', style: TextStyle(fontSize: 12)),
            ],
          ),
      ],
    ),
    if (_nativeGps) ...[const SizedBox(height: 10), _gnssBar()],
    if (p.isMocked)
      const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Text(
          '⚠️ تنبيه: الموقع صادر من تطبيق موقع وهمي (Mock)',
          style: TextStyle(color: Color(0xFFDC2626), fontSize: 12.5),
        ),
      ),
    const SizedBox(height: 12),
    InkWell(
      onTap: _address == null ? null : () => _copy(_address!, 'العنوان'),
      borderRadius: BorderRadius.circular(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.place, color: kPrimary, size: 26),
          const SizedBox(width: 8),
          Expanded(
            child: _address == null
                ? Text(
                    _loadingAddress
                        ? 'جاري جلب العنوان...'
                        : 'العنوان غير متاح',
                    style: const TextStyle(color: Colors.black54, fontSize: 15),
                  )
                : Text(
                    _address!,
                    style: const TextStyle(
                      fontSize: 16.5,
                      fontWeight: FontWeight.w700,
                      height: 1.4,
                    ),
                  ),
          ),
        ],
      ),
    ),
    const SizedBox(height: 10),
    Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F4),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.explore_outlined, size: 18, color: Colors.black54),
          const SizedBox(width: 8),
          Expanded(
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Text(
                _coords,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: 'نسخ الإحداثيات',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.copy, size: 18),
            onPressed: () => _copy(_coords, 'الإحداثيات'),
          ),
        ],
      ),
    ),
    const SizedBox(height: 14),
    SizedBox(
      height: 52,
      child: FilledButton.icon(
        onPressed: _whatsapp,
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF25D366),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        icon: const Icon(Icons.chat, color: Colors.white),
        label: const Text(
          'إرسال عبر واتساب',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
      ),
    ),
    const SizedBox(height: 10),
    Row(
      children: [
        Expanded(child: _smallBtn(Icons.share, 'مشاركة', _share)),
        const SizedBox(width: 8),
        Expanded(
          child: _smallBtn(
            Icons.link,
            'نسخ الرابط',
            () => _copy(_mapsLink, 'الرابط'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(child: _smallBtn(Icons.map, 'فتح بالخرائط', _openMaps)),
      ],
    ),
  ];

  Widget _gnssBar() {
    final good = _satUsed >= 8;
    final c = _satUsed == 0
        ? const Color(0xFFDC2626)
        : good
        ? const Color(0xFF16A34A)
        : const Color(0xFFF59E0B);
    final names = _constellations.entries
        .where((e) => e.value.length > 1 && e.value[1] > 0)
        .map((e) => '${e.key} ${e.value[1]}')
        .join(' • ');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.satellite_alt, size: 18, color: c),
              const SizedBox(width: 6),
              Text(
                'GPS الهاتف • أقمار مستخدمة $_satUsed من $_satVisible',
                style: TextStyle(
                  color: c,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              const Spacer(),
              if (_avgCn0 > 0)
                Text(
                  '${_avgCn0.toStringAsFixed(0)} dB-Hz',
                  style: const TextStyle(fontSize: 11.5, color: Colors.black54),
                ),
            ],
          ),
          if (names.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Directionality(
                textDirection: TextDirection.ltr,
                child: Text(
                  names,
                  style: const TextStyle(fontSize: 11.5, color: Colors.black54),
                ),
              ),
            ),
          if (_samples.length > 1)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(
                'متوسط ${_samples.length} قراءة (ثبّت الجوال لدقة أعلى)'
                '${_raw != null ? ' • آخر قراءة ±${_raw!.accuracy.toStringAsFixed(1)}م' : ''}',
                style: const TextStyle(fontSize: 11.5, color: Colors.black54),
              ),
            ),
          if (_satUsed == 0)
            const Padding(
              padding: EdgeInsets.only(top: 3),
              child: Text(
                'يبحث عن الأقمار... اطلع لمكان مفتوح بعيداً عن السقف',
                style: TextStyle(fontSize: 11.5),
              ),
            ),
        ],
      ),
    );
  }

  Widget _smallBtn(IconData icon, String label, VoidCallback onTap) =>
      OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(vertical: 10),
          foregroundColor: kPrimary,
          side: const BorderSide(color: Color(0xFFCFE3DC)),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      );
}
