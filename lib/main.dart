import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/screens/chat_people_screen.dart';
import 'src/app_controller.dart';
import 'src/core/app_version.dart';
import 'src/services/auth_storage.dart';
import 'src/services/location_tracking_service.dart';
import 'src/services/offline_outbox.dart';
import 'src/services/push_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Read the build version once so every API request can report it via the
  // x-app-version header (powers the server-side force-update gate).
  await AppVersion.load();
  // Initialize FCM as early as possible. Safe to call before google-services.json
  // is configured — it will log and skip.
  await PushService.instance.initialize();
  // Route uncaught Flutter + platform errors to Crashlytics so real-device
  // crashes surface in the console. Firebase was already initialized by
  // PushService above; wrap so any Crashlytics hiccup never blocks startup.
  try {
    FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;
    WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
      FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
      return true;
    };
  } catch (_) {}
  // Initialize the offline outbox (loads any queued actions from disk).
  await OfflineOutbox.instance.initialize();
  // Wire up the background GPS-tracking service so it can be started later when
  // a trip is dispatched (it keeps posting even if the app is swiped away).
  await LocationTrackingService.instance.configure();

  final controller = AppController(storage: AuthStorage());
  // Wire notification taps to the controller. The UI watches pendingDocNo
  // and navigates to job detail (after auth if needed).
  PushService.instance.onNotificationOpened = (docNo) {
    controller.requestOpenJob(docNo);
  };
  // Tapping a chat (DM) notification opens the chat people list.
  PushService.instance.onChatOpened = () {
    final nav = LocationTrackingService.navigatorKey.currentState;
    if (nav != null) {
      nav.push(
        MaterialPageRoute(
          builder: (_) => ChatPeopleScreen(controller: controller),
        ),
      );
    }
  };
  await controller.initialize();
  // If a saved session exists, register the token for that user right away.
  if (controller.user != null) {
    OfflineOutbox.instance.setBaseUrl(controller.baseUrl);
    OfflineOutbox.instance.setAuthToken(controller.user!.token);
    await PushService.instance.registerWithBackend(
      baseUrl: controller.baseUrl,
      userCode: controller.user!.code,
      authToken: controller.user!.token,
    );
  }
  runApp(TmsApp(controller: controller));
}
