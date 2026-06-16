import 'dart:async';
import 'dart:convert';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/app_theme.dart';
import '../core/app_version.dart';
import '../models/delivery_job.dart';
import 'api_client.dart';

// Keys shared between the UI isolate (writer) and the background isolate
// (reader). The background service reads these on every tick, so updating them
// from the UI steers the service without restarting it.
const String _kDocNo = 'tracking_doc_no';
const String _kBaseUrl = 'tracking_base_url';
const String _kToken = 'tracking_auth_token';
const String _kDriverId = 'tracking_driver_id';

// Set once the first-launch permission pass has run, so the driver is asked for
// location/battery/notification access exactly once (at install) and never
// nagged again during normal use.
const String _kPermsOnboarded = 'perms_onboarded_v1';

// Set by the background loop when a GPS post is rejected for auth (session
// expired mid-trip / after a reboot). The UI reads it on resume to prompt a
// re-login, since the background isolate can't refresh the token itself.
const String _kAuthFailed = 'tracking_auth_failed';

// Low-importance channel for the mandatory foreground-service notification.
// Android *requires* a location foreground service to post a persistent
// notification — it can't be hidden — so we keep it neutral and silent: no
// sound, no heads-up, collapsed at the bottom of the shade, and worded so it
// reveals nothing about GPS being sent.
const String _kChannelId = 'odgtms_service';
const String _kNotifTitle = 'ODG TMS';
const String _kNotifBody = 'ກຳລັງເຮັດວຽກ';

/// What the in-app GPS status banner should show.
enum TrackingState {
  /// No active trip — not tracking (banner hidden).
  off,

  /// Tracking and posting GPS.
  active,

  /// Active trip, but location permission is missing — needs a fix.
  needsPermission,

  /// Active trip, but the device's location service (GPS) is turned off.
  gpsOff,
}

/// Continuously posts the driver's GPS to the travel-history endpoint every
/// 5 seconds while a trip is active (received "ຮັບຖ້ຽວ" through dispatching,
/// job_status 1–2) — and keeps doing so **even after the driver swipes the app
/// away**.
///
/// The work runs in a separate background isolate hosted by an Android
/// foreground service (`flutter_background_service`). That service is declared
/// `stopWithTask="false"`, so removing the app from recents does NOT stop it;
/// it only stops when the trip is closed:
///   * the driver closes the trip in-app → the UI clears [_kDocNo] → the loop
///     sees no active doc and stops itself;
///   * as a server-side safety net, the loop re-checks job status every ~90s
///     and stops if the trip is no longer dispatching (e.g. closed from the
///     office while the app was killed).
///
/// This [LocationTrackingService] is the UI-side controller: [configure] wires
/// the isolate once at startup, and [sync] (called whenever the jobs list
/// loads) starts/stops tracking to match the active dispatched job.
class LocationTrackingService {
  LocationTrackingService._();
  static final LocationTrackingService instance = LocationTrackingService._();

  /// Navigator key shared with [MaterialApp] so the service can show the
  /// background-permission rationale dialog from outside the widget tree.
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  /// Drives the in-app GPS status banner. Updated by [start] / [stop] so the
  /// UI can show "sending GPS" or prompt the driver to fix permission / GPS.
  final ValueNotifier<TrackingState> state = ValueNotifier<TrackingState>(
    TrackingState.off,
  );

  /// Post cadence — also reused by the background loop.
  static const Duration postInterval = Duration(seconds: 5);

  final FlutterBackgroundService _service = FlutterBackgroundService();
  bool _configured = false;

  // While a trip is active and the app is in the foreground, re-check GPS +
  // permission on this cadence so the alert banner reflects a driver disabling
  // them mid-trip (the background isolate handles detection when app is killed).
  Timer? _watch;

  /// True if a trip is currently being tracked — read from the persisted active
  /// doc, so it's correct even right after launch before the jobs list loads.
  Future<bool> hasActiveTrip() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return (prefs.getString(_kDocNo) ?? '').isEmpty == false;
  }

  /// True if the background loop hit an auth failure (expired session) during a
  /// trip. The UI checks this on resume to prompt a re-login, then clears it.
  Future<bool> consumeAuthFailed() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final failed = prefs.getBool(_kAuthFailed) ?? false;
    if (failed) await prefs.remove(_kAuthFailed);
    return failed;
  }

  /// Wire up the background service. Call once from main() before runApp().
  Future<void> configure() async {
    if (_configured) return;

    // Register the foreground-service notification on a *low-importance* channel
    // so the (OS-mandated, un-removable) notification is silent and collapsed —
    // no sound, no heads-up pop. Best-effort: the service still runs if this
    // fails, just on the plugin's default channel.
    try {
      await FlutterLocalNotificationsPlugin()
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(
            const AndroidNotificationChannel(
              _kChannelId,
              'ODG TMS',
              importance: Importance.low,
            ),
          );
    } catch (_) {}

    await _service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: _onBackgroundStart,
        // We start/stop it ourselves based on trip state. autoStartOnBoot=true
        // lets tracking *resume after a phone reboot* mid-trip — on boot the
        // isolate checks the persisted active doc and immediately stops itself
        // if there's no open trip, so it only comes back when one was running.
        autoStart: false,
        autoStartOnBoot: true,
        isForegroundMode: true,
        notificationChannelId: _kChannelId,
        initialNotificationTitle: _kNotifTitle,
        initialNotificationContent: _kNotifBody,
        // Android 14 requires the foreground service type to be declared.
        foregroundServiceTypes: const [AndroidForegroundType.location],
      ),
      iosConfiguration: IosConfiguration(autoStart: false),
    );
    _configured = true;
  }

  /// First-launch permission pass. Asks for everything the tracking service
  /// needs — location (while-in-use → "all the time"), battery-optimization
  /// exemption and notifications — exactly **once**, then records a flag so the
  /// driver is never prompted again during normal use. Safe to call on every
  /// launch; it no-ops after the first run. Best-effort throughout — a denied or
  /// failed prompt never throws.
  Future<void> ensureOnboardingPermissions() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_kPermsOnboarded) == true) return;
      prefs.setBool(_kPermsOnboarded, true);

      // Notifications (Android 13+): needed so the foreground-service
      // notification — and FCM job pushes — can show at all.
      if (!await Permission.notification.isGranted) {
        await Permission.notification.request();
      }

      // Foreground (while-in-use) location must be granted before Android will
      // even offer the background ("all the time") upgrade.
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      final hasForeground =
          perm == LocationPermission.whileInUse ||
          perm == LocationPermission.always;

      if (hasForeground && !await Permission.locationAlways.isGranted) {
        await Permission.locationAlways.request();
      }
      if (!await Permission.ignoreBatteryOptimizations.isGranted) {
        await Permission.ignoreBatteryOptimizations.request();
      }

      // Aggressive OEMs (Xiaomi/Oppo/Vivo/Huawei…) kill background apps despite
      // the battery exemption — they need a manual "Autostart" toggle that no
      // standard API can flip. Show a one-time, neutrally-worded tip with a
      // shortcut to the app's settings. Best-effort; no-op without a navigator.
      await _showOemAutostartTip();
    } catch (_) {
      // Never let a permission hiccup block app startup.
    }
  }

  /// One-time OEM autostart/battery hint. Worded generically ("work
  /// continuously") so it never reveals GPS is being sent.
  Future<void> _showOemAutostartTip() async {
    final ctx = navigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return;
    final go = await _confirm(
      ctx,
      icon: Icons.battery_saver_rounded,
      title: 'ໃຫ້ແອັບເຮັດວຽກຕໍ່ເນື່ອງ',
      body: 'ໃນບາງຍີ່ຫໍ້ໂທລະສັບ (Xiaomi, Oppo, Vivo, Huawei…) ລະບົບອາດປິດ '
          'ແອັບຕອນຢູ່ພື້ນຫຼັງ. ກະລຸນາເປີດ "Autostart / ເລີ່ມອັດຕະໂນມັດ" ແລະ '
          'ຕັ້ງແບັດເຕີຣີ່ເປັນ "ບໍ່ຈຳກັດ" ສຳລັບແອັບນີ້.',
      action: 'ໄປຕັ້ງຄ່າ',
    );
    if (go == true) await Geolocator.openAppSettings();
  }

  /// Reconcile tracking with the latest jobs list: track the first *active*
  /// job and stop when there's none. "Active" = the driver has received the
  /// trip ("ຮັບຖ້ຽວ", job_status == 1) up until they close it ("ປິດຖ້ຽວ",
  /// job_status >= 3) — so tracking spans both job_status 1 and 2. Safe to call
  /// on every jobs refresh.
  Future<void> sync({
    required List<DeliveryJob> jobs,
    required String baseUrl,
    required String authToken,
    required String driverId,
  }) async {
    DeliveryJob? active;
    for (final j in jobs) {
      if (j.jobStatus == 1 || j.jobStatus == 2) {
        active = j;
        break;
      }
    }
    if (active == null) {
      await stop();
    } else {
      await start(
        docNo: active.docNo,
        baseUrl: baseUrl,
        authToken: authToken,
        driverId: driverId,
      );
    }
  }

  /// Start (or keep) tracking [docNo]. Re-writes the shared config each call so
  /// a re-login's new token is picked up by the running service.
  Future<void> start({
    required String docNo,
    required String baseUrl,
    required String authToken,
    required String driverId,
  }) async {
    // Permission is requested once at first launch (ensureOnboardingPermissions),
    // never here — starting a trip must stay silent. We only *check*: if GPS is
    // off or access is missing the service just doesn't start (no prompt, no
    // banner). while-in-use is enough; the foreground service carries location
    // access past the app being backgrounded/killed.
    if (!await Geolocator.isLocationServiceEnabled()) {
      state.value = TrackingState.gpsOff;
      return;
    }
    final perm = await Geolocator.checkPermission();
    final granted =
        perm == LocationPermission.whileInUse ||
        perm == LocationPermission.always;
    if (!granted) {
      state.value = TrackingState.needsPermission;
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kDocNo, docNo);
    await prefs.setString(_kBaseUrl, baseUrl);
    await prefs.setString(_kToken, authToken);
    await prefs.setString(_kDriverId, driverId);

    if (!await _service.isRunning()) {
      await _service.startService();
    }
    state.value = TrackingState.active;
    _startWatch();
  }

  // Foreground watchdog: while a trip is active and the app is open, re-check
  // GPS + permission every 10s so the alert banner reacts to the driver
  // disabling them mid-trip, and self-heals (restarts the service) once they're
  // turned back on. Background detection (app killed) lives in the isolate loop.
  void _startWatch() {
    _watch ??= Timer.periodic(const Duration(seconds: 10), (_) => _recheck());
  }

  Future<void> _recheck() async {
    if (!await hasActiveTrip()) {
      _watch?.cancel();
      _watch = null;
      return;
    }
    if (!await Geolocator.isLocationServiceEnabled()) {
      state.value = TrackingState.gpsOff;
      return;
    }
    final perm = await Geolocator.checkPermission();
    final granted =
        perm == LocationPermission.whileInUse ||
        perm == LocationPermission.always;
    if (!granted) {
      state.value = TrackingState.needsPermission;
      return;
    }
    state.value = TrackingState.active;
    if (!await _service.isRunning()) {
      await _service.startService(); // self-heal after GPS/perm restored
    }
  }

  /// Open the OS location-services settings (when GPS is turned off).
  Future<void> openLocationSettings() => Geolocator.openLocationSettings();

  /// Open this app's system settings so the driver can grant location /
  /// "Allow all the time".
  Future<void> openAppPermissionSettings() => Geolocator.openAppSettings();

  /// Pre-trip gate: make sure GPS + location permission are ON **before a trip
  /// starts**. Android won't let an app flip these silently, so when something
  /// is off we drive the driver straight to the system prompt / settings and
  /// re-check. Returns true only when the device is fully ready to post GPS.
  /// Call this right before "ຮັບຖ້ຽວ".
  Future<bool> ensureLocationReady(BuildContext context) async {
    // 1) Location services (GPS) must be on. Can't be toggled programmatically —
    //    send the driver to the OS location settings, then re-check on return.
    if (!await Geolocator.isLocationServiceEnabled()) {
      if (!context.mounted) return false;
      final go = await _confirm(
        context,
        icon: Icons.gps_off_rounded,
        title: 'GPS ປິດຢູ່',
        body: 'ກະລຸນາເປີດ GPS (ຕຳແໜ່ງ) ກ່ອນອອກຖ້ຽວ.',
        action: 'ເປີດ GPS',
      );
      if (go != true) return false;
      await Geolocator.openLocationSettings();
      if (!await Geolocator.isLocationServiceEnabled()) return false;
    }

    // 2) Foreground (while-in-use) permission. Re-request if simply denied.
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.deniedForever) {
      // Permanently denied — the system dialog won't show again, so the only
      // way back is the app's settings page.
      if (!context.mounted) return false;
      final go = await _confirm(
        context,
        icon: Icons.location_disabled_rounded,
        title: 'ສິດຕຳແໜ່ງຖືກປິດ',
        body: 'ກະລຸນາເປີດສິດ "ຕຳແໜ່ງ → ອະນຸຍາດຕະຫຼອດເວລາ" ໃນ Settings '
            'ກ່ອນອອກຖ້ຽວ.',
        action: 'ໄປ Settings',
      );
      if (go == true) await Geolocator.openAppSettings();
      return false;
    }
    final hasForeground =
        perm == LocationPermission.whileInUse ||
        perm == LocationPermission.always;
    if (!hasForeground) return false;

    // 3) Background ("all the time") keeps posting after the app is
    //    backgrounded/killed. Best-effort: ask once, don't hard-block the trip
    //    on it (while-in-use + the foreground service still track).
    if (!await Permission.locationAlways.isGranted) {
      await Permission.locationAlways.request();
    }
    return true;
  }

  /// Small themed confirm dialog used by [ensureLocationReady]. Returns true if
  /// the driver taps the action button.
  Future<bool?> _confirm(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String body,
    required String action,
  }) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppTheme.bgCard,
        icon: Icon(icon, color: AppTheme.primary),
        title: Text(
          title,
          style: const TextStyle(color: AppTheme.textBright, fontSize: 16),
        ),
        content: Text(
          body,
          style: const TextStyle(
            color: AppTheme.textSecondary,
            fontSize: 13,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: const Text('ຍົກເລີກ'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.primary),
            onPressed: () => Navigator.of(dctx).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
  }

  /// Stop tracking. Clears the active doc (so the loop exits on its next tick)
  /// and signals the service to stop now.
  Future<void> stop() async {
    state.value = TrackingState.off;
    _watch?.cancel();
    _watch = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kDocNo);
    if (await _service.isRunning()) {
      _service.invoke('refresh');
    }
  }
}

// Mirror of AuthStorage's session key. The background isolate patches the
// stored token in place after a refresh so the UI (which reads this on launch)
// picks up the fresh token too — keeping both isolates in sync.
const String _kSessionKey = 'tms_driver_session';

/// Patch the persisted login session's token in place (best-effort). Keeps the
/// UI's stored token in sync with a refresh done by the background loop.
Future<void> _persistSessionToken(
  SharedPreferences prefs,
  String token,
) async {
  try {
    final raw = prefs.getString(_kSessionKey);
    if (raw == null || raw.isEmpty) return;
    final decoded = jsonDecode(raw);
    if (decoded is Map && decoded['user'] is Map) {
      (decoded['user'] as Map)['token'] = token;
      await prefs.setString(_kSessionKey, jsonEncode(decoded));
    }
  } catch (_) {
    // Malformed/absent session — the prefs _kToken write already covers the loop.
  }
}

/// Background-isolate entrypoint. Runs inside the foreground service, so it
/// keeps executing after the app is swiped away. Drives a steady 3-second post
/// using the freshest GPS fix, and shuts itself down once the trip closes.
@pragma('vm:entry-point')
Future<void> _onBackgroundStart(ServiceInstance service) async {
  // Plugins (geolocator / shared_preferences / package_info) must be registered
  // in this isolate before use.
  DartPluginRegistrant.ensureInitialized();
  await AppVersion.load();

  // On a reboot (autoStartOnBoot) the OS may start this service even when no
  // trip is open. Bail out immediately in that case so nothing runs and no
  // notification appears — we only resume if an active doc was persisted.
  {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    if ((prefs.getString(_kDocNo) ?? '').isEmpty) {
      await service.stopSelf();
      return;
    }
  }

  if (service is AndroidServiceInstance) {
    await service.setAsForegroundService();
  }
  service.on('stop').listen((_) => service.stopSelf());
  service.on('refresh').listen((_) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final docNo = prefs.getString(_kDocNo) ?? '';
    if (docNo.isEmpty) await service.stopSelf();
  });

  // A position stream keeps the latest fix fresh when a trip is active; the
  // timer below — not the stream — drives the post cadence so it's steady even
  // when parked.
  Position? lastFix;
  StreamSubscription<Position>? sub;

  var tick = 0;
  // One-shot early refresh ~60s after this isolate starts. Critical on a reboot
  // resume: the service restarts with tick=0, so without this the ~6h periodic
  // refresh might not fire before an already-aging token hits its 8h expiry.
  var refreshedEarly = false;
  Timer.periodic(LocationTrackingService.postInterval, (timer) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload(); // pick up writes from the UI isolate

    final docNo = prefs.getString(_kDocNo) ?? '';
    if (docNo.isEmpty) {
      // Trip closed or user logged out — shut down.
      timer.cancel();
      await sub?.cancel();
      await service.stopSelf();
      return;
    }

    if (sub == null) {
      try {
        sub = Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 0,
          ),
        ).listen((p) => lastFix = p, onError: (_) {});
      } catch (_) {
        // Stream may fail to start without permission/service — the timer still
        // runs and will exit cleanly when the doc is cleared.
      }
    }

    final baseUrl = prefs.getString(_kBaseUrl) ?? '';
    if (baseUrl.isEmpty) return;
    final token = prefs.getString(_kToken) ?? '';
    final driverId = prefs.getString(_kDriverId) ?? '';
    final api = ApiClient(
      baseUrl: baseUrl,
      authToken: token.isEmpty ? null : token,
    );

    // Health check: detect a driver disabling tracking mid-trip. Without this
    // the office just sees points stop and can't tell tampering from a parked
    // truck / dead zone. Reasons are reported (throttled ~30s) below.
    String? problem;
    if (!await Geolocator.isLocationServiceEnabled()) {
      problem = 'gps_off';
    } else {
      final perm = await Geolocator.checkPermission();
      if (perm != LocationPermission.whileInUse &&
          perm != LocationPermission.always) {
        problem = 'no_permission';
      }
    }

    final fix = lastFix;
    if (problem == null && fix != null) {
      try {
        await api.saveTravelHistory(
          docNo: docNo,
          lat: fix.latitude.toString(),
          lng: fix.longitude.toString(),
        );
      } on ApiException catch (e) {
        // Session expired mid-trip (common after a reboot resume). Flag it so
        // the UI prompts a re-login — the isolate can't refresh the token.
        final m = e.message.toLowerCase();
        if (m.contains('401') || m.contains('403') || m.contains('unauthor')) {
          await prefs.setBool(_kAuthFailed, true);
          problem = 'auth_expired';
        }
      } catch (_) {
        // Best-effort telemetry — next tick sends a fresh point.
      }
    }

    // Report a tracking problem to the control center, throttled to ~30s
    // (every 6th 5s tick) so we don't hammer the endpoint. Best-effort.
    if (problem != null && tick % 6 == 0) {
      try {
        await api.reportTrackingStatus(docNo: docNo, status: problem);
      } catch (_) {}
    }

    if (service is AndroidServiceInstance) {
      // Keep the OS-mandated notification neutral — no GPS/trip wording.
      await service.setForegroundNotificationInfo(
        title: _kNotifTitle,
        content: _kNotifBody,
      );
    }

    // Proactive token refresh every ~6h (4320 × 5s ticks). The 8h token would
    // otherwise expire mid-trip — especially when the app is killed and only
    // this loop runs — and GPS posts would start 401'ing. Refresh while still
    // valid and persist the new token so both this loop and the UI use it.
    final earlyRefresh = !refreshedEarly && tick >= 12; // ~60s after start
    if (token.isNotEmpty &&
        (earlyRefresh || (tick > 0 && tick % 4320 == 0))) {
      refreshedEarly = true;
      try {
        final fresh = await api.refreshToken();
        if (fresh != null && fresh.isNotEmpty) {
          await prefs.setString(_kToken, fresh);
          await _persistSessionToken(prefs, fresh);
        }
      } catch (_) {
        // Keep the old token; we'll retry next cycle.
      }
    }

    // Safety net: every ~90s, stop if this trip is closed ("ປິດຖ້ຽວ",
    // job_status >= 3) or gone — covers the trip being closed from the office
    // while the app is killed. Still tracks job_status 1 and 2.
    tick++;
    if (tick % 30 == 0 && driverId.isNotEmpty) {
      try {
        final jobs = await api.getJobs(driverId: driverId);
        final match = jobs.where((j) => j.docNo == docNo).toList();
        final stillActive =
            match.isNotEmpty &&
            (match.first.jobStatus == 1 || match.first.jobStatus == 2);
        if (!stillActive) {
          await prefs.remove(_kDocNo);
          timer.cancel();
          await sub?.cancel();
          await service.stopSelf();
        }
      } catch (_) {
        // Network hiccup — keep tracking; we'll re-check next cycle.
      }
    }
  });
}
