import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Queue of pending POST actions that failed due to no network. Survives app
/// restarts via SharedPreferences. Retried periodically and on demand.
class OfflineOutbox extends ChangeNotifier {
  OfflineOutbox._();
  static final OfflineOutbox instance = OfflineOutbox._();

  static const _storageKey = 'tms_outbox_v1';
  static const _maxRetries = 30;
  static const _flushInterval = Duration(seconds: 30);

  final List<OutboxAction> _queue = [];
  Timer? _timer;
  bool _flushing = false;
  String? _baseUrl;
  String? _authToken;
  String? _lastError;

  int get pendingCount => _queue.length;
  String? get lastError => _lastError;
  List<OutboxAction> get items => List.unmodifiable(_queue);

  Future<void> initialize() async {
    await _load();
    _timer ??= Timer.periodic(_flushInterval, (_) => flush());
  }

  /// Update the baseUrl whenever the current session changes (e.g. login).
  void setBaseUrl(String? url) {
    _baseUrl = url;
    if (url != null && _queue.isNotEmpty) {
      // Try to flush soon after login.
      Future.delayed(const Duration(milliseconds: 250), flush);
    }
  }

  void setAuthToken(String? token) {
    _authToken = token;
  }

  /// Enqueue a POST action and trigger a flush attempt.
  Future<void> enqueue({
    required String path,
    required Map<String, dynamic> body,
  }) async {
    final action = OutboxAction(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      path: path,
      body: body,
      createdAt: DateTime.now().toIso8601String(),
      retries: 0,
    );
    _queue.add(action);
    await _persist();
    notifyListeners();
    // Fire-and-forget flush attempt (will silently fail if still offline).
    unawaited(flush());
  }

  /// Try to send everything in FIFO order. Stops at first network error so
  /// later actions don't run before earlier ones (state ordering matters).
  Future<void> flush() async {
    if (_flushing || _queue.isEmpty || _baseUrl == null) return;
    _flushing = true;
    try {
      while (_queue.isNotEmpty) {
        final action = _queue.first;
        final outcome = await _send(action);
        switch (outcome) {
          case _Outcome.success:
            _queue.removeAt(0);
            await _persist();
            notifyListeners();
            break;
          case _Outcome.permanentFailure:
            // 4xx etc — server rejected, drop the action.
            _lastError = 'Server rejected ${action.path}';
            debugPrint('[outbox] dropping action ${action.path} (4xx)');
            _queue.removeAt(0);
            await _persist();
            notifyListeners();
            break;
          case _Outcome.networkError:
            action.retries++;
            if (action.retries >= _maxRetries) {
              _lastError = 'Network retry limit reached for ${action.path}';
              debugPrint(
                '[outbox] dropping ${action.path} after $_maxRetries retries',
              );
              _queue.removeAt(0);
            }
            await _persist();
            notifyListeners();
            return; // stop — try again next interval
        }
      }
    } finally {
      _flushing = false;
    }
  }

  Future<_Outcome> _send(OutboxAction action) async {
    final url = (_baseUrl ?? '').replaceAll(RegExp(r'/+$'), '');
    if (url.isEmpty) return _Outcome.networkError;
    try {
      final res = await http
          .post(
            Uri.parse('$url${action.path}'),
            headers: {
              'Content-Type': 'application/json',
              if (_authToken != null && _authToken!.isNotEmpty)
                'Authorization': 'Bearer $_authToken',
            },
            body: jsonEncode(action.body),
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        return _Outcome.success;
      }
      // 5xx → still keep retrying (transient).
      if (res.statusCode >= 500) return _Outcome.networkError;
      // 4xx → drop. Can't recover by retrying.
      return _Outcome.permanentFailure;
    } on SocketException {
      return _Outcome.networkError;
    } on TimeoutException {
      return _Outcome.networkError;
    } on http.ClientException {
      return _Outcome.networkError;
    } catch (e) {
      debugPrint('[outbox] unexpected error: $e');
      return _Outcome.networkError;
    }
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      if (raw == null || raw.isEmpty) return;
      final list = jsonDecode(raw) as List<dynamic>;
      _queue
        ..clear()
        ..addAll(
          list.map((e) => OutboxAction.fromJson(e as Map<String, dynamic>)),
        );
    } catch (e) {
      debugPrint('[outbox] load failed: $e');
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _storageKey,
        jsonEncode(_queue.map((e) => e.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('[outbox] persist failed: $e');
    }
  }

  Future<void> clear() async {
    _queue.clear();
    _lastError = null;
    await _persist();
    notifyListeners();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

class OutboxAction {
  OutboxAction({
    required this.id,
    required this.path,
    required this.body,
    required this.createdAt,
    required this.retries,
  });

  final String id;
  final String path;
  final Map<String, dynamic> body;
  final String createdAt;
  int retries;

  Map<String, dynamic> toJson() => {
    'id': id,
    'path': path,
    'body': body,
    'createdAt': createdAt,
    'retries': retries,
  };

  factory OutboxAction.fromJson(Map<String, dynamic> json) => OutboxAction(
    id: (json['id'] ?? '').toString(),
    path: (json['path'] ?? '').toString(),
    body: Map<String, dynamic>.from(json['body'] as Map),
    createdAt: (json['createdAt'] ?? '').toString(),
    retries: (json['retries'] ?? 0) as int,
  );
}

enum _Outcome { success, permanentFailure, networkError }
