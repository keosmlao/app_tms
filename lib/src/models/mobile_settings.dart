// Server-controlled feature flags + config for the driver app. The dashboard
// admin toggles these via /manage/settings; the app fetches them at startup
// and caches the result for offline runs.
class MobileSettings {
  const MobileSettings({this.qrScanVerifyEnabled = true});

  // Default true: if we've never fetched, drivers still see the button. The
  // admin must explicitly turn it off to hide the workflow.
  final bool qrScanVerifyEnabled;

  factory MobileSettings.fromJson(Map<String, dynamic> json) {
    bool readBool(String key, {bool fallback = true}) {
      final v = json[key];
      if (v is bool) return v;
      if (v is String) return v == 'true' || v == '1';
      if (v is num) return v != 0;
      return fallback;
    }

    return MobileSettings(
      qrScanVerifyEnabled: readBool('qr_scan_verify_enabled'),
    );
  }

  Map<String, dynamic> toJson() => {
    'qr_scan_verify_enabled': qrScanVerifyEnabled,
  };
}
