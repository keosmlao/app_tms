import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/auth_user.dart';

class StoredSession {
  const StoredSession({required this.baseUrl, required this.user});

  final String baseUrl;
  final AuthUser user;
}

class AuthStorage {
  static const _sessionKey = 'tms_driver_session';

  Future<StoredSession?> readSession() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_sessionKey);
    if (raw == null || raw.isEmpty) {
      return null;
    }

    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    return StoredSession(
      baseUrl: (decoded['baseUrl'] ?? '').toString(),
      user: AuthUser.fromStoredJson(decoded['user'] as Map<String, dynamic>),
    );
  }

  Future<void> saveSession({
    required String baseUrl,
    required AuthUser user,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _sessionKey,
      jsonEncode({'baseUrl': baseUrl, 'user': user.toJson()}),
    );
  }

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_sessionKey);
  }
}
