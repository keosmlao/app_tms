import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'core/app_config.dart';
import 'models/app_update_info.dart';
import 'models/auth_user.dart';
import 'models/mobile_settings.dart';
import 'services/api_client.dart';
import 'services/auth_storage.dart';
import 'services/location_tracking_service.dart';
import 'services/offline_outbox.dart';
import 'services/push_service.dart';

class AppController extends ChangeNotifier {
  AppController({required this.storage});

  final AuthStorage storage;

  static const _settingsCacheKey = 'tms_driver_mobile_settings';

  bool _isReady = false;
  String _baseUrl = AppConfig.defaultBaseUrl;
  AuthUser? _user;
  String? _pendingDocNo;
  MobileSettings _settings = const MobileSettings();
  AppUpdateInfo? _appUpdate;

  bool get isReady => _isReady;
  String get baseUrl => _baseUrl;
  AuthUser? get user => _user;
  bool get isAuthenticated => _user != null;
  String? get pendingDocNo => _pendingDocNo;
  MobileSettings get settings => _settings;
  AppUpdateInfo? get appUpdate => _appUpdate;
  // When true the whole app is blocked behind the update screen.
  bool get mustUpdate => _appUpdate?.forceUpdate == true;

  // Record the latest update policy from the backend (login/settings/426).
  // Only escalates to a blocking state — a forced flag is never cleared by a
  // later non-forced response within the same session.
  void setAppUpdate(AppUpdateInfo info) {
    if (_appUpdate?.forceUpdate == true && !info.forceUpdate) return;
    _appUpdate = info;
    notifyListeners();
  }

  ApiClient get api => ApiClient(baseUrl: _baseUrl, authToken: _user?.token);

  Future<void> initialize() async {
    // Any request that hits the version gate (426), plus the app_update block
    // on login/settings, routes here so the UI can react from anywhere.
    ApiClient.onAppUpdate = setAppUpdate;
    final session = await storage.readSession();
    if (session != null) {
      if (session.user.token.trim().isEmpty) {
        await storage.clear();
      } else {
        _baseUrl = session.baseUrl.trim().isNotEmpty
            ? session.baseUrl
            : AppConfig.defaultBaseUrl;
        _user = session.user;
      }
    }
    // Restore last known feature-flag state so the UI doesn't flip while the
    // first network fetch is in flight (or if the device is offline).
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_settingsCacheKey);
    if (cached != null && cached.isNotEmpty) {
      try {
        final map = jsonDecode(cached) as Map<String, dynamic>;
        _settings = MobileSettings.fromJson(map);
      } catch (_) {
        // Corrupted cache — ignore and stick with defaults.
      }
    }
    _isReady = true;
    notifyListeners();
  }

  // Pull the latest feature flags from the server. Silently keeps the cached
  // value on failure so a transient network error doesn't strip features
  // from the UI.
  Future<void> loadSettings() async {
    if (_user == null) return;
    try {
      final next = await api.getMobileSettings();
      _settings = next;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_settingsCacheKey, jsonEncode(next.toJson()));
      notifyListeners();
    } catch (_) {
      // Stay on cached value.
    }
  }

  /// Called when a notification is tapped. Stashes the docNo so the UI can
  /// navigate to the job detail page once the user is authenticated.
  void requestOpenJob(String docNo) {
    if (docNo.isEmpty) return;
    _pendingDocNo = docNo;
    notifyListeners();
  }

  void consumePendingDocNo() {
    _pendingDocNo = null;
  }

  Future<void> login({
    String? baseUrl,
    required String username,
    required String password,
    required bool rememberMe,
  }) async {
    final apiClient = ApiClient(baseUrl: baseUrl ?? AppConfig.defaultBaseUrl);
    final authUser = await apiClient.login(
      username: username.trim(),
      password: password,
    );
    final resolvedDriverId = authUser.driverId.trim().isNotEmpty
        ? authUser.driverId.trim()
        : authUser.code.trim().isNotEmpty
        ? authUser.code.trim()
        : authUser.username.trim();

    _baseUrl = apiClient.baseUrl;
    _user = authUser.copyWith(
      driverId: resolvedDriverId,
      code: authUser.code.isEmpty ? authUser.username : authUser.code,
    );
    if (rememberMe) {
      await storage.saveSession(baseUrl: _baseUrl, user: _user!);
    } else {
      await storage.clear();
    }
    // Tell the offline outbox where to send any queued actions, then flush.
    OfflineOutbox.instance.setBaseUrl(_baseUrl);
    OfflineOutbox.instance.setAuthToken(_user!.token);
    // Register FCM token so backend can push to this driver.
    await PushService.instance.registerWithBackend(
      baseUrl: _baseUrl,
      userCode: _user!.code,
      authToken: _user!.token,
    );
    // Fire-and-forget — UI uses cached/default flags meanwhile.
    unawaited(loadSettings());
    _notifyAfterFrame();
  }

  Future<void> logout() async {
    // NOTE: we intentionally do NOT unregister the FCM token here so the
    // device keeps receiving notifications for the previous driver. Tapping
    // a notification will route the user through login → job detail.
    _user = null;
    _pendingDocNo = null;
    OfflineOutbox.instance.setAuthToken(null);
    // Stop continuous GPS tracking + tear down its foreground service.
    unawaited(LocationTrackingService.instance.stop());
    await storage.clear();
    _notifyAfterFrame();
  }

  void _notifyAfterFrame() {
    Timer.run(notifyListeners);
  }
}
