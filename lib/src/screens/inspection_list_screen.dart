import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../core/app_theme.dart';
import '../models/inspection.dart';
import '../services/api_client.dart';
import 'inspection_detail_screen.dart';
import 'inspection_form_screen.dart';

class InspectionListScreen extends StatefulWidget {
  const InspectionListScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<InspectionListScreen> createState() => _InspectionListScreenState();
}

class _InspectionListScreenState extends State<InspectionListScreen>
    with SingleTickerProviderStateMixin {
  List<InspectionRecord> _records = const [];
  bool _loading = true;
  String? _error;

  // Inspector tab state
  List<InspectionRecord> _pending = const [];
  bool _loadingPending = false;
  late final TabController _tab;

  bool get _isInspector {
    final roles = (widget.controller.user?.roles ?? '').toLowerCase();
    return roles.contains('inspect') || roles.contains('admin');
  }

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: _isInspector ? 2 : 1, vsync: this);
    _fetch();
    if (_isInspector) _fetchPending();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _fetch() async {
    final user = widget.controller.user;
    if (user == null) return;
    setState(() {
      _loading = _records.isEmpty;
      _error = null;
    });
    try {
      final list = await widget.controller.api.getInspections(
        driverCode: user.code,
      );
      if (!mounted) return;
      setState(() {
        _records = list;
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

  Future<void> _fetchPending() async {
    setState(() => _loadingPending = true);
    try {
      final list = await widget.controller.api.getInspections(
        pendingOnly: true,
      );
      if (!mounted) return;
      setState(() {
        _pending = list;
        _loadingPending = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingPending = false);
    }
  }

  Future<void> _openAdd() async {
    HapticFeedback.selectionClick();
    final added = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => InspectionFormScreen(controller: widget.controller),
      ),
    );
    if (added == true && mounted) {
      _fetch();
      if (_isInspector) _fetchPending();
    }
  }

  Future<void> _openDetail(InspectionRecord r) async {
    HapticFeedback.selectionClick();
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => InspectionDetailScreen(
          controller: widget.controller,
          inspectCode: r.inspectCode,
        ),
      ),
    );
    if (changed == true && mounted) {
      _fetch();
      if (_isInspector) _fetchPending();
    }
  }

  int get _pendingCount => _records.where((r) => r.isPending).length;
  int get _approvedCount => _records.where((r) => r.isApproved).length;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgDark,
      appBar: AppBar(
        backgroundColor: AppTheme.bgMid,
        title: const Text('ກວດສະພາບລົດ'),
        bottom: _isInspector
            ? TabBar(
                controller: _tab,
                labelColor: AppTheme.primary,
                unselectedLabelColor: AppTheme.textMuted,
                indicatorColor: AppTheme.primary,
                tabs: [
                  const Tab(text: 'ຂອງຂ້ອຍ'),
                  Tab(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('ລໍຖ້າອານຸມັດ'),
                        if (_pending.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          _badge(_pending.length),
                        ],
                      ],
                    ),
                  ),
                ],
              )
            : null,
      ),
      body: SafeArea(
        bottom: false,
        child: _isInspector
            ? TabBarView(
                controller: _tab,
                children: [
                  _myTab(),
                  _pendingTab(),
                ],
              )
            : _myTab(),
      ),
    );
  }

  Widget _myTab() {
    return RefreshIndicator(
      color: AppTheme.primary,
      backgroundColor: AppTheme.bgCard,
      onRefresh: _fetch,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
        children: [
          _summaryCard(),
          const SizedBox(height: 14),
          _addButton(),
          const SizedBox(height: 20),
          _historyHeader(),
          const SizedBox(height: 8),
          if (_loading && _records.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 60),
              child: Center(
                child: CircularProgressIndicator(
                  color: AppTheme.primary,
                  strokeWidth: 2.5,
                ),
              ),
            )
          else if (_error != null && _records.isEmpty)
            _errorState(_error!)
          else if (_records.isEmpty)
            _emptyState()
          else
            ..._records.map(_recordRow),
        ],
      ),
    );
  }

  Widget _pendingTab() {
    return RefreshIndicator(
      color: AppTheme.primary,
      backgroundColor: AppTheme.bgCard,
      onRefresh: _fetchPending,
      child: _loadingPending && _pending.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : _pending.isEmpty
              ? ListView(
                  children: [
                    const SizedBox(height: 80),
                    _emptyState(label: 'ບໍ່ມີລາຍການລໍຖ້າອານຸມັດ'),
                  ],
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
                  itemCount: _pending.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) => _recordRow(_pending[i]),
                ),
    );
  }

  Widget _summaryCard() {
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
                  color: AppTheme.info.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                  border:
                      Border.all(color: AppTheme.info.withValues(alpha: 0.4)),
                ),
                child: const Icon(
                  Icons.fact_check_rounded,
                  color: AppTheme.info,
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
                      'ສະຫຼຸບການກວດ',
                      style: TextStyle(
                        color: AppTheme.textBright,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'ປະຫວັດການກວດສະພາບລົດ',
                      style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
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
                  label: 'ທັງໝົດ',
                  value: _records.length.toString(),
                  color: AppTheme.info,
                  icon: Icons.list_alt_rounded,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _statBlock(
                  label: 'ລໍຖ້າ',
                  value: _pendingCount.toString(),
                  color: AppTheme.warning,
                  icon: Icons.pending_outlined,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _statBlock(
                  label: 'ອານຸມັດ',
                  value: _approvedCount.toString(),
                  color: AppTheme.success,
                  icon: Icons.check_circle_outline,
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
          Text(label,
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 10)),
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
              colors: [AppTheme.info, Color(0xFF0369A1)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            boxShadow: [
              BoxShadow(
                color: AppTheme.info.withValues(alpha: 0.4),
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
                      'ກວດສະພາບລົດ',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      'ກວດລາຍການ ແລ້ວສົ່ງໃຫ້ຫົວໜ້າອານຸມັດ',
                      style: TextStyle(color: Colors.white70, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded,
                  color: Colors.white, size: 24),
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
          Icon(Icons.history_rounded,
              size: 16, color: AppTheme.textSecondary),
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

  Widget _recordRow(InspectionRecord r) {
    final statusColor = r.isPending
        ? AppTheme.warning
        : r.isApproved
            ? AppTheme.success
            : AppTheme.error;
    final statusLabel =
        r.isPending ? 'ລໍຖ້າ' : r.isApproved ? 'ອານຸມັດ' : 'ປະຕິເສດ';

    return GestureDetector(
      onTap: () => _openDetail(r),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.bgCard,
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          border: Border.all(
            color: r.isPending
                ? AppTheme.warning.withValues(alpha: 0.3)
                : AppTheme.surfaceBorder,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppTheme.info.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppTheme.radiusSm),
              ),
              child: const Icon(
                Icons.directions_car_rounded,
                color: AppTheme.info,
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
                        r.vehicleName.isNotEmpty ? r.vehicleName : r.vehicleCode,
                        style: const TextStyle(
                          color: AppTheme.textBright,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (r.vehicleName.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppTheme.info.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            r.vehicleCode,
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
                        r.inspectDate,
                        style: const TextStyle(
                          color: AppTheme.textMuted,
                          fontSize: 12,
                        ),
                      ),
                      if (r.detailCount > 0) ...[
                        const SizedBox(width: 8),
                        Text(
                          '${r.detailCount} ລາຍການ',
                          style: const TextStyle(
                            color: AppTheme.textMuted,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (r.isRejected && r.approvalNote != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      r.approvalNote!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTheme.error,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(AppTheme.radiusFull),
                border:
                    Border.all(color: statusColor.withValues(alpha: 0.4)),
              ),
              child: Text(
                statusLabel,
                style: TextStyle(
                  color: statusColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyState({String label = 'ຍັງບໍ່ມີການກວດ'}) {
    return Container(
      margin: const EdgeInsets.only(top: 20),
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 20),
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: AppTheme.surfaceBorder),
      ),
      child: Column(
        children: [
          const Icon(Icons.fact_check_outlined,
              size: 40, color: AppTheme.textSecondary),
          const SizedBox(height: 8),
          Text(
            label,
            style: const TextStyle(
              color: AppTheme.textBright,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            'ກົດປຸ່ມ "ກວດສະພາບລົດ" ເພື່ອເລີ່ມກວດ',
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
          const Icon(Icons.cloud_off_rounded,
              color: AppTheme.error, size: 28),
          const SizedBox(height: 8),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.textBright, fontSize: 12),
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

  Widget _badge(int count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: AppTheme.warning,
        borderRadius: BorderRadius.circular(AppTheme.radiusFull),
      ),
      child: Text(
        '$count',
        style: const TextStyle(
            color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800),
      ),
    );
  }
}
