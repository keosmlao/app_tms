import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../core/app_theme.dart';
import '../models/delivery_job.dart';
import '../services/api_client.dart';
import '../services/local_cache.dart';
import '../services/location_tracking_service.dart';
import '../services/offline_outbox.dart';
import 'job_detail_screen.dart';

enum _JobFilter { all, waiting, active, done }

class JobsScreen extends StatefulWidget {
  const JobsScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<JobsScreen> createState() => _JobsScreenState();
}

class _JobsScreenState extends State<JobsScreen> with WidgetsBindingObserver {
  final _searchController = TextEditingController();
  Timer? _autoRefresh;
  _JobFilter _filter = _JobFilter.all;
  bool _searchOpen = false;
  bool _loading = true;
  bool _refreshing = false;
  bool _lastFetchUsedCache = false;
  DateTime? _jobsCacheAt;
  String? _error;
  List<DeliveryJob> _jobs = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_onControllerChanged);
    OfflineOutbox.instance.addListener(_onOutboxChanged);
    _searchController.addListener(() => setState(() {}));
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
    _searchController.dispose();
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
    if (widget.controller.pendingDocNo == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeOpenPendingDoc());
  }

  Future<void> _maybeOpenPendingDoc() async {
    final docNo = widget.controller.pendingDocNo;
    if (docNo == null || !mounted) return;
    widget.controller.consumePendingDocNo();
    if (_jobs.isEmpty) await _fetch(silent: true);
    final match = _jobs.where((job) => job.docNo == docNo).firstOrNull;
    if (!mounted) return;
    if (match != null) {
      await _openDetail(match);
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('ບໍ່ພົບຖ້ຽວ $docNo')));
    }
  }

  Future<void> _fetch({bool silent = false}) async {
    setState(() {
      if (silent) {
        _refreshing = true;
      } else {
        _loading = _jobs.isEmpty;
        _error = null;
      }
    });
    try {
      final user = widget.controller.user!;
      final api = widget.controller.api;
      final data = await api.getJobs(driverId: user.driverId);
      final cacheAt = await LocalCache.instance.jobsSavedAt(user.driverId);
      if (!mounted) return;
      setState(() {
        _jobs = data;
        _lastFetchUsedCache = api.lastFetchUsedCache;
        _jobsCacheAt = cacheAt;
        _loading = false;
        _refreshing = false;
        _error = null;
      });
      // Only drivers post GPS for their own trips — never operations staff.
      if (user.isDriverOnly) {
        LocationTrackingService.instance.sync(
          jobs: data,
          baseUrl: widget.controller.baseUrl,
          authToken: user.token,
          driverId: user.driverId,
        );
      }
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

  bool _matchesSearch(DeliveryJob job) {
    final query = _searchController.text.trim().toLowerCase();
    if (query.isEmpty) return true;
    return '${job.docNo} ${job.car} ${job.driver} ${job.dateLogistic}'
        .toLowerCase()
        .contains(query);
  }

  bool _matchesFilter(DeliveryJob job) => switch (_filter) {
    _JobFilter.all => true,
    _JobFilter.waiting => job.jobStatus == 0,
    _JobFilter.active => job.jobStatus == 1 || job.jobStatus == 2,
    _JobFilter.done => job.jobStatus >= 3,
  };

  List<DeliveryJob> get _visible =>
      _jobs.where((job) => _matchesFilter(job) && _matchesSearch(job)).toList();

  List<DeliveryJob> get _activeJobs => _jobs
      .where((job) => job.jobStatus == 1 || job.jobStatus == 2)
      .toList(growable: false);

  int get _waitingCount => _jobs.where((job) => job.jobStatus == 0).length;
  int get _activeCount => _activeJobs.length;
  int get _doneCount => _jobs.where((job) => job.jobStatus >= 3).length;

  void _setFilter(_JobFilter value) {
    HapticFeedback.selectionClick();
    setState(() => _filter = value);
  }

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
              ? const Center(
                  child: CircularProgressIndicator(color: AppTheme.primary),
                )
              : Column(
                  children: [
                    _header(),
                    if (_error != null) _errorBanner(),
                    if (OfflineOutbox.instance.pendingCount > 0)
                      _outboxBanner(),
                    if (_lastFetchUsedCache) _cacheBanner(),
                    if (_activeJobs.isNotEmpty && _filter == _JobFilter.all)
                      _activeTrip(_activeJobs.first),
                    _filterBar(),
                    Expanded(child: _jobList()),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _header() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppTheme.surfaceBorder)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              _iconButton(
                icon: Icons.arrow_back_rounded,
                tooltip: 'ກັບຄືນ',
                onTap: () => Navigator.pop(context),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'ວຽກຂົນສົ່ງ',
                      style: TextStyle(
                        color: AppTheme.textBright,
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      'ຈັດລຳດັບ ແລະ ສືບຕໍ່ວຽກຂອງທ່ານ',
                      style: TextStyle(color: AppTheme.textMuted, fontSize: 10),
                    ),
                  ],
                ),
              ),
              _iconButton(
                icon: _searchOpen
                    ? Icons.search_off_rounded
                    : Icons.search_rounded,
                tooltip: 'ຄົ້ນຫາ',
                selected: _searchOpen,
                onTap: () {
                  setState(() {
                    _searchOpen = !_searchOpen;
                    if (!_searchOpen) _searchController.clear();
                  });
                },
              ),
              const SizedBox(width: 7),
              _iconButton(
                icon: Icons.refresh_rounded,
                tooltip: 'ໂຫຼດໃໝ່',
                loading: _refreshing,
                onTap: _refreshing ? null : _refresh,
              ),
            ],
          ),
          if (_searchOpen) ...[
            const SizedBox(height: 10),
            TextField(
              controller: _searchController,
              autofocus: true,
              style: const TextStyle(color: AppTheme.textBright, fontSize: 12),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'ຄົ້ນຫາເລກຖ້ຽວ, ລົດ ຫຼື ວັນທີ',
                prefixIcon: const Icon(Icons.search_rounded, size: 18),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'ລ້າງຄຳຄົ້ນ',
                        onPressed: _searchController.clear,
                        icon: const Icon(Icons.close_rounded, size: 17),
                      ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _iconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onTap,
    bool selected = false,
    bool loading = false,
  }) {
    return Material(
      color: selected ? AppTheme.primary : AppTheme.bgSurface,
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        child: Tooltip(
          message: tooltip,
          child: SizedBox(
            width: 40,
            height: 40,
            child: loading
                ? const Center(
                    child: SizedBox(
                      width: 15,
                      height: 15,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppTheme.primary,
                      ),
                    ),
                  )
                : Icon(
                    icon,
                    color: selected ? Colors.white : AppTheme.textSecondary,
                    size: 19,
                  ),
          ),
        ),
      ),
    );
  }

  Widget _activeTrip(DeliveryJob job) {
    final completed = job.completedBillCount;
    final total = job.itemBill;
    final progress = total > 0 ? (completed / total).clamp(0.0, 1.0) : 0.0;
    final status = _jobStatus(job);
    return Material(
      color: AppTheme.bgCard,
      child: InkWell(
        onTap: () => _openDetail(job),
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 13),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: AppTheme.surfaceBorder)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: status.color.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(AppTheme.radiusFull),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: status.color,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          'ວຽກທີ່ກຳລັງເຮັດ',
                          style: TextStyle(
                            color: status.color,
                            fontSize: 9,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '$completed/$total ບິນ',
                    style: const TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 9),
              Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: status.color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                    ),
                    child: Icon(status.icon, color: status.color, size: 21),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          job.docNo,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppTheme.textBright,
                            fontSize: 14,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        Text(
                          '${job.car} · ${status.label}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: status.color, fontSize: 10),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: AppTheme.primary,
                      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                    ),
                    child: const Row(
                      children: [
                        Text(
                          'ສືບຕໍ່',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        SizedBox(width: 4),
                        Icon(
                          Icons.arrow_forward_rounded,
                          color: Colors.white,
                          size: 14,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 5,
                  color: status.color,
                  backgroundColor: AppTheme.bgSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _filterBar() {
    return Container(
      height: 76,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 9),
      decoration: const BoxDecoration(
        color: AppTheme.bgDark,
        border: Border(bottom: BorderSide(color: AppTheme.surfaceBorder)),
      ),
      child: Row(
        children: [
          _filterItem(_JobFilter.all, 'ທັງໝົດ', _jobs.length),
          _filterItem(_JobFilter.waiting, 'ລໍຖ້າ', _waitingCount),
          _filterItem(_JobFilter.active, 'ກຳລັງ', _activeCount),
          _filterItem(_JobFilter.done, 'ສຳເລັດ', _doneCount),
        ],
      ),
    );
  }

  Widget _filterItem(_JobFilter value, String label, int count) {
    final selected = _filter == value;
    final color = switch (value) {
      _JobFilter.all => AppTheme.primary,
      _JobFilter.waiting => AppTheme.warning,
      _JobFilter.active => AppTheme.info,
      _JobFilter.done => AppTheme.success,
    };
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: Material(
          color: selected ? color.withValues(alpha: 0.14) : Colors.transparent,
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
          child: InkWell(
            onTap: () => _setFilter(value),
            borderRadius: BorderRadius.circular(AppTheme.radiusSm),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                border: Border.all(
                  color: selected
                      ? color.withValues(alpha: 0.5)
                      : AppTheme.surfaceBorder,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '$count',
                    style: TextStyle(
                      color: selected ? color : AppTheme.textSecondary,
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? color : AppTheme.textMuted,
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _jobList() {
    final rows = _visible;
    if (rows.isEmpty) {
      return RefreshIndicator(
        onRefresh: _refresh,
        color: AppTheme.primary,
        backgroundColor: AppTheme.bgCard,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.45,
              child: _emptyState(),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      color: AppTheme.primary,
      backgroundColor: AppTheme.bgCard,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 28),
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: rows.length,
        separatorBuilder: (_, _) => const SizedBox(height: 7),
        itemBuilder: (_, index) => _jobRow(rows[index]),
      ),
    );
  }

  Widget _jobRow(DeliveryJob job) {
    final status = _jobStatus(job);
    final total = job.itemBill;
    final completed = job.completedBillCount;
    final open = job.waitingBillCount + job.inprogressBillCount;
    final progress = total > 0 ? (completed / total).clamp(0.0, 1.0) : 0.0;
    return Material(
      color: AppTheme.bgSurface,
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      child: InkWell(
        onTap: () => _openDetail(job),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        child: Container(
          constraints: const BoxConstraints(minHeight: 92),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            border: Border.all(color: AppTheme.surfaceBorder),
          ),
          child: Row(
            children: [
              Container(
                width: 4,
                constraints: const BoxConstraints(minHeight: 90),
                decoration: BoxDecoration(
                  color: status.color,
                  borderRadius: const BorderRadius.horizontal(
                    left: Radius.circular(AppTheme.radiusMd),
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(11, 10, 10, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              job.docNo,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppTheme.textBright,
                                fontSize: 12,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                          Text(
                            status.label,
                            style: TextStyle(
                              color: status.color,
                              fontSize: 9,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          const Icon(
                            Icons.local_shipping_outlined,
                            color: AppTheme.textMuted,
                            size: 13,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              job.car,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppTheme.textSecondary,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const Icon(
                            Icons.event_outlined,
                            color: AppTheme.textDim,
                            size: 12,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            job.dateLogistic,
                            style: const TextStyle(
                              color: AppTheme.textMuted,
                              fontSize: 9,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(3),
                              child: LinearProgressIndicator(
                                value: progress,
                                minHeight: 4,
                                color: status.color,
                                backgroundColor: AppTheme.bgCard,
                              ),
                            ),
                          ),
                          const SizedBox(width: 9),
                          _jobMeta('$completed/$total', AppTheme.textSecondary),
                          _jobMeta('open $open', AppTheme.info),
                          if (job.cancelledBillCount > 0)
                            _jobMeta(
                              'cancel ${job.cancelledBillCount}',
                              AppTheme.error,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(right: 8),
                child: Icon(
                  Icons.chevron_right_rounded,
                  color: AppTheme.textMuted,
                  size: 19,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _jobMeta(String text, Color color) {
    return Padding(
      padding: const EdgeInsets.only(left: 7),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 8,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  ({Color color, IconData icon, String label}) _jobStatus(DeliveryJob job) {
    if (job.pendingApproval) {
      return (
        color: AppTheme.warning,
        icon: Icons.hourglass_top_rounded,
        label: 'ລໍອະນຸມັດ',
      );
    }
    return switch (job.jobStatus) {
      0 => (
        color: AppTheme.warning,
        icon: Icons.schedule_rounded,
        label: 'ລໍຮັບວຽກ',
      ),
      1 => (
        color: AppTheme.primary,
        icon: Icons.inventory_2_rounded,
        label: 'ຮັບວຽກແລ້ວ',
      ),
      2 => (
        color: AppTheme.info,
        icon: Icons.local_shipping_rounded,
        label: 'ກຳລັງຈັດສົ່ງ',
      ),
      3 => (
        color: AppTheme.success,
        icon: Icons.task_alt_rounded,
        label: 'ປິດງານແລ້ວ',
      ),
      _ => (
        color: AppTheme.textMuted,
        icon: Icons.lock_rounded,
        label: 'ປິດແລ້ວ',
      ),
    };
  }

  Widget _emptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.route_outlined, color: AppTheme.textDim, size: 34),
          const SizedBox(height: 9),
          const Text(
            'ບໍ່ມີຖ້ຽວໃນລາຍການນີ້',
            style: TextStyle(
              color: AppTheme.textBright,
              fontSize: 13,
              fontWeight: FontWeight.w900,
            ),
          ),
          if (_searchController.text.isNotEmpty) ...[
            const SizedBox(height: 7),
            TextButton(
              onPressed: _searchController.clear,
              child: const Text('ລ້າງຄຳຄົ້ນ'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _errorBanner() {
    return _noticeBanner(
      icon: Icons.error_outline_rounded,
      color: AppTheme.error,
      title: 'ດຶງຂໍ້ມູນບໍ່ສຳເລັດ',
      detail: _error!,
      action: 'ລອງໃໝ່',
      onTap: _refresh,
    );
  }

  Widget _outboxBanner() {
    return _noticeBanner(
      icon: Icons.cloud_off_rounded,
      color: AppTheme.warning,
      title: '${OfflineOutbox.instance.pendingCount} ລາຍການລໍສົ່ງ',
      detail: OfflineOutbox.instance.lastError ?? 'ລໍຖ້າການເຊື່ອມຕໍ່',
      action: 'ສົ່ງໃໝ່',
      onTap: OfflineOutbox.instance.flush,
    );
  }

  Widget _cacheBanner() {
    final time = _jobsCacheAt?.toLocal();
    final label = time == null
        ? 'ກຳລັງໃຊ້ຂໍ້ມູນທີ່ບັນທຶກໄວ້'
        : 'ຂໍ້ມູນບັນທຶກ ${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
    return _noticeBanner(
      icon: Icons.cached_rounded,
      color: AppTheme.info,
      title: 'ໂໝດ Offline',
      detail: label,
      action: 'ອັບເດດ',
      onTap: _refresh,
    );
  }

  Widget _noticeBanner({
    required IconData icon,
    required Color color,
    required String title,
    required String detail,
    required String action,
    required VoidCallback onTap,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        border: Border(
          bottom: BorderSide(color: color.withValues(alpha: 0.28)),
        ),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 17),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: AppTheme.textBright,
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 8,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: onTap,
            style: TextButton.styleFrom(
              foregroundColor: color,
              minimumSize: const Size(0, 30),
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: Text(action),
          ),
        ],
      ),
    );
  }
}
