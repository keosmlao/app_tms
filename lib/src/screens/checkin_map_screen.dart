import 'dart:async';

import 'package:flutter_map/flutter_map.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  final _mapController = MapController();
  final _distance = const Distance();
  StreamSubscription<Position>? _posSub;
  Position? _current;
  String? _error;
  bool _confirming = false;
  bool _mapReady = false;

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
        }
      } catch (_) {
        // ignore; the stream below will provide the position when ready.
      }

      _posSub =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.bestForNavigation,
              distanceFilter: 2,
            ),
          ).listen((pos) {
            if (!mounted) return;
            final wasWaiting = _current == null;
            setState(() => _current = pos);
            if (wasWaiting) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _fitInitialMap();
              });
            }
          });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _recenter() {
    final target = _currentPoint ?? _customerPoint;
    if (!_mapReady || target == null) return;
    HapticFeedback.selectionClick();
    _mapController.move(target, _currentPoint != null ? 17 : 15);
  }

  Future<void> _confirm() async {
    if (_current == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('ຍັງບໍ່ໄດ້ຮັບສັນຍານ GPS')));
      return;
    }
    HapticFeedback.mediumImpact();
    setState(() => _confirming = true);
    Navigator.pop(context, _current);
  }

  LatLng? get _currentPoint {
    final current = _current;
    if (current == null) return null;
    return LatLng(current.latitude, current.longitude);
  }

  LatLng? get _customerPoint {
    final plannedLat = double.tryParse(widget.bill.plannedLat.trim());
    final plannedLng = double.tryParse(widget.bill.plannedLng.trim());
    if (_validPoint(plannedLat, plannedLng)) {
      return LatLng(plannedLat!, plannedLng!);
    }
    final lat = double.tryParse(widget.bill.lat.trim());
    final lng = double.tryParse(widget.bill.lng.trim());
    if (_validPoint(lat, lng)) return LatLng(lat!, lng!);
    return null;
  }

  bool _validPoint(double? lat, double? lng) {
    if (lat == null || lng == null) return false;
    if (lat == 0 && lng == 0) return false;
    return lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180;
  }

  double? get _distanceMeters {
    final current = _currentPoint;
    final customer = _customerPoint;
    if (current == null || customer == null) return null;
    return _distance.as(LengthUnit.Meter, current, customer);
  }

  String _formatDistance(double meters) {
    if (meters >= 1000) return '${(meters / 1000).toStringAsFixed(2)} km';
    return '${meters.toStringAsFixed(0)} m';
  }

  Color _distanceColor(double? meters) {
    if (meters == null) return AppTheme.textMuted;
    if (meters <= 120) return AppTheme.success;
    if (meters <= 500) return AppTheme.warning;
    return AppTheme.error;
  }

  String get _customerLocationLabel {
    final hasPlanned =
        widget.bill.plannedLat.trim().isNotEmpty &&
        widget.bill.plannedLng.trim().isNotEmpty;
    if (hasPlanned) return 'ຈຸດທີ່ dispatcher ກຳນົດ';
    if (_customerPoint != null) return 'ຈຸດລູກຄ້າຈາກລະບົບ';
    return 'ບໍ່ມີພິກັດລູກຄ້າ';
  }

  void _fitInitialMap() {
    if (!_mapReady) return;
    final current = _currentPoint;
    final customer = _customerPoint;
    if (current != null && customer != null) {
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds.fromPoints([current, customer]),
          padding: const EdgeInsets.fromLTRB(56, 150, 56, 260),
          maxZoom: 17,
        ),
      );
      return;
    }
    final single = current ?? customer;
    if (single != null) _mapController.move(single, current != null ? 17 : 15);
  }

  @override
  Widget build(BuildContext context) {
    final current = _currentPoint;
    final customer = _customerPoint;
    final distanceMeters = _distanceMeters;
    final initialCenter =
        current ?? customer ?? const LatLng(17.9757, 102.6331);
    return Scaffold(
      backgroundColor: AppTheme.bgDark,
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: initialCenter,
              initialZoom: current != null ? 17 : 15,
              minZoom: 4,
              maxZoom: 19,
              onMapReady: () {
                _mapReady = true;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _fitInitialMap();
                });
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.odg.odgtms',
              ),
              if (current != null && customer != null)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: [current, customer],
                      strokeWidth: 4,
                      color: _distanceColor(
                        distanceMeters,
                      ).withValues(alpha: 0.85),
                    ),
                  ],
                ),
              MarkerLayer(
                markers: [
                  if (customer != null)
                    Marker(
                      point: customer,
                      width: 52,
                      height: 52,
                      child: const _PinIcon(
                        color: AppTheme.warning,
                        icon: Icons.storefront_rounded,
                      ),
                    ),
                  if (current != null)
                    Marker(
                      point: current,
                      width: 54,
                      height: 54,
                      child: const _PinIcon(
                        color: AppTheme.primary,
                        icon: Icons.local_shipping_rounded,
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
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.bgCard.withValues(alpha: 0.92),
                        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
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
                            '${widget.bill.custName} · $_customerLocationLabel',
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
                        borderRadius: BorderRadius.circular(AppTheme.radiusXl),
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
                                      ? AppTheme.success.withValues(alpha: 0.15)
                                      : AppTheme.warning.withValues(
                                          alpha: 0.15,
                                        ),
                                  borderRadius: BorderRadius.circular(
                                    AppTheme.radiusMd,
                                  ),
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
                                  crossAxisAlignment: CrossAxisAlignment.start,
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
                                          : 'ກວດສິດ Location ໃນ Settings ຖ້າລໍຖ້ານານ',
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
                          if (customer != null || distanceMeters != null) ...[
                            const SizedBox(height: 12),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: AppTheme.bgSurface,
                                borderRadius: BorderRadius.circular(
                                  AppTheme.radiusMd,
                                ),
                                border: Border.all(
                                  color: AppTheme.surfaceBorder,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.route_rounded,
                                    color: _distanceColor(distanceMeters),
                                    size: 18,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      distanceMeters != null
                                          ? 'ຫ່າງຈາກຈຸດສົ່ງ ${_formatDistance(distanceMeters)}'
                                          : _customerLocationLabel,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: _distanceColor(distanceMeters),
                                        fontSize: 12,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
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
  const _PinIcon({required this.color, required this.icon, this.glow = false});

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
