import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../core/app_theme.dart';
import '../models/auth_user.dart';
import '../models/delivery_job.dart';
import '../services/api_client.dart';
import '../services/offline_outbox.dart';
import 'job_detail_screen.dart';

// ════════════════════════════════════════════════════════════════════
// JobsScreen — Tab Pager design
// ════════════════════════════════════════════════════════════════════
class JobsScreen extends StatefulWidget {
  const JobsScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<JobsScreen> createState() => _JobsScreenState();
}

class _JobsScreenState extends State<JobsScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  final _searchCtrl = TextEditingController();
  late TabController _tabCtrl;
  Timer? _autoRefresh;
  bool _searchOpen = false;

  bool _loading = true;
  bool _refreshing = false;
  String? _error;
  List<DeliveryJob> _jobs = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_onControllerChanged);
    OfflineOutbox.instance.addListener(_onOutboxChanged);
    _searchCtrl.addListener(() => setState(() {}));
    _tabCtrl = TabController(length: 4, vsync: this);
    _tabCtrl.addListener(() => setState(() {}));
    _fetch().then((_) => _maybeOpenPendingDoc());
    _autoRefresh = Timer.periodic(
      const Duration(seconds: 60),
      (_) => _fetch(silent: true),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_onControllerChanged);
    OfflineOutbox.instance.removeListener(_onOutboxChanged);
    _autoRefresh?.cancel();
    _searchCtrl.dispose();
    _tabCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      OfflineOutbox.instance.flush();
      _fetch(silent: true);
    }
  }

  void _onOutboxChanged() {
    if (mounted) setState(() {});
  }

  void _onControllerChanged() {
    if (widget.controller.pendingDocNo != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _maybeOpenPendingDoc();
      });
    }
  }

  Future<void> _maybeOpenPendingDoc() async {
    final docNo = widget.controller.pendingDocNo;
    if (docNo == null || !mounted) return;
    widget.controller.consumePendingDocNo();
    if (_jobs.isEmpty) await _fetch(silent: true);
    final match = _jobs.where((j) => j.docNo == docNo).toList();
    if (!mounted) return;
    if (match.isNotEmpty) {
      await _openDetail(match.first);
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('ບໍ່ພົບຖ້ຽວ $docNo')));
    }
  }

  // ────────────────────────────── data ──────────────────────────────
  Future<void> _fetch({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    } else {
      setState(() => _refreshing = true);
    }
    try {
      final data = await widget.controller.api.getJobs(
        driverId: widget.controller.user!.driverId,
      );
      if (!mounted) return;
      setState(() {
        _jobs = data;
        _loading = false;
        _refreshing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _refreshing = false;
        _error = e is ApiException ? e.message : '$e';
      });
    }
  }

  Future<void> _refresh() async {
    HapticFeedback.lightImpact();
    await _fetch();
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
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
    if (confirmed == true) await widget.controller.logout();
  }

  Future<void> _openDetail(DeliveryJob job) async {
    HapticFeedback.selectionClick();
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            JobDetailScreen(controller: widget.controller, initialJob: job),
      ),
    );
    if (mounted) _fetch(silent: true);
  }

  // ────────────────────────────── derived ──────────────────────────────
  bool _matches(DeliveryJob j) {
    final q = _searchCtrl.text.trim().toLowerCase();
    if (q.isEmpty) return true;
    return j.docNo.toLowerCase().contains(q) ||
        j.car.toLowerCase().contains(q) ||
        j.driver.toLowerCase().contains(q);
  }

  List<DeliveryJob> get _all => _jobs.where(_matches).toList();
  List<DeliveryJob> get _pending => _jobs
      .where((j) => (j.jobStatus == 0 || j.pendingApproval) && _matches(j))
      .toList();
  List<DeliveryJob> get _inProgress => _jobs
      .where((j) => (j.jobStatus == 1 || j.jobStatus == 2) && _matches(j))
      .toList();
  List<DeliveryJob> get _done =>
      _jobs.where((j) => j.jobStatus >= 3 && _matches(j)).toList();

  int get _pendingCount =>
      _jobs.where((j) => j.jobStatus == 0 || j.pendingApproval).length;
  int get _inProgressCount =>
      _jobs.where((j) => j.jobStatus == 1 || j.jobStatus == 2).length;
  int get _doneCount => _jobs.where((j) => j.jobStatus >= 3).length;

  // ────────────────────────────── build ──────────────────────────────
  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
      ),
      child: Scaffold(
        backgroundColor: AppTheme.bgDark,
        body: SafeArea(
          child: _loading
              ? const _LoadingState()
              : _error != null && _jobs.isEmpty
              ? _ErrorState(message: _error!, onRetry: _refresh)
              : _content(),
        ),
      ),
    );
  }

  Widget _content() {
    return Column(
      children: [
        _Header(
          user: widget.controller.user!,
          refreshing: _refreshing,
          searchOpen: _searchOpen,
          onToggleSearch: () {
            setState(() {
              _searchOpen = !_searchOpen;
              if (!_searchOpen) _searchCtrl.clear();
            });
          },
          onRefresh: _refresh,
          onLogout: _logout,
        ),
        if (_searchOpen)
          _SearchBar(
            controller: _searchCtrl,
            onClose: () {
              setState(() {
                _searchOpen = false;
                _searchCtrl.clear();
              });
            },
          ),
        if (OfflineOutbox.instance.pendingCount > 0)
          _OutboxBanner(
            count: OfflineOutbox.instance.pendingCount,
            error: OfflineOutbox.instance.lastError,
            onRetry: () => OfflineOutbox.instance.flush(),
          ),
        _TabBar(
          controller: _tabCtrl,
          tabs: [
            _TabSpec(
              label: 'ທັງໝົດ',
              count: _jobs.length,
              color: AppTheme.textBright,
            ),
            _TabSpec(
              label: 'ລໍຖ້າ',
              count: _pendingCount,
              color: AppTheme.warning,
            ),
            _TabSpec(
              label: 'ກຳລັງ',
              count: _inProgressCount,
              color: AppTheme.primary,
            ),
            _TabSpec(
              label: 'ສຳເລັດ',
              count: _doneCount,
              color: AppTheme.success,
            ),
          ],
        ),
        Expanded(
          child: TabBarView(
            controller: _tabCtrl,
            children: [
              _JobList(
                jobs: _all,
                hasJobs: _jobs.isNotEmpty,
                onTapJob: _openDetail,
                onRefresh: _refresh,
                onClearSearch: _searchCtrl.text.isNotEmpty
                    ? _searchCtrl.clear
                    : null,
              ),
              _JobList(
                jobs: _pending,
                hasJobs: _jobs.isNotEmpty,
                onTapJob: _openDetail,
                onRefresh: _refresh,
                onClearSearch: _searchCtrl.text.isNotEmpty
                    ? _searchCtrl.clear
                    : null,
              ),
              _JobList(
                jobs: _inProgress,
                hasJobs: _jobs.isNotEmpty,
                onTapJob: _openDetail,
                onRefresh: _refresh,
                onClearSearch: _searchCtrl.text.isNotEmpty
                    ? _searchCtrl.clear
                    : null,
              ),
              _JobList(
                jobs: _done,
                hasJobs: _jobs.isNotEmpty,
                onTapJob: _openDetail,
                onRefresh: _refresh,
                onClearSearch: _searchCtrl.text.isNotEmpty
                    ? _searchCtrl.clear
                    : null,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// Header
// ════════════════════════════════════════════════════════════════════
class _Header extends StatelessWidget {
  const _Header({
    required this.user,
    required this.refreshing,
    required this.searchOpen,
    required this.onToggleSearch,
    required this.onRefresh,
    required this.onLogout,
  });

  final AuthUser user;
  final bool refreshing;
  final bool searchOpen;
  final VoidCallback onToggleSearch;
  final VoidCallback onRefresh;
  final VoidCallback onLogout;

  String _greeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'ສະບາຍດີຕອນເຊົ້າ';
    if (hour < 17) return 'ສະບາຍດີຕອນບ່າຍ';
    return 'ສະບາຍດີຕອນຄ່ຳ';
  }

  String _today() {
    final n = DateTime.now();
    final d = n.day.toString().padLeft(2, '0');
    final m = n.month.toString().padLeft(2, '0');
    return '$d/$m/${n.year}';
  }

  @override
  Widget build(BuildContext context) {
    final initial = user.displayName.isNotEmpty
        ? user.displayName[0].toUpperCase()
        : '?';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              gradient: AppTheme.accentGradient,
              borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            ),
            child: Center(
              child: Text(
                initial,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '${_greeting()} · ${_today()}',
                  style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  user.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.textBright,
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ),
          _IconBtn(
            icon: searchOpen ? Icons.search_off_rounded : Icons.search_rounded,
            onTap: onToggleSearch,
            highlight: searchOpen,
          ),
          const SizedBox(width: 6),
          _IconBtn(
            icon: Icons.refresh_rounded,
            spinning: refreshing,
            onTap: onRefresh,
          ),
          const SizedBox(width: 6),
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
              if (v == 'logout') onLogout();
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
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
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  const _IconBtn({
    required this.icon,
    required this.onTap,
    this.spinning = false,
    this.highlight = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool spinning;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: highlight ? AppTheme.primary : AppTheme.bgSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        side: BorderSide(
          color: highlight ? AppTheme.primary : AppTheme.surfaceBorder,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        child: SizedBox(
          width: 40,
          height: 40,
          child: spinning
              ? const Center(
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: AppTheme.primary,
                    ),
                  ),
                )
              : Icon(
                  icon,
                  color: highlight ? Colors.white : AppTheme.textSecondary,
                  size: 18,
                ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// Outbox Banner — shown when offline actions are queued
// ════════════════════════════════════════════════════════════════════
class _OutboxBanner extends StatelessWidget {
  const _OutboxBanner({
    required this.count,
    required this.error,
    required this.onRetry,
  });

  final int count;
  final String? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.warning.withValues(alpha: 0.12),
        border: Border.all(color: AppTheme.warning.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$count ການເຮັດວຽກລໍສົ່ງ',
                  style: const TextStyle(
                    color: AppTheme.textBright,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  error?.isNotEmpty == true
                      ? error!
                      : 'ຈະສົ່ງເຂົ້າ server ເມື່ອມີເນັດ',
                  style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          TextButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded, size: 14),
            label: const Text('ລອງສົ່ງ'),
            style: TextButton.styleFrom(
              foregroundColor: AppTheme.warning,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: const Size(0, 0),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// Search Bar (toggleable)
// ════════════════════════════════════════════════════════════════════
class _SearchBar extends StatelessWidget {
  const _SearchBar({required this.controller, required this.onClose});

  final TextEditingController controller;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.bgCard,
          borderRadius: BorderRadius.circular(AppTheme.radiusFull),
          border: Border.all(color: AppTheme.primary.withValues(alpha: 0.4)),
        ),
        child: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: AppTheme.textBright, fontSize: 13),
          decoration: InputDecoration(
            hintText: 'ຄົ້ນຫາ ເລກຖ້ຽວ ຫຼື ລົດ',
            hintStyle: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
            prefixIcon: const Icon(
              Icons.search_rounded,
              color: AppTheme.textMuted,
              size: 18,
            ),
            suffixIcon: controller.text.isNotEmpty
                ? IconButton(
                    icon: const Icon(
                      Icons.close_rounded,
                      color: AppTheme.textMuted,
                      size: 16,
                    ),
                    onPressed: controller.clear,
                  )
                : null,
            filled: true,
            fillColor: Colors.transparent,
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 12,
            ),
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// Tab Bar
// ════════════════════════════════════════════════════════════════════
class _TabSpec {
  const _TabSpec({
    required this.label,
    required this.count,
    required this.color,
  });
  final String label;
  final int count;
  final Color color;
}

class _TabBar extends StatelessWidget {
  const _TabBar({required this.controller, required this.tabs});

  final TabController controller;
  final List<_TabSpec> tabs;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppTheme.surfaceBorder, width: 1),
        ),
      ),
      child: TabBar(
        controller: controller,
        isScrollable: false,
        labelPadding: const EdgeInsets.symmetric(horizontal: 4),
        indicatorColor: AppTheme.primary,
        indicatorWeight: 3,
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: Colors.transparent,
        labelColor: AppTheme.textBright,
        unselectedLabelColor: AppTheme.textMuted,
        labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w900),
        unselectedLabelStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
        tabs: List.generate(tabs.length, (i) {
          final t = tabs[i];
          final selected = controller.index == i;
          return Tab(
            height: 46,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(t.label),
                const SizedBox(width: 6),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: selected
                        ? t.color.withValues(alpha: 0.18)
                        : AppTheme.bgSurface,
                    borderRadius: BorderRadius.circular(AppTheme.radiusFull),
                  ),
                  child: Text(
                    '${t.count}',
                    style: TextStyle(
                      color: selected ? t.color : AppTheme.textMuted,
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// Job List (per-tab)
// ════════════════════════════════════════════════════════════════════
class _JobList extends StatelessWidget {
  const _JobList({
    required this.jobs,
    required this.hasJobs,
    required this.onTapJob,
    required this.onRefresh,
    required this.onClearSearch,
  });

  final List<DeliveryJob> jobs;
  final bool hasJobs;
  final void Function(DeliveryJob) onTapJob;
  final Future<void> Function() onRefresh;
  final VoidCallback? onClearSearch;

  @override
  Widget build(BuildContext context) {
    if (jobs.isEmpty) {
      return RefreshIndicator(
        onRefresh: onRefresh,
        color: AppTheme.primary,
        backgroundColor: AppTheme.bgCard,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.of(context).size.height * 0.4,
              child: _EmptyState(
                hasJobs: hasJobs,
                onClearSearch: onClearSearch,
              ),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: onRefresh,
      color: AppTheme.primary,
      backgroundColor: AppTheme.bgCard,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: jobs.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (_, i) =>
            _JobCard(job: jobs[i], onTap: () => onTapJob(jobs[i])),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// Job Card
// ════════════════════════════════════════════════════════════════════
class _JobCard extends StatelessWidget {
  const _JobCard({required this.job, required this.onTap});

  final DeliveryJob job;
  final VoidCallback onTap;

  ({Color color, String label, IconData icon}) get _status {
    if (job.pendingApproval) {
      return (
        color: AppTheme.warning,
        label: 'ລໍຖ້າອະນຸມັດ',
        icon: Icons.hourglass_top_rounded,
      );
    }
    return switch (job.jobStatus) {
      0 => (
        color: AppTheme.info,
        label: 'ລໍຖ້າຈັດສົ່ງ',
        icon: Icons.schedule_rounded,
      ),
      1 => (
        color: AppTheme.warning,
        label: 'ຮັບແລ້ວ',
        icon: Icons.inventory_2_rounded,
      ),
      2 => (
        color: AppTheme.primary,
        label: 'ກຳລັງຈັດສົ່ງ',
        icon: Icons.local_shipping_rounded,
      ),
      3 => (
        color: AppTheme.success,
        label: 'ປິດງານແລ້ວ',
        icon: Icons.check_circle_rounded,
      ),
      _ => (
        color: AppTheme.textMuted,
        label: 'ປິດແລ້ວ',
        icon: Icons.lock_rounded,
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final s = _status;
    final total = job.itemBill;
    final completed = job.completedBillCount;
    final progress = total > 0 ? completed / total : 0.0;

    return Material(
      color: AppTheme.bgCard,
      borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            border: Border.all(color: AppTheme.surfaceBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: s.color.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                    ),
                    child: Icon(s.icon, color: s.color, size: 18),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          job.docNo,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppTheme.textBright,
                            fontSize: 15,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          s.label,
                          style: TextStyle(
                            color: s.color,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.bgSurface,
                      borderRadius: BorderRadius.circular(AppTheme.radiusFull),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.inventory_2_outlined,
                          size: 11,
                          color: AppTheme.textMuted,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          '$total',
                          style: const TextStyle(
                            color: AppTheme.textBright,
                            fontSize: 11,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  const Icon(
                    Icons.local_shipping_outlined,
                    size: 13,
                    color: AppTheme.textMuted,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      job.car,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(
                    Icons.event_outlined,
                    size: 13,
                    color: AppTheme.textMuted,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    job.dateLogistic,
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              if (total > 0 && !job.pendingApproval) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(
                          AppTheme.radiusFull,
                        ),
                        child: LinearProgressIndicator(
                          value: progress.clamp(0.0, 1.0),
                          minHeight: 4,
                          backgroundColor: AppTheme.bgSurface,
                          valueColor: AlwaysStoppedAnimation(s.color),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '$completed/$total',
                      style: TextStyle(
                        color: s.color,
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// States: Loading / Error / Empty
// ════════════════════════════════════════════════════════════════════
class _LoadingState extends StatelessWidget {
  const _LoadingState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SizedBox(
        width: 28,
        height: 28,
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
          color: AppTheme.primary,
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: AppTheme.error.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.cloud_off_rounded,
                color: AppTheme.error,
                size: 30,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'ດຶງຂໍ້ມູນບໍ່ສຳເລັດ',
              style: TextStyle(
                color: AppTheme.textBright,
                fontSize: 16,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('ລອງໃໝ່'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.hasJobs, this.onClearSearch});

  final bool hasJobs;
  final VoidCallback? onClearSearch;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: AppTheme.bgCard,
                shape: BoxShape.circle,
                border: Border.all(color: AppTheme.surfaceBorder),
              ),
              child: const Icon(
                Icons.inbox_rounded,
                color: AppTheme.textMuted,
                size: 28,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              hasJobs ? 'ບໍ່ມີຖ້ຽວໃນປະເພດນີ້' : 'ຍັງບໍ່ມີຖ້ຽວ',
              style: const TextStyle(
                color: AppTheme.textBright,
                fontSize: 14,
                fontWeight: FontWeight.w900,
              ),
            ),
            if (onClearSearch != null) ...[
              const SizedBox(height: 10),
              TextButton(
                onPressed: onClearSearch,
                child: const Text('ລ້າງການຄົ້ນຫາ'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
