import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';

/// The running app's version + platform, loaded once at startup and sent on
/// every API request via the `x-app-version` / `x-app-platform` headers so the
/// backend can force an update when the build is too old.
abstract final class AppVersion {
  /// Semantic version from pubspec (e.g. "1.1.1"). Empty until [load] runs (or
  /// if loading fails) — the backend treats an empty/missing version as an old
  /// build and forces an update once a minimum is configured.
  static String current = '';

  /// Build number from pubspec (the part after `+`, e.g. "7").
  static String build = '';

  static String get platform =>
      Platform.isIOS ? 'ios' : (Platform.isAndroid ? 'android' : '');

  /// Human-friendly label for the UI, e.g. "v1.2.1 (7)". Empty until loaded.
  static String get display {
    if (current.isEmpty) return '';
    return build.isEmpty ? 'v$current' : 'v$current ($build)';
  }

  static Future<void> load() async {
    try {
      final info = await PackageInfo.fromPlatform();
      current = info.version;
      build = info.buildNumber;
    } catch (_) {
      current = '';
      build = '';
    }
  }
}
