# ALGORITHMS — الخوارزميات بالتفصيل

كل الثوابت أدناه مطابقة للكود حرفياً. إن غيّرت أي ثابت، حدّث هذا الملف و`docs/HISTORY.md`.

## 0. اصطلاحات
- الحالة: `(x, y)` = شرق/شمال بالمتر من نقطة أصل `origin` (أول قراءة مقبولة)، تحويل محلي مستوٍ:
  `x = Δlng·π/180·R·cos(lat0)`، `y = Δlat·π/180·R`، `R = 6378137`.
- التغاير: `P = [[pxx, pxy],[pxy, pyy]]`.
- دقة أندرويد `acc` = نصف قطر 68٪ لتوزيع غاوسي دائري ⇒ **σ(محور) = acc / 1.515** (`kAcc68`).
- الدقة المعروضة = `1.515 · sqrt((pxx+pyy)/2)`.

## 1. المرحلة 1 — التثبيت (ACQUIRING)
**المصادر:** Google Fused (`PRIORITY_HIGH_ACCURACY`، 1 ث، min 0.5 ث) + GPS الخام (`GPS_PROVIDER`، كل قراءة).
**القبول:** `0 < acc ≤ 100` فقط. القراءات `cached` تُهمَل في Dart.

**تحديث Kalman (موقع ثابت، H = I):**
```
R = (acc/1.515)² · I
(Q الزمني) pxx += 0.02·dt ، pyy += 0.02·dt      dt مقصوص على [0,10] ث
S = P + R ، ν = z − x
d² = νᵀ S⁻¹ ν      ← بوابة χ²(2) عند 99.9٪ = 13.8
K = P S⁻¹ ، x += K ν ، P = (I − K) P
أرضية: pxx,pyy ≥ (0.35·acc/1.515)²
```
- **لماذا Q الزمني والأرضية؟** أخطاء GNSS مترابطة زمنياً (multipath/atmosphere) فليست مستقلة؛ متوسط N قراءة لا يقلّ
  الخطأ بنسبة √N فعلياً. الأرضية تمنع الثقة الزائدة.
- **منع العدّ المزدوج:** Fused و GPS مترابطان؛ تُقبل قراءة واحدة كل ~0.9 ث إلا إذا كانت أدق بـ 20٪ (`acc < 0.8·lastUsedAcc`).
- **رفض القفزات:** إذا `d² > 13.8` (بعد أول قراءتين) تُرفض. إذا رُفضت **4 متتالية** وقراءة GNSS جيدة (`acc ≤ 12`)
  ⇒ اعتبر أن الحالة انحرفت: إعادة ضبط على GNSS.

**شروط التثبيت (`_checkLock`):**
| الشرط | |
|---|---|
| ≥5 قراءات مقبولة و الدقة ≤ **5م** (`lockTargetAcc`) | أو |
| ≥5 قراءات و زمن ≥25 ث و الدقة ≤10م | أو |
| زمن ≥60 ث و الدقة ≤25م | |
زر «ثبّت الآن» (`forceLock`) يظهر بعد 8 ث.

## 2. المرحلة 2 — التتبع بالحساسات (PDR)

### 2.1 كشف الخطوات (Kotlin `onAccel`)
1. حساس التسارع `TYPE_ACCELEROMETER` بـ `SENSOR_DELAY_GAME` (~50Hz).
2. الجاذبية: مرشح تمرير منخفض `g = 0.9·g + 0.1·a`.
3. التسارع الرأسي: `vert = (a − g)·g / |g|` (إسقاط على متجه الجاذبية ⇒ مستقل عن وضعية الجوال).
4. تنعيم: `s = 0.7·s + 0.3·vert`.
5. **قاع**: نقطة صغرى محلية تُحفظ كـ `valley`.
6. **قمة**: نقطة عظمى محلية و `s > 0.3`. الخطوة تُقبل إذا:
   - `Δ = peak − valley ≥ max(1.0, 0.5·mean(Δ لآخر 8 خطوات))` (عتبة تكيفية؛ مستلهمة من Liu 2026: `Δ = T0 + α(σ+μ)`)
   - و الزمن منذ آخر خطوة ≥ 0.25 ث (حد 4 خطوات/ث).
   - تُحسب كخطوة إذا `dt ≤ 2.0` ث (إيقاع صالح) أو كانت الأولى.
7. **الاتجاه لكل خطوة**: متوسط دائري لكل عيّنات الاتجاه منذ الخطوة السابقة: `atan2(Σsin, Σcos)`.
8. بعد توقف >2 ث وهدوء (`|s| < 0.2`): إعادة ضبط القاع.
9. يُرسَل `w = Δ^(1/4)`.

### 2.2 طول الخطوة (Weinberg 2002) — Dart
`L = K · w` ، مقصوص على **[0.25, 1.3] م**. K افتراضي **0.5**، يتعاير تلقائياً (§2.5).

### 2.3 الاتجاه
- **أساسي:** Google `FusedOrientationProviderClient` (play-services-location ≥ 21.2.0)، `OUTPUT_PERIOD_DEFAULT`،
  يعطي `headingDegrees` (شمال حقيقي عند توفر الانحراف) و`headingErrorDegrees` (مقصوص [1,180]).
- **احتياطي:** `TYPE_ROTATION_VECTOR` → `getRotationMatrixFromVector` → `getOrientation` → azimuth + `GeomagneticField.declination`
  (يُحدّث مع كل قراءة موقع). الخطأ من `values[4]` إن توفر وإلا 12°.
- **تصحيح الانحياز المتعلَّم:** `h = heading − headingBiasDeg`.

### 2.4 التنبؤ (Kalman predict لكل خطوة)
```
x += L·sin(h) ، y += L·cos(h)
σ_along = 0.08·L + 0.03     σ_cross = L · rad(clamp(headingErr, 2°, 60°))
Q = Rᵀ diag(σ_along², σ_cross²) R   مع along=(sin h, cos h), cross=(cos h, −sin h)
pxx += qa·sin²h + qc·cos²h ، pyy += qa·cos²h + qc·sin²h ، pxy += (qa−qc)·sin h·cos h
```
⇒ دائرة الدقة تكبر مع المشي بشكل واقعي (أسرع عرضياً عند ضعف الاتجاه).

### 2.5 الأوضاع والمعايرة
| الوضع | سلوك قراءات GNSS بعد التثبيت |
|---|---|
| `hybrid` (افتراضي) | تُقبل فقط إذا `acc ≤ 20م` وتمر ببوابة χ²، وتُصحّح انحراف PDR |
| `sensors` | **تُتجاهل كلياً** — الموقع من الحساسات فقط |

**معايرة تلقائية (`_calibrate`، وضع hybrid فقط، قراءات `acc ≤ 8م`):**
- تُجمع مقاطع بين قراءتين GNSS دقيقتين: مسافة ≥ **30م** و خطوات ≥ **20**.
- استقامة المقطع: `|Σ(sin,cos)|/n ≥ 0.92`.
- `K_obs = dist_GNSS / Σw` مقبول في (0.2, 1.0) ⇒ `K = (1−a)K + a·K_obs`، `a = 0.6` أول مرة ثم 0.3.
- انحياز الاتجاه: `b = bearing_steps − bearing_GNSS` (مطويّ إلى ±180)، يُقبل إذا `|b| < 35°` ⇒ تنعيم بنفس `a`.
- تُحفظ K والانحياز في التخزين.

### 2.6 إعادة التثبيت
زر «إعادة التثبيت بالـ GPS» (`relock`): يحذف الأصل والحالة ويعيد المرحلة 1 (يحتفظ بالمعايرة).

## 3. تحديد النقطة
لحظة الضغط تُجمَّد: `position`, `accuracy`, `method` (gnss | hybrid | sensors), `steps`, `walked`. ثم (اختيارياً) الكاميرا.
الإحداثيات تُعرض/تُشارك بـ **7 خانات عشرية** (~1 سم كتمثيل رقمي — ليست الدقة الفعلية).

## 4. العنوان
Nominatim `/reverse` (`zoom=18`, `accept-language=ar,en`, User-Agent مخصص على أندرويد)، يُعاد الطلب فقط عند تحرك >40م
(سياسة الاستخدام: ≤1 طلب/ث).

## 5. التحديث التلقائي
1. `GET https://api.github.com/repos/alabasi2025/GPS/releases/latest`.
2. `tag_name` بدون `v` ⇐ مقارنة رقمية (major.minor.patch) مع `appVersion` الأصلي.
3. الأصل `mawqi-now.apk` (وإلا أول `.apk`).
4. تنزيل متدفق إلى `cacheDir/updates/mawqi-now-<ver>.apk` مع شريط تقدم، والتحقق من الحجم = `asset.size`.
5. `installApk` ⇒ مثبّت النظام. إن لم يُسمح بالتثبيت من المصدر ⇒ تُفتح الإعدادات وتُرجع `need_permission`.
6. فحص صامت عند كل تشغيل؛ يتحوّل الزر للبرتقالي إذا وُجد تحديث.

## 6. المراجع
- Weinberg, H. (2002). *Using the ADXL202 in Pedometer and Personal Navigation Applications*. Analog Devices AN-602.
- Liu H. et al. (2026). *Motion-State-Aware Adaptive Step-Length Smartphone PDR*. Sensors (PMC13468752) — عتبة قمم تكيفية،
  Weinberg بمعامل تكيفي، دمج اتجاه Kalman بالمتجهات؛ أخطاء 0.47–1.86٪ من المسافة.
- Ho N-H. et al. (2016). *Step-Detection and Adaptive Step-Length Estimation for PDR at Various Walking Speeds Using a Smartphone*. Sensors 16(9):1423.
- Google (2024). *Introducing the Fused Orientation Provider API* — android-developers.googleblog.com/2024/03.
- Android: `FusedLocationProviderClient`, `GnssStatus`, `GeomagneticField`, `Location.getAccuracy()` (68٪).
