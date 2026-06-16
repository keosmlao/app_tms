import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_controller.dart';
import '../core/app_theme.dart';
import '../core/app_version.dart';
import '../models/delivery_job.dart';
import '../services/location_tracking_service.dart';
import '../services/offline_outbox.dart';
import '../widgets/gps_tracking_banner.dart';
import 'chat_people_screen.dart';
import 'outbox_screen.dart';
import 'fuel_refill_screen.dart';
import 'inspection_list_screen.dart';
import 'jobs_screen.dart';

/// Driver home: a clean, focused, premium hub. One hero card for the current trip
/// (status + progress + a big "ໄປຖ້ຽວ" button) over a 2×2 grid of large
/// quick actions. Minimal by design — the trip is the one thing that matters.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.controller});

  final AppController controller;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  List<DeliveryJob> _jobs = const [];
  bool _loadingJobs = true;
  int _chatUnread = 0;
  int _pendingInspections = 0;
  Timer? _chatPoll;
  bool _onDuty = true;

  @override
  void initState() {
    super.initState();
    // Ask for location / battery / notification access once, on first launch.
    // No-ops on every launch after the first.
    LocationTrackingService.instance.ensureOnboardingPermissions();
    // If background tracking hit an expired session (e.g. after a reboot
    // resume), prompt a re-login so GPS can resume.
    _checkAuthFailed();
    _loadDutyStatus();
    _fetchAll();
    _loadChatUnread();
    _chatPoll = Timer.periodic(
      const Duration(seconds: 20),
      (_) => _loadChatUnread(),
    );
  }

  @override
  void dispose() {
    _chatPoll?.cancel();
    super.dispose();
  }

  Future<void> _loadDutyStatus() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (mounted) {
        setState(() {
          _onDuty = prefs.getBool('driver_on_duty') ?? true;
        });
      }
    } catch (_) {}
  }

  Future<void> _toggleDutyStatus() async {
    HapticFeedback.mediumImpact();
    setState(() {
      _onDuty = !_onDuty;
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('driver_on_duty', _onDuty);
    } catch (_) {}
  }

  Future<void> _loadChatUnread() async {
    try {
      final people = await widget.controller.api.getChatPeople();
      if (!mounted) return;
      setState(() => _chatUnread = people.fold(0, (s, p) => s + p.unread));
    } catch (_) {
      /* ignore */
    }
  }

  Future<void> _loadInspectionPending() async {
    final user = widget.controller.user;
    if (user == null) return;
    try {
      final records = await widget.controller.api.getInspections(
        driverCode: user.code,
        pendingOnly: true,
      );
      if (!mounted) return;
      setState(() => _pendingInspections = records.length);
    } catch (_) {
      /* ignore */
    }
  }

  Future<void> _fetchAll() async {
    // Refresh feature flags alongside the home data — admin toggles in the
    // dashboard take effect on the next pull-to-refresh / app reopen.
    unawaited(widget.controller.loadSettings());
    unawaited(_loadInspectionPending());
    await _fetchJobs();
  }

  Future<void> _fetchJobs() async {
    final user = widget.controller.user;
    if (user == null) return;
    setState(() => _loadingJobs = _jobs.isEmpty);
    try {
      final data = await widget.controller.api.getJobs(driverId: user.driverId);
      if (!mounted) return;
      setState(() {
        _jobs = data;
        _loadingJobs = false;
      });
      // Keep continuous GPS tracking aligned with the active dispatched job —
      // starts it after a restart mid-trip, stops it once the trip closes.
      LocationTrackingService.instance.sync(
        jobs: data,
        baseUrl: widget.controller.baseUrl,
        authToken: user.token,
        driverId: user.driverId,
      );
    } catch (_) {
      if (mounted) setState(() => _loadingJobs = false);
    }
  }

  Future<void> _openChat() async {
    HapticFeedback.selectionClick();
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatPeopleScreen(controller: widget.controller),
      ),
    );
  }

  Future<void> _checkAuthFailed() async {
    final failed = await LocationTrackingService.instance.consumeAuthFailed();
    if (!failed || !mounted) return;
    final reauth = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgCard,
        icon: const Icon(Icons.lock_clock_rounded, color: AppTheme.warning),
        title: const Text(
          'ເຊສຊັນໝົດອາຍຸ',
          style: TextStyle(color: AppTheme.textBright, fontSize: 16),
        ),
        content: const Text(
          'ກະລຸນາເຂົ້າສູ່ລະບົບໃໝ່ ເພື່ອໃຫ້ການຕິດຕາມຖ້ຽວສືບຕໍ່ໄດ້.',
          style: TextStyle(
            color: AppTheme.textSecondary,
            fontSize: 13,
            height: 1.5,
          ),
        ),
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.primary),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('ເຂົ້າສູ່ລະບົບໃໝ່'),
          ),
        ],
      ),
    );
    // reauthenticate() drops the session but keeps the active trip + service
    // running, so GPS resumes the moment a fresh token is written post-login.
    if (reauth == true) await widget.controller.reauthenticate();
  }

  Future<void> _logout() async {
    // Block logout while a trip is in progress. Otherwise a driver could log
    // out to silently kill GPS tracking before closing the trip — they must
    // close the trip first. Check both the loaded jobs (job_status 1–2) AND the
    // persisted active doc, so this holds even before the jobs list loads.
    final hasActiveTrip =
        _jobs.any((j) => j.jobStatus == 1 || j.jobStatus == 2) ||
        await LocationTrackingService.instance.hasActiveTrip();
    if (hasActiveTrip) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppTheme.error,
          behavior: SnackBarBehavior.floating,
          content: const Text(
            'ກະລຸນາປິດຖ້ຽວທີ່ກຳລັງດຳເນີນກ່ອນ ຈຶ່ງຈະອອກຈາກລະບົບໄດ້',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      );
      return;
    }
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 36),
        child: Container(
          padding: const EdgeInsets.fromLTRB(24, 26, 24, 22),
          decoration: BoxDecoration(
            color: AppTheme.bgCard,
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: AppTheme.surfaceBorder),
            boxShadow: const [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 30,
                offset: Offset(0, 12),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 66,
                height: 66,
                decoration: BoxDecoration(
                  color: AppTheme.error.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.logout_rounded,
                  color: AppTheme.error,
                  size: 30,
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'ອອກຈາກລະບົບ?',
                style: TextStyle(
                  color: AppTheme.textBright,
                  fontSize: 19,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'ທ່ານຈະຕ້ອງເຂົ້າສູ່ລະບົບໃໝ່ເພື່ອໃຊ້ງານ',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.textMuted, fontSize: 13),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.textSecondary,
                        side: const BorderSide(color: AppTheme.surfaceBorder),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(15),
                        ),
                      ),
                      child: const Text(
                        'ຍົກເລີກ',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.error,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(15),
                        ),
                      ),
                      child: const Text(
                        'ອອກຈາກລະບົບ',
                        style: TextStyle(fontWeight: FontWeight.w900),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
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

  Future<void> _openAddFuel() async {
    HapticFeedback.selectionClick();
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => FuelRefillScreen(controller: widget.controller),
      ),
    );
  }

  Future<void> _openInspection() async {
    HapticFeedback.selectionClick();
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => InspectionListScreen(controller: widget.controller),
      ),
    );
    if (mounted) _loadInspectionPending();
  }

  // The trip to surface in the hero card: an active one first, else the next
  // approved-but-not-started, else just the first.
  DeliveryJob? get _currentJob {
    final active = _jobs.where((j) => j.jobStatus == 1 || j.jobStatus == 2);
    if (active.isNotEmpty) return active.first;
    final next = _jobs.where((j) => j.isApproved && j.jobStatus == 0);
    if (next.isNotEmpty) return next.first;
    return _jobs.isNotEmpty ? _jobs.first : null;
  }

  // Compact, login-matching header: avatar + greeting + duty pill, with chat
  // and logout actions on the right.
  Widget _greeting() {
    final user = widget.controller.user;
    final name = user?.displayName ?? '';
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
    final h = DateTime.now().hour;
    final hello = h < 12
        ? 'ສະບາຍດີຕອນເຊົ້າ'
        : (h < 17 ? 'ສະບາຍດີຕອນບ່າຍ' : 'ສະບາຍດີຕອນຄ່ຳ');
    return Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            gradient: AppTheme.accentGradient,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: AppTheme.primary.withValues(alpha: 0.3),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Center(
            child: Text(
              initial,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 19,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                hello,
                style: const TextStyle(
                  color: AppTheme.textMuted,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 1),
              Row(
                children: [
                  Flexible(
                    child: Text(
                      name.isEmpty ? 'ຄົນຂັບ' : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTheme.textBright,
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _dutyPill(),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        _headerIcon(
          icon: Icons.chat_bubble_outline_rounded,
          onTap: _openChat,
          badge: _chatUnread,
        ),
        const SizedBox(width: 8),
        _headerIcon(
          icon: Icons.logout_rounded,
          onTap: _logout,
          danger: true,
        ),
      ],
    );
  }

  Widget _dutyPill() {
    final on = _onDuty;
    final color = on ? AppTheme.success : AppTheme.textMuted;
    return GestureDetector(
      onTap: _toggleDutyStatus,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 5),
            Text(
              on ? 'ພ້ອມ' : 'ພັກ',
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _headerIcon({
    required IconData icon,
    required VoidCallback onTap,
    int badge = 0,
    bool danger = false,
  }) {
    final fg = danger ? AppTheme.error : AppTheme.textSecondary;
    return Material(
      color: danger ? AppTheme.error.withValues(alpha: 0.1) : AppTheme.bgCard,
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                border: Border.all(
                  color: danger
                      ? AppTheme.error.withValues(alpha: 0.3)
                      : AppTheme.surfaceBorder,
                ),
              ),
              child: Icon(icon, color: fg, size: 19),
            ),
            if (badge > 0)
              Positioned(
                right: -3,
                top: -3,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  constraints: const BoxConstraints(minWidth: 16),
                  decoration: BoxDecoration(
                    color: AppTheme.error,
                    borderRadius: BorderRadius.circular(9),
                    border: Border.all(color: AppTheme.bgDark, width: 1.5),
                  ),
                  child: Text(
                    badge > 99 ? '99+' : '$badge',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // Clean white hero card (login-matching) for the current trip.
  Widget _heroTripCard() {
    final radius = BorderRadius.circular(24);
    final cardShadow = [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.05),
        blurRadius: 22,
        offset: const Offset(0, 10),
      ),
    ];
    if (_loadingJobs && _jobs.isEmpty) {
      return Container(
        height: 150,
        decoration: BoxDecoration(
          color: AppTheme.bgCard,
          borderRadius: radius,
          border: Border.all(color: AppTheme.surfaceBorder),
          boxShadow: cardShadow,
        ),
        child: const Center(
          child: CircularProgressIndicator(color: AppTheme.primary),
        ),
      );
    }
    final job = _currentJob;
    if (job == null) {
      return Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
          color: AppTheme.bgCard,
          borderRadius: radius,
          border: Border.all(color: AppTheme.surfaceBorder),
          boxShadow: cardShadow,
        ),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: AppTheme.success.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.coffee_rounded,
                color: AppTheme.success,
                size: 22,
              ),
            ),
            const SizedBox(width: 14),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'ບໍ່ມີຖ້ຽວມື້ນີ້',
                    style: TextStyle(
                      color: AppTheme.textBright,
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'ພັກຜ່ອນໄດ້ — ຈະແຈ້ງເມື່ອມີວຽກ',
                    style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    final total = job.itemBill;
    final done = job.completedBillCount + job.cancelledBillCount;
    final pct = total > 0 ? (done / total).clamp(0.0, 1.0) : 0.0;
    final statusColor = job.jobStatus == 2
        ? AppTheme.info
        : (job.jobStatus == 1 ? AppTheme.primary : AppTheme.warning);
    return Material(
      color: AppTheme.bgCard,
      borderRadius: radius,
      child: InkWell(
        onTap: _openJobs,
        borderRadius: radius,
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(color: AppTheme.surfaceBorder),
            boxShadow: cardShadow,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text(
                    'ຖ້ຽວປັດຈຸບັນ',
                    style: TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: statusColor,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          job.statusText,
                          style: TextStyle(
                            color: statusColor,
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '#${job.docNo}',
                style: const TextStyle(
                  color: AppTheme.textBright,
                  fontSize: 19,
                  fontWeight: FontWeight.w900,
                ),
              ),
              if (job.car.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.local_shipping_outlined,
                        size: 14,
                        color: AppTheme.textMuted,
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Text(
                          job.car,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppTheme.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    'ສຳເລັດ ${job.completedBillCount}',
                    style: const TextStyle(
                      color: AppTheme.textBright,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    ' / $total ບິນ',
                    style: const TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 12.5,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${(pct * 100).round()}%',
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: pct,
                  minHeight: 8,
                  backgroundColor: AppTheme.bgSurface,
                  valueColor: AlwaysStoppedAnimation(statusColor),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton.icon(
                  onPressed: _openJobs,
                  icon: const Icon(Icons.arrow_forward_rounded, size: 19),
                  label: const Text('ໄປຖ້ຽວ'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.primary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(15),
                    ),
                    textStyle: const TextStyle(
                      fontWeight: FontWeight.w900,
                      fontSize: 15,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _outboxBanner() {
    return InkWell(
      onTap: () {
        Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const OutboxScreen()));
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
            const Icon(Icons.chevron_right, color: AppTheme.warning, size: 16),
          ],
        ),
      ),
    );
  }

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
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 28),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _greeting(),
                      const SizedBox(height: 16),
                      const GpsTrackingBanner(),
                      if (OfflineOutbox.instance.pendingCount > 0) ...[
                        _outboxBanner(),
                        const SizedBox(height: 12),
                      ],
                      _heroTripCard(),
                      const SizedBox(height: 16),
                      _quickActions(),
                      const SizedBox(height: 26),
                      _versionFooter(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _quickActions() {
    final actions =
        <
          ({
            IconData icon,
            String label,
            String sub,
            Color color,
            VoidCallback onTap,
            int badge,
          })
        >[
          (
            icon: Icons.list_alt_rounded,
            label: 'ທຸກຖ້ຽວ',
            sub: 'ເບິ່ງ / ຈັດການ',
            color: AppTheme.primary,
            onTap: _openJobs,
            badge: 0,
          ),
          (
            icon: Icons.chat_bubble_rounded,
            label: 'ແຊັດ',
            sub: 'ຄຸຍກັບ office',
            color: AppTheme.info,
            onTap: _openChat,
            badge: 0,
          ),
          (
            icon: Icons.local_gas_station_rounded,
            label: 'ນ້ຳມັນ',
            sub: 'ບັນທຶກເຕີມ',
            color: AppTheme.warning,
            onTap: _openAddFuel,
            badge: 0,
          ),
          (
            icon: Icons.fact_check_rounded,
            label: 'ກວດສະພາບລົດ',
            sub: 'ກວດ / ສົ່ງອານຸມັດ',
            color: AppTheme.info,
            onTap: _openInspection,
            badge: _pendingInspections,
          ),
          (
            icon: Icons.refresh_rounded,
            label: 'ໂຫຼດຄືນ',
            sub: 'ອັບເດດຂໍ້ມູນ',
            color: AppTheme.success,
            onTap: _fetchAll,
            badge: 0,
          ),
        ];
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 12,
      crossAxisSpacing: 12,
      childAspectRatio: 1.32,
      children: [for (final a in actions) _bigAction(a)],
    );
  }

  Widget _bigAction(
    ({
      IconData icon,
      String label,
      String sub,
      Color color,
      VoidCallback onTap,
      int badge,
    })
    a,
  ) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: a.onTap,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        child: Container(
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            color: AppTheme.bgCard,
            borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            border: Border.all(color: AppTheme.surfaceBorder),
            boxShadow: AppTheme.shadowSm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(9),
                        decoration: BoxDecoration(
                          color: a.color.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(a.icon, color: a.color, size: 21),
                      ),
                      if (a.badge > 0)
                        Positioned(
                          right: -4,
                          top: -4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 1,
                            ),
                            constraints: const BoxConstraints(minWidth: 16),
                            decoration: BoxDecoration(
                              color: AppTheme.error,
                              borderRadius: BorderRadius.circular(9),
                              border: Border.all(
                                color: AppTheme.bgCard,
                                width: 1.5,
                              ),
                            ),
                            child: Text(
                              a.badge > 99 ? '99+' : '${a.badge}',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 9,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  Icon(
                    Icons.arrow_forward_ios_rounded,
                    color: AppTheme.textMuted.withValues(alpha: 0.5),
                    size: 13,
                  ),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    a.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.textBright,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    a.sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _versionFooter() {
    final v = AppVersion.display;
    return Center(
      child: Text(
        v.isEmpty ? 'ເວີຊັນ —' : 'ເວີຊັນ $v',
        style: const TextStyle(
          color: AppTheme.textMuted,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

}

class _StatusIndicator extends StatefulWidget {
  const _StatusIndicator({required this.active});
  final bool active;

  @override
  State<_StatusIndicator> createState() => _StatusIndicatorState();
}

class _StatusIndicatorState extends State<_StatusIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final baseColor = widget.active ? AppTheme.success : AppTheme.textMuted;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: baseColor.withValues(
                  alpha: widget.active
                      ? 0.15 + (_controller.value * 0.25)
                      : 0.1,
                ),
              ),
            ),
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: baseColor,
                boxShadow: widget.active
                    ? [
                        BoxShadow(
                          color: baseColor.withValues(alpha: 0.5),
                          blurRadius: 4 + (_controller.value * 4),
                          spreadRadius: _controller.value * 1,
                        ),
                      ]
                    : null,
              ),
            ),
          ],
        );
      },
    );
  }
}


