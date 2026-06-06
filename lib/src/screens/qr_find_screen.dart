import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/app_theme.dart';

/// Parsed result of a "ຈຸດສົ່ງ" QR scan plus the driver's GPS at scan time.
/// Not bound to a specific bill — the caller matches it against the trip's
/// bills (by [billNo]) and the 50 m proximity check.
class QrFindResult {
  const QrFindResult({
    required this.billNo,
    required this.lat,
    required this.lng,
    required this.pos,
    this.gpsError,
  });

  final String billNo;
  final double lat;
  final double lng;
  final Position? pos;
  final String? gpsError;
}

/// Full-screen QR scanner used by the floating "Scan ສຳເລັດ" button. Scans the
/// dashboard QR (`…/maps?q=LAT,LNG&bill=BILL_NO`), captures a fresh GPS fix, and
/// pops a [QrFindResult] for the caller to resolve.
class QrFindScreen extends StatefulWidget {
  const QrFindScreen({super.key});

  @override
  State<QrFindScreen> createState() => _QrFindScreenState();
}

class _QrFindScreenState extends State<QrFindScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
  );
  bool _processing = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_processing) return;
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null || raw.isEmpty) return;
    setState(() => _processing = true);
    HapticFeedback.mediumImpact();
    await _controller.stop();

    final uri = Uri.tryParse(raw);
    final q = uri?.queryParameters['q'];
    final parts = (q ?? '').split(',');
    final lat = parts.length >= 2 ? double.tryParse(parts[0].trim()) : null;
    final lng = parts.length >= 2 ? double.tryParse(parts[1].trim()) : null;
    final billNo = (uri?.queryParameters['bill'] ?? '').trim();
    if (lat == null || lng == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('QR ບໍ່ຖືກຕ້ອງ — ບໍ່ແມ່ນ QR ຈຸດສົ່ງ')),
      );
      Navigator.pop(context);
      return;
    }

    Position? pos;
    String? gpsError;
    try {
      pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 8),
        ),
      );
    } on TimeoutException {
      gpsError = 'GPS ບໍ່ຕອບກັບ';
    } catch (e) {
      gpsError = 'ບໍ່ສາມາດອ່ານ GPS: $e';
    }

    if (!mounted) return;
    Navigator.pop(
      context,
      QrFindResult(
        billNo: billNo,
        lat: lat,
        lng: lng,
        pos: pos,
        gpsError: gpsError,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Scan QR ສຳເລັດການສົ່ງ'),
      ),
      body: Stack(
        alignment: Alignment.center,
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          // Aiming frame.
          Container(
            width: 230,
            height: 230,
            decoration: BoxDecoration(
              border: Border.all(color: AppTheme.success, width: 3),
              borderRadius: BorderRadius.circular(16),
            ),
          ),
          Positioned(
            bottom: 40,
            left: 24,
            right: 24,
            child: Text(
              _processing
                  ? 'ກຳລັງກວດສອບ...'
                  : 'ເລັງ QR ຈຸດສົ່ງ — ລະບົບຈະຫາບິນ + ກວດໄລຍະ 50m ໃຫ້ເອງ',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (_processing)
            const Center(child: CircularProgressIndicator(color: Colors.white)),
        ],
      ),
    );
  }
}
