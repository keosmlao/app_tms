import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../core/app_config.dart';
import '../models/auth_user.dart';
import '../models/delivery_bill.dart';
import '../models/delivery_item.dart';
import '../models/delivery_job.dart';
import '../models/fuel_log.dart';
import '../models/mobile_settings.dart';
import 'local_cache.dart';
import 'offline_outbox.dart';

class ApiException implements Exception {
  const ApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

class ApiClient {
  ApiClient({required String baseUrl, this.authToken})
    : baseUrl = _normalizeBaseUrl(baseUrl);

  final String baseUrl;
  final String? authToken;

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
    final message = body is Map<String, dynamic> && body['error'] != null
        ? body['error'].toString()
        : 'Request failed (${response.statusCode})';
    throw ApiException(message);
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

    return AuthUser.fromJson(body, fallbackUsername: username);
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
    await _postQueueable('/api/mobile/jobs', {
      'action': 'save_travel_history',
      'doc_no': docNo,
      'lat': lat,
      'lng': lng,
    });
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
