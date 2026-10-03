import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart' hide Path;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'engine/fusion.dart';
import 'services/points.dart';
import 'services/updater.dart';

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
  static const _stream = EventChannel('mawqi/stream');
  bool get _android =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  final MapController _map = MapController();
  final FusionEngine _eng = FusionEngine();
  StreamSubscription<dynamic>? _sub;
  StreamSubscription<Position>? _webSub;
  Timer? _tick;

  String? _error;
  String? _address;
  bool _loadingAddress = false;
  LatLng? _lastGeocoded;
  bool _mapReady = false;
  bool _follow = true;

  // live sensor info
  int _satUsed = 0, _satVisible = 0;
  double _cn0 = 0;
  Map<String, List<int>> _consts = {};
  double? _heading;
  double _headingErr = 0;
  String _headingSrc = '';
  final List<LatLng> _trail = [];

  List<SavedPoint> _points = [];

  // updater
  UpdateInfo? _update;
  double? _updProgress;
  String _version = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _loadState();
      _start();
      _checkUpdate(silent: true);
    });
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _eng.phase == Phase.acquiring) setState(() {});
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _webSub?.cancel();
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _loadState() async {
    final (k, b, c, m) = await Store.loadCalibration();
    _eng.stepK = k;
    _eng.headingBiasDeg = b;
    _eng.calibrations = c;
    _eng.mode = m == 'sensors' ? FusionMode.sensors : FusionMode.hybrid;
    _points = await Store.loadPoints();
    _version = await Updater.currentVersion();
    if (mounted) setState(() {});
  }

  void _saveCal() => Store.saveCalibration(
    _eng.stepK,
    _eng.headingBiasDeg,
    _eng.calibrations,
    _eng.mode == FusionMode.sensors ? 'sensors' : 'hybrid',
  );

  // ---------------------------------------------------------------- start
  Future<void> _start() async {
    setState(() => _error = null);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        setState(
          () => _error = 'خدمة الموقع مقفلة. فعّلها ثم اضغط "إعادة المحاولة".',
        );
        if (!kIsWeb) await Geolocator.openLocationSettings();
        return;
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied) {
        setState(() => _error = 'لازم تسمح للتطبيق بالوصول إلى الموقع.');
        return;
      }
      if (perm == LocationPermission.deniedForever) {
        setState(
          () => _error =
              'صلاحية الموقع مرفوضة نهائياً. افتح الإعدادات واسمح بها.',
        );
        if (!kIsWeb) await Geolocator.openAppSettings();
        return;
      }
      if (_android) {
        final acc = await Geolocator.getLocationAccuracy();
        if (acc == LocationAccuracyStatus.reduced && mounted) {
          setState(
            () => _error =
                'التطبيق مسموح له بالموقع "التقريبي" فقط. افتح الإعدادات واختر "الموقع الدقيق".',
          );
          await Geolocator.openAppSettings();
          return;
        }
      }
      await _sub?.cancel();
      await _webSub?.cancel();
      _eng.start(DateTime.now());
      if (_android) {
        _sub = _stream.receiveBroadcastStream().listen(
          _onEvent,
          onError: _onStreamError,
        );
      } else {
        _webSub =
            Geolocator.getPositionStream(
              locationSettings: const LocationSettings(
                accuracy: LocationAccuracy.best,
                distanceFilter: 0,
              ),
            ).listen(
              (p) => _onFix(
                Fix(
                  lat: p.latitude,
                  lng: p.longitude,
                  acc: p.accuracy,
                  source: 'web',
                  time: DateTime.now(),
                ),
              ),
              onError: _onStreamError,
            );
      }
    } catch (e) {
      setState(() => _error = 'حدث خطأ: $e');
    }
  }

  void _onStreamError(Object e) {
    if (!mounted) return;
    final code = e is PlatformException ? e.code : '';
    setState(() {
      _error = code == 'GPS_DISABLED'
          ? 'الموقع مقفل. فعّله من الإعدادات ثم اضغط "إعادة المحاولة".'
          : 'تعذر تحديد الموقع: $e';
    });
    if (code == 'GPS_DISABLED') Geolocator.openLocationSettings();
  }

  void _onEvent(dynamic e) {
    final m = Map<String, dynamic>.from(e as Map);
    switch (m['type']) {
      case 'fix':
        if (m['cached'] == true) return; // never seed with stale cache
        _onFix(
          Fix(
            lat: (m['lat'] as num).toDouble(),
            lng: (m['lng'] as num).toDouble(),
            acc: (m['acc'] as num?)?.toDouble() ?? 50,
            source: m['source'] as String? ?? 'gps',
            time: DateTime.now(),
            mock: m['mock'] == true,
            speed: (m['speed'] as num?)?.toDouble(),
          ),
        );
      case 'gnss':
        setState(() {
          _satVisible = (m['visible'] as num?)?.toInt() ?? 0;
          _satUsed = (m['used'] as num?)?.toInt() ?? 0;
          _cn0 = (m['avgCn0'] as num?)?.toDouble() ?? 0;
          _consts = (m['constellations'] as Map? ?? {}).map(
            (k, v) => MapEntry(
              k as String,
              (v as List).map((x) => (x as num).toInt()).toList(),
            ),
          );
        });
      case 'heading':
        setState(() {
          _heading = (m['deg'] as num).toDouble();
          _headingErr = (m['err'] as num?)?.toDouble() ?? 0;
          _headingSrc = m['src'] as String? ?? '';
        });
      case 'step':
        final wasCal = _eng.calibrations;
        _eng.addStep(
          StepEvent(
            (m['w'] as num).toDouble(),
            (m['heading'] as num).toDouble(),
            (m['headingErr'] as num?)?.toDouble() ?? 15,
          ),
        );
        if (_eng.calibrations != wasCal) _saveCal();
        _afterUpdate();
      case 'disabled':
        setState(
          () => _error = 'تم إيقاف GPS. فعّله ثم اضغط "إعادة المحاولة".',
        );
    }
  }

  void _onFix(Fix f) {
    final wasCal = _eng.calibrations;
    final wasPhase = _eng.phase;
    _eng.addFix(f);
    if (_eng.calibrations != wasCal) _saveCal();
    if (wasPhase == Phase.acquiring && _eng.phase == Phase.tracking) {
      HapticFeedback.mediumImpact();
      _trail.clear();
    }
    _afterUpdate();
  }

  void _afterUpdate() {
    if (!mounted || !_eng.hasPosition) return;
    final p = _eng.position;
    final ll = LatLng(p.lat, p.lng);
    if (_eng.phase == Phase.tracking) {
      if (_trail.isEmpty ||
          const Distance().as(LengthUnit.Meter, _trail.last, ll) > 0.5) {
        _trail.add(ll);
        if (_trail.length > 2000) _trail.removeAt(0);
      }
    }
    setState(() {});
    if (_mapReady && _follow) {
      final z = _map.camera.zoom;
      _map.move(ll, z < 15 ? 18 : z);
    }
    if (_lastGeocoded == null ||
        const Distance().as(LengthUnit.Meter, _lastGeocoded!, ll) > 40) {
      _reverseGeocode(ll);
    }
  }

  // ---------------------------------------------------------------- address
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
                'User-Agent': 'MawqiNow/1.2 (com.mawqianow.location)',
            },
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode == 200) {
        _address = _formatAddress(jsonDecode(utf8.decode(res.bodyBytes)));
      }
    } catch (_) {
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
    return parts.isEmpty ? data['display_name'] as String? : parts.join('، ');
  }

  // ---------------------------------------------------------------- helpers
  String get _method {
    if (_eng.phase != Phase.tracking) return 'gnss';
    return _eng.mode == FusionMode.sensors ? 'sensors' : 'hybrid';
  }

  String _methodLabel(String m) => switch (m) {
    'sensors' => 'حساسات الهاتف (PDR)',
    'hybrid' => 'دمج GPS + حساسات',
    _ => 'GPS + Google Fused',
  };

  String _coordsOf(double lat, double lng) =>
      '${lat.toStringAsFixed(7)}, ${lng.toStringAsFixed(7)}';

  String _linkOf(double lat, double lng) =>
      'https://maps.google.com/?q=${lat.toStringAsFixed(7)},${lng.toStringAsFixed(7)}';

  String _shareTextOf({
    required double lat,
    required double lng,
    required double acc,
    String? address,
    String title = '📍 موقعي الحالي',
  }) {
    final b = StringBuffer('$title\n');
    if (address != null) b.writeln(address);
    b.writeln('الإحداثيات: ${_coordsOf(lat, lng)}');
    b.writeln('الدقة: ±${acc.toStringAsFixed(1)} متر');
    b.write(_linkOf(lat, lng));
    return b.toString();
  }

  String get _shareText {
    final p = _eng.position;
    return _shareTextOf(
      lat: p.lat,
      lng: p.lng,
      acc: _eng.accuracy,
      address: _address,
    );
  }

  Future<void> _whatsappText(String text) async {
    final uri = Uri.parse('https://wa.me/?text=${Uri.encodeComponent(text)}');
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      await SharePlus.instance.share(ShareParams(text: text));
    }
  }

  void _copy(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    _snack('تم نسخ $label');
  }

  void _snack(String s) => ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(s),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ),
  );

  Color _accColor(double acc) {
    if (acc <= 5) return const Color(0xFF16A34A);
    if (acc <= 15) return const Color(0xFF65A30D);
    if (acc <= 50) return const Color(0xFFF59E0B);
    return const Color(0xFFDC2626);
  }

  // ---------------------------------------------------------------- capture
  Future<void> _capture({required bool withPhoto}) async {
    if (!_eng.hasPosition) return;
    // freeze the position at the moment of the press
    final p = _eng.position;
    final acc = _eng.accuracy;
    final method = _method;
    final steps = _eng.steps;
    final walked = _eng.walked;
    String? photo;
    if (withPhoto) {
      try {
        final x = await ImagePicker().pickImage(
          source: ImageSource.camera,
          imageQuality: 80,
          maxWidth: 1920,
        );
        if (x == null) return;
        if (!kIsWeb) {
          final dir = await getApplicationDocumentsDirectory();
          final pd = Directory('${dir.path}/photos');
          if (!pd.existsSync()) pd.createSync(recursive: true);
          final dest =
              '${pd.path}/${DateTime.now().millisecondsSinceEpoch}.jpg';
          await File(x.path).copy(dest);
          photo = dest;
        }
      } catch (e) {
        _snack('تعذر فتح الكاميرا: $e');
        return;
      }
    }
    final pt = SavedPoint(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      lat: p.lat,
      lng: p.lng,
      acc: acc,
      method: method,
      time: DateTime.now(),
      photoPath: photo,
      address: _address,
      steps: steps,
      walked: walked,
      name: 'نقطة ${_points.length + 1}',
    );
    setState(() => _points.insert(0, pt));
    await Store.savePoints(_points);
    HapticFeedback.heavyImpact();
    if (mounted) _openPoint(pt);
  }

  void _openPoint(SavedPoint pt) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  pt.name,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${_methodLabel(pt.method)} • ±${pt.acc.toStringAsFixed(1)} م'
                  '${pt.steps > 0 ? ' • ${pt.steps} خطوة (${pt.walked.toStringAsFixed(0)} م)' : ''}',
                  style: TextStyle(color: _accColor(pt.acc), fontSize: 13),
                ),
                if (pt.photoPath != null && !kIsWeb) ...[
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Image.file(
                      File(pt.photoPath!),
                      height: 220,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                if (pt.address != null)
                  Text(pt.address!, style: const TextStyle(fontSize: 15)),
                const SizedBox(height: 6),
                Directionality(
                  textDirection: TextDirection.ltr,
                  child: SelectableText(
                    pt.coords,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  '${pt.time.year}/${pt.time.month}/${pt.time.day} '
                  '${pt.time.hour.toString().padLeft(2, '0')}:${pt.time.minute.toString().padLeft(2, '0')}',
                  style: const TextStyle(color: Colors.black54, fontSize: 12),
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF25D366),
                    minimumSize: const Size.fromHeight(48),
                  ),
                  onPressed: () => _whatsappText(
                    _shareTextOf(
                      lat: pt.lat,
                      lng: pt.lng,
                      acc: pt.acc,
                      address: pt.address,
                      title: '📍 ${pt.name}',
                    ),
                  ),
                  icon: const Icon(Icons.chat),
                  label: const Text('إرسال عبر واتساب'),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () {
                          final text = _shareTextOf(
                            lat: pt.lat,
                            lng: pt.lng,
                            acc: pt.acc,
                            address: pt.address,
                            title: '📍 ${pt.name}',
                          );
                          SharePlus.instance.share(
                            ShareParams(
                              text: text,
                              files: pt.photoPath != null && !kIsWeb
                                  ? [XFile(pt.photoPath!)]
                                  : null,
                            ),
                          );
                        },
                        icon: const Icon(Icons.share),
                        label: Text(
                          pt.photoPath != null ? 'مشاركة مع الصورة' : 'مشاركة',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => launchUrl(
                          Uri.parse(pt.mapsLink),
                          mode: LaunchMode.externalApplication,
                        ),
                        icon: const Icon(Icons.map),
                        label: const Text('فتح بالخرائط'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextButton.icon(
                        onPressed: () {
                          Navigator.pop(ctx);
                          _map.move(LatLng(pt.lat, pt.lng), 19);
                          setState(() => _follow = false);
                        },
                        icon: const Icon(Icons.center_focus_strong),
                        label: const Text('عرض على الخريطة'),
                      ),
                    ),
                    Expanded(
                      child: TextButton.icon(
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.red,
                        ),
                        onPressed: () async {
                          Navigator.pop(ctx);
                          setState(
                            () => _points.removeWhere((e) => e.id == pt.id),
                          );
                          await Store.savePoints(_points);
                          if (pt.photoPath != null && !kIsWeb) {
                            try {
                              File(pt.photoPath!).deleteSync();
                            } catch (_) {}
                          }
                        },
                        icon: const Icon(Icons.delete_outline),
                        label: const Text('حذف'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openPointsList() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: _points.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(30),
                  child: Text(
                    'ما في نقاط محفوظة بعد.\nاضغط "تحديد النقطة" أو "لقطة + نقطة".',
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: _points.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final pt = _points[i];
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: _accColor(
                          pt.acc,
                        ).withValues(alpha: 0.15),
                        child: Icon(
                          pt.photoPath != null
                              ? Icons.photo_camera
                              : Icons.place,
                          color: _accColor(pt.acc),
                        ),
                      ),
                      title: Text(pt.name),
                      subtitle: Text(
                        '±${pt.acc.toStringAsFixed(1)} م • ${_methodLabel(pt.method)}',
                      ),
                      onTap: () {
                        Navigator.pop(ctx);
                        _openPoint(pt);
                      },
                    );
                  },
                ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- updates
  Future<void> _checkUpdate({bool silent = false}) async {
    if (!_android) {
      if (!silent) _snack('التحديث التلقائي متاح في تطبيق أندرويد فقط');
      return;
    }
    try {
      final u = await Updater.check();
      if (!mounted) return;
      setState(() => _update = u);
      if (u == null) {
        if (!silent) _snack('عندك آخر إصدار ($_version) ✅');
      } else if (!silent) {
        _runUpdate();
      }
    } catch (e) {
      if (!silent) _snack('تعذر فحص التحديث: $e');
    }
  }

  Future<void> _runUpdate() async {
    final u = _update;
    if (u == null || _updProgress != null) return;
    setState(() => _updProgress = 0);
    try {
      final r = await Updater.downloadAndInstall(u, (p) {
        if (mounted) setState(() => _updProgress = p);
      });
      if (!mounted) return;
      if (r == 'need_permission') {
        _snack('اسمح بـ "تثبيت التطبيقات" لموقعي الآن، ثم ارجع واضغط تحديث');
      } else if (r != 'ok') {
        _snack('فشل التحديث: $r');
      }
    } catch (e) {
      _snack('فشل التنزيل: $e');
    } finally {
      if (mounted) setState(() => _updProgress = null);
    }
  }

  void _openSettings() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Directionality(
          textDirection: TextDirection.rtl,
          child: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'وضع التتبع بعد التثبيت',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<FusionMode>(
                    segments: const [
                      ButtonSegment(
                        value: FusionMode.hybrid,
                        label: Text('دمج (الأدق)'),
                        icon: Icon(Icons.merge_type),
                      ),
                      ButtonSegment(
                        value: FusionMode.sensors,
                        label: Text('حساسات فقط'),
                        icon: Icon(Icons.directions_walk),
                      ),
                    ],
                    selected: {_eng.mode},
                    onSelectionChanged: (s) {
                      _eng.mode = s.first;
                      _saveCal();
                      setS(() {});
                      setState(() {});
                    },
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _eng.mode == FusionMode.hybrid
                        ? 'الحساسات تحسب كل خطوة، والـ GPS الجيد يصحّح الانحراف ويعاير طول خطوتك واتجاه البوصلة تلقائياً.'
                        : 'بعد التثبيت الأول يعتمد فقط على حساسات الهاتف (الخطوات + الاتجاه). مفيد داخل المباني. الخطأ يتراكم مع المسافة (~2–5٪).',
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: Colors.black54,
                    ),
                  ),
                  const Divider(height: 28),
                  const Text(
                    'المعايرة',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'معامل طول الخطوة K = ${_eng.stepK.toStringAsFixed(3)}\n'
                    'تصحيح البوصلة = ${_eng.headingBiasDeg.toStringAsFixed(1)}°\n'
                    'عدد المعايرات التلقائية = ${_eng.calibrations}',
                    style: const TextStyle(fontSize: 13.5, height: 1.6),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'تتعاير تلقائياً لما تمشي في خط مستقيم 30م+ والـ GPS دقيق (≤8م) في وضع الدمج.',
                    style: TextStyle(fontSize: 12, color: Colors.black54),
                  ),
                  TextButton(
                    onPressed: () {
                      _eng.stepK = 0.5;
                      _eng.headingBiasDeg = 0;
                      _eng.calibrations = 0;
                      _saveCal();
                      setS(() {});
                    },
                    child: const Text('إعادة ضبط المعايرة'),
                  ),
                  const Divider(height: 20),
                  Row(
                    children: [
                      const Icon(Icons.system_update, color: kPrimary),
                      const SizedBox(width: 8),
                      Expanded(child: Text('الإصدار الحالي: $_version')),
                      FilledButton(
                        onPressed: () {
                          Navigator.pop(ctx);
                          _checkUpdate();
                        },
                        child: const Text('فحص التحديث'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- UI
  @override
  Widget build(BuildContext context) {
    final has = _eng.hasPosition;
    final pos = has ? _eng.position : null;
    final ll = pos == null
        ? const LatLng(15.3694, 44.1910)
        : LatLng(pos.lat, pos.lng);
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: FlutterMap(
              mapController: _map,
              options: MapOptions(
                initialCenter: ll,
                initialZoom: has ? 18 : 5,
                maxZoom: 20,
                onMapReady: () => _mapReady = true,
                onPositionChanged: (_, gesture) {
                  if (gesture && _follow) setState(() => _follow = false);
                },
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.mawqianow.location',
                  maxNativeZoom: 19,
                ),
                if (_trail.length > 1)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: _trail,
                        strokeWidth: 4,
                        color: const Color(0xFF2563EB).withValues(alpha: 0.7),
                      ),
                    ],
                  ),
                if (has)
                  CircleLayer(
                    circles: [
                      CircleMarker(
                        point: ll,
                        radius: _eng.accuracy,
                        useRadiusInMeter: true,
                        color: kPrimary.withValues(alpha: 0.15),
                        borderColor: kPrimary.withValues(alpha: 0.5),
                        borderStrokeWidth: 1.5,
                      ),
                    ],
                  ),
                MarkerLayer(
                  markers: [
                    for (final pt in _points)
                      Marker(
                        point: LatLng(pt.lat, pt.lng),
                        width: 30,
                        height: 30,
                        child: GestureDetector(
                          onTap: () => _openPoint(pt),
                          child: Icon(
                            pt.photoPath != null
                                ? Icons.photo_camera
                                : Icons.location_on,
                            color: const Color(0xFFDC2626),
                            size: 28,
                          ),
                        ),
                      ),
                    if (has)
                      Marker(
                        point: ll,
                        width: 60,
                        height: 60,
                        child: _UserDot(heading: _heading),
                      ),
                  ],
                ),
              ],
            ),
          ),
          SafeArea(child: _topBar()),
          Positioned(
            left: 14,
            bottom: 380,
            child: FloatingActionButton.small(
              heroTag: 'follow',
              backgroundColor: _follow ? kPrimary : Colors.white,
              onPressed: () {
                setState(() => _follow = true);
                if (has) _map.move(ll, math.max(_map.camera.zoom, 18));
              },
              child: Icon(
                Icons.my_location,
                color: _follow ? Colors.white : kPrimary,
              ),
            ),
          ),
          Align(alignment: Alignment.bottomCenter, child: _panel()),
        ],
      ),
    );
  }

  Widget _pill({required Widget child, VoidCallback? onTap, Color? color}) =>
      Material(
        color: color ?? Colors.white,
        borderRadius: BorderRadius.circular(30),
        elevation: 3,
        shadowColor: Colors.black26,
        child: InkWell(
          borderRadius: BorderRadius.circular(30),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: child,
          ),
        ),
      );

  Widget _topBar() {
    final updating = _updProgress != null;
    final hasUpd = _update != null;
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Row(
        children: [
          _pill(
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.my_location, color: kPrimary, size: 19),
                SizedBox(width: 5),
                Text(
                  'موقعي الآن',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                ),
              ],
            ),
          ),
          const Spacer(),
          // auto-update button
          _pill(
            color: hasUpd ? const Color(0xFFF59E0B) : null,
            onTap: updating
                ? null
                : (hasUpd ? _runUpdate : () => _checkUpdate()),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                updating
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          value: _updProgress == 0 ? null : _updProgress,
                        ),
                      )
                    : Icon(
                        Icons.system_update,
                        size: 19,
                        color: hasUpd ? Colors.white : kPrimary,
                      ),
                const SizedBox(width: 5),
                Text(
                  updating
                      ? '${((_updProgress ?? 0) * 100).round()}%'
                      : hasUpd
                      ? 'تحديث ${_update!.version}'
                      : 'تحديث',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: hasUpd ? Colors.white : Colors.black87,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          _pill(
            onTap: _openPointsList,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.bookmarks_outlined, size: 19, color: kPrimary),
                if (_points.isNotEmpty) ...[
                  const SizedBox(width: 4),
                  Text(
                    '${_points.length}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 6),
          _pill(
            onTap: _openSettings,
            child: const Icon(Icons.tune, size: 19, color: kPrimary),
          ),
        ],
      ),
    );
  }

  Widget _panel() {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 600),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
        boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 16)],
      ),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
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
            const SizedBox(height: 10),
            if (_error != null)
              ..._errorView()
            else ...[
              _phaseCard(),
              if (_eng.hasPosition) ..._infoView(),
            ],
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

  /// Phase card: acquiring (progress to lock) or tracking (steps/heading).
  Widget _phaseCard() {
    final acq = _eng.phase != Phase.tracking;
    final acc = _eng.accuracy;
    final c = _eng.hasPosition ? _accColor(acc) : Colors.black45;
    final secs = _eng.acquiringFor(DateTime.now()).inSeconds;
    final names = _consts.entries
        .where((e) => e.value.length > 1 && e.value[1] > 0)
        .map((e) => '${e.key} ${e.value[1]}')
        .join(' • ');
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: c.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                acq
                    ? Icons.satellite_alt
                    : (_eng.mode == FusionMode.sensors
                          ? Icons.directions_walk
                          : Icons.merge_type),
                color: c,
                size: 20,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  acq
                      ? 'المرحلة 1: تثبيت دقيق (GPS + Google) • $secs ث'
                      : 'المرحلة 2: ${_methodLabel(_method)}',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: c,
                    fontSize: 13.5,
                  ),
                ),
              ),
              if (_eng.hasPosition)
                Text(
                  '±${acc.toStringAsFixed(1)} م',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: c,
                    fontSize: 15,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          if (acq) ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                minHeight: 6,
                value: !_eng.hasPosition
                    ? null
                    : (_eng.lockTargetAcc / acc).clamp(0.05, 1.0),
                color: c,
                backgroundColor: c.withValues(alpha: 0.12),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              !_eng.hasPosition
                  ? 'يبحث عن الأقمار... اطلع لمكان مفتوح وثبّت الجوال'
                  : 'ثبّت الجوال • ${_eng.acqSamples} قراءة • أفضل قراءة ±${_eng.bestFixAcc.toStringAsFixed(1)}م • الهدف ±${_eng.lockTargetAcc.toStringAsFixed(0)}م',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
            if (_eng.hasPosition && secs >= 8)
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton(
                  onPressed: () => setState(_eng.forceLock),
                  child: const Text('ثبّت الآن وابدأ التتبع'),
                ),
              ),
          ] else ...[
            Row(
              children: [
                _stat(Icons.directions_walk, '${_eng.steps}', 'خطوة'),
                _stat(Icons.straighten, _eng.walked.toStringAsFixed(1), 'متر'),
                _stat(
                  Icons.explore,
                  _heading == null ? '—' : '${_heading!.round()}°',
                  _headingSrc == 'google' ? 'Google' : 'بوصلة',
                ),
                _stat(Icons.adjust, '±${_headingErr.round()}°', 'خطأ الاتجاه'),
              ],
            ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton.icon(
                onPressed: () {
                  _trail.clear();
                  setState(() => _eng.relock(DateTime.now()));
                },
                icon: const Icon(Icons.gps_fixed, size: 16),
                label: const Text('إعادة التثبيت بالـ GPS'),
              ),
            ),
          ],
          if (_android)
            Text(
              'أقمار: $_satUsed/$_satVisible'
              '${_cn0 > 0 ? ' • ${_cn0.toStringAsFixed(0)} dB-Hz' : ''}'
              '${names.isNotEmpty ? ' • $names' : ''}',
              textDirection: TextDirection.ltr,
              style: const TextStyle(fontSize: 11, color: Colors.black54),
            ),
          if (_eng.mockDetected)
            const Text(
              '⚠️ تم رصد موقع وهمي (Mock) — النتيجة غير موثوقة',
              style: TextStyle(color: Color(0xFFDC2626), fontSize: 12),
            ),
        ],
      ),
    );
  }

  Widget _stat(IconData i, String v, String l) => Expanded(
    child: Column(
      children: [
        Icon(i, size: 18, color: kPrimary),
        Text(v, style: const TextStyle(fontWeight: FontWeight.bold)),
        Text(l, style: const TextStyle(fontSize: 10.5, color: Colors.black54)),
      ],
    ),
  );

  List<Widget> _infoView() {
    final p = _eng.position;
    final coords = _coordsOf(p.lat, p.lng);
    return [
      const SizedBox(height: 10),
      InkWell(
        onTap: _address == null ? null : () => _copy(_address!, 'العنوان'),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.place, color: kPrimary, size: 22),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                _address ??
                    (_loadingAddress
                        ? 'جاري جلب العنوان...'
                        : 'العنوان غير متاح'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: _address == null
                      ? FontWeight.normal
                      : FontWeight.w700,
                  color: _address == null ? Colors.black54 : Colors.black87,
                ),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 6),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: const Color(0xFFF1F5F4),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                coords,
                textDirection: TextDirection.ltr,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () => _copy(coords, 'الإحداثيات'),
            ),
          ],
        ),
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 52,
              child: FilledButton.icon(
                onPressed: () => _capture(withPhoto: false),
                style: FilledButton.styleFrom(
                  backgroundColor: kPrimary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                icon: const Icon(Icons.add_location_alt),
                label: const Text(
                  'تحديد النقطة',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SizedBox(
              height: 52,
              child: FilledButton.icon(
                onPressed: () => _capture(withPhoto: true),
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF2563EB),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                icon: const Icon(Icons.photo_camera),
                label: const Text(
                  'لقطة + نقطة',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      Row(
        children: [
          Expanded(
            child: _smallBtn(
              Icons.chat,
              'واتساب',
              () => _whatsappText(_shareText),
              color: const Color(0xFF128C7E),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _smallBtn(
              Icons.share,
              'مشاركة',
              () => SharePlus.instance.share(ShareParams(text: _shareText)),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _smallBtn(
              Icons.link,
              'نسخ الرابط',
              () => _copy(_linkOf(p.lat, p.lng), 'الرابط'),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _smallBtn(
              Icons.map,
              'الخرائط',
              () => launchUrl(
                Uri.parse(_linkOf(p.lat, p.lng)),
                mode: LaunchMode.externalApplication,
              ),
            ),
          ),
        ],
      ),
    ];
  }

  Widget _smallBtn(
    IconData icon,
    String label,
    VoidCallback onTap, {
    Color color = kPrimary,
  }) => OutlinedButton(
    onPressed: onTap,
    style: OutlinedButton.styleFrom(
      padding: const EdgeInsets.symmetric(vertical: 8),
      foregroundColor: color,
      side: const BorderSide(color: Color(0xFFCFE3DC)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 19),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
    ),
  );
}

class _UserDot extends StatelessWidget {
  final double? heading;
  const _UserDot({this.heading});

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        if (heading != null)
          Transform.rotate(
            angle: heading! * math.pi / 180,
            child: CustomPaint(size: const Size(60, 60), painter: _Cone()),
          ),
        Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: const Color(0xFF2563EB),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 4),
            boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 6)],
          ),
        ),
      ],
    );
  }
}

class _Cone extends CustomPainter {
  @override
  void paint(Canvas canvas, Size s) {
    final c = Offset(s.width / 2, s.height / 2);
    final path = Path()
      ..moveTo(c.dx, c.dy)
      ..lineTo(c.dx - 13, 2)
      ..quadraticBezierTo(c.dx, -4, c.dx + 13, 2)
      ..close();
    canvas.drawPath(
      path,
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0xFF2563EB).withValues(alpha: 0.55),
            const Color(0xFF2563EB).withValues(alpha: 0.0),
          ],
        ).createShader(Rect.fromCircle(center: c, radius: s.width / 2)),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
