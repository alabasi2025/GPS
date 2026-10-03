# 📍 موقعي الآن — Mawqi Now

تطبيق أندرويد بسيط وسريع **يحدد موقعك بدقة عالية عبر GPS**، يعرض العنوان على خريطة، ويشاركه عبر واتساب أو أي تطبيق برابط خرائط جوجل.

## ⬇️ تحميل التطبيق

**[تحميل مباشر — mawqi-now.apk (7.4 MB)](https://github.com/alabasi2025/GPS/releases/latest/download/mawqi-now.apk)**

```
https://github.com/alabasi2025/GPS/releases/latest/download/mawqi-now.apk
```

| البند | القيمة |
|---|---|
| الإصدار | 1.2.0 (build 3) |
| الحجم | 8.6 MB |
| المعمارية | arm64-v8a فقط (أندرويد 64-بت) |
| Target SDK | 36 |
| اسم الحزمة | `com.mawqianow.location` |
| SHA-1 | `0f0c75bf4888a7b4d873b7efd057b1417af4257a` |
| شهادة التوقيع SHA-256 | `4fc4240df87be9cdb83a830d101055d5095813a9b4c38f403533e6f56c14ae91` |

> إذا كانت لديك نسخة سابقة موقّعة بمفتاح مختلف، احذفها قبل التثبيت. فعّل "السماح بالتثبيت من مصادر غير معروفة" عند الطلب.

---

## 🧭 v1.2.0 — تثبيت دقيق ثم ملاحة بالحساسات (PDR)

**المرحلة 1 – تثبيت دقيق:** يدمج Google Fused Location (GPS + Wi-Fi + أبراج + حساسات) مع قراءات شريحة GNSS الخام عبر **مرشح Kalman ثنائي الأبعاد**، مع رفض القفزات (χ² 99.9٪). يثبّت تلقائياً عند الوصول لـ ±5م (68٪) بعد 5 قراءات على الأقل، أو ±10م بعد 25ث، أو ±25م بعد 60ث. زر «ثبّت الآن» متاح يدوياً.

**المرحلة 2 – الملاحة بالحساسات (Pedestrian Dead Reckoning):**
- **كشف الخطوات:** تسارع رأسي (إسقاط على متجه الجاذبية) + تنعيم + كشف قمم بعتبة تكيفية `Δ ≥ max(1.0, 0.5·mean(Δ آخر 8 خطوات))` وزمن خطوة بين 0.25 و 2.0 ث.
- **طول الخطوة (Weinberg):** `L = K · Δa^(1/4)`، و K **يتعاير تلقائياً** من مقاطع GPS مستقيمة (≥30م، دقة ≤8م).
- **الاتجاه:** Google **Fused Orientation Provider** (شمال حقيقي + تقدير الخطأ بالدرجات)، والاحتياطي Rotation Vector + الانحراف المغناطيسي (GeomagneticField). يتعلّم انحياز البوصلة تلقائياً.
- **الضوضاء:** كل خطوة = تنبؤ Kalman بتباين غير متماثل (طولي 8٪ L، عرضي L·σθ).
- **الأوضاع:** «دمج» (GPS الجيد يصحح الانحراف) أو «حساسات فقط».

**تحديد النقطة / لقطة + نقطة:** يجمّد الموقع لحظة الضغط، ويحفظ الإحداثيات + الدقة + الطريقة + عدد الخطوات + الصورة (اختيارية) + العنوان، مع المشاركة عبر واتساب (مع الصورة).

**التحديث التلقائي:** زر «تحديث» في الأعلى يقرأ `releases/latest` من هذا المستودع، ويقارن الإصدار، وينزّل `mawqi-now.apk`، ويفتح المثبّت (تحديث فوق النسخة، نفس التوقيع).

**الاختبارات (`test/fusion_test.dart`، محاكاة Monte-Carlo):**
| الاختبار | النتيجة |
|---|---|
| التثبيت: الوسيط < 3م مقابل ≈4.7م لقراءة ±6م منفردة (200 تجربة) | ✅ |
| رفض قفزة 80م | ✅ |
| حساسات فقط: مربع 100م، وسيط الخطأ < 5م (<5٪، 100 تجربة) | ✅ |
| معايرة K من 0.40 إلى 0.5±0.05 | ✅ |
| تعلّم انحياز بوصلة 10° (±3°) | ✅ |

> هذه نتائج **محاكاة**. الدقة الفعلية على الجهاز تعتمد على الحساسات وطريقة حمل الجوال (الأفضل: في اليد أمامك).

## 🔐 التوقيع (للتحديث بدون حذف)
انظر [`signing/README.md`](signing/README.md): مفتاح التوقيع مشفّر AES-256 في `signing/signing.tgz.enc`، وكلمة السر **ليست** في المستودع.

## ✨ المزايا

- تحديد الموقع لحظياً بأعلى دقة (`bestForNavigation`) مع تحسين تلقائي للقراءة.
- عرض هامش الخطأ بالمتر مع تلوين (أخضر ≤10م، أخضر فاتح ≤30م، أصفر ≤100م، أحمر >100م) ودائرة دقة على الخريطة.
- العنوان بالعربي (شارع، حي، مدينة، منطقة، دولة).
- الإحداثيات بـ 6 خانات عشرية مع نسخ بلمسة.
- إرسال عبر واتساب / مشاركة عامة / نسخ الرابط / فتح في خرائط جوجل.
- معالجة حالات: GPS مقفل، صلاحية مرفوضة، صلاحية مرفوضة نهائياً (يفتح الإعدادات).

## 🧱 التقنيات

| الحزمة | الإصدار المستخدم | الدور |
|---|---|---|
| Flutter / Dart | 3.35.4 / 3.9.2 | الإطار |
| `geolocator` | 14.0.2 | GPS |
| `flutter_map` | 8.3.2 | خريطة OpenStreetMap (بدون API key) |
| `latlong2` | 0.9.1 | الإحداثيات والمسافات |
| `http` | 1.6.0 | Reverse geocoding عبر Nominatim |
| `share_plus` | 11.1.0 | المشاركة |
| `url_launcher` | 6.3.2 | فتح واتساب (`wa.me`) وخرائط جوجل |

الواجهة: Material 3، اتجاه RTL، الكود كاملاً في `lib/main.dart`.

## ⚙️ آلية الدقة (v1.1.0 — GPS الهاتف الخام)

**أندرويد:** القراءة مباشرة من شريحة GNSS عبر كود Kotlin أصلي في `MainActivity.kt`:
1. `LocationManager.GPS_PROVIDER` فقط — **بدون** Wi-Fi/أبراج/Fused (لا خلط بمصادر تقريبية).
2. `requestLocationUpdates(GPS_PROVIDER, 0ms, 0m)` → كل قراءة تنتجها الشريحة (~1Hz).
3. `GnssStatus.Callback` → عدد الأقمار المرئية/المستخدمة، قوة الإشارة (C/N0 dB-Hz)، والأنظمة: GPS, GLONASS, Galileo, BeiDou, QZSS, SBAS.
4. يُرسل لـ Dart عبر `EventChannel('mawqi/gps')`، و `MethodChannel('mawqi/gps_info')` لفحص توفر/تفعيل GPS.
5. كشف المواقع الوهمية (`Location.isMock`) وعرض تحذير.

**تحسين الدقة في Dart (`lib/main.dart`):**
- **متوسط مرجّح بعكس التباين** (وزن = 1/accuracy²) لآخر حتى 60 قراءة أثناء الثبات → نقطة أدق من أي قراءة منفردة.
- تُقبل في المتوسط القراءات ذات دقة ≤ 50م فقط.
- يُصفَّر المتوسط عند الحركة (سرعة > 1 م/ث) أو قفزة أكبر من `clamp(1.5×accuracy, 8م, 60م)`.
- يُعاد جلب العنوان فقط عند التحرك أكثر من 40م.

**الويب:** يستخدم `geolocator` (Geolocation API للمتصفح).

> نصيحة: للحصول على أعلى دقة (2–5م) كن في مكان مفتوح، ثبّت الجوال 20–30 ثانية حتى يتجمع المتوسط.

نص المشاركة:
```
📍 موقعي الحالي
<العنوان>
الإحداثيات: lat, lng
الدقة: ±N متر
https://maps.google.com/?q=lat,lng
```

## 🤖 إعدادات أندرويد

- الصلاحيات: `INTERNET`, `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`.
- `<uses-feature android.hardware.location.gps required=false>`.
- `<queries>` لمخططي `https` و `geo` (مطلوبة لـ url_launcher على Android 11+).
- `namespace` و `applicationId` و `MainActivity.kt` كلها على `com.mawqianow.location`.
- توقيع release يُقرأ من `android/key.properties` و `android/release-key.jks` (**غير مرفوعين للمستودع** — أنشئ ملفاتك الخاصة).

### `android/key.properties` (مثال)
```properties
storePassword=YOUR_PASSWORD
keyPassword=YOUR_PASSWORD
keyAlias=release
storeFile=../release-key.jks
```
إنشاء المفتاح:
```bash
keytool -genkey -v -keystore android/release-key.jks -keyalg RSA -keysize 2048 -validity 10000 -alias release
```

## 📦 تصغير الحجم (45MB ← 7.4MB)

- بناء arm64 فقط: `--target-platform android-arm64`
- R8: `isMinifyEnabled = true` و `isShrinkResources = true` + `proguard-rules.pro`
- `--obfuscate --split-debug-info` لحذف رموز التنقيح من كود Dart
- استبعاد `META-INF/*.txt`، `LICENSE*`، `NOTICE*`، `kotlin/**`
- إزالة `cupertino_icons` غير المستخدمة + tree-shaking لخط الأيقونات

## 🛠️ البناء

```bash
flutter pub get
flutter analyze

# APK
flutter build apk --release \
  --target-platform android-arm64 \
  --obfuscate --split-debug-info=build/debug-info
# الناتج: build/app/outputs/flutter-apk/app-release.apk

# Web (معاينة)
flutter build web --release
python3 -m http.server 5060 --directory build/web
```

## ✅ التحقق المُنفَّذ

- `flutter analyze` → No issues found
- `apksigner verify` → Verified (v2 scheme)
- `aapt2 dump badging` → `native-code: arm64-v8a`, targetSdk 36, الصلاحيات الثلاث فقط
- `unzip -t` → No errors
- ⚠️ لم يُختبر بعد على جهاز حقيقي.

## 📁 البنية

```
lib/main.dart                       # الواجهة + المتوسط المرجّح + المشاركة
android/app/build.gradle.kts        # التوقيع + R8 + packaging
android/app/proguard-rules.pro      # قواعد R8
android/app/src/main/AndroidManifest.xml
android/app/src/main/kotlin/com/mawqianow/location/MainActivity.kt  # GPS خام + GnssStatus
```

## ⚖️ ملاحظات الاستخدام

- بيانات الخريطة والعنوان من © OpenStreetMap contributors. Nominatim له سياسة استخدام عادل (طلب واحد/ثانية تقريباً) — التطبيق يلتزم بها عبر جلب العنوان فقط عند التحرك 40م+.

## 📜 سجل الإصدارات

- **v1.2.0** — تثبيت Kalman (Fused + GNSS)، ملاحة PDR (خطوات + Weinberg + Google Fused Orientation)، معايرة تلقائية، تحديد نقطة + صورة، تحديث تلقائي من GitHub.
- **v1.1.0** — قراءة GPS الهاتف مباشرة (GPS_PROVIDER)، عرض الأقمار والأنظمة وقوة الإشارة، متوسط مرجّح للقراءات، كشف المواقع الوهمية.
- **v1.0.0** — الإصدار الأول (Fused Location عبر geolocator).
