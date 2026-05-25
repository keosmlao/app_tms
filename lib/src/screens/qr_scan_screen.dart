import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/app_theme.dart';
import '../models/delivery_bill.dart';

/// Scan a "ຈຸດສົ່ງ" QR (printed from the dashboard) and verify two things:
///   1. The bill number embedded in the URL matches the bill we're delivering
///   2. The driver's current GPS is close enough to the encoded lat/lng
///
/// QR payload is the same Google Maps URL the printer generates:
///   https://www.google.com/maps?q=LAT,LNG&bill=BILL_NO
class QrScanVerifyScreen extends StatefulWidget {
  const QrScanVerifyScreen({super.key, required this.bill});

  final DeliveryBill bill;

  @override
  State<QrScanVerifyScreen> createState() => _QrScanVerifyScreenState();
}

class _QrScanVerifyScreenState extends State<QrScanVerifyScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
  );
  _ScanResult? _result;
  bool _processing = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_processing || _result != null) return;
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null || raw.isEmpty) return;
    setState(() => _processing = true);
    HapticFeedback.mediumImpact();
    await _controller.stop();
    final parsed = _parsePayload(raw);
    if (parsed == null) {
      setState(() {
        _processing = false;
        _result = _ScanResult.invalid(raw: raw);
      });
      return;
    }
    // Capture the driver's current position. We don't await permission here —
    // jobs screen requested it on dispatch start; if it's denied we surface
    // the error so the driver knows GPS verification is unavailable.
    Position? pos;
    String? gpsError;
    try {
      pos = await Geolocator.getCurrentPosition(
        // Force a fresh fix — cached positions can lag the driver's actual
        // location by several minutes when they were just driving.
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 8),
        ),
      );
    } on TimeoutException {
      gpsError = 'GPS ບໍ່ຕອບກັບ — ກວດສອບສັນຍານແລ້ວ scan ໃໝ່';
    } catch (e) {
      gpsError = 'ບໍ່ສາມາດອ່ານ GPS: $e';
    }
    final billMatches =
        parsed.billNo.isEmpty || parsed.billNo == widget.bill.billNo;
    double? distance;
    if (pos != null) {
      distance = Geolocator.distanceBetween(
        pos.latitude,
        pos.longitude,
        parsed.lat,
        parsed.lng,
      );
    }
    if (!mounted) return;
    setState(() {
      _processing = false;
      _result = _ScanResult.ok(
        raw: raw,
        scannedBillNo: parsed.billNo,
        scannedLat: parsed.lat,
        scannedLng: parsed.lng,
        currentLat: pos?.latitude,
        currentLng: pos?.longitude,
        distanceMeters: distance,
        billMatches: billMatches,
        gpsError: gpsError,
      );
    });
  }

  _ParsedPayload? _parsePayload(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;
    final q = uri.queryParameters['q'];
    if (q == null) return null;
    final parts = q.split(',');
    if (parts.length < 2) return null;
    final lat = double.tryParse(parts[0].trim());
    final lng = double.tryParse(parts[1].trim());
    if (lat == null || lng == null) return null;
    final billNo = (uri.queryParameters['bill'] ?? '').trim();
    return _ParsedPayload(lat: lat, lng: lng, billNo: billNo);
  }

  void _rescan() {
    setState(() => _result = null);
    _controller.start();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Scan QR ກວດສອບຈຸດສົ່ງ'),
        actions: [
          IconButton(
            icon: const Icon(Icons.flash_on_rounded),
            onPressed: () => _controller.toggleTorch(),
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (_, error, __) => Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'ບໍ່ສາມາດເປີດກ້ອງ: ${error.errorDetails?.message ?? error.errorCode.name}',
                  style: const TextStyle(color: Colors.white),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ),
          // Aim overlay
          IgnorePointer(
            child: Center(
              child: Container(
                width: 260,
                height: 260,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white70, width: 3),
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
          Positioned(
            top: 16,
            left: 16,
            right: 16,
            child: _hintBanner(),
          ),
          if (_result != null) _resultSheet(_result!),
          if (_processing)
            const Center(child: CircularProgressIndicator(color: Colors.white)),
        ],
      ),
    );
  }

  Widget _hintBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.qr_code_scanner_rounded, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'ບີນ ${widget.bill.billNo} — ຍົກກ້ອງເຂົ້າຫາ QR ໃນບິນ',
              style: const TextStyle(color: Colors.white, fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _resultSheet(_ScanResult r) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        top: false,
        child: Container(
          margin: const EdgeInsets.all(12),
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
          decoration: BoxDecoration(
            color: AppTheme.bgCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppTheme.surfaceBorder),
          ),
          child: r.invalid
              ? _invalidBody(r)
              : _validBody(r),
        ),
      ),
    );
  }

  Widget _invalidBody(_ScanResult r) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: const [
            Icon(Icons.error_rounded, color: AppTheme.error, size: 20),
            SizedBox(width: 8),
            Text(
              'QR ບໍ່ຖືກຮູບແບບ',
              style: TextStyle(
                color: AppTheme.error,
                fontSize: 14,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'ບໍ່ໄດ້ມີ lat/lng ໃນ QR ນີ້ — ກວດສອບວ່າເປັນ QR ທີ່ພິມຈາກລະບົບ TMS.',
          style: TextStyle(
            color: AppTheme.textSecondary,
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          r.raw,
          style: const TextStyle(
            color: AppTheme.textMuted,
            fontSize: 10,
            fontFamily: 'monospace',
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 12),
        _actionRow(),
      ],
    );
  }

  Widget _validBody(_ScanResult r) {
    final dist = r.distanceMeters;
    Color color;
    String level;
    IconData icon;
    if (!r.billMatches) {
      color = AppTheme.error;
      level = 'ບີນບໍ່ຕົງກັນ';
      icon = Icons.warning_amber_rounded;
    } else if (dist == null) {
      color = AppTheme.warning;
      level = r.gpsError ?? 'ບໍ່ຮູ້ໄລຍະ';
      icon = Icons.gps_off_rounded;
    } else if (dist < 100) {
      color = AppTheme.success;
      level = 'ໃກ້ຈຸດສົ່ງ';
      icon = Icons.check_circle_rounded;
    } else if (dist < 500) {
      color = AppTheme.warning;
      level = 'ຄ່ອນຂ້າງໄກ';
      icon = Icons.warning_amber_rounded;
    } else {
      color = AppTheme.error;
      level = 'ໄກຈາກຈຸດສົ່ງ';
      icon = Icons.location_off_rounded;
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                level,
                style: TextStyle(
                  color: color,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (dist != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  _fmtDistance(dist),
                  style: TextStyle(
                    color: color,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        if (!r.billMatches)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppTheme.error.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              'QR ນີ້ສຳລັບບີນ ${r.scannedBillNo} — ບໍ່ໃຊ່ບີນ ${widget.bill.billNo}.',
              style: const TextStyle(
                color: AppTheme.error,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        _kv('ຈຸດສົ່ງ (ໃນ QR)',
            '${r.scannedLat!.toStringAsFixed(6)}, ${r.scannedLng!.toStringAsFixed(6)}'),
        _kv(
          'ຕຳແໜ່ງປະຈຸບັນ',
          r.currentLat != null && r.currentLng != null
              ? '${r.currentLat!.toStringAsFixed(6)}, ${r.currentLng!.toStringAsFixed(6)}'
              : (r.gpsError ?? '—'),
        ),
        const SizedBox(height: 12),
        _actionRow(),
      ],
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              k,
              style: const TextStyle(
                color: AppTheme.textMuted,
                fontSize: 11,
              ),
            ),
          ),
          Expanded(
            child: Text(
              v,
              style: const TextStyle(
                color: AppTheme.textBright,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _actionRow() {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _rescan,
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: const Text('Scan ໃໝ່'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.textBright,
              side: BorderSide(color: AppTheme.surfaceBorder),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.check_rounded, size: 16),
            label: const Text('ປິດ'),
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.primary,
              foregroundColor: Colors.white,
            ),
          ),
        ),
      ],
    );
  }

  String _fmtDistance(double meters) {
    if (meters < 1000) return '${meters.toStringAsFixed(0)} m';
    return '${(meters / 1000).toStringAsFixed(meters < 10000 ? 2 : 1)} km';
  }
}

class _ParsedPayload {
  const _ParsedPayload({
    required this.lat,
    required this.lng,
    required this.billNo,
  });
  final double lat;
  final double lng;
  final String billNo;
}

class _ScanResult {
  const _ScanResult._({
    required this.raw,
    required this.invalid,
    this.scannedLat,
    this.scannedLng,
    this.scannedBillNo = '',
    this.currentLat,
    this.currentLng,
    this.distanceMeters,
    this.billMatches = true,
    this.gpsError,
  });

  factory _ScanResult.invalid({required String raw}) =>
      _ScanResult._(raw: raw, invalid: true);

  factory _ScanResult.ok({
    required String raw,
    required String scannedBillNo,
    required double scannedLat,
    required double scannedLng,
    double? currentLat,
    double? currentLng,
    double? distanceMeters,
    required bool billMatches,
    String? gpsError,
  }) => _ScanResult._(
    raw: raw,
    invalid: false,
    scannedBillNo: scannedBillNo,
    scannedLat: scannedLat,
    scannedLng: scannedLng,
    currentLat: currentLat,
    currentLng: currentLng,
    distanceMeters: distanceMeters,
    billMatches: billMatches,
    gpsError: gpsError,
  );

  final String raw;
  final bool invalid;
  final String scannedBillNo;
  final double? scannedLat;
  final double? scannedLng;
  final double? currentLat;
  final double? currentLng;
  final double? distanceMeters;
  final bool billMatches;
  final String? gpsError;
}
