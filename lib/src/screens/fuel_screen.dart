import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../core/app_theme.dart';
import '../models/fuel_log.dart';
import '../services/api_client.dart';
import 'fuel_refill_screen.dart';

/// Driver-facing fuel module — shows the driver's recent fuel-refill history
/// plus a big call-to-action button that opens the entry form.
class FuelScreen extends StatefulWidget {
  const FuelScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<FuelScreen> createState() => _FuelScreenState();
}

class _FuelScreenState extends State<FuelScreen> {
  FuelLogList? _data;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    final user = widget.controller.user;
    if (user == null) return;
    setState(() {
      _loading = _data == null;
      _error = null;
    });
    try {
      final list = await widget.controller.api.getFuelLogs(
        userCode: user.code,
        limit: 50,
      );
      if (!mounted) return;
      setState(() {
        _data = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is ApiException ? e.message : '$e';
      });
    }
  }

  Future<void> _openAdd() async {
    HapticFeedback.selectionClick();
    final added = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => FuelRefillScreen(controller: widget.controller),
      ),
    );
    if (added == true) _fetch();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgDark,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          color: AppTheme.primary,
          backgroundColor: AppTheme.bgCard,
          onRefresh: _fetch,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
            children: [
              _summaryCard(),
              const SizedBox(height: 16),
              _addButton(),
              const SizedBox(height: 20),
              _historyHeader(),
              const SizedBox(height: 8),
              if (_loading && _data == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 60),
                  child: Center(
                    child: CircularProgressIndicator(
                      color: AppTheme.primary,
                      strokeWidth: 2.5,
                    ),
                  ),
                )
              else if (_error != null && (_data?.rows.isEmpty ?? true))
                _errorState(_error!)
              else if (_data?.rows.isEmpty ?? true)
                _emptyState()
              else
                ..._data!.rows.map(_row),
            ],
          ),
        ),
      ),
    );
  }

  Widget _summaryCard() {
    final liters = _data?.totalLiters ?? 0;
    final amount = _data?.totalAmount ?? 0;
    final count = _data?.count ?? 0;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppTheme.brandNavyLight, AppTheme.bgCard],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: AppTheme.surfaceBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppTheme.warning.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                  border: Border.all(
                    color: AppTheme.warning.withValues(alpha: 0.4),
                  ),
                ),
                child: const Icon(
                  Icons.local_gas_station_rounded,
                  color: AppTheme.warning,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'ສະຫຼຸບການເຕີມນ້ຳມັນ',
                      style: TextStyle(
                        color: AppTheme.textBright,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'ປະຫວັດທັງໝົດຂອງທ່ານ',
                      style: TextStyle(
                        color: AppTheme.textMuted,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _statBlock(
                  label: 'ລາຍການ',
                  value: count.toString(),
                  color: AppTheme.info,
                  icon: Icons.list_alt_rounded,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _statBlock(
                  label: 'ລິດ',
                  value: _fmt(liters),
                  color: AppTheme.warning,
                  icon: Icons.water_drop_rounded,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _statBlock(
                  label: 'ຍອດເງິນ',
                  value: _fmt(amount),
                  color: AppTheme.success,
                  icon: Icons.payments_rounded,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _statBlock({
    required String label,
    required String value,
    required Color color,
    required IconData icon,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(
        color: AppTheme.bgSurface,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppTheme.surfaceBorder),
      ),
      child: Column(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontSize: 16,
              fontWeight: FontWeight.w900,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _addButton() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _openAdd,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 18),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [AppTheme.primary, AppTheme.primaryDark],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            boxShadow: [
              BoxShadow(
                color: AppTheme.primary.withValues(alpha: 0.4),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                ),
                child: const Icon(
                  Icons.add_rounded,
                  color: Colors.white,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'ບັນທຶກເຕີມນ້ຳມັນ',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      'ໃສ່ຈຳນວນລິດ, ຍອດເງິນ, ຮູບ',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right_rounded,
                color: Colors.white,
                size: 24,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _historyHeader() {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          Icon(Icons.history_rounded, size: 16, color: AppTheme.textSecondary),
          SizedBox(width: 6),
          Text(
            'ປະຫວັດລ່າສຸດ',
            style: TextStyle(
              color: AppTheme.textBright,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(FuelLog log) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppTheme.surfaceBorder),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppTheme.warning.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppTheme.radiusSm),
            ),
            child: const Icon(
              Icons.local_gas_station_rounded,
              color: AppTheme.warning,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      log.fuelDate,
                      style: const TextStyle(
                        color: AppTheme.textBright,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (log.car.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.info.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          log.car,
                          style: const TextStyle(
                            color: AppTheme.info,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Text(
                      '${_fmt(log.liters)} L',
                      style: const TextStyle(
                        color: AppTheme.warning,
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '${_fmt(log.amount)} ₭',
                      style: const TextStyle(
                        color: AppTheme.success,
                        fontSize: 13,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
                if (log.station.isNotEmpty || log.note.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    [
                      if (log.station.isNotEmpty) log.station,
                      if (log.note.isNotEmpty) log.note,
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 11,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (log.hasImage)
            const Icon(
              Icons.image_rounded,
              size: 16,
              color: AppTheme.textSecondary,
            ),
        ],
      ),
    );
  }

  Widget _emptyState() {
    return Container(
      margin: const EdgeInsets.only(top: 20),
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 20),
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: AppTheme.surfaceBorder),
      ),
      child: const Column(
        children: [
          Icon(
            Icons.inbox_rounded,
            size: 40,
            color: AppTheme.textSecondary,
          ),
          SizedBox(height: 8),
          Text(
            'ຍັງບໍ່ມີບັນທຶກ',
            style: TextStyle(
              color: AppTheme.textBright,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
          SizedBox(height: 4),
          Text(
            'ກົດປຸ່ມຂ້າງເທິງເພື່ອບັນທຶກການເຕີມນ້ຳມັນຄັ້ງທຳອິດ',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _errorState(String message) {
    return Container(
      margin: const EdgeInsets.only(top: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.error.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppTheme.error.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          const Icon(
            Icons.cloud_off_rounded,
            color: AppTheme.error,
            size: 28,
          ),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppTheme.textBright,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _fetch,
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.error,
              side: const BorderSide(color: AppTheme.error),
            ),
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: const Text('ລອງໃໝ່'),
          ),
        ],
      ),
    );
  }

  String _fmt(double n) {
    if (n.abs() < 1000) {
      // Drop trailing .0 for clean display
      return n == n.roundToDouble() ? n.toStringAsFixed(0) : n.toStringAsFixed(2);
    }
    final s = n.toStringAsFixed(n == n.roundToDouble() ? 0 : 2);
    final parts = s.split('.');
    final intPart = parts[0].replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+$)'),
      (m) => '${m[1]},',
    );
    return parts.length > 1 ? '$intPart.${parts[1]}' : intPart;
  }
}
