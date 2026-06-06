import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../core/app_theme.dart';
import '../core/app_version.dart';
import '../models/delivery_job.dart';
import '../services/api_client.dart';
import 'fleet_map_screen.dart';
import 'job_detail_screen.dart';

class SupervisorDashboardScreen extends StatefulWidget {
  const SupervisorDashboardScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<SupervisorDashboardScreen> createState() =>
      _SupervisorDashboardScreenState();
}

class _SupervisorDashboardScreenState extends State<SupervisorDashboardScreen> {
  final _search = TextEditingController();
  final _jobsSectionKey = GlobalKey();
  bool _loading = true;
  bool _refreshing = false;
  String? _error;
  String _filter = 'all';
  List<DeliveryJob> _jobs = const [];
  Map<String, dynamic> _kpi = const {};
  String? _busyApprove;

  @override
  void initState() {
    super.initState();
    _search.addListener(() => setState(() {}));
    _fetch();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _fetch({bool silent = false}) async {
    setState(() {
      _loading = !silent && _jobs.isEmpty;
      _refreshing = silent;
      _error = null;
    });
    try {
      final rows = await widget.controller.api.getSupervisorJobs();
      Map<String, dynamic> kpi = _kpi;
      try {
        kpi = await widget.controller.api.getSupervisorKpi();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _jobs = rows;
        _kpi = kpi;
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

  List<DeliveryJob> get _filtered {
    final query = _search.text.trim().toLowerCase();
    return _jobs
        .where((job) {
          final filterMatch = switch (_filter) {
            'pending' => job.pendingApproval,
            'active' => job.jobStatus == 1 || job.jobStatus == 2,
            'done' => job.jobStatus >= 3,
            'issue' =>
              job.cancelledBillCount > 0 || job.inprogressBillCount > 0,
            _ => true,
          };
          if (!filterMatch) return false;
          if (query.isEmpty) return true;
          return '${job.docNo} ${job.driver} ${job.car} ${job.userCreated}'
              .toLowerCase()
              .contains(query);
        })
        .toList(growable: false);
  }

  int get _pending => _jobs.where((job) => job.jobStatus == 0).length;
  int get _active =>
      _jobs.where((job) => job.jobStatus == 1 || job.jobStatus == 2).length;
  int get _done => _jobs.where((job) => job.jobStatus >= 3).length;
  int get _cancelBills =>
      _jobs.fold(0, (sum, job) => sum + job.cancelledBillCount);
  int get _openBills => _jobs.fold(
    0,
    (sum, job) => sum + job.waitingBillCount + job.inprogressBillCount,
  );
  int get _pendingApproval => _jobs.where((job) => job.pendingApproval).length;

  num _readNum(String key) {
    final value = _kpi[key];
    if (value is num) return value;
    return num.tryParse('${value ?? ''}'.trim()) ?? 0;
  }

  String _money(num value) => value
      .toStringAsFixed(0)
      .replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');

  String _today() {
    final now = DateTime.now();
    final day = now.day.toString().padLeft(2, '0');
    final month = now.month.toString().padLeft(2, '0');
    return '$day/$month/${now.year}';
  }

  Future<void> _openFleetMap() async {
    HapticFeedback.selectionClick();
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FleetMapScreen(controller: widget.controller),
      ),
    );
  }

  Future<void> _openJob(DeliveryJob job) async {
    HapticFeedback.selectionClick();
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => JobDetailScreen(
          controller: widget.controller,
          initialJob: job,
          readOnly: true,
        ),
      ),
    );
    if (mounted) _fetch(silent: true);
  }

  Future<void> _approve(DeliveryJob job) async {
    setState(() => _busyApprove = job.docNo);
    try {
      await widget.controller.api.approveJob(job.docNo);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('ອະນຸມັດ ${job.docNo} ແລ້ວ'),
          backgroundColor: AppTheme.success,
        ),
      );
      await _fetch(silent: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('ອະນຸມັດບໍ່ໄດ້: ${e is ApiException ? e.message : e}'),
        ),
      );
    } finally {
      if (mounted) setState(() => _busyApprove = null);
    }
  }

  Future<void> _logout() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.bgCard,
        title: const Text(
          'ອອກຈາກລະບົບ?',
          style: TextStyle(color: AppTheme.textBright),
        ),
        content: const Text(
          'ທ່ານຈະຕ້ອງ login ໃໝ່ເພື່ອໃຊ້ງານ.',
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
    if (accepted == true) await widget.controller.logout();
  }

  void _setFilter(String value) {
    HapticFeedback.selectionClick();
    setState(() => _filter = value);
  }

  void _openFilter(String value) {
    _setFilter(value);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final sectionContext = _jobsSectionKey.currentContext;
      if (sectionContext == null) return;
      Scrollable.ensureVisible(
        sectionContext,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
        alignment: 0,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgDark,
      body: SafeArea(
        child: _loading
            ? const Center(
                child: CircularProgressIndicator(color: AppTheme.primary),
              )
            : RefreshIndicator(
                color: AppTheme.primary,
                backgroundColor: AppTheme.bgCard,
                onRefresh: () => _fetch(silent: true),
                child: CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(child: _topBar()),
                    if (_error != null)
                      SliverToBoxAdapter(child: _errorBanner(_error!)),
                    SliverToBoxAdapter(child: _dailyOverview()),
                    SliverToBoxAdapter(child: _commands()),
                    SliverToBoxAdapter(child: _attention()),
                    SliverPersistentHeader(
                      pinned: true,
                      delegate: _FilterHeaderDelegate(
                        child: _searchAndFilters(),
                      ),
                    ),
                    _jobsSliver(),
                    SliverToBoxAdapter(child: _versionFooter()),
                    const SliverToBoxAdapter(child: SizedBox(height: 28)),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _versionFooter() {
    final v = AppVersion.display;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Center(
        child: Text(
          v.isEmpty ? 'ເວີຊັນ —' : 'ເວີຊັນ $v',
          style: const TextStyle(
            color: AppTheme.textMuted,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _topBar() {
    final user = widget.controller.user;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppTheme.primary,
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            ),
            child: Text(
              user?.displayName.trim().isNotEmpty == true
                  ? user!.displayName.trim()[0].toUpperCase()
                  : '?',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  user?.displayName ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.textBright,
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Text(
                  '${user?.roleLabel ?? 'Operations'} · ${_today()}',
                  style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          _topAction(
            icon: _refreshing ? null : Icons.refresh_rounded,
            tooltip: 'ໂຫຼດຂໍ້ມູນໃໝ່',
            onTap: _refreshing ? null : () => _fetch(silent: true),
            loading: _refreshing,
          ),
          const SizedBox(width: 7),
          _topAction(
            icon: Icons.logout_rounded,
            tooltip: 'ອອກຈາກລະບົບ',
            onTap: _logout,
          ),
        ],
      ),
    );
  }

  Widget _topAction({
    required IconData? icon,
    required String tooltip,
    required VoidCallback? onTap,
    bool loading = false,
  }) {
    return Material(
      color: AppTheme.bgSurface,
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
                : Icon(icon, color: AppTheme.textSecondary, size: 18),
          ),
        ),
      ),
    );
  }

  Widget _dailyOverview() {
    final delivered = _readNum('delivered_bills').toInt();
    final total = _readNum('total_bills').toInt();
    final cod = _readNum('cod_collected');
    final progress = total == 0 ? 0.0 : (delivered / total).clamp(0.0, 1.0);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(color: AppTheme.surfaceBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'ພາບລວມການຂົນສົ່ງມື້ນີ້',
                      style: TextStyle(
                        color: AppTheme.textBright,
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'ຂໍ້ມູນສຳລັບຄວບຄຸມວຽກ',
                      style: TextStyle(color: AppTheme.textMuted, fontSize: 10),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                decoration: BoxDecoration(
                  color: AppTheme.success.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppTheme.radiusFull),
                ),
                child: Text(
                  '${(progress * 100).round()}% ສຳເລັດ',
                  style: const TextStyle(
                    color: AppTheme.success,
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 7,
              color: AppTheme.success,
              backgroundColor: AppTheme.bgSurface,
            ),
          ),
          const SizedBox(height: 15),
          Row(
            children: [
              _overviewMetric(
                value: '$_active',
                label: 'ຖ້ຽວກຳລັງແລ່ນ',
                icon: Icons.local_shipping_rounded,
                color: AppTheme.info,
              ),
              _overviewDivider(),
              _overviewMetric(
                value: '$delivered/$total',
                label: 'ບິນສົ່ງສຳເລັດ',
                icon: Icons.task_alt_rounded,
                color: AppTheme.success,
              ),
              _overviewDivider(),
              _overviewMetric(
                value: '$_pendingApproval',
                label: 'ລໍອະນຸມັດ',
                icon: Icons.pending_actions_rounded,
                color: AppTheme.warning,
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
            decoration: BoxDecoration(
              color: AppTheme.bgSurface,
              borderRadius: BorderRadius.circular(AppTheme.radiusSm),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.payments_rounded,
                  color: AppTheme.success,
                  size: 17,
                ),
                const SizedBox(width: 8),
                const Text(
                  'COD ເກັບແລ້ວ',
                  style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
                ),
                const Spacer(),
                Text(
                  '${_money(cod)} ກີບ',
                  style: const TextStyle(
                    color: AppTheme.textBright,
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _overviewMetric({
    required String value,
    required String label,
    required IconData icon,
    required Color color,
  }) {
    return Expanded(
      child: Column(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(height: 5),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
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

  Widget _overviewDivider() =>
      Container(width: 1, height: 42, color: AppTheme.surfaceBorder);

  Widget _commands() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle('ຄຳສັ່ງດ່ວນ', Icons.bolt_rounded),
          const SizedBox(height: 9),
          Row(
            children: [
              Expanded(
                child: _command(
                  label: 'Fleet Map',
                  detail: 'ຕິດຕາມສົດ',
                  icon: Icons.map_rounded,
                  color: AppTheme.primary,
                  onTap: _openFleetMap,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _command(
                  label: 'ລໍອະນຸມັດ',
                  detail: '$_pendingApproval ຖ້ຽວ',
                  icon: Icons.approval_rounded,
                  color: AppTheme.warning,
                  onTap: () => _openFilter('pending'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _command(
                  label: 'ບັນຫາ',
                  detail: '$_cancelBills ບິນ',
                  icon: Icons.report_problem_rounded,
                  color: AppTheme.error,
                  onTap: () => _openFilter('issue'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _command({
    required String label,
    required String detail,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Material(
      color: AppTheme.bgSurface,
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        child: Container(
          height: 88,
          padding: const EdgeInsets.all(11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            border: Border.all(color: AppTheme.surfaceBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: color, size: 21),
              const Spacer(),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppTheme.textBright,
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                ),
              ),
              Text(
                detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: color, fontSize: 9),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _attention() {
    if (_pending == 0 && _openBills == 0 && _cancelBills == 0) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle('ຈຸດທີ່ຕ້ອງຈັດການ', Icons.notifications_rounded),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.bgSurface,
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              border: Border.all(color: AppTheme.surfaceBorder),
            ),
            child: Row(
              children: [
                _attentionItem('ຖ້ຽວລໍຖ້າ', _pending, AppTheme.warning),
                _overviewDivider(),
                _attentionItem('ບິນຍັງບໍ່ປິດ', _openBills, AppTheme.info),
                _overviewDivider(),
                _attentionItem('ບິນຍົກເລີກ', _cancelBills, AppTheme.error),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _attentionItem(String label, int value, Color color) {
    return Expanded(
      child: Column(
        children: [
          Text(
            '$value',
            style: TextStyle(
              color: color,
              fontSize: 16,
              fontWeight: FontWeight.w900,
            ),
          ),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 8),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text, IconData icon) {
    return Row(
      children: [
        Icon(icon, color: AppTheme.textSecondary, size: 15),
        const SizedBox(width: 6),
        Text(
          text,
          style: const TextStyle(
            color: AppTheme.textBright,
            fontSize: 12,
            fontWeight: FontWeight.w900,
          ),
        ),
      ],
    );
  }

  Widget _searchAndFilters() {
    return Container(
      key: _jobsSectionKey,
      color: AppTheme.bgDark,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'ຖ້ຽວຂົນສົ່ງ',
                  style: TextStyle(
                    color: AppTheme.textBright,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Text(
                '${_filtered.length}/${_jobs.length}',
                style: const TextStyle(
                  color: AppTheme.textMuted,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _search,
            style: const TextStyle(color: AppTheme.textBright, fontSize: 12),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'ຄົ້ນຫາຖ້ຽວ, ຄົນຂັບ ຫຼື ລົດ',
              prefixIcon: const Icon(Icons.search_rounded, size: 18),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'ລ້າງຄຳຄົ້ນ',
                      onPressed: _search.clear,
                      icon: const Icon(Icons.close_rounded, size: 17),
                    ),
            ),
          ),
          const SizedBox(height: 7),
          SizedBox(
            height: 31,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _filterButton('all', 'ທັງໝົດ', _jobs.length),
                _filterButton('pending', 'ລໍອະນຸມັດ', _pendingApproval),
                _filterButton('active', 'ກຳລັງ', _active),
                _filterButton('done', 'ສຳເລັດ', _done),
                _filterButton('issue', 'ບັນຫາ', _cancelBills),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterButton(String value, String label, int count) {
    final selected = _filter == value;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Material(
        color: selected ? AppTheme.primary : AppTheme.bgSurface,
        borderRadius: BorderRadius.circular(AppTheme.radiusFull),
        child: InkWell(
          onTap: () => _setFilter(value),
          borderRadius: BorderRadius.circular(AppTheme.radiusFull),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 11),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppTheme.radiusFull),
              border: Border.all(
                color: selected ? AppTheme.primary : AppTheme.surfaceBorder,
              ),
            ),
            child: Text(
              '$label $count',
              style: const TextStyle(
                color: AppTheme.textBright,
                fontSize: 9,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _jobsSliver() {
    final rows = _filtered;
    if (rows.isEmpty) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 48),
          child: Column(
            children: [
              Icon(Icons.route_outlined, color: AppTheme.textDim, size: 32),
              SizedBox(height: 8),
              Text(
                'ບໍ່ມີຖ້ຽວຕາມເງື່ອນໄຂ',
                style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverList.builder(
        itemCount: rows.length,
        itemBuilder: (context, index) => _jobRow(rows[index]),
      ),
    );
  }

  Widget _jobRow(DeliveryJob job) {
    final color = switch (job.jobStatus) {
      0 => AppTheme.warning,
      1 => AppTheme.primary,
      2 => AppTheme.info,
      >= 3 => AppTheme.success,
      _ => AppTheme.textMuted,
    };
    final open = job.waitingBillCount + job.inprogressBillCount;
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Material(
        color: AppTheme.bgSurface,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        child: InkWell(
          onTap: () => _openJob(job),
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          child: Container(
            padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
              border: Border.all(color: AppTheme.surfaceBorder),
            ),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                  ),
                  child: Icon(Icons.route_rounded, color: color, size: 20),
                ),
                const SizedBox(width: 10),
                Expanded(
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
                            job.statusText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: color,
                              fontSize: 9,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${job.driver} · ${job.car}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.textMuted,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Row(
                        children: [
                          _miniStat('${job.itemBill} ບິນ', AppTheme.textMuted),
                          _miniStat('open $open', AppTheme.info),
                          if (job.cancelledBillCount > 0)
                            _miniStat(
                              'cancel ${job.cancelledBillCount}',
                              AppTheme.error,
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (job.pendingApproval &&
                    widget.controller.user?.canApproveJobs == true)
                  SizedBox(
                    height: 32,
                    child: FilledButton(
                      onPressed: _busyApprove == job.docNo
                          ? null
                          : () => _approve(job),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.success,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        minimumSize: const Size(0, 32),
                      ),
                      child: _busyApprove == job.docNo
                          ? const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text(
                              'ອະນຸມັດ',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                    ),
                  )
                else
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

  Widget _miniStat(String text, Color color) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _errorBanner(String message) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: AppTheme.error.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppTheme.error.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, color: AppTheme.error),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: AppTheme.textBright, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _FilterHeaderDelegate({required this.child});

  final Widget child;

  @override
  double get minExtent => 134;

  @override
  double get maxExtent => 134;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return child;
  }

  @override
  bool shouldRebuild(covariant _FilterHeaderDelegate oldDelegate) =>
      oldDelegate.child != child;
}
