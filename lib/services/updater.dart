import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// In-app updater backed by GitHub Releases (alabasi2025/GPS).
class UpdateInfo {
  final String version; // e.g. 1.2.0
  final String apkUrl;
  final String notes;
  final int size;
  const UpdateInfo(this.version, this.apkUrl, this.notes, this.size);
}

class Updater {
  static const repo = 'alabasi2025/GPS';
  static const assetName = 'mawqi-now.apk';
  static const _ch = MethodChannel('mawqi/native');

  static Future<String> currentVersion() async {
    try {
      return (await _ch.invokeMethod<String>('appVersion')) ?? '0';
    } catch (_) {
      return '0';
    }
  }

  /// Returns null when already up to date.
  static Future<UpdateInfo?> check() async {
    final res = await http
        .get(
          Uri.parse('https://api.github.com/repos/$repo/releases/latest'),
          headers: {
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'MawqiNow-Updater',
          },
        )
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw Exception('GitHub HTTP ${res.statusCode}');
    }
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    final tag = (j['tag_name'] as String? ?? '').replaceFirst('v', '');
    final assets = (j['assets'] as List? ?? []).cast<Map<String, dynamic>>();
    final apk = assets.firstWhere(
      (a) => a['name'] == assetName,
      orElse: () => assets.firstWhere(
        (a) => (a['name'] as String).endsWith('.apk'),
        orElse: () => {},
      ),
    );
    if (apk.isEmpty) return null;
    final cur = await currentVersion();
    if (compare(tag, cur) <= 0) return null;
    return UpdateInfo(
      tag,
      apk['browser_download_url'] as String,
      j['body'] as String? ?? '',
      (apk['size'] as num?)?.toInt() ?? 0,
    );
  }

  static int compare(String a, String b) {
    List<int> p(String s) =>
        s.split(RegExp(r'[.+\-]')).map((e) => int.tryParse(e) ?? 0).toList();
    final x = p(a), y = p(b);
    for (var i = 0; i < 3; i++) {
      final xi = i < x.length ? x[i] : 0, yi = i < y.length ? y[i] : 0;
      if (xi != yi) return xi.compareTo(yi);
    }
    return 0;
  }

  /// Downloads the APK (progress 0..1) and launches the system installer.
  /// Returns: ok | need_permission | error message.
  static Future<String> downloadAndInstall(
    UpdateInfo u,
    void Function(double) onProgress,
  ) async {
    final dir = Directory('${(await getTemporaryDirectory()).path}/updates');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    for (final f in dir.listSync()) {
      try {
        f.deleteSync();
      } catch (_) {}
    }
    final file = File('${dir.path}/mawqi-now-${u.version}.apk');
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(u.apkUrl));
      final resp = await client.send(req);
      if (resp.statusCode != 200) return 'HTTP ${resp.statusCode}';
      final total = resp.contentLength ?? u.size;
      final sink = file.openWrite();
      var got = 0;
      await for (final chunk in resp.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) onProgress(got / total);
      }
      await sink.close();
      if (u.size > 0 && file.lengthSync() != u.size) {
        return 'الملف ناقص (${file.lengthSync()} من ${u.size})';
      }
    } finally {
      client.close();
    }
    return install(file.path);
  }

  static Future<String> install(String path) async =>
      (await _ch.invokeMethod<String>('installApk', {'path': path})) ?? 'error';

  static Future<String?> pendingApk() async {
    final dir = Directory('${(await getTemporaryDirectory()).path}/updates');
    if (!dir.existsSync()) return null;
    final apks = dir.listSync().whereType<File>().where(
      (f) => f.path.endsWith('.apk'),
    );
    return apks.isEmpty ? null : apks.first.path;
  }
}
