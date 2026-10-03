# ARCHITECTURE — البنية وتدفق البيانات

## 1. نظرة عامة
```
┌──────────────────────── Android (Kotlin, MainActivity.kt) ────────────────────────┐
│  Google FusedLocationProviderClient  ── PRIORITY_HIGH_ACCURACY, 1000ms ─┐          │
│  LocationManager.GPS_PROVIDER (raw)  ── 0ms / 0m ───────────────────────┤ "fix"    │
│  GnssStatus.Callback                  ── satellites ────────────────────┤ "gnss"   │
│  FusedOrientationProviderClient (Google) ─┐                             │          │
│      fallback: TYPE_ROTATION_VECTOR + GeomagneticField declination ─────┤ "heading"│
│  TYPE_ACCELEROMETER (~50Hz) → step detector (onAccel) ──────────────────┤ "step"   │
│                                                                         ▼          │
│                       EventChannel "mawqi/stream"  (Map messages)                  │
│  MethodChannel "mawqi/native": isGpsEnabled, appVersion, sensorInfo, installApk    │
└────────────────────────────────────────┬──────────────────────────────────────────┘
                                         ▼
┌──────────────────────────── Dart (Flutter) ───────────────────────────────────────┐
│ lib/main.dart  _onEvent → _onFix / addStep → FusionEngine → _afterUpdate → UI     │
│ lib/engine/fusion.dart   FusionEngine (Kalman 2D + PDR + calibration)  [pure Dart]│
│ lib/services/points.dart Store (shared_preferences: points + calibration)         │
│ lib/services/updater.dart Updater (GitHub Releases → download → installApk)       │
│ Nominatim reverse geocoding (http)    flutter_map + OSM tiles                     │
└───────────────────────────────────────────────────────────────────────────────────┘
```
على **الويب** (معاينة فقط): لا توجد قنوات أصلية؛ يُستخدم `Geolocator.getPositionStream` ويُمرَّر كـ `Fix(source:'web')`.
لا PDR ولا أقمار ولا تحديث تلقائي على الويب.

## 2. الملفات
| الملف | السطور تقريباً | الدور |
|---|---|---|
| `lib/main.dart` | ~1450 | الواجهة كاملة + منطق الشاشة (StatefulWidget واحد `LocationScreen`) |
| `lib/engine/fusion.dart` | ~340 | محرك الدمج، Dart خالص بدون Flutter، قابل للاختبار |
| `lib/services/points.dart` | ~115 | نموذج `SavedPoint` + `Store` للحفظ |
| `lib/services/updater.dart` | ~125 | المحدّث التلقائي |
| `android/app/src/main/kotlin/com/mawqianow/location/MainActivity.kt` | ~420 | المحرك الأصلي (حساسات/مواقع/تثبيت APK) |
| `android/app/src/main/AndroidManifest.xml` | — | الصلاحيات، queries، FileProvider للتحديث |
| `android/app/src/main/res/xml/update_paths.xml` | — | `cache-path name=updates path=updates/` |
| `android/app/build.gradle.kts` | — | التوقيع release، R8، packaging excludes، تبعيات أصلية |
| `android/app/proguard-rules.pro` | — | keep rules (Flutter, geolocator, gms.location, FileProvider, التطبيق) |
| `android/gradle.properties` | — | ذاكرة Gradle (`-Xmx3G`, workers=2) |
| `signing/` | — | مفتاح التوقيع المشفّر + سكربت الاستعادة |
| `test/` | — | اختبارات المحرك والمحدّث |

## 3. بروتوكول القناة `mawqi/stream` (Kotlin → Dart)
كل رسالة `Map` فيها `type`:

### `type: "fix"` — قراءة موقع
| الحقل | النوع | الوصف |
|---|---|---|
| `source` | String | `"fused"` (Google) أو `"gps"` (شريحة GNSS خام) |
| `lat`, `lng` | double | درجات WGS84 |
| `acc` | double | نصف قطر الدقة الأفقية بالمتر (**68٪**، تعريف أندرويد). إن لم يتوفر = 50 |
| `alt` | double? | الارتفاع |
| `speed` | double? | م/ث |
| `time` | long | ms epoch (من الجهاز) |
| `cached` | bool | `true` = lastLocation قديم؛ **Dart يتجاهله** (حتى لا يُثبَّت على موقع قديم) |
| `mock` | bool | موقع وهمي (`Location.isMock` / `isFromMockProvider`) |

### `type: "gnss"` — حالة الأقمار
`visible` (int)، `used` (int، المستخدمة في الحل)، `avgCn0` (dB-Hz لمتوسط المستخدمة)،
`constellations`: `Map<String, [visible, used]>` لـ GPS/GLONASS/Galileo/BeiDou/QZSS/SBAS/Other.

### `type: "heading"` — الاتجاه (كل ≥200ms)
`deg` (0–360 شمال حقيقي)، `err` (خطأ تقديري بالدرجات)، `src` = `"google"` | `"rotation_vector"`.

### `type: "step"` — خطوة مكتشفة
| الحقل | الوصف |
|---|---|
| `w` | حد Weinberg = `Δa^(1/4)` (Δ = قمة − قاع للتسارع الرأسي المنعّم، m/s²) |
| `delta` | Δ نفسه |
| `dt` | زمن منذ الخطوة السابقة (ث)، 0 لأول خطوة |
| `heading` | متوسط دائري للاتجاه خلال الخطوة (درجات) |
| `headingErr` | خطأ الاتجاه الحالي |
| `headingSrc` | مصدر الاتجاه |
| `count` | عدّاد الخطوات منذ بدء البث |

### `type: "disabled"` — المستخدم أطفأ GPS.
### أخطاء البث: `GPS_DISABLED`, `NO_PERMISSION`, `ERROR`.

## 4. القناة `mawqi/native` (Dart → Kotlin)
| الطريقة | المعاملات | النتيجة |
|---|---|---|
| `isGpsEnabled` | — | bool |
| `appVersion` | — | versionName (مثلاً `"1.2.0"`) |
| `sensorInfo` | — | Map: accelerometer/gyroscope/magnetometer/rotationVector → bool |
| `installApk` | `path` | `"ok"` \| `"need_permission"` (فتح إعداد "تثبيت تطبيقات غير معروفة") \| `"missing"` |

`installApk` يستخدم `FileProvider` بسلطة `${applicationId}.updates`، والملف يجب أن يكون في `cacheDir/updates/`.

## 5. تدفق Dart
1. `initState` → `_loadState()` (معايرة + نقاط + الإصدار) → `_start()` → `_checkUpdate(silent:true)`.
2. `_start()`: فحص خدمة الموقع → الصلاحية → **رفض "الموقع التقريبي"** (`LocationAccuracyStatus.reduced`) وفتح الإعدادات → `_eng.start()` → الاشتراك في `mawqi/stream`.
3. `_onEvent` يوزّع: `fix` → `_onFix` → `FusionEngine.addFix`؛ `step` → `addStep`؛ `gnss`/`heading` → حالة الواجهة.
4. `_afterUpdate`: يرسم المسار (`_trail`، نقطة كل >0.5م، حد 2000)، يحرّك الخريطة إن كان `_follow`، ويجلب العنوان إن تحرّك >40م.
5. عند انتقال `acquiring → tracking`: اهتزاز + مسح المسار.
6. المعايرة تُحفظ في `shared_preferences` كلما زاد `calibrations`.

## 6. الواجهة
- **الشريط العلوي**: الاسم | زر **تحديث** (برتقالي + رقم الإصدار إن وُجد تحديث، نسبة التنزيل أثناء التحميل) | قائمة النقاط (العدد) | الإعدادات.
- **الخريطة**: OSM، المسار الأزرق، دائرة الدقة، نقطة المستخدم مع مخروط الاتجاه (`_UserDot`/`_Cone`)، علامات النقاط المحفوظة.
- **اللوحة السفلية**: بطاقة المرحلة (`_phaseCard`)، العنوان، الإحداثيات (7 خانات)، أزرار «تحديد النقطة» و«لقطة + نقطة»، ثم واتساب/مشاركة/نسخ الرابط/الخرائط.
- **الإعدادات**: وضع التتبع (دمج / حساسات فقط)، قيم المعايرة وإعادة ضبطها، الإصدار وفحص التحديث.
- ألوان الدقة: ≤5م أخضر، ≤15م أخضر فاتح، ≤50م برتقالي، غير ذلك أحمر.

## 7. التخزين (`shared_preferences`)
| المفتاح | المحتوى |
|---|---|
| `points_v1` | JSON لقائمة `SavedPoint` (id, lat, lng, acc, method, time, photo, address, steps, walked, name) |
| `step_k` | معامل Weinberg K (افتراضي 0.5) |
| `heading_bias` | انحياز البوصلة بالدرجات (افتراضي 0) |
| `calibrations` | عدد المعايرات الناجحة |
| `fusion_mode` | `hybrid` \| `sensors` |
الصور تُنسخ إلى `ApplicationDocumentsDirectory/photos/<ms>.jpg`.

## 8. الصلاحيات (Manifest)
`INTERNET`, `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`, `REQUEST_INSTALL_PACKAGES`.
Features غير إلزامية: `location.gps`, `camera`, `sensor.accelerometer`, `sensor.compass`.
`<queries>`: VIEW https / geo، `IMAGE_CAPTURE`، PROCESS_TEXT.

## 9. التبعيات (المُثبّتة فعلياً حسب `pubspec.lock`)
| الحزمة | الإصدار | الاستخدام |
|---|---|---|
| geolocator | 14.0.2 (android 5.1.1+1) | الصلاحيات + الويب فقط (القراءة على أندرويد أصلية) |
| flutter_map | 8.3.2 | الخريطة |
| latlong2 | 0.9.1 | `LatLng`, `Distance` (مستورد مع `hide Path`) |
| http | 1.6.0 | Nominatim + GitHub API + تنزيل APK |
| share_plus | 11.1.0 | المشاركة (نص + صورة) |
| url_launcher | 6.3.2 | wa.me + Google Maps |
| image_picker | 1.2.2 | الكاميرا |
| path_provider | 2.1.5 | مجلدات الصور والتحديث |
| shared_preferences | 2.5.5 | التخزين |
أصلية (Gradle): `com.google.android.gms:play-services-location:21.2.0`، `androidx.core:core-ktx:1.13.1`.
