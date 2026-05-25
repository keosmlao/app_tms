import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../core/app_theme.dart';
import '../models/delivery_bill.dart';

/// Map screen shown before a driver confirms checkin. Displays the driver's
/// live GPS position (and the customer's stored location if available) so the
/// driver can verify they're at the right spot before sending the action.
class CheckinMapScreen extends StatefulWidget {
  const CheckinMapScreen({super.key, required this.bill});

  final DeliveryBill bill;

  @override
  State<CheckinMapScreen> createState() => _CheckinMapScreenState();
}

class _CheckinMapScreenState extends State<CheckinMapScreen> {
  final _mapCtrl = MapController();
  StreamSubscription<Position>? _posSub;
  Position? _current;
  String? _error;
  bool _confirming = false;

  LatLng? get _customerPoint {
    // Prefer the dispatcher's planned pin (set on the bills-pending dashboard)
    // — it's verified by a human and won't drift like the customer's stored
    // coordinates. Fall back to the bill's lat/lng otherwise.
    final pLat = double.tryParse(widget.bill.plannedLat.trim());
    final pLng = double.tryParse(widget.bill.plannedLng.trim());
    if (pLat != null && pLng != null && !(pLat == 0 && pLng == 0)) {
      return LatLng(pLat, pLng);
    }
    final lat = double.tryParse(widget.bill.lat.trim());
    final lng = double.tryParse(widget.bill.lng.trim());
    if (lat == null || lng == null) return null;
    if (lat == 0 && lng == 0) return null;
    return LatLng(lat, lng);
  }

  @override
  void initState() {
    super.initState();
    _startTracking();
  }

  @override
  void dispose() {
    _posSub?.cancel();
    super.dispose();
  }

  Future<void> _startTracking() async {
    try {
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        final req = await Geolocator.requestPermission();
        if (req == LocationPermission.denied ||
            req == LocationPermission.deniedForever) {
          setState(() => _error = 'ບໍ່ໄດ້ສິດເຂົ້າເຖິງ GPS');
          return;
        }
      }
      // Try to grab a one-shot position quickly so the marker shows even before
      // the stream emits.
      try {
        final first = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
          ),
        );
        if (mounted) {
          setState(() => _current = first);
          _mapCtrl.move(LatLng(first.latitude, first.longitude), 17);
        }
      } catch (_) {
        // ignore; the stream below will provide the position when ready.
      }

      _posSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 2,
        ),
      ).listen((pos) {
        if (!mounted) return;
        setState(() => _current = pos);
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _recenter() {
    if (_current == null) return;
    HapticFeedback.selectionClick();
    _mapCtrl.move(LatLng(_current!.latitude, _current!.longitude), 18);
  }

  Future<void> _confirm() async {
    if (_current == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ຍັງບໍ່ໄດ້ຮັບສັນຍານ GPS')),
      );
      return;
    }
    HapticFeedback.mediumImpact();
    setState(() => _confirming = true);
    Navigator.pop(context, _current);
  }

  @override
  Widget build(BuildContext context) {
    final initialCenter = _current != null
        ? LatLng(_current!.latitude, _current!.longitude)
        : _customerPoint ?? const LatLng(17.967, 102.611); // Vientiane fallback

    return Scaffold(
      backgroundColor: AppTheme.bgDark,
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapCtrl,
            options: MapOptions(
              initialCenter: initialCenter,
              initialZoom: 17,
              minZoom: 4,
              maxZoom: 19,
            ),
            children: [
              TileLayer(
                urlTemplate:
                    'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.odg.odgtms',
                maxZoom: 19,
              ),
              if (_customerPoint != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _customerPoint!,
                      width: 44,
                      height: 44,
                      child: _PinIcon(
                        color: AppTheme.warning,
                        icon: Icons.store_rounded,
                      ),
                    ),
                  ],
                ),
              if (_current != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: LatLng(
                        _current!.latitude,
                        _current!.longitude,
                      ),
                      width: 56,
                      height: 56,
                      child: _PinIcon(
                        color: AppTheme.primary,
                        icon: Icons.my_location_rounded,
                        glow: true,
                      ),
                    ),
                  ],
                ),
            ],
          ),

          // Top app bar
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: Row(
                children: [
                  _circleBtn(
                    Icons.arrow_back_rounded,
                    () => Navigator.pop(context),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppTheme.bgCard.withValues(alpha: 0.92),
                        borderRadius:
                            BorderRadius.circular(AppTheme.radiusLg),
                        border: Border.all(color: AppTheme.surfaceBorder),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Check-in · ${widget.bill.billNo}',
                            style: const TextStyle(
                              color: AppTheme.textBright,
                              fontSize: 13,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            widget.bill.custName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppTheme.textMuted,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // GPS status bottom card
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Align(
                      alignment: Alignment.centerRight,
                      child: _circleBtn(
                        Icons.my_location_rounded,
                        _recenter,
                        elevated: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                      decoration: BoxDecoration(
                        color: AppTheme.bgCard,
                        borderRadius:
                            BorderRadius.circular(AppTheme.radiusXl),
                        border: Border.all(color: AppTheme.surfaceBorder),
                        boxShadow: AppTheme.shadowMd,
                      ),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: _current != null
                                      ? AppTheme.success
                                          .withValues(alpha: 0.15)
                                      : AppTheme.warning
                                          .withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(
                                      AppTheme.radiusMd),
                                ),
                                child: Icon(
                                  _current != null
                                      ? Icons.gps_fixed_rounded
                                      : Icons.gps_not_fixed_rounded,
                                  color: _current != null
                                      ? AppTheme.success
                                      : AppTheme.warning,
                                  size: 18,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      _current != null
                                          ? 'ໄດ້ສັນຍານ GPS'
                                          : (_error ?? 'ກຳລັງຫາ GPS...'),
                                      style: const TextStyle(
                                        color: AppTheme.textBright,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      _current != null
                                          ? '${_current!.latitude.toStringAsFixed(6)}, ${_current!.longitude.toStringAsFixed(6)} · ±${_current!.accuracy.toStringAsFixed(0)} m'
                                          : 'ກວດສິດ Location ໃນ Settings ຖ້າຍູ່ນານ',
                                      style: const TextStyle(
                                        color: AppTheme.textMuted,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          SizedBox(
                            width: double.infinity,
                            height: 50,
                            child: FilledButton.icon(
                              onPressed: _current == null || _confirming
                                  ? null
                                  : _confirm,
                              icon: _confirming
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.location_on_rounded,
                                      size: 20,
                                    ),
                              label: const Text(
                                'ຢືນຢັນ Check-in',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w900,
                                ),
                              ),
                              style: FilledButton.styleFrom(
                                backgroundColor: AppTheme.primary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _circleBtn(
    IconData icon,
    VoidCallback onTap, {
    bool elevated = false,
  }) {
    return Material(
      color: AppTheme.bgCard.withValues(alpha: 0.92),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusFull),
        side: const BorderSide(color: AppTheme.surfaceBorder),
      ),
      elevation: elevated ? 6 : 0,
      shadowColor: Colors.black.withValues(alpha: 0.4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.radiusFull),
        child: SizedBox(
          width: 44,
          height: 44,
          child: Icon(icon, color: AppTheme.textBright, size: 20),
        ),
      ),
    );
  }
}

class _PinIcon extends StatelessWidget {
  const _PinIcon({
    required this.color,
    required this.icon,
    this.glow = false,
  });

  final Color color;
  final IconData icon;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        border: Border.all(color: Colors.white, width: 2.5),
        boxShadow: [
          if (glow)
            BoxShadow(
              color: color.withValues(alpha: 0.55),
              blurRadius: 16,
              spreadRadius: 4,
            ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Icon(icon, color: Colors.white, size: 20),
    );
  }
}
