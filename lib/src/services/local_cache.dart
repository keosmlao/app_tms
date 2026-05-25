import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Lightweight local cache for read endpoints (jobs, bills, items) so the
/// driver can keep working in areas with no signal. Each cache key holds a
/// JSON array of rows (Maps) plus a `_savedAt` timestamp.
class LocalCache {
  LocalCache._();
  static final LocalCache instance = LocalCache._();

  static const _prefix = 'tms_cache_v1::';

  String _jobsKey(String driverId) => '${_prefix}jobs::$driverId';
  String _billsKey(String docNo) => '${_prefix}bills::$docNo';
  String _itemsKey(String billNo) => '${_prefix}items::$billNo';

  // ────────────────────────── jobs ──────────────────────────
  Future<void> saveJobs(String driverId, List<dynamic> rows) async {
    await _save(_jobsKey(driverId), rows);
  }

  Future<List<Map<String, dynamic>>?> readJobs(String driverId) async {
    return _read(_jobsKey(driverId));
  }

  // ────────────────────────── bills ──────────────────────────
  Future<void> saveBills(String docNo, List<dynamic> rows) async {
    await _save(_billsKey(docNo), rows);
  }

  Future<List<Map<String, dynamic>>?> readBills(String docNo) async {
    return _read(_billsKey(docNo));
  }

  // ────────────────────────── items ──────────────────────────
  Future<void> saveItems(String billNo, List<dynamic> rows) async {
    await _save(_itemsKey(billNo), rows);
  }

  Future<List<Map<String, dynamic>>?> readItems(String billNo) async {
    return _read(_itemsKey(billNo));
  }

  // ────────────────────────── utility ──────────────────────────
  Future<DateTime?> jobsSavedAt(String driverId) =>
      _readSavedAt(_jobsKey(driverId));

  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith(_prefix)).toList();
    for (final k in keys) {
      await prefs.remove(k);
    }
  }

  // ────────────────────────── internals ──────────────────────────
  Future<void> _save(String key, List<dynamic> rows) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final wrapper = {
        'savedAt': DateTime.now().toIso8601String(),
        'rows': rows,
      };
      await prefs.setString(key, jsonEncode(wrapper));
    } catch (e) {
      debugPrint('[cache] save failed for $key: $e');
    }
  }

  Future<List<Map<String, dynamic>>?> _read(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) return null;
      final wrapper = jsonDecode(raw) as Map<String, dynamic>;
      final rows = wrapper['rows'] as List<dynamic>? ?? const [];
      return rows
          .whereType<Map>()
          .map((r) => Map<String, dynamic>.from(r))
          .toList();
    } catch (e) {
      debugPrint('[cache] read failed for $key: $e');
      return null;
    }
  }

  Future<DateTime?> _readSavedAt(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) return null;
      final wrapper = jsonDecode(raw) as Map<String, dynamic>;
      final savedAt = wrapper['savedAt']?.toString();
      if (savedAt == null || savedAt.isEmpty) return null;
      return DateTime.tryParse(savedAt);
    } catch (_) {
      return null;
    }
  }
}
