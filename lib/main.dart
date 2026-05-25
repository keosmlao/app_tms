import 'package:flutter/widgets.dart';

import 'src/app.dart';
import 'src/app_controller.dart';
import 'src/services/auth_storage.dart';
import 'src/services/offline_outbox.dart';
import 'src/services/push_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Initialize FCM as early as possible. Safe to call before google-services.json
  // is configured — it will log and skip.
  await PushService.instance.initialize();
  // Initialize the offline outbox (loads any queued actions from disk).
  await OfflineOutbox.instance.initialize();

  final controller = AppController(storage: AuthStorage());
  // Wire notification taps to the controller. The UI watches pendingDocNo
  // and navigates to job detail (after auth if needed).
  PushService.instance.onNotificationOpened = (docNo) {
    controller.requestOpenJob(docNo);
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
  runApp(TmsDriverApp(controller: controller));
}
