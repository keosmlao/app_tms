import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../app_controller.dart';
import '../core/app_theme.dart';
import '../models/delivery_job.dart';
import '../models/fleet_driver.dart';
import '../services/api_client.dart';
import 'job_detail_screen.dart';

enum _FleetFilter { all, vehicle, phone, online, offline }

class FleetMapScreen extends StatefulWidget {
  const FleetMapScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<FleetMapScreen> createState() => _FleetMapScreenState();
}

class _FleetMapScreenState extends State<FleetMapScreen> {
  static const _vientiane = LatLng(17.9757, 102.6331);

  final _mapController = MapController();
  final _searchController = TextEditingController();
  Timer? _refresh;
  List<FleetDriver> _items = const [];
  _FleetFilter _filter = _FleetFilter.all;
  FleetDriver? _selected;
  bool _loading = true;
  bool _fitted = false;
  String _search = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetch();
    _refresh = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _fetch(silent: true),
    );
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetch({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final data = await widget.controller.api.getFleet();
      if (!mounted) return;
      setState(() {
        _items = data;
        _loading = false;
        _error = null;
      });
      _fitVisible();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is ApiException ? e.message : '$e';
      });
    }
  }

  List<FleetDriver> get _located =>
      _items.where((item) => item.hasLocation).toList(growable: false);

  List<FleetDriver> get _visible {
    final query = _search.trim().toLowerCase();
    return _located
        .where((item) {
          final filterMatch = switch (_filter) {
            _FleetFilter.all => true,
            _FleetFilter.vehicle => item.isVehicleGps,
            _FleetFilter.phone => item.isPhoneGps,
            _FleetFilter.online => item.isOnline,
            _FleetFilter.offline => !item.isOnline,
          };
          if (!filterMatch) return false;
          if (query.isEmpty) return true;
          return '${item.car} ${item.driver} ${item.docNo} ${item.address}'
              .toLowerCase()
              .contains(query);
        })
        .toList(growable: false);
  }

  int get _vehicleCount => _located.where((item) => item.isVehicleGps).length;
  int get _phoneCount => _located.where((item) => item.isPhoneGps).length;
  int get _onlineCount => _located.where((item) => item.isOnline).length;
  int get _offlineCount => _located.where((item) => !item.isOnline).length;

  Color _markerColor(FleetDriver item) {
    if (!item.isOnline) return AppTheme.textDim;
    if (item.isVehicleGps) return AppTheme.info;
    return switch (item.jobStatus) {
      2 => AppTheme.success,
      1 => AppTheme.warning,
      _ => AppTheme.primary,
    };
  }

  String _statusText(FleetDriver item) {
    if (!item.isOnline) return 'ບໍ່ອອນລາຍ';
    if (item.isVehicleGps) return 'GPS ລົດອອນລາຍ';
    return switch (item.jobStatus) {
      2 => 'ກຳລັງຈັດສົ່ງ',
      1 => 'ຮັບຖ້ຽວ / ເບີກເຄື່ອງ',
      _ => 'ມືຖືອອນລາຍ',
    };
  }

  String _ago(int seconds) {
    if (seconds <= 0) return 'ຫາກໍອັບເດດ';
    if (seconds < 60) return '$seconds ວິນາທີ';
    if (seconds < 3600) return '${seconds ~/ 60} ນາທີ';
    return '${seconds ~/ 3600} ຊົ່ວໂມງ';
  }

  void _fitVisible({bool force = false}) {
    if (_fitted && !force) return;
    final points = _visible
        .map((item) => LatLng(item.lat!, item.lng!))
        .toList(growable: false);
    if (points.isEmpty) return;
    _fitted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (points.length == 1) {
        _mapController.move(points.first, 16);
      } else {
        _mapController.fitCamera(
          CameraFit.bounds(
            bounds: LatLngBounds.fromPoints(points),
            padding: const EdgeInsets.fromLTRB(40, 190, 40, 210),
            maxZoom: 16,
          ),
        );
      }
    });
  }

  void _setFilter(_FleetFilter filter) {
    HapticFeedback.selectionClick();
    setState(() {
      _filter = filter;
      _selected = null;
    });
    _fitVisible(force: true);
  }

  void _select(FleetDriver item) {
    HapticFeedback.selectionClick();
    setState(() => _selected = item);
    _mapController.move(LatLng(item.lat!, item.lng!), 16);
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    return Scaffold(
      backgroundColor: AppTheme.bgDark,
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: const MapOptions(
              initialCenter: _vientiane,
              initialZoom: 12,
              minZoom: 4,
              maxZoom: 19,
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.odg.odgtms',
              ),
              MarkerLayer(
                markers: [
                  for (final item in visible)
                    Marker(
                      point: LatLng(item.lat!, item.lng!),
                      width: 52,
                      height: 58,
                      alignment: Alignment.topCenter,
                      child: GestureDetector(
                        onTap: () => _select(item),
                        child: _FleetPin(
                          color: _markerColor(item),
                          icon: item.isVehicleGps
                              ? Icons.local_shipping_rounded
                              : Icons.person_pin_circle_rounded,
                          selected: identical(_selected, item),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.center,
                    colors: [
                      AppTheme.bgDark.withValues(alpha: 0.62),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _header(),
                  const SizedBox(height: 10),
                  _summaryStrip(),
                  const SizedBox(height: 8),
                  _filterBar(),
                ],
              ),
            ),
          ),
          Positioned(
            right: 12,
            bottom: 172,
            child: Column(
              children: [
                _mapAction(
                  icon: Icons.center_focus_strong_rounded,
                  tooltip: 'ສະແດງທຸກຈຸດ',
                  onTap: () => _fitVisible(force: true),
                ),
                const SizedBox(height: 8),
                _mapAction(
                  icon: Icons.refresh_rounded,
                  tooltip: 'ໂຫຼດໃໝ່',
                  onTap: () => _fetch(),
                ),
              ],
            ),
          ),
          if (_selected != null)
            Positioned(
              left: 12,
              right: 12,
              bottom: 154,
              child: _selectedCard(_selected!),
            ),
          _fleetSheet(visible),
          if (_loading)
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(
                minHeight: 2,
                color: AppTheme.primary,
                backgroundColor: Colors.transparent,
              ),
            ),
          if (_error != null) _errorBanner(),
        ],
      ),
    );
  }

  Widget _header() {
    return Row(
      children: [
        _roundButton(
          icon: Icons.arrow_back_rounded,
          tooltip: 'ກັບຄືນ',
          onTap: () => Navigator.pop(context),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Container(
            height: 50,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: AppTheme.bgDark.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              border: Border.all(color: AppTheme.surfaceBorder),
              boxShadow: AppTheme.shadowMd,
            ),
            child: const Row(
              children: [
                Icon(Icons.radar_rounded, color: AppTheme.primaryLight),
                SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Fleet Control',
                        style: TextStyle(
                          color: AppTheme.textBright,
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      Text(
                        'ຕິດຕາມລົດ ແລະ ຄົນຂັບແບບສົດ',
                        style: TextStyle(
                          color: AppTheme.textMuted,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _summaryStrip() {
    return Container(
      height: 58,
      decoration: BoxDecoration(
        color: AppTheme.bgDark.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppTheme.surfaceBorder),
      ),
      child: Row(
        children: [
          _summaryItem(
            value: '$_onlineCount',
            label: 'ອອນລາຍ',
            color: AppTheme.success,
          ),
          _divider(),
          _summaryItem(
            value: '$_vehicleCount',
            label: 'GPS ລົດ',
            color: AppTheme.info,
          ),
          _divider(),
          _summaryItem(
            value: '$_phoneCount',
            label: 'ມືຖື',
            color: AppTheme.primaryLight,
          ),
          _divider(),
          _summaryItem(
            value: '$_offlineCount',
            label: 'ຂາດສັນຍານ',
            color: AppTheme.warning,
          ),
        ],
      ),
    );
  }

  Widget _summaryItem({
    required String value,
    required String label,
    required Color color,
  }) {
    return Expanded(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 17,
              fontWeight: FontWeight.w900,
            ),
          ),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 9),
          ),
        ],
      ),
    );
  }

  Widget _divider() =>
      Container(width: 1, height: 28, color: AppTheme.surfaceBorder);

  Widget _filterBar() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _filterButton(_FleetFilter.all, 'ທັງໝົດ', Icons.layers_rounded),
          _filterButton(
            _FleetFilter.vehicle,
            'GPS ລົດ',
            Icons.local_shipping_rounded,
          ),
          _filterButton(
            _FleetFilter.phone,
            'ມືຖືຄົນຂັບ',
            Icons.phone_android_rounded,
          ),
          _filterButton(_FleetFilter.online, 'ອອນລາຍ', Icons.wifi_rounded),
          _filterButton(
            _FleetFilter.offline,
            'ຂາດສັນຍານ',
            Icons.wifi_off_rounded,
          ),
        ],
      ),
    );
  }

  Widget _filterButton(_FleetFilter value, String label, IconData icon) {
    final selected = _filter == value;
    return Padding(
      padding: const EdgeInsets.only(right: 7),
      child: Material(
        color: selected
            ? AppTheme.primary
            : AppTheme.bgDark.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(AppTheme.radiusFull),
        child: InkWell(
          onTap: () => _setFilter(value),
          borderRadius: BorderRadius.circular(AppTheme.radiusFull),
          child: Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppTheme.radiusFull),
              border: Border.all(
                color: selected ? AppTheme.primary : AppTheme.surfaceBorder,
              ),
            ),
            child: Row(
              children: [
                Icon(icon, size: 14, color: AppTheme.textBright),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: const TextStyle(
                    color: AppTheme.textBright,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _fleetSheet(List<FleetDriver> visible) {
    return DraggableScrollableSheet(
      initialChildSize: 0.12,
      minChildSize: 0.12,
      maxChildSize: 0.68,
      snap: true,
      snapSizes: const [0.12, 0.38, 0.68],
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: AppTheme.bgDark,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
            border: Border.all(color: AppTheme.surfaceBorder),
            boxShadow: AppTheme.shadowLg,
          ),
          child: ListView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(12, 7, 12, 24),
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppTheme.textDim,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
              const SizedBox(height: 9),
              Row(
                children: [
                  const Icon(
                    Icons.list_alt_rounded,
                    color: AppTheme.primaryLight,
                    size: 19,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'ລາຍການຕິດຕາມ · ${visible.length} ຈຸດ',
                      style: const TextStyle(
                        color: AppTheme.textBright,
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  Text(
                    'ລາກຂຶ້ນເພື່ອເບິ່ງ',
                    style: TextStyle(
                      color: AppTheme.textMuted.withValues(alpha: 0.8),
                      fontSize: 9,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _searchController,
                onChanged: (value) => setState(() => _search = value),
                style: const TextStyle(
                  color: AppTheme.textBright,
                  fontSize: 12,
                ),
                decoration: InputDecoration(
                  hintText: 'ຄົ້ນຫາລົດ, ຄົນຂັບ ຫຼື ເລກຖ້ຽວ',
                  prefixIcon: const Icon(Icons.search_rounded, size: 19),
                  suffixIcon: _search.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'ລ້າງຄຳຄົ້ນ',
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _search = '');
                          },
                          icon: const Icon(Icons.close_rounded, size: 18),
                        ),
                ),
              ),
              const SizedBox(height: 10),
              if (visible.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 28),
                  child: Text(
                    'ບໍ່ພົບຕຳແໜ່ງຕາມຕົວກອງທີ່ເລືອກ',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
                  ),
                )
              else
                for (final item in visible) _fleetRow(item),
            ],
          ),
        );
      },
    );
  }

  Widget _fleetRow(FleetDriver item) {
    final color = _markerColor(item);
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Material(
        color: identical(_selected, item)
            ? color.withValues(alpha: 0.12)
            : AppTheme.bgCard,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        child: InkWell(
          onTap: () {
            _select(item);
            _showDetails(item);
          },
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          child: Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              border: Border.all(
                color: identical(_selected, item)
                    ? color.withValues(alpha: 0.6)
                    : AppTheme.surfaceBorder,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                  ),
                  child: Icon(
                    item.isVehicleGps
                        ? Icons.local_shipping_rounded
                        : Icons.phone_android_rounded,
                    color: color,
                    size: 19,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.isVehicleGps ? item.car : item.driver,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.textBright,
                          fontSize: 12,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        item.isVehicleGps
                            ? '${item.speed.isEmpty ? '0' : item.speed} km/h · ${_ago(item.ageSeconds)}'
                            : '${item.car} · ${_ago(item.ageSeconds)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.textMuted,
                          fontSize: 10,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: AppTheme.textMuted,
                  size: 19,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _selectedCard(FleetDriver item) {
    final color = _markerColor(item);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.bgDark.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: color.withValues(alpha: 0.65)),
        boxShadow: AppTheme.shadowLg,
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(AppTheme.radiusSm),
            ),
            child: Icon(
              item.isVehicleGps
                  ? Icons.local_shipping_rounded
                  : Icons.phone_android_rounded,
              color: color,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.isVehicleGps ? item.car : item.driver,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.textBright,
                    fontSize: 13,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Text(
                  '${_statusText(item)} · ${_ago(item.ageSeconds)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: color, fontSize: 10),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'ເບິ່ງລາຍລະອຽດ',
            onPressed: () => _showDetails(item),
            icon: const Icon(
              Icons.info_outline_rounded,
              color: AppTheme.textBright,
            ),
          ),
          IconButton(
            tooltip: 'ປິດ',
            onPressed: () => setState(() => _selected = null),
            icon: const Icon(Icons.close_rounded, color: AppTheme.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _mapAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return _roundButton(icon: icon, tooltip: tooltip, onTap: onTap, size: 42);
  }

  Widget _roundButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    double size = 50,
  }) {
    return Material(
      color: AppTheme.bgDark.withValues(alpha: 0.93),
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        child: Tooltip(
          message: tooltip,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              border: Border.all(color: AppTheme.surfaceBorder),
            ),
            child: Icon(icon, color: AppTheme.textBright, size: 20),
          ),
        ),
      ),
    );
  }

  Widget _errorBanner() {
    return Positioned(
      left: 12,
      right: 12,
      bottom: 118,
      child: Container(
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: AppTheme.error.withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.error_outline_rounded,
              color: Colors.white,
              size: 18,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _error!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 11),
              ),
            ),
            IconButton(
              tooltip: 'ລອງໃໝ່',
              onPressed: () => _fetch(),
              icon: const Icon(Icons.refresh_rounded, color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }

  void _showDetails(FleetDriver item) {
    final color = _markerColor(item);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.bgDark,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppTheme.textDim,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                      ),
                      child: Icon(
                        item.isVehicleGps
                            ? Icons.local_shipping_rounded
                            : Icons.phone_android_rounded,
                        color: color,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.isVehicleGps ? item.car : item.driver,
                            style: const TextStyle(
                              color: AppTheme.textBright,
                              fontSize: 16,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          Text(
                            _statusText(item),
                            style: TextStyle(
                              color: color,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _detailRow(
                  'ແຫຼ່ງຂໍ້ມູນ',
                  item.isVehicleGps ? 'GPS ປະຈຳລົດ' : 'ມືຖືຄົນຂັບ',
                ),
                _detailRow('ອັບເດດຫຼ້າສຸດ', _ago(item.ageSeconds)),
                _detailRow(
                  'ເວລາ GPS',
                  item.recordedAt.isEmpty ? '-' : item.recordedAt,
                ),
                if (item.speed.isNotEmpty)
                  _detailRow('ຄວາມໄວ', '${item.speed} km/h'),
                if (item.isPhoneGps)
                  _detailRow('ລົດ', item.car.isEmpty ? '-' : item.car),
                if (item.docNo.isNotEmpty) _detailRow('ເລກຖ້ຽວ', item.docNo),
                if (item.battery.isNotEmpty)
                  _detailRow('ແບັດເຕີຣີ', '${item.battery}%'),
                if (item.address.isNotEmpty)
                  _detailRow('ສະຖານທີ່', item.address),
                if (item.docNo.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    height: 46,
                    child: FilledButton.icon(
                      onPressed: () {
                        Navigator.pop(sheetContext);
                        _openJob(item);
                      },
                      icon: const Icon(Icons.open_in_new_rounded, size: 17),
                      label: const Text('ເປີດລາຍລະອຽດຖ້ຽວ'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 118,
            child: Text(
              label,
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: AppTheme.textBright,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openJob(FleetDriver item) async {
    final job = DeliveryJob.fromJson({
      'doc_no': item.docNo,
      'car': item.car,
      'driver': item.driver,
      'job_status': item.jobStatus,
    });
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => JobDetailScreen(
          controller: widget.controller,
          initialJob: job,
          readOnly: true,
        ),
      ),
    );
  }
}

class _FleetPin extends StatelessWidget {
  const _FleetPin({
    required this.color,
    required this.icon,
    required this.selected,
  });

  final Color color;
  final IconData icon;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: selected ? 42 : 34,
          height: selected ? 42 : 34,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: selected ? 3 : 2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: selected ? 12 : 7,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Icon(icon, color: Colors.white, size: selected ? 21 : 17),
        ),
        Container(width: 2, height: 8, color: color),
      ],
    );
  }
}
