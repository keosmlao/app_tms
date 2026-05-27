import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../core/app_theme.dart';
import '../models/delivery_job.dart';
import '../models/fuel_log.dart';
import '../services/api_client.dart';
import '../services/offline_outbox.dart';
import 'outbox_screen.dart';
import 'fuel_refill_screen.dart';
import 'fuel_screen.dart';
import 'inspection_list_screen.dart';
import 'jobs_screen.dart';

/// Hub home: greeting + two big module cards (delivery + fuel) with live
/// stats baked into each card. Modules open as a pushed route, so the hub
/// stays clean and can grow when more modules arrive.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.controller});

  final AppController controller;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  List<DeliveryJob> _jobs = const [];
  FuelLogList? _fuel;
  int _totalInspections = 0;
  int _pendingInspections = 0;
  int _approvedInspections = 0;
  bool _loadingJobs = true;
  bool _loadingFuel = true;
  bool _loadingInspections = false;
  String? _jobsError;
  String? _fuelError;

  @override
  void initState() {
    super.initState();
    _fetchAll();
  }

  Future<void> _fetchAll() async {
    // Refresh feature flags alongside the home data — admin toggles in the
    // dashboard take effect on the next pull-to-refresh / app reopen.
    unawaited(widget.controller.loadSettings());
    await Future.wait([_fetchJobs(), _fetchFuel(), _fetchInspections()]);
  }

  Future<void> _fetchJobs() async {
    final user = widget.controller.user;
    if (user == null) return;
    setState(() {
      _loadingJobs = _jobs.isEmpty;
      _jobsError = null;
    });
    try {
      final data = await widget.controller.api.getJobs(driverId: user.driverId);
      if (!mounted) return;
      setState(() {
        _jobs = data;
        _loadingJobs = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingJobs = false;
        _jobsError = e is ApiException ? e.message : '$e';
      });
    }
  }

  Future<void> _fetchFuel() async {
    final user = widget.controller.user;
    if (user == null) return;
    setState(() {
      _loadingFuel = _fuel == null;
      _fuelError = null;
    });
    try {
      final data = await widget.controller.api.getFuelLogs(
        userCode: user.code,
        limit: 30,
      );
      if (!mounted) return;
      setState(() {
        _fuel = data;
        _loadingFuel = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingFuel = false;
        _fuelError = e is ApiException ? e.message : '$e';
      });
    }
  }

  Future<void> _fetchInspections() async {
    final user = widget.controller.user;
    if (user == null) return;
    setState(() => _loadingInspections = true);
    try {
      final records = await widget.controller.api.getInspections(
        driverCode: user.code,
        pendingOnly: false,
      );
      if (!mounted) return;
      setState(() {
        _totalInspections = records.length;
        _pendingInspections =
            records.where((r) => r.approvalStatus == 'pending').length;
        _approvedInspections =
            records.where((r) => r.approvalStatus == 'approved').length;
        _loadingInspections = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingInspections = false);
    }
  }

  Future<void> _openInspection() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            InspectionListScreen(controller: widget.controller),
      ),
    );
    if (mounted) _fetchInspections();
  }

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.bgCard,
        title: const Text(
          'ອອກຈາກລະບົບ?',
          style: TextStyle(color: AppTheme.textBright),
        ),
        content: const Text(
          'ທ່ານຈະຕ້ອງເຂົ້າສູ່ລະບົບໃໝ່ເພື່ອໃຊ້ງານ.',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('ຍົກເລີກ'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: AppTheme.error),
            child: const Text('ອອກ'),
          ),
        ],
      ),
    );
    if (ok == true) await widget.controller.logout();
  }

  Future<void> _openJobs() async {
    HapticFeedback.selectionClick();
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => JobsScreen(controller: widget.controller),
      ),
    );
    if (mounted) _fetchJobs();
  }

  Future<void> _openFuel() async {
    HapticFeedback.selectionClick();
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FuelScreen(controller: widget.controller),
      ),
    );
    if (mounted) _fetchFuel();
  }

  Future<void> _openAddFuel() async {
    HapticFeedback.selectionClick();
    final added = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => FuelRefillScreen(controller: widget.controller),
      ),
    );
    if (added == true && mounted) _fetchFuel();
  }

  int get _pendingCount =>
      _jobs.where((j) => j.jobStatus == 0 || j.pendingApproval).length;
  int get _inProgressCount =>
      _jobs.where((j) => j.jobStatus == 1 || j.jobStatus == 2).length;
  int get _doneCount => _jobs.where((j) => j.jobStatus >= 3).length;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgDark,
      body: SafeArea(
        child: RefreshIndicator(
          color: AppTheme.primary,
          backgroundColor: AppTheme.bgCard,
          onRefresh: _fetchAll,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              _greeting(),
              const SizedBox(height: 20),
              if (OfflineOutbox.instance.pendingCount > 0) ...[
                _outboxBanner(),
                const SizedBox(height: 12),
              ],
              _sectionLabel(icon: Icons.apps_rounded, label: 'ໂມດູນຂອງທ່ານ'),
              const SizedBox(height: 10),
              _jobsCard(),
              const SizedBox(height: 12),
              _fuelCard(),
              const SizedBox(height: 12),
              _inspectionCard(),
              const SizedBox(height: 22),
              _sectionLabel(icon: Icons.flash_on_rounded, label: 'ດຳເນີນການໄວ'),
              const SizedBox(height: 10),
              _quickActions(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _greeting() {
    final user = widget.controller.user;
    final initial = (user?.displayName.isNotEmpty ?? false)
        ? user!.displayName[0].toUpperCase()
        : '?';
    return Row(
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            gradient: AppTheme.accentGradient,
            borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            boxShadow: [
              BoxShadow(
                color: AppTheme.primary.withValues(alpha: 0.35),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Center(
            child: Text(
              initial,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${_greetingText()} · ${_today()}',
                style: const TextStyle(
                  color: AppTheme.textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                user?.displayName ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppTheme.textBright,
                  fontSize: 19,
                  fontWeight: FontWeight.w900,
                  height: 1.15,
                ),
              ),
            ],
          ),
        ),
        PopupMenuButton<String>(
          color: AppTheme.bgCard,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            side: const BorderSide(color: AppTheme.surfaceBorder),
          ),
          icon: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppTheme.bgSurface,
              borderRadius: BorderRadius.circular(AppTheme.radiusLg),
              border: Border.all(color: AppTheme.surfaceBorder),
            ),
            child: const Icon(
              Icons.more_vert_rounded,
              color: AppTheme.textSecondary,
              size: 18,
            ),
          ),
          onSelected: (v) {
            if (v == 'refresh') _fetchAll();
            if (v == 'logout') _logout();
          },
          itemBuilder: (_) => const [
            PopupMenuItem(
              value: 'refresh',
              child: Row(
                children: [
                  Icon(Icons.refresh_rounded, color: AppTheme.info, size: 18),
                  SizedBox(width: 10),
                  Text(
                    'ໂຫຼດຂໍ້ມູນຄືນ',
                    style: TextStyle(color: AppTheme.textBright),
                  ),
                ],
              ),
            ),
            PopupMenuDivider(),
            PopupMenuItem(
              value: 'logout',
              child: Row(
                children: [
                  Icon(Icons.logout_rounded, color: AppTheme.error, size: 18),
                  SizedBox(width: 10),
                  Text(
                    'ອອກຈາກລະບົບ',
                    style: TextStyle(color: AppTheme.textBright),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _outboxBanner() {
    return InkWell(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const OutboxScreen()),
        );
      },
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.warning.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          border: Border.all(color: AppTheme.warning.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.cloud_off_rounded,
              color: AppTheme.warning,
              size: 18,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                OfflineOutbox.instance.lastError?.isNotEmpty == true
                    ? OfflineOutbox.instance.lastError!
                    : 'ມີ ${OfflineOutbox.instance.pendingCount} ລາຍການລໍສົ່ງ',
                style: const TextStyle(
                  color: AppTheme.textBright,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            TextButton(
              onPressed: () => OfflineOutbox.instance.flush(),
              style: TextButton.styleFrom(
                foregroundColor: AppTheme.warning,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 32),
              ),
              child: const Text('ລອງສົ່ງ'),
            ),
            const Icon(
              Icons.chevron_right,
              color: AppTheme.warning,
              size: 16,
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel({required IconData icon, required String label}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          Icon(icon, size: 14, color: AppTheme.textSecondary),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              color: AppTheme.textBright,
              fontSize: 13,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  Widget _jobsCard() {
    return _ModuleCard(
      title: 'ຖ້ຽວຂົນສົ່ງ',
      subtitle: 'ຈັດການຖ້ຽວຂອງທ່ານ',
      icon: Icons.local_shipping_rounded,
      accent: AppTheme.primary,
      onTap: _openJobs,
      loading: _loadingJobs,
      error: _jobsError,
      mainStat: _StatItem(label: 'ທັງໝົດ', value: _jobs.length.toString()),
      subStats: [
        _StatItem(
          label: 'ລໍຖ້າ',
          value: _pendingCount.toString(),
          color: AppTheme.warning,
        ),
        _StatItem(
          label: 'ກຳລັງ',
          value: _inProgressCount.toString(),
          color: AppTheme.info,
        ),
        _StatItem(
          label: 'ສຳເລັດ',
          value: _doneCount.toString(),
          color: AppTheme.success,
        ),
      ],
    );
  }

  Widget _fuelCard() {
    return _ModuleCard(
      title: 'ບັນທຶກນ້ຳມັນ',
      subtitle: 'ປະຫວັດການເຕີມຂອງທ່ານ',
      icon: Icons.local_gas_station_rounded,
      accent: AppTheme.warning,
      onTap: _openFuel,
      loading: _loadingFuel,
      error: _fuelError,
      mainStat: _StatItem(
        label: 'ລາຍການ',
        value: (_fuel?.count ?? 0).toString(),
      ),
      subStats: [
        _StatItem(
          label: 'ລິດ',
          value: _fmt(_fuel?.totalLiters ?? 0),
          color: AppTheme.warning,
        ),
        _StatItem(
          label: 'ຍອດເງິນ',
          value: _fmt(_fuel?.totalAmount ?? 0),
          color: AppTheme.success,
        ),
      ],
    );
  }

  Widget _inspectionCard() {
    return _ModuleCard(
      title: 'ກວດສະພາບລົດ',
      subtitle: 'ກວດ ແລະ ສົ່ງໃຫ້ຫົວໜ້າອານຸມັດ',
      icon: Icons.fact_check_rounded,
      accent: AppTheme.info,
      onTap: _openInspection,
      loading: _loadingInspections,
      error: null,
      mainStat: _StatItem(
        label: 'ທັງໝົດ',
        value: _totalInspections.toString(),
      ),
      subStats: [
        _StatItem(
          label: 'ລໍຖ້າ',
          value: _pendingInspections.toString(),
          color: _pendingInspections > 0 ? AppTheme.warning : AppTheme.textMuted,
        ),
        _StatItem(
          label: 'ອານຸມັດ',
          value: _approvedInspections.toString(),
          color: AppTheme.success,
        ),
      ],
    );
  }

  Widget _quickActions() {
    return Row(
      children: [
        Expanded(
          child: _QuickAction(
            icon: Icons.add_rounded,
            label: 'ເຕີມນ້ຳມັນ',
            color: AppTheme.warning,
            onTap: _openAddFuel,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _QuickAction(
            icon: Icons.refresh_rounded,
            label: 'ໂຫຼດຄືນ',
            color: AppTheme.info,
            onTap: _fetchAll,
          ),
        ),
      ],
    );
  }

  String _greetingText() {
    final h = DateTime.now().hour;
    if (h < 12) return 'ສະບາຍດີຕອນເຊົ້າ';
    if (h < 17) return 'ສະບາຍດີຕອນບ່າຍ';
    return 'ສະບາຍດີຕອນຄ່ຳ';
  }

  String _today() {
    final n = DateTime.now();
    final d = n.day.toString().padLeft(2, '0');
    final m = n.month.toString().padLeft(2, '0');
    return '$d/$m/${n.year}';
  }

  String _fmt(double n) {
    final s = n.toStringAsFixed(n == n.roundToDouble() ? 0 : 2);
    final parts = s.split('.');
    final intPart = parts[0].replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+$)'),
      (m) => '${m[1]},',
    );
    return parts.length > 1 ? '$intPart.${parts[1]}' : intPart;
  }
}

// ════════════════════════════════════════════════════════════════════
// Module card
// ════════════════════════════════════════════════════════════════════
class _StatItem {
  const _StatItem({required this.label, required this.value, this.color});
  final String label;
  final String value;
  final Color? color;
}

class _ModuleCard extends StatelessWidget {
  const _ModuleCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.accent,
    required this.onTap,
    required this.loading,
    required this.error,
    required this.mainStat,
    required this.subStats,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color accent;
  final VoidCallback onTap;
  final bool loading;
  final String? error;
  final _StatItem mainStat;
  final List<_StatItem> subStats;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppTheme.bgCard,
            borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            border: Border.all(color: AppTheme.surfaceBorder),
            boxShadow: [
              BoxShadow(
                color: accent.withValues(alpha: 0.05),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                      border: Border.all(color: accent.withValues(alpha: 0.4)),
                    ),
                    child: Icon(icon, color: accent, size: 24),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            color: AppTheme.textBright,
                            fontSize: 16,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: const TextStyle(
                            color: AppTheme.textMuted,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        mainStat.value,
                        style: TextStyle(
                          color: accent,
                          fontSize: 24,
                          fontWeight: FontWeight.w900,
                          height: 1.0,
                        ),
                      ),
                      Text(
                        mainStat.label,
                        style: const TextStyle(
                          color: AppTheme.textMuted,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (loading && error == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 4),
                  child: LinearProgressIndicator(
                    minHeight: 2,
                    color: AppTheme.primary,
                    backgroundColor: AppTheme.surfaceBorder,
                  ),
                )
              else if (error != null)
                Text(
                  error!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppTheme.error, fontSize: 11),
                )
              else
                Row(
                  children: [
                    for (var i = 0; i < subStats.length; i++) ...[
                      Expanded(child: _subStat(subStats[i])),
                      if (i < subStats.length - 1) const SizedBox(width: 8),
                    ],
                  ],
                ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    'ເປີດ',
                    style: TextStyle(
                      color: accent,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.arrow_forward_rounded, color: accent, size: 16),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _subStat(_StatItem item) {
    final c = item.color ?? AppTheme.textBright;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(
        color: AppTheme.bgSurface,
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        border: Border.all(color: AppTheme.surfaceBorder),
      ),
      child: Column(
        children: [
          Text(
            item.value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: c,
              fontSize: 16,
              fontWeight: FontWeight.w900,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            item.label,
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 10),
          ),
        ],
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
          decoration: BoxDecoration(
            color: AppTheme.bgCard,
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            border: Border.all(color: color.withValues(alpha: 0.3)),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                ),
                child: Icon(icon, color: color, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.textBright,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
