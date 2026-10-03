# AGENTS.md — اقرأ هذا أولاً (دليل الوكيل / المطوّر القادم)

> هذا الملف هو نقطة البداية لأي وكيل ذكاء اصطناعي أو مطوّر يستلم المشروع في جلسة جديدة.
> اقرأه كاملاً، ثم اقرأ الملفات في `docs/` بالترتيب المذكور. لا تفترض أي شيء غير مكتوب هنا.

## 1. ما هو المشروع
**«موقعي الآن» (Mawqi Now)** — تطبيق أندرويد (Flutter) لتحديد موقع المستخدم **بدقة عالية جداً**، ثم تتبّع حركته
مشياً بحساسات الهاتف (Pedestrian Dead Reckoning)، وتحديد/حفظ نقاط مع صورة، ومشاركتها عبر واتساب،
مع **تحديث تلقائي من داخل التطبيق** من GitHub Releases لهذا المستودع.

| البند | القيمة |
|---|---|
| المستودع | `https://github.com/alabasi2025/GPS` (عام / public) |
| الفرع | `main` |
| اسم التطبيق | موقعي الآن |
| اسم الحزمة (applicationId / namespace) | `com.mawqianow.location` |
| اسم مشروع Dart (pubspec `name`) | `mawqi_now` |
| آخر إصدار منشور | `v1.2.0` (versionName `1.2.0`, versionCode `3`) |
| المعمارية المستهدفة | `arm64-v8a` فقط (أندرويد 64-بت) |
| رابط التحميل الثابت | `https://github.com/alabasi2025/GPS/releases/latest/download/mawqi-now.apk` |
| اسم ملف الأصل في كل Release | **`mawqi-now.apk`** (إلزامي — المحدّث الداخلي يبحث عنه بالاسم) |
| شهادة التوقيع SHA-256 | `4fc4240df87be9cdb83a830d101055d5095813a9b4c38f403533e6f56c14ae91` |
| Flutter / Dart | 3.35.4 / 3.9.2 (لا تُحدّث) |
| Android compileSdk / targetSdk | 36 / 36 (من Flutter) |
| Java | OpenJDK 17 |

## 2. متطلبات المالك (ما يريده المستخدم بالضبط — لا تخالفه)
المالك يكتب بالعربية (لهجة يمنية/خليجية) ويريد ردوداً **مختصرة ودقيقة** بالعربية.
1. **الدقة أولاً**: "ضروري بدقة" — كل قرار يجب أن يخدم دقة الموقع.
2. **مرحلتان**: (أ) أول مرة تحديد دقيق عبر Google (Fused) + GPS. (ب) بعدها الاعتماد على **حساسات الهاتف**:
   عدّ الخطوات، الاتجاه (يمين/شمال)، مثل تطبيقات الرياضة، حتى يصل للمكان.
3. عند الوصول: **تحديد النقطة** و/أو **لقطة صورة + نقطة** تلقائياً بإحداثيات تلك اللحظة.
4. **مشاركة** عبر واتساب برابط Google Maps.
5. **زر تحديث تلقائي** داخل التطبيق يحمّل آخر إصدار من هذا المستودع ويثبّته **فوق** النسخة (بدون حذف).
6. **حجم صغير**، أندرويد **64-بت فقط**.
7. **التوثيق داخل GitHub** — لا يريد أن يُرسَل له شيء خارج المستودع؛ أي وكيل جديد يقرأ المستودع ويفهم كل شيء.
8. يريد بحثاً عن أحدث الخوارزميات وتطبيقها، مع تحقق واختبار، دون ادعاءات غير مُثبتة.

## 3. خريطة الوثائق (اقرأ بالترتيب)
| # | الملف | المحتوى |
|---|---|---|
| 1 | `AGENTS.md` | هذا الملف: نظرة عامة + القواعد + سير العمل |
| 2 | `docs/ARCHITECTURE.md` | البنية، الملفات، تدفق البيانات، القنوات الأصلية (بروتوكول الرسائل) |
| 3 | `docs/ALGORITHMS.md` | الخوارزميات بالتفصيل الرياضي (Kalman، PDR، Weinberg، المعايرة) + المراجع |
| 4 | `docs/BUILD_RELEASE.md` | البناء، التوقيع، النشر، التحديث التلقائي، الفحوصات |
| 5 | `docs/TESTING.md` | الاختبارات الموجودة ونتائجها وما لم يُختبر |
| 6 | `docs/HISTORY.md` | سجل القرارات والإصدارات والمشاكل التي حدثت وحلولها |
| 7 | `docs/ROADMAP.md` | المعروف من القيود + ما يمكن تحسينه لاحقاً |
| 8 | `signing/README.md` | مفتاح التوقيع المشفّر وكيفية استعادته |
| 9 | `README.md` | صفحة المستودع للمستخدم (عربي) |

## 4. القواعد الذهبية (لا تكسرها)
1. **لا تغيّر مفتاح التوقيع أبداً.** أي APK بشهادة مختلفة عن `4fc4240d…ae91` لن يتثبّت فوق نسخة المستخدم.
   استعد المفتاح من `signing/` (انظر `signing/README.md`). إن لم تتوفر كلمة السر: **توقّف واطلبها من المالك**، لا تولّد مفتاحاً جديداً.
2. **لا ترفع أسراراً** إلى المستودع (عام): `android/key.properties`، `android/*.jks`، كلمة السر. كلها في `.gitignore`.
3. **ارفع `versionCode`** (الرقم بعد `+` في `pubspec.yaml`) في كل إصدار، وإلا يرفض أندرويد التحديث.
4. **اسم أصل الـ Release = `mawqi-now.apk`** و `tag = vX.Y.Z` مطابق لـ `versionName`، و`make_latest=true`.
5. ابنِ دائماً بـ: `--target-platform android-arm64 --obfuscate --split-debug-info=build/debug-info`.
6. شغّل `flutter analyze` (يجب 0 issues) و `flutter test` (يجب كلها تنجح) قبل أي نشر.
7. تحقّق من الشهادة بـ `apksigner verify --print-certs` قبل النشر.
8. لا تُحدّث Flutter/Dart/AGP/Gradle. حزم Firebase غير مستخدمة.
9. لا تدّعِ دقة لم تُقَس على جهاز حقيقي. نتائج الاختبارات الحالية **محاكاة**.

## 5. سير عمل جلسة جديدة (خطوة بخطوة)
```bash
git clone https://github.com/alabasi2025/GPS.git /home/user/flutter_app
cd /home/user/flutter_app
SIGNING_PASS='<من المالك>' ./signing/restore.sh   # يطبع: keystore SHA-256 OK
flutter pub get
flutter analyze            # 0 issues
flutter test               # All tests passed
# ... عدّل الكود ...
# ارفع version في pubspec.yaml مثلاً 1.2.1+4
flutter build apk --release --target-platform android-arm64 --obfuscate --split-debug-info=build/debug-info
$ANDROID_HOME/build-tools/35.0.0/apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk | grep "certificate SHA-256"
# يجب: 4fc4240df87be9cdb83a830d101055d5095813a9b4c38f403533e6f56c14ae91
git add -A && git commit -m "..." && git push origin main
# ثم أنشئ Release vX.Y.Z وأرفق APK باسم mawqi-now.apk (التفاصيل في docs/BUILD_RELEASE.md)
```
> ملاحظة بيئة sandbox: ذاكرة ~8GB. Gradle مضبوط على `-Xmx3G` و `workers.max=2` في `android/gradle.properties`
> لأن `-Xmx8G` أدى لموت Gradle daemon. شغّل البناء في سكربت منفصل عبر `setsid nohup` لأنه يستغرق 2–5 دقائق.
> لا تستخدم `pkill -f Gradle...` داخل نفس أمر bash (قد يقتل الصدفة نفسها).

## 6. أين كل شيء في الكود (فهرس سريع)
| المهمة | الملف / الدالة |
|---|---|
| قراءة Fused + GPS + أقمار + خطوات + اتجاه (أصلي) | `android/app/src/main/kotlin/com/mawqianow/location/MainActivity.kt` → `startAll`, `emitLocation`, `emitGnss`, `startHeading`, `onAccel` |
| تثبيت APK للتحديث (أصلي) | `MainActivity.kt` → `installApk` + `res/xml/update_paths.xml` + `<provider …updates>` في Manifest |
| محرك الدمج (Kalman + PDR + المعايرة) | `lib/engine/fusion.dart` → `FusionEngine.addFix`, `addStep`, `_calibrate`, `_checkLock` |
| الواجهة واستقبال الأحداث | `lib/main.dart` → `_start`, `_onEvent`, `_onFix`, `_afterUpdate`, `_phaseCard`, `_infoView` |
| تحديد نقطة / صورة | `lib/main.dart` → `_capture`, `_openPoint`, `_openPointsList` |
| حفظ النقاط والمعايرة | `lib/services/points.dart` → `Store` (shared_preferences) |
| التحديث التلقائي | `lib/services/updater.dart` → `Updater.check`, `downloadAndInstall`, `compare` |
| العنوان | `lib/main.dart` → `_reverseGeocode` (Nominatim) |
| الاختبارات | `test/fusion_test.dart`, `test/updater_test.dart` |
