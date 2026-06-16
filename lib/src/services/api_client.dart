import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../core/app_config.dart';
import '../core/app_version.dart';
import '../models/app_update_info.dart';
import '../models/auth_user.dart';
import '../models/chat_models.dart';
import '../models/delivery_bill.dart';
import '../models/delivery_item.dart';
import '../models/delivery_job.dart';
import '../models/fleet_driver.dart';
import '../models/fuel_log.dart';
import '../models/inspection.dart';
import '../models/mobile_settings.dart';
import 'local_cache.dart';
import 'offline_outbox.dart';

class ApiException implements Exception {
  const ApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Thrown when the backend returns 426 (Upgrade Required) — the app build is
/// older than the admin-set minimum. The global [ApiClient.onAppUpdate] hook
/// fires first so the UI can swap to the blocking update screen even if a
/// caller swallows this exception.
class AppUpdateRequiredException implements Exception {
  const AppUpdateRequiredException(this.info);

  final AppUpdateInfo info;

  @override
  String toString() => 'App update required';
}

class ApiClient {
  ApiClient({required String baseUrl, this.authToken})
    : baseUrl = _normalizeBaseUrl(baseUrl);

  final String baseUrl;
  final String? authToken;

  /// Global hook fired whenever the backend reports an app-update policy —
  /// either a forced 426 or the `app_update` block on login/settings. The
  /// AppController registers this to drive the blocking update screen.
  static void Function(AppUpdateInfo info)? onAppUpdate;

  // Tracks whether the most recent getJobs/getBills call fell back to the
  // local cache (network failure). UI uses this to warn the user that what
  // they see may be stale — e.g. after pressing "ສຳເລັດ", if the reload
  // can't reach the server, the bill phase on screen is the old one.
  bool _lastJobsFromCache = false;
  bool _lastBillsFromCache = false;
  bool get lastFetchUsedCache => _lastJobsFromCache || _lastBillsFromCache;
  void resetFetchState() {
    _lastJobsFromCache = false;
    _lastBillsFromCache = false;
  }

  // Client-generated idempotency key attached to every queueable action. The
  // same id rides the direct POST, all in-loop retries, AND the offline-outbox
  // replay (the outbox persists the body verbatim), so the server applies the
  // action exactly once. microsecond timestamp + 31-bit random keeps it unique
  // across devices/drivers.
  final Random _actionRng = Random();
  String _newActionId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_actionRng.nextInt(0x7fffffff)}';

  static String _normalizeBaseUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return AppConfig.defaultBaseUrl;
    }
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }

  Uri _uri(String path, [Map<String, String?>? query]) {
    final filtered = <String, String>{};
    query?.forEach((key, value) {
      if (value != null && value.isNotEmpty) {
        filtered[key] = value;
      }
    });
    return Uri.parse(
      '$baseUrl$path',
    ).replace(queryParameters: filtered.isEmpty ? null : filtered);
  }

  Map<String, String> _headers({bool json = false}) {
    return {
      if (json) 'Content-Type': 'application/json',
      if (authToken != null && authToken!.isNotEmpty)
        'Authorization': 'Bearer $authToken',
      // Let the backend gate old builds. Sent on every request.
      if (AppVersion.current.isNotEmpty) 'x-app-version': AppVersion.current,
      if (AppVersion.platform.isNotEmpty) 'x-app-platform': AppVersion.platform,
    };
  }

  Future<dynamic> _decodeResponse(http.Response response) async {
    final text = utf8.decode(response.bodyBytes);
    if (text.isEmpty) {
      return null;
    }
    return jsonDecode(text);
  }

  Never _throwRequestError(http.Response response, dynamic body) {
    // 426 Upgrade Required — surface the update policy globally, then throw a
    // dedicated exception so callers don't queue/retry it as a normal error.
    if (response.statusCode == 426) {
      final map = body is Map<String, dynamic>
          ? body
          : const <String, dynamic>{};
      final raw = map['app_update'];
      final info = raw is Map
          ? AppUpdateInfo.fromJson(Map<String, dynamic>.from(raw))
          : const AppUpdateInfo(forceUpdate: true);
      onAppUpdate?.call(info);
      throw AppUpdateRequiredException(info);
    }
    final message = body is Map<String, dynamic> && body['error'] != null
        ? body['error'].toString()
        : 'Request failed (${response.statusCode})';
    throw ApiException(message);
  }

  // Pull the optional `app_update` block out of a 2xx body (login / settings)
  // and notify the global hook so a soft "update available" — or a forced
  // update reported on login — reaches the UI without an error.
  void _notifyAppUpdate(dynamic body) {
    if (body is Map<String, dynamic> && body['app_update'] is Map) {
      onAppUpdate?.call(
        AppUpdateInfo.fromJson(Map<String, dynamic>.from(body['app_update'])),
      );
    }
  }

  Future<dynamic> _get(String path, [Map<String, String?>? query]) async {
    final response = await http
        .get(_uri(path, query), headers: _headers())
        .timeout(AppConfig.requestTimeout);
    final body = await _decodeResponse(response);
    if (response.statusCode >= 400) {
      _throwRequestError(response, body);
    }
    return body;
  }

  Future<dynamic> _post(
    String path,
    Map<String, dynamic> payload, {
    Duration? timeout,
  }) async {
    final response = await http
        .post(
          _uri(path),
          headers: _headers(json: true),
          body: jsonEncode(payload),
        )
        .timeout(timeout ?? AppConfig.requestTimeout);
    final body = await _decodeResponse(response);
    if (response.statusCode >= 400) {
      // Retry server errors (5xx) — they're often transient (overloaded
      // backend, brief DB hiccup). Client errors (4xx) are deterministic so
      // surface them immediately without burning retries.
      _throwRequestError(response, body);
    }
    return body;
  }

  /// Post that falls back to the offline outbox if the network is unreachable.
  /// Used for state-changing job actions so the driver can keep working in
  /// areas with no signal — the action gets sent when connectivity returns.
  ///
  /// [timeout] overrides the default request timeout — bump it for large
  /// payloads (image uploads) where the default 30s is tight on slow data.
  /// [maxRetries] retries transient failures (network drops, 5xx, timeout)
  /// with exponential backoff before giving up to the outbox / surfacing the
  /// error. 4xx errors never retry — they're deterministic.
  Future<void> _postQueueable(
    String path,
    Map<String, dynamic> payload, {
    Duration? timeout,
    int maxRetries = 2,
  }) async {
    // Stamp a stable idempotency key so the direct POST, retries, and any
    // offline-outbox replay all carry the same id (added once; mutating the
    // payload map is what the outbox later persists + replays).
    payload.putIfAbsent('action_id', _newActionId);
    var attempt = 0;
    while (true) {
      try {
        await _post(path, payload, timeout: timeout);
        return;
      } on SocketException {
        if (attempt >= maxRetries) {
          OfflineOutbox.instance.setBaseUrl(baseUrl);
          OfflineOutbox.instance.setAuthToken(authToken);
          await OfflineOutbox.instance.enqueue(path: path, body: payload);
          return;
        }
      } on TimeoutException {
        if (attempt >= maxRetries) {
          OfflineOutbox.instance.setBaseUrl(baseUrl);
          OfflineOutbox.instance.setAuthToken(authToken);
          await OfflineOutbox.instance.enqueue(path: path, body: payload);
          return;
        }
      } on http.ClientException {
        if (attempt >= maxRetries) {
          OfflineOutbox.instance.setBaseUrl(baseUrl);
          OfflineOutbox.instance.setAuthToken(authToken);
          await OfflineOutbox.instance.enqueue(path: path, body: payload);
          return;
        }
      } on ApiException catch (e) {
        // Retry server-side hiccups (5xx) but never client errors (4xx).
        if (!e.message.contains('Request failed (5') || attempt >= maxRetries) {
          rethrow;
        }
      }
      attempt++;
      // Exponential backoff: 400ms, 800ms, 1600ms.
      await Future<void>.delayed(
        Duration(milliseconds: 400 * (1 << (attempt - 1))),
      );
    }
  }

  Future<AuthUser> login({
    required String username,
    required String password,
  }) async {
    final body = await _post('/api/mobile/login', {
      'username': username,
      'password': password,
    });

    if (body == null || body is! Map<String, dynamic>) {
      throw const ApiException('ຊື່ຜູ້ໃຊ້ ຫຼື ລະຫັດຜ່ານບໍ່ຖືກ');
    }

    // Login isn't hard-gated server-side; if the policy says force_update the
    // hook fires here so the app shows the update screen right after sign-in.
    _notifyAppUpdate(body);
    return AuthUser.fromJson(body, fallbackUsername: username);
  }

  /// Exchange the current (still-valid) token for a fresh 8h one. Used to keep
  /// continuous GPS tracking alive past the token lifetime on long trips without
  /// forcing a re-login. Returns the new token, or null if the server rejects
  /// the refresh (e.g. token already fully expired → caller must re-login).
  Future<String?> refreshToken() async {
    try {
      final body = await _post('/api/mobile/refresh', const {});
      if (body is Map && body['token'] is String && body['token'].isNotEmpty) {
        return body['token'] as String;
      }
    } catch (_) {
      // Expired/unauthorized or network error — caller keeps the old token.
    }
    return null;
  }

  Future<List<DeliveryJob>> getJobs({required String driverId}) async {
    _lastJobsFromCache = false;
    try {
      final body = await _get('/api/mobile/jobs', {'driver_id': driverId});
      if (body is! List) return const [];
      await LocalCache.instance.saveJobs(driverId, body);
      return body
          .whereType<Map>()
          .map((row) => DeliveryJob.fromJson(Map<String, dynamic>.from(row)))
          .toList();
    } on SocketException {
      _lastJobsFromCache = true;
      return _readCachedJobs(driverId);
    } on TimeoutException {
      _lastJobsFromCache = true;
      return _readCachedJobs(driverId);
    } on http.ClientException {
      _lastJobsFromCache = true;
      return _readCachedJobs(driverId);
    }
  }

  Future<List<DeliveryJob>> getSupervisorJobs({
    String? driverId,
    String? status,
  }) async {
    _lastJobsFromCache = false;
    try {
      final body = await _get('/api/mobile/jobs', {
        'scope': 'all',
        'driver_id': driverId,
        'status': status,
      });
      if (body is! List) return const [];
      return body
          .whereType<Map>()
          .map((row) => DeliveryJob.fromJson(Map<String, dynamic>.from(row)))
          .toList();
    } on ApiException catch (e) {
      // Older backends may only support the driver-scoped endpoint. Surface
      // deterministic permission/client errors; callers can still show the
      // message in the supervisor dashboard.
      throw ApiException(
        '${e.message} — ກະລຸນາເພີ່ມ all-jobs API ສຳລັບ supervisor',
      );
    }
  }

  /// Live positions of every driver in the supervisor's branch (fleet map).
  Future<List<FleetDriver>> getFleet() async {
    final body = await _get('/api/mobile/jobs', {'scope': 'fleet'});
    if (body is! List) return const [];
    return body
        .whereType<Map>()
        .map((row) => FleetDriver.fromJson(Map<String, dynamic>.from(row)))
        .toList();
  }

  /// Today's KPI summary for the supervisor dashboard (Module F.2).
  Future<Map<String, dynamic>> getSupervisorKpi() async {
    final body = await _get('/api/mobile/jobs', {'scope': 'kpi'});
    if (body is Map) return Map<String, dynamic>.from(body);
    return const {};
  }

  /// Supervisor approves a trip so its driver can start dispatching. Posted
  /// directly (not queued) so the supervisor sees success/failure immediately.
  Future<void> approveJob(String docNo) async {
    await _post('/api/mobile/jobs', {'action': 'approve_job', 'doc_no': docNo});
  }

  // ── Chat (1:1 DM with office/dispatchers) ──
  Future<List<ChatPerson>> getChatPeople() async {
    final body = await _get('/api/mobile/chat');
    final people = (body is Map ? body['people'] : null);
    if (people is! List) return const [];
    return people
        .whereType<Map>()
        .map((r) => ChatPerson.fromJson(Map<String, dynamic>.from(r)))
        .toList();
  }

  /// Messages of a DM thread (also marks it read). Returns (messages, myCode).
  Future<({List<ChatMessage> messages, String me})> getChatMessages(
    String recordId,
  ) async {
    final body = await _get('/api/mobile/chat', {'record_id': recordId});
    final msgs = (body is Map ? body['messages'] : null);
    final me = (body is Map ? (body['me'] ?? '').toString() : '');
    final list = msgs is List
        ? msgs
              .whereType<Map>()
              .map((r) => ChatMessage.fromJson(Map<String, dynamic>.from(r)))
              .toList()
        : <ChatMessage>[];
    return (messages: list, me: me);
  }

  Future<void> sendChatMessage(String recordId, String body) async {
    await _post('/api/mobile/chat', {'record_id': recordId, 'body': body});
  }

  Future<List<DeliveryJob>> _readCachedJobs(String driverId) async {
    final cached = await LocalCache.instance.readJobs(driverId);
    if (cached == null) {
      throw const ApiException('ບໍ່ມີເນັດແລະບໍ່ມີຂໍ້ມູນທີ່ບັນທຶກໄວ້');
    }
    return cached.map(DeliveryJob.fromJson).toList();
  }

  Future<List<DeliveryBill>> getBills({required String docNo}) async {
    _lastBillsFromCache = false;
    try {
      final body = await _get('/api/mobile/bills', {'doc_no': docNo});
      if (body is! List) return const [];
      await LocalCache.instance.saveBills(docNo, body);
      return body
          .whereType<Map>()
          .map((row) => DeliveryBill.fromJson(Map<String, dynamic>.from(row)))
          .toList();
    } on SocketException {
      _lastBillsFromCache = true;
      return _readCachedBills(docNo);
    } on TimeoutException {
      _lastBillsFromCache = true;
      return _readCachedBills(docNo);
    } on http.ClientException {
      _lastBillsFromCache = true;
      return _readCachedBills(docNo);
    }
  }

  Future<List<DeliveryBill>> _readCachedBills(String docNo) async {
    final cached = await LocalCache.instance.readBills(docNo);
    if (cached == null) {
      throw const ApiException('ບໍ່ມີເນັດແລະບໍ່ມີຂໍ້ມູນທີ່ບັນທຶກໄວ້');
    }
    return cached.map(DeliveryBill.fromJson).toList();
  }

  Future<List<DeliveryItem>> getBillItems({required String billNo}) async {
    try {
      final body = await _get('/api/mobile/bills', {
        'type': 'products',
        'bill_no': billNo,
      });
      if (body is! List) return const [];
      await LocalCache.instance.saveItems(billNo, body);
      return body
          .whereType<Map>()
          .map((row) => DeliveryItem.fromJson(Map<String, dynamic>.from(row)))
          .toList();
    } on SocketException {
      return _readCachedItems(billNo);
    } on TimeoutException {
      return _readCachedItems(billNo);
    } on http.ClientException {
      return _readCachedItems(billNo);
    }
  }

  /// Fetch the proof-of-pickup image bytes (data URIs) the driver captured at
  /// the customer's yard. Either field is '' when not present. Throws on
  /// network errors so the caller can show a retry message.
  Future<({String photo, String signature})> getPickupImages({
    required String billNo,
  }) async {
    final body = await _get('/api/mobile/bills', {
      'type': 'pickup_images',
      'bill_no': billNo,
    });
    if (body is Map) {
      return (
        photo: (body['recipt_img'] ?? '').toString(),
        signature: (body['recipt_sign_img'] ?? '').toString(),
      );
    }
    return (photo: '', signature: '');
  }

  Future<List<DeliveryItem>> _readCachedItems(String billNo) async {
    final cached = await LocalCache.instance.readItems(billNo);
    if (cached == null) {
      throw const ApiException('ບໍ່ມີເນັດແລະບໍ່ມີຂໍ້ມູນທີ່ບັນທຶກໄວ້');
    }
    return cached.map(DeliveryItem.fromJson).toList();
  }

  Future<void> receiveJob(String docNo) async {
    await _postQueueable('/api/mobile/jobs', {
      'action': 'receive',
      'doc_no': docNo,
    });
  }

  Future<void> pickupBill({required String billNo}) async {
    await _postQueueable('/api/mobile/jobs', {
      'action': 'pickup_bill',
      'bill_no': billNo,
    });
  }

  // Receive goods at the customer's home/shop ("ຮັບສິນຄ້າຈາກລານລູກຄ້າ") for
  // '__CUSTOMER__' pickup bills. Captures the receive GPS + a proof photo + the
  // customer's signature. The bill stays in the "pickup" phase afterwards — the
  // driver still does a separate Check in + ສຳເລັດ at the delivery destination.
  // Photo/signature each go in their own request (same per-image upload pattern
  // as completeBill) so a single payload never balloons past the size limit.
  Future<void> receiveCustomerPickup({
    required String billNo,
    String? lat,
    String? lng,
    String? photo,
    String? signature,
  }) async {
    if (photo != null && photo.isNotEmpty) {
      await _postQueueable('/api/mobile/jobs', {
        'action': 'attach_bill_image',
        'bill_no': billNo,
        'kind': 'pickup',
        'image_data': photo,
      }, timeout: _uploadTimeout);
    }
    if (signature != null && signature.isNotEmpty) {
      await _postQueueable('/api/mobile/jobs', {
        'action': 'attach_bill_image',
        'bill_no': billNo,
        'kind': 'pickup_signature',
        'image_data': signature,
      }, timeout: _uploadTimeout);
    }
    await _postQueueable('/api/mobile/jobs', {
      'action': 'receive_customer_bill',
      'bill_no': billNo,
      'lat': lat,
      'lng': lng,
    });
  }

  // Image uploads use a longer timeout — full-resolution photos can take
  // 30+ seconds over slow mobile data, well past the default 30s window.
  static const Duration _uploadTimeout = Duration(seconds: 90);

  Future<void> startDispatch({
    required String docNo,
    required String milesStart,
    String? imageDataUri,
    String? lat,
    String? lng,
  }) async {
    // Upload the odometer photo on its own request first so the action's body
    // stays small even when the photo is full-resolution.
    if (imageDataUri != null && imageDataUri.isNotEmpty) {
      await _postQueueable('/api/mobile/jobs', {
        'action': 'attach_job_image',
        'doc_no': docNo,
        'kind': 'start',
        'image_data': imageDataUri,
      }, timeout: _uploadTimeout);
    }
    await _postQueueable('/api/mobile/jobs', {
      'action': 'start_dispatch',
      'doc_no': docNo,
      'miles_start': milesStart,
      'lat': lat,
      'lng': lng,
    });
  }

  Future<void> checkInBill({
    required String billNo,
    String? lat,
    String? lng,
  }) async {
    await _postQueueable('/api/mobile/jobs', {
      'action': 'checkin_bill',
      'bill_no': billNo,
      'lat': lat,
      'lng': lng,
    });
  }

  Future<void> completeBill({
    required String billNo,
    required List<Map<String, dynamic>> items,
    List<String>? deliveryImages,
    String? signatureImage,
    String? comment,
    String? lat,
    String? lng,
    String? latEnd,
    String? lngEnd,
    num? collectedAmount,
    String? paymentMethod,
  }) async {
    // Each photo goes in its own request so a single payload never balloons
    // past the server / proxy size limit (full-resolution photos are 3-5MB).
    if (deliveryImages != null) {
      // First image also gets stored on the bill row as the legacy "primary"
      // url_img, mirroring the original complete_bill behaviour.
      for (var i = 0; i < deliveryImages.length; i++) {
        final img = deliveryImages[i];
        if (img.isEmpty) continue;
        if (i == 0) {
          await _postQueueable('/api/mobile/jobs', {
            'action': 'attach_bill_image',
            'bill_no': billNo,
            'kind': 'primary',
            'image_data': img,
          }, timeout: _uploadTimeout);
        }
        await _postQueueable('/api/mobile/jobs', {
          'action': 'attach_bill_image',
          'bill_no': billNo,
          'kind': 'delivery',
          'image_data': img,
        }, timeout: _uploadTimeout);
      }
    }
    if (signatureImage != null && signatureImage.isNotEmpty) {
      await _postQueueable('/api/mobile/jobs', {
        'action': 'attach_bill_image',
        'bill_no': billNo,
        'kind': 'signature',
        'image_data': signatureImage,
      }, timeout: _uploadTimeout);
    }
    await _postQueueable('/api/mobile/jobs', {
      'action': 'complete_bill',
      'bill_no': billNo,
      'items': items,
      'comment': comment,
      'lat': lat,
      'lng': lng,
      'lat_end': latEnd,
      'lng_end': lngEnd,
      if (collectedAmount != null) 'collected_amount': collectedAmount,
      if (paymentMethod != null && paymentMethod.isNotEmpty)
        'payment_method': paymentMethod,
    });
  }

  Future<void> cancelBill({
    required String billNo,
    String? comment,
    String? deliveryImage,
    String? lat,
    String? lng,
    String? latEnd,
    String? lngEnd,
    String? reasonCode,
    String? rescheduleDate,
  }) async {
    if (deliveryImage != null && deliveryImage.isNotEmpty) {
      await _postQueueable('/api/mobile/jobs', {
        'action': 'attach_bill_image',
        'bill_no': billNo,
        'kind': 'primary',
        'image_data': deliveryImage,
      }, timeout: _uploadTimeout);
    }
    await _postQueueable('/api/mobile/jobs', {
      'action': 'cancel_bill',
      'bill_no': billNo,
      'comment': comment,
      'lat': lat,
      'lng': lng,
      'lat_end': latEnd,
      'lng_end': lngEnd,
      if (reasonCode != null && reasonCode.isNotEmpty)
        'reason_code': reasonCode,
      if (rescheduleDate != null && rescheduleDate.isNotEmpty)
        'reschedule_date': rescheduleDate,
    });
  }

  // Roll a "ຈັດສົ່ງສຳເລັດ" bill back to "ກຳລັງຈັດສົ່ງ" so the driver can redo
  // the photo + location capture. Backend rejects this once the trip is closed.
  Future<void> revertCompleteBill({required String billNo}) async {
    await _postQueueable('/api/mobile/jobs', {
      'action': 'revert_complete_bill',
      'bill_no': billNo,
    });
  }

  // Edit a completed bill in-place. Each arg is optional — pass only what the
  // driver actually changed. Photos / signature replace the previous set;
  // GPS coordinates are preserved on the server.
  Future<void> editCompleteBill({
    required String billNo,
    List<Map<String, dynamic>>? items,
    List<String>? deliveryImages,
    String? signatureImage,
    String? comment,
  }) async {
    // Delivery photos: first attach call wipes the old set, subsequent calls
    // append. Same first photo also gets stored as the legacy primary url_img.
    if (deliveryImages != null && deliveryImages.isNotEmpty) {
      for (var i = 0; i < deliveryImages.length; i++) {
        final img = deliveryImages[i];
        if (img.isEmpty) continue;
        if (i == 0) {
          await _postQueueable('/api/mobile/jobs', {
            'action': 'attach_bill_image',
            'bill_no': billNo,
            'kind': 'primary',
            'image_data': img,
          }, timeout: _uploadTimeout);
        }
        await _postQueueable('/api/mobile/jobs', {
          'action': 'attach_bill_image',
          'bill_no': billNo,
          'kind': 'delivery',
          'image_data': img,
          if (i == 0) 'replace': true,
        }, timeout: _uploadTimeout);
      }
    }
    if (signatureImage != null && signatureImage.isNotEmpty) {
      await _postQueueable('/api/mobile/jobs', {
        'action': 'attach_bill_image',
        'bill_no': billNo,
        'kind': 'signature',
        'image_data': signatureImage,
      }, timeout: _uploadTimeout);
    }
    await _postQueueable('/api/mobile/jobs', {
      'action': 'edit_complete_bill',
      'bill_no': billNo,
      'items': items ?? const <Map<String, dynamic>>[],
      'comment': comment,
    });
  }

  Future<void> completeJob({
    required String docNo,
    required String carCode,
    required String milesEnd,
    String? imageDataUri,
    String? lat,
    String? lng,
  }) async {
    if (imageDataUri != null && imageDataUri.isNotEmpty) {
      await _postQueueable('/api/mobile/jobs', {
        'action': 'attach_job_image',
        'doc_no': docNo,
        'car_code': carCode,
        'kind': 'end',
        'image_data': imageDataUri,
      }, timeout: _uploadTimeout);
    }
    await _postQueueable('/api/mobile/jobs', {
      'action': 'complete_job',
      'doc_no': docNo,
      'car_code': carCode,
      'miles_end': milesEnd,
      'lat': lat,
      'lng': lng,
    });
  }

  // Driver-app feature flags. Defaults are conservative — if the request
  // fails or a key is missing, treat the feature as enabled so we don't
  // accidentally hide functionality from drivers because of a transient
  // network blip.
  Future<MobileSettings> getMobileSettings() async {
    final body = await _get('/api/mobile/settings', const {});
    if (body is Map<String, dynamic>) {
      _notifyAppUpdate(body);
      return MobileSettings.fromJson(body);
    }
    return const MobileSettings();
  }

  // Save travel history location point
  Future<void> saveTravelHistory({
    required String docNo,
    required String lat,
    required String lng,
  }) async {
    // Best-effort telemetry — posted directly (NOT via the offline outbox). At
    // a 3-second cadence, queuing would pile thousands of stale points into the
    // outbox; the caller drops failures and the next tick sends a fresh point.
    await _post('/api/mobile/jobs', {
      'action': 'save_travel_history',
      'doc_no': docNo,
      'lat': lat,
      'lng': lng,
    }, timeout: const Duration(seconds: 10));
  }

  // Report the tracking *health* for an active trip when GPS can't be posted —
  // the driver turned off location services, revoked permission, or the session
  // expired mid-trip. Lets the control center distinguish "parked / no signal"
  // from "driver disabled tracking". Best-effort, posted directly with a short
  // timeout; failures are swallowed by the caller.
  //
  // NOTE: the backend must handle action 'tracking_status' (status is one of
  // 'gps_off' | 'no_permission' | 'auth_expired'). If it doesn't yet, this call
  // simply 4xx's and is ignored — nothing else breaks.
  Future<void> reportTrackingStatus({
    required String docNo,
    required String status,
  }) async {
    await _post('/api/mobile/jobs', {
      'action': 'tracking_status',
      'doc_no': docNo,
      'status': status,
    }, timeout: const Duration(seconds: 10));
  }

  // ─── Inspection ──────────────────────────────────────────────────────────

  Future<List<DriverCar>> getDriverCars({required String driverId}) async {
    final body = await _get('/api/mobile/cars', {'driver_id': driverId});
    if (body is! List) return const [];
    return body
        .whereType<Map>()
        .map((r) => DriverCar.fromJson(Map<String, dynamic>.from(r)))
        .toList();
  }

  Future<InspectMeta> getInspectMeta() async {
    final body = await _get('/api/mobile/inspect-meta');
    if (body is Map<String, dynamic>) return InspectMeta.fromJson(body);
    return const InspectMeta(items: [], statuses: []);
  }

  Future<List<InspectionRecord>> getInspections({
    String? driverCode,
    String? dateFrom,
    String? dateTo,
    bool pendingOnly = false,
  }) async {
    final body = await _get('/api/mobile/inspections', {
      'driver_code': driverCode,
      'dateFrom': dateFrom,
      'dateTo': dateTo,
      'pending_only': pendingOnly ? '1' : null,
    });
    if (body is! List) return const [];
    return body
        .whereType<Map>()
        .map((r) => InspectionRecord.fromJson(Map<String, dynamic>.from(r)))
        .toList();
  }

  Future<InspectionRecord> submitInspection({
    required String vehicleCode,
    required String inspectDate,
    String? inspectTime,
    String? driverCode,
    double? odometer,
    String? note,
    required List<Map<String, dynamic>> details,
  }) async {
    final body = await _post('/api/mobile/inspections', {
      'vehicle_code': vehicleCode,
      'inspect_date': inspectDate,
      if (inspectTime != null) 'inspect_time': inspectTime,
      if (driverCode != null && driverCode.isNotEmpty) 'driver_code': driverCode,
      if (odometer != null) 'odometer': odometer,
      if (note != null && note.isNotEmpty) 'note': note,
      'details': details,
    });
    if (body is Map<String, dynamic>) return InspectionRecord.fromJson(body);
    throw const ApiException('ເກີດຂໍ້ຜິດພາດໃນການສົ່ງຂໍ້ມູນ');
  }

  Future<InspectionRecord> getInspectionDetail(String inspectCode) async {
    final body = await _get('/api/mobile/inspections/$inspectCode');
    if (body is Map<String, dynamic>) return InspectionRecord.fromJson(body);
    throw const ApiException('ບໍ່ພົບຂໍ້ມູນການກວດ');
  }

  Future<void> approveInspection({
    required String inspectCode,
    required String action,
    String? note,
  }) async {
    final response = await http
        .patch(
          _uri('/api/mobile/inspections/$inspectCode'),
          headers: _headers(json: true),
          body: jsonEncode({
            'action': action,
            if (note != null && note.isNotEmpty) 'note': note,
          }),
        )
        .timeout(AppConfig.requestTimeout);
    final body = await _decodeResponse(response);
    if (response.statusCode >= 400) _throwRequestError(response, body);
  }

  // Fetch the driver's fuel-refill history (most recent first).
  Future<FuelLogList> getFuelLogs({
    required String userCode,
    String? fromDate,
    String? toDate,
    int? limit,
  }) async {
    final body = await _get('/api/mobile/fuel', {
      'user_code': userCode,
      'from': fromDate,
      'to': toDate,
      'limit': limit?.toString(),
    });
    if (body is Map<String, dynamic>) {
      return FuelLogList.fromJson(body);
    }
    return const FuelLogList(
      rows: [],
      totalLiters: 0,
      totalAmount: 0,
      count: 0,
    );
  }

  // Fuel refill — driver records liters/amount + photo. Queues offline
  // so refills entered without signal still reach the server later.
  Future<void> submitFuelRefill({
    required String userCode,
    String? driverName,
    String? car,
    String? docNo,
    required double liters,
    required double amount,
    double? odometer,
    String? station,
    String? note,
    String? imageDataUri,
    String? lat,
    String? lng,
  }) async {
    await _postQueueable('/api/mobile/jobs', {
      'action': 'fuel_refill',
      'user_code': userCode,
      'driver_name': driverName,
      'car': car,
      'doc_no': docNo,
      'liters': liters,
      'amount': amount,
      'odometer': odometer,
      'station': station,
      'note': note,
      'image_data': imageDataUri,
      'lat': lat,
      'lng': lng,
    });
  }
}
