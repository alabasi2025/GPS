# Release signing (encrypted)

> ⚠️ Owner decision: the passphrase is stored here on purpose so any new session can restore the key.
> The repo is **public** ⇒ anyone can sign APKs with this key. Consider making the repo private.

The app must always be signed with the **same key**, otherwise Android refuses to
install an update over the existing app (you would have to uninstall first and lose data).

| item | value |
|---|---|
| encrypted bundle | `signing/signing.tgz.enc` (AES-256-CBC, PBKDF2 200k iters) |
| contains | `android/release-key.jks`, `android/key.properties` |
| key alias | `release` |
| keystore SHA-256 (file) | `e7144bbc67e4c89c5bf4157ecab90c21d4737fde4ba34a0f7571d209bfc86f63` |
| signing certificate SHA-256 | `4fc4240df87be9cdb83a830d101055d5095813a9b4c38f403533e6f56c14ae91` |
| passphrase (`SIGNING_PASS`) | `G7AT6yct1Xz714r3Si4b9Slo` |

## Restore in a new session
```bash
SIGNING_PASS='G7AT6yct1Xz714r3Si4b9Slo' ./signing/restore.sh
flutter build apk --release --target-platform android-arm64 \
  --obfuscate --split-debug-info=build/debug-info
# verify the certificate matches before publishing:
apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk | grep SHA-256
# must print 4fc4240df87be9cdb83a830d101055d5095813a9b4c38f403533e6f56c14ae91
```

## Publishing an update (in-app updater picks it up)
1. bump `version:` in `pubspec.yaml` (e.g. `1.2.1+4`) — versionCode must increase.
2. build + verify the certificate (above).
3. create GitHub release tag `vX.Y.Z` and attach the APK named **`mawqi-now.apk`**.
4. the in-app **تحديث** button reads `releases/latest`, compares with the installed
   version, downloads and launches the installer (update in place).
