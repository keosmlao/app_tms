import 'dart:io';
import 'dart:ui' show Color;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

const _androidChannelId = 'odgtms_jobs';
const _androidChannelName = 'ODG TMS ຖ້ຽວຂົນສົ່ງ';
const _androidChannelDescription =
    'ການແຈ້ງເຕືອນກ່ຽວກັບຖ້ຽວຈັດສົ່ງ (ຈັດຖ້ຽວ, ອະນຸມັດ, ຍົກເລີກ, ປິດຖ້ຽວ)';

/// Foreground push handler — display a local notification because Firebase
/// Messaging only auto-shows tray notifications in background.
@pragma('vm:entry-point')
Future<void> _firebaseBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  // Android shows background notifications itself when `notification` field is
  // set. Nothing else to do here.
}

class PushService {
  PushService._();
  static final PushService instance = PushService._();

  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  String? _token;
  String? _registeredBaseUrl;
  String? _registeredUserCode;
  String? _registeredAuthToken;

  /// Set by [main] / [AppController] so notification taps can request the
  /// app to navigate to a job detail page (after auth if needed).
  void Function(String docNo)? onNotificationOpened;

  /// Called when a chat (DM) notification is tapped, so the UI can open chat.
  void Function()? onChatOpened;

  String? get token => _token;

  /// Call once from `main()` before `runApp`. Safe to call before Firebase is
  /// configured — it will skip gracefully.
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      await Firebase.initializeApp();
    } catch (e) {
      debugPrint(
        '[push] Firebase init failed (missing google-services.json?): $e',
      );
      return;
    }

    // Background handler must be registered as a top-level function.
    FirebaseMessaging.onBackgroundMessage(_firebaseBackgroundHandler);

    // Local notifications for foreground display.
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);
    await _localNotifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (response) {
        final docNo = response.payload;
        if (docNo != null && docNo.isNotEmpty) {
          onNotificationOpened?.call(docNo);
        }
      },
    );

    // Create the notification channel (Android 8+).
    if (Platform.isAndroid) {
      const channel = AndroidNotificationChannel(
        _androidChannelId,
        _androidChannelName,
        description: _androidChannelDescription,
        importance: Importance.high,
      );
      await _localNotifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.createNotificationChannel(channel);
    }

    await FirebaseMessaging.instance.requestPermission();

    try {
      _token = await FirebaseMessaging.instance.getToken();
      debugPrint('[push] FCM token: $_token');
    } catch (e) {
      debugPrint('[push] getToken failed: $e');
    }

    FirebaseMessaging.onMessage.listen(_onForegroundMessage);

    // App was in background and user tapped notification → opens app.
    FirebaseMessaging.onMessageOpenedApp.listen(_handleNotificationTap);

    // App was terminated and launched by tapping a notification.
    final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
    if (initialMessage != null) {
      // Defer slightly so the UI can mount before we navigate.
      Future.delayed(const Duration(milliseconds: 50), () {
        _handleNotificationTap(initialMessage);
      });
    }

    FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
      _token = newToken;
      if (_registeredBaseUrl != null && _registeredUserCode != null) {
        await registerWithBackend(
          baseUrl: _registeredBaseUrl!,
          userCode: _registeredUserCode!,
          authToken: _registeredAuthToken,
        );
      }
    });

    _initialized = true;
  }

  void _onForegroundMessage(RemoteMessage message) {
    final n = message.notification;
    if (n == null) return;
    _localNotifications.show(
      message.hashCode,
      n.title,
      n.body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _androidChannelId,
          _androidChannelName,
          channelDescription: _androidChannelDescription,
          importance: Importance.high,
          priority: Priority.high,
          styleInformation: BigTextStyleInformation(''),
          color: Color(0xFF0D9488),
        ),
      ),
      payload: message.data['doc_no']?.toString() ?? '',
    );
  }

  void _handleNotificationTap(RemoteMessage message) {
    if (message.data['type']?.toString() == 'dm') {
      onChatOpened?.call();
      return;
    }
    final docNo = message.data['doc_no']?.toString();
    if (docNo == null || docNo.isEmpty) return;
    onNotificationOpened?.call(docNo);
  }

  /// Post the token to backend so it can target this driver.
  Future<void> registerWithBackend({
    required String baseUrl,
    required String userCode,
    String? authToken,
  }) async {
    if (_token == null || _token!.isEmpty) return;
    _registeredBaseUrl = baseUrl;
    _registeredUserCode = userCode;
    _registeredAuthToken = authToken;

    final normalized = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final uri = Uri.parse('$normalized/api/mobile/fcm-token');

    try {
      final res = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              if (authToken != null && authToken.isNotEmpty)
                'Authorization': 'Bearer $authToken',
            },
            body: jsonEncode({
              'user_code': userCode,
              'token': _token,
              'platform': Platform.isAndroid ? 'android' : 'ios',
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (res.statusCode >= 400) {
        debugPrint('[push] register failed: ${res.statusCode} ${res.body}');
      }
    } catch (e) {
      debugPrint('[push] register error: $e');
    }
  }

  /// Remove token on logout so this device stops receiving push.
  Future<void> unregister({required String baseUrl}) async {
    if (_token == null || _token!.isEmpty) return;
    final normalized = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final uri = Uri.parse('$normalized/api/mobile/fcm-token');
    try {
      await http
          .delete(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'token': _token}),
          )
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('[push] unregister error: $e');
    }
    _registeredBaseUrl = null;
    _registeredUserCode = null;
    _registeredAuthToken = null;
  }
}
