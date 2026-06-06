import 'dart:async';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
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
  // The "always" location + battery-exemption prompts are asked at most once
  // per app session (they're heavier system dialogs we don't want to re-pop on
  // every sync).
  bool _askedBgPerms = false;

  /// Wire up the background service. Call once from main() before runApp().
  Future<void> configure() async {
    if (_configured) return;
    await _service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: _onBackgroundStart,
        // We start/stop it ourselves based on trip state, and don't want it
        // resurrecting on boot without a fresh login/session.
        autoStart: false,
        autoStartOnBoot: false,
        isForegroundMode: true,
        initialNotificationTitle: 'ກຳລັງຕິດຕາມຖ້ຽວ',
        initialNotificationContent: 'ກຳລັງສົ່ງຕຳແໜ່ງ GPS ໃຫ້ສູນຄວບຄຸມ',
        // Android 14 requires the foreground service type to be declared.
        foregroundServiceTypes: const [AndroidForegroundType.location],
      ),
      iosConfiguration: IosConfiguration(autoStart: false),
    );
    _configured = true;
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
    // The background isolate can't prompt for permission — it must already be
    // granted. Surface the exact blocker via [state] so the in-app banner can
    // prompt the driver to fix it. while-in-use is enough: the foreground
    // service carries location access past the app being backgrounded/killed.
    if (!await Geolocator.isLocationServiceEnabled()) {
      state.value = TrackingState.gpsOff;
      return;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
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
      // First launch of the service this session — ask for the permissions that
      // make tracking survive backgrounding/kill. Best-effort: tracking still
      // runs with while-in-use, just less reliably on aggressive OEMs.
      await _requestBackgroundPermsOnce();
      await _service.startService();
    }
    state.value = TrackingState.active;
  }

  /// Open the OS location-services settings (when GPS is turned off).
  Future<void> openLocationSettings() => Geolocator.openLocationSettings();

  /// Open this app's system settings so the driver can grant location /
  /// "Allow all the time".
  Future<void> openAppPermissionSettings() => Geolocator.openAppSettings();

  /// Ask for "Allow all the time" location + battery-optimization exemption,
  /// at most once per session. Both are best-effort — never block tracking on
  /// the result.
  Future<void> _requestBackgroundPermsOnce() async {
    if (_askedBgPerms) return;
    _askedBgPerms = true;
    try {
      final needsAlways = !await Permission.locationAlways.isGranted;
      final needsBattery =
          !await Permission.ignoreBatteryOptimizations.isGranted;
      if (!needsAlways && !needsBattery) return;

      // Explain WHY before the bare system dialogs appear — drivers grant
      // "Allow all the time" far more often when they understand it.
      await _showRationaleDialog();

      // Must already hold while-in-use (granted in _ensurePermission) before
      // Android will consider the background ("always") upgrade.
      if (needsAlways) {
        await Permission.locationAlways.request();
      }
      if (needsBattery) {
        await Permission.ignoreBatteryOptimizations.request();
      }
    } catch (_) {
      // Plugin/permission errors must not stop tracking from starting.
    }
  }

  /// One-time explainer shown before the OS permission prompts. No-op if the
  /// app has no live navigator (e.g. permissions already settled in background).
  Future<void> _showRationaleDialog() async {
    final ctx = navigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return;
    await showDialog<void>(
      context: ctx,
      barrierDismissible: false,
      builder: (dctx) => AlertDialog(
        backgroundColor: AppTheme.bgCard,
        icon: const Icon(Icons.my_location_rounded, color: AppTheme.primary),
        title: const Text(
          'ເປີດສິດຕຳແໜ່ງ "ຕະຫຼອດເວລາ"',
          style: TextStyle(color: AppTheme.textBright, fontSize: 16),
        ),
        content: const Text(
          'ແອັບຕ້ອງສົ່ງຕຳແໜ່ງ GPS ໃຫ້ສູນຄວບຄຸມຕະຫຼອດການຈັດສົ່ງ — ເຖິງປິດໜ້າຈໍ '
          'ຫຼື ບໍ່ໄດ້ເປີດແອັບໄວ້. ກະລຸນາເລືອກ:\n\n'
          '• ຕຳແໜ່ງ → "ອະນຸຍາດຕະຫຼອດເວລາ" (Allow all the time)\n'
          '• ແບັດເຕີຣີ່ → "ອະນຸຍາດ" (ບໍ່ optimize)\n\n'
          'ການຕິດຕາມຈະຢຸດເອງເມື່ອທ່ານປິດຖ້ຽວ.',
          style: TextStyle(
            color: AppTheme.textSecondary,
            fontSize: 13,
            height: 1.5,
          ),
        ),
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.primary),
            onPressed: () => Navigator.of(dctx).pop(),
            child: const Text('ເຂົ້າໃຈແລ້ວ, ສືບຕໍ່'),
          ),
        ],
      ),
    );
  }

  /// Stop tracking. Clears the active doc (so the loop exits on its next tick)
  /// and signals the service to stop now.
  Future<void> stop() async {
    state.value = TrackingState.off;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kDocNo);
    if (await _service.isRunning()) {
      _service.invoke('refresh');
    }
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

    final fix = lastFix;
    if (fix != null) {
      try {
        await api.saveTravelHistory(
          docNo: docNo,
          lat: fix.latitude.toString(),
          lng: fix.longitude.toString(),
        );
      } catch (_) {
        // Best-effort telemetry — next tick sends a fresh point.
      }
    }

    if (service is AndroidServiceInstance) {
      await service.setForegroundNotificationInfo(
        title: 'ກຳລັງຕິດຕາມຖ້ຽວ',
        content: 'ກຳລັງສົ່ງຕຳແໜ່ງ GPS (ຖ້ຽວ $docNo)',
      );
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
