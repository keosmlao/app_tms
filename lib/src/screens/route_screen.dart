import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_theme.dart';
import '../models/delivery_bill.dart';

/// A nearest-neighbour delivery route over the trip's remaining stops, ordered
/// from the driver's current position. Client-side (straight-line) ordering +
/// rough ETA at ~25 km/h — no routing service required (Module C / P1a).
class RouteScreen extends StatefulWidget {
  const RouteScreen({super.key, required this.bills});

  /// Unfinished bills of the current trip (the screen filters to ones with a
  /// usable coordinate).
  final List<DeliveryBill> bills;

  @override
  State<RouteScreen> createState() => _RouteScreenState();
}

class _Stop {
  final DeliveryBill bill;
  final LatLng point;
  double legKm = 0; // distance from the previous stop
  double cumulativeKm = 0;
  _Stop(this.bill, this.point);
}

class _RouteScreenState extends State<RouteScreen> {
  static const _vientiane = LatLng(17.9757, 102.6331);
  static const _avgSpeedKmh = 25.0; // rough urban average for ETA

  final _mapController = MapController();
  LatLng? _origin;
  List<_Stop> _stops = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _build();
  }

  LatLng? _billPoint(DeliveryBill b) {
    double? parse(String s) {
      final v = double.tryParse(s.trim());
      if (v == null || v == 0) return null;
      return v;
    }

    // Prefer the dispatcher's planned pin, else the bill's lat/lng.
    final plat = parse(b.plannedLat), plng = parse(b.plannedLng);
    if (plat != null && plng != null) return LatLng(plat, plng);
    final lat = parse(b.lat), lng = parse(b.lng);
    if (lat != null && lng != null) return LatLng(lat, lng);
    return null;
  }

  Future<void> _build() async {
    try {
      final located = <_Stop>[];
      for (final b in widget.bills) {
        if (b.isFinished) continue;
        final p = _billPoint(b);
        if (p != null) located.add(_Stop(b, p));
      }
      if (located.isEmpty) {
        setState(() {
          _error = 'ບໍ່ມີບິນທີ່ມີພິກັດສຳລັບຈັດເສັ້ນທາງ';
          _loading = false;
        });
        return;
      }

      LatLng origin = _vientiane;
      try {
        final pos = await Geolocator.getCurrentPosition(
          locationSettings:
              const LocationSettings(accuracy: LocationAccuracy.high),
        ).timeout(const Duration(seconds: 12));
        origin = LatLng(pos.latitude, pos.longitude);
      } catch (_) {
        // Fall back to ordering from the first stop if GPS is unavailable.
        origin = located.first.point;
      }

      // Greedy nearest-neighbour ordering.
      final distance = const Distance();
      final remaining = [...located];
      final ordered = <_Stop>[];
      var cursor = origin;
      var cumulative = 0.0;
      while (remaining.isNotEmpty) {
        remaining.sort((a, b) => distance
            .as(LengthUnit.Meter, cursor, a.point)
            .compareTo(distance.as(LengthUnit.Meter, cursor, b.point)));
        final next = remaining.removeAt(0);
        next.legKm = distance.as(LengthUnit.Kilometer, cursor, next.point);
        cumulative += next.legKm;
        next.cumulativeKm = cumulative;
        ordered.add(next);
        cursor = next.point;
      }

      if (!mounted) return;
      setState(() {
        _origin = origin;
        _stops = ordered;
        _loading = false;
      });
      _fit();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _fit() {
    final pts = <LatLng>[
      if (_origin != null) _origin!,
      for (final s in _stops) s.point,
    ];
    if (pts.length < 2) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _mapController.fitCamera(
        CameraFit.bounds(
          bounds: LatLngBounds.fromPoints(pts),
          padding: const EdgeInsets.fromLTRB(40, 90, 40, 300),
          maxZoom: 16,
        ),
      );
    });
  }

  String _eta(double cumulativeKm) {
    final mins = (cumulativeKm / _avgSpeedKmh * 60).round();
    if (mins < 60) return '~$mins ນາທີ';
    return '~${mins ~/ 60} ຊມ ${mins % 60} ນທ';
  }

  Future<void> _navigate(_Stop s) async {
    HapticFeedback.selectionClick();
    final uri = Uri.parse(
      'https://www.google.com/maps/dir/?api=1&destination=${s.point.latitude},${s.point.longitude}&travelmode=driving',
    );
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgDark,
      appBar: AppBar(
        backgroundColor: AppTheme.bgDark,
        foregroundColor: AppTheme.textBright,
        elevation: 0,
        title: Text(
          'ເສັ້ນທາງຈັດສົ່ງ · ${_stops.length} ຈຸດ',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primary),
            )
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppTheme.textMuted),
                ),
              ),
            )
          : Column(
              children: [
                SizedBox(height: 260, child: _map()),
                Expanded(child: _list()),
              ],
            ),
    );
  }

  Widget _map() {
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: _origin ?? _vientiane,
        initialZoom: 12,
        minZoom: 4,
        maxZoom: 19,
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.odg.odgtms',
        ),
        PolylineLayer(
          polylines: [
            Polyline(
              points: [
                if (_origin != null) _origin!,
                for (final s in _stops) s.point,
              ],
              strokeWidth: 3,
              color: AppTheme.primary.withValues(alpha: 0.8),
            ),
          ],
        ),
        MarkerLayer(
          markers: [
            if (_origin != null)
              Marker(
                point: _origin!,
                width: 22,
                height: 22,
                child: const Icon(
                  Icons.my_location_rounded,
                  color: AppTheme.info,
                  size: 20,
                ),
              ),
            for (var i = 0; i < _stops.length; i++)
              Marker(
                point: _stops[i].point,
                width: 26,
                height: 26,
                child: Container(
                  decoration: const BoxDecoration(
                    color: AppTheme.primary,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    '${i + 1}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _list() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 20),
      itemCount: _stops.length,
      itemBuilder: (_, i) {
        final s = _stops[i];
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.bgSurface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.surfaceBorder),
          ),
          child: Row(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: AppTheme.primary.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  '${i + 1}',
                  style: const TextStyle(
                    color: AppTheme.primary,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.bill.custName.isNotEmpty
                          ? s.bill.custName
                          : s.bill.billNo,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTheme.textBright,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${s.bill.billNo} · ${s.cumulativeKm.toStringAsFixed(1)} km · ${_eta(s.cumulativeKm)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTheme.textMuted,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => _navigate(s),
                icon: const Icon(
                  Icons.navigation_rounded,
                  color: AppTheme.primary,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
