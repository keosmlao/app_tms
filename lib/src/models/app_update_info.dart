// Update policy returned by the backend (in login / settings responses and in
// the body of a 426 "force update" error). Drives the blocking update screen.
class AppUpdateInfo {
  const AppUpdateInfo({
    this.forceUpdate = false,
    this.updateAvailable = false,
    this.minVersion = '',
    this.latestVersion = '',
    this.currentVersion = '',
    this.updateUrl = '',
  });

  // Below the admin-set minimum (or no version reported) — block the app.
  final bool forceUpdate;
  // A newer version exists but this one is still allowed — soft prompt.
  final bool updateAvailable;
  final String minVersion;
  final String latestVersion;
  final String currentVersion;
  final String updateUrl;

  factory AppUpdateInfo.fromJson(Map<String, dynamic> json) {
    bool b(dynamic v) {
      if (v is bool) return v;
      if (v is String) return v == 'true' || v == '1';
      if (v is num) return v != 0;
      return false;
    }

    String s(dynamic v) => v == null ? '' : v.toString();

    return AppUpdateInfo(
      forceUpdate: b(json['force_update']),
      updateAvailable: b(json['update_available']),
      minVersion: s(json['min_version']),
      latestVersion: s(json['latest_version']),
      currentVersion: s(json['current_version']),
      updateUrl: s(json['update_url']),
    );
  }
}
