# BUILD & RELEASE — البناء والتوقيع والنشر

## 1. البيئة
| الأداة | الإصدار |
|---|---|
| Flutter | 3.35.4 (`/opt/flutter`) |
| Dart | 3.9.2 |
| Java | OpenJDK 17 (`/usr/lib/jvm/java-17-openjdk-amd64`) |
| Android SDK | `/home/user/android-sdk`، build-tools 35.0.0 |
| Gradle JVM | `-Xmx3G -XX:MaxMetaspaceSize=1G`، `kotlin.daemon.jvmargs=-Xmx1G`، `org.gradle.workers.max=2` |

## 2. استعادة مفتاح التوقيع (إلزامي قبل أي بناء release)
```bash
SIGNING_PASS='G7AT6yct1Xz714r3Si4b9Slo' ./signing/restore.sh
# المتوقع:
# restored android/release-key.jks + android/key.properties
# keystore SHA-256 OK
```
التفاصيل: `signing/README.md`. **لا تولّد مفتاحاً جديداً أبداً.**
`android/app/build.gradle.kts` يقرأ `android/key.properties` (`storePassword`, `keyPassword`, `keyAlias=release`, `storeFile=../release-key.jks`).

## 3. إعداد release في Gradle (موجود)
```kotlin
signingConfig = signingConfigs.getByName("release")
isMinifyEnabled = true          // R8
isShrinkResources = true
proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
packaging { jniLibs { useLegacyPackaging = true }
            resources { excludes += META-INF/*.txt, *.version, LICENSE*, NOTICE*, kotlin/**, DebugProbesKt.bin } }
dependencies { play-services-location:21.2.0 ; androidx.core:core-ktx:1.13.1 }
```

## 4. البناء
```bash
flutter pub get
flutter analyze        # يجب: No issues found!
flutter test           # يجب: All tests passed!
flutter build apk --release --target-platform android-arm64 \
  --obfuscate --split-debug-info=build/debug-info
# الناتج: build/app/outputs/flutter-apk/app-release.apk  (~8.6MB في v1.2.0)
```
في الـ sandbox: البناء يستغرق 2–5 دقائق؛ شغّله بسكربت منفصل:
```bash
cat > /home/user/build_apk.sh <<'X'
#!/bin/bash
cd /home/user/flutter_app
flutter build apk --release --target-platform android-arm64 --obfuscate --split-debug-info=build/debug-info > /home/user/apk.log 2>&1
echo "EXIT=$?" >> /home/user/apk.log
X
chmod +x /home/user/build_apk.sh && setsid nohup /home/user/build_apk.sh >/dev/null 2>&1 < /dev/null &
# ثم راقب: grep -E "✓|EXIT=|What went wrong" /home/user/apk.log
```
ملفات `build/debug-info/*.symbols` لازمة لفك تشفير stack traces (غير مرفوعة).

## 5. الفحوصات قبل النشر (كلها إلزامية)
```bash
BT=/home/user/android-sdk/build-tools/35.0.0
APK=build/app/outputs/flutter-apk/app-release.apk
$BT/apksigner verify --print-certs $APK | grep "certificate SHA-256"
#   = 4fc4240df87be9cdb83a830d101055d5095813a9b4c38f403533e6f56c14ae91   ← إن اختلف: لا تنشر
$BT/aapt2 dump badging $APK | grep -E "^package|native-code"
#   package name='com.mawqianow.location' versionCode=<أكبر من السابق>
#   native-code يحتوي 'arm64-v8a' (قد تظهر مكتبة صغيرة libdatastore_shared_counter لمعماريات أخرى — طبيعي، من shared_preferences)
unzip -tq $APK                                   # No errors
unzip -p $APK 'classes*.dex' | grep -ac "mawqi/stream"   # ≥1 (القناة الأصلية لم يحذفها R8)
sha1sum $APK
```

## 6. النشر على GitHub Releases
1. `pubspec.yaml`: `version: X.Y.Z+N` — **N يجب أن يزيد** في كل إصدار (`1.0.0+1`, `1.1.0+2`, `1.2.0+3`, …).
2. commit + push إلى `main`.
3. إنشاء Release:
```bash
TOKEN=...   # من setup_github_environment / ~/.git-credentials
RID=$(curl -s -X POST -H "Authorization: token $TOKEN" \
  https://api.github.com/repos/alabasi2025/GPS/releases \
  -d '{"tag_name":"vX.Y.Z","target_commitish":"main","name":"موقعي الآن vX.Y.Z","body":"...","make_latest":"true"}' \
  | python3 -c "import json,sys;print(json.load(sys.stdin)['id'])")
curl -s -X POST -H "Authorization: token $TOKEN" -H "Content-Type: application/vnd.android.package-archive" \
  --data-binary @build/app/outputs/flutter-apk/app-release.apk \
  "https://uploads.github.com/repos/alabasi2025/GPS/releases/$RID/assets?name=mawqi-now.apk"
```
4. تحقّق: `curl -sL -o /tmp/t.apk https://github.com/alabasi2025/GPS/releases/latest/download/mawqi-now.apk && sha1sum /tmp/t.apk` = sha1 المحلي.
5. حدّث جدول الإصدار في `README.md` و `AGENTS.md` (§1) و `docs/HISTORY.md`.

## 7. كيف يصل التحديث للمستخدم
- التطبيق عند الفتح يفحص `releases/latest` بصمت؛ إن كان `tag > versionName` المثبّت يصبح زر «تحديث» برتقالياً.
- الضغط ⇒ تنزيل + تحقق الحجم + مثبّت النظام ⇒ «تحديث» (لا حذف) لأن الشهادة واحدة و versionCode أكبر.
- أول مرة يطلب أندرويد السماح لـ «موقعي الآن» بتثبيت التطبيقات.

## 8. سجل الإصدارات المنشورة
| tag | versionCode | الحجم | SHA-1 | الشهادة |
|---|---|---|---|---|
| v1.0.0 | 1 | 7.4MB | `57e968e06cbae0ff18f3dfee1f154c500b534f52` | 4fc4240d…ae91 |
| v1.1.0 | 2 | 7.4MB | `bb2c411fa9fa7a46453cca9e5553cee9cc091c6e` | 4fc4240d…ae91 |
| v1.2.0 | 3 | 8.6MB | `0f0c75bf4888a7b4d873b7efd057b1417af4257a` | 4fc4240d…ae91 |
> ملاحظة: أول APK بُني في الجلسة الأولى (45MB ثم 16MB، غير منشور على GitHub) كان موقّعاً بمفتاح debug.
> من ثبّته يجب أن يحذفه مرة واحدة ثم يثبّت v1.0.0+ ؛ بعدها كل التحديثات فوق بعض.

## 9. الويب (معاينة فقط)
```bash
flutter build web --release
cd build/web && python3 -m http.server 5060 --bind 0.0.0.0
```
