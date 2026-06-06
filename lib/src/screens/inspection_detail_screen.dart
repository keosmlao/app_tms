import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../core/app_theme.dart';
import '../models/inspection.dart';
import '../services/api_client.dart';

/// Shows full inspection details.
/// If the user is an inspector and the status is pending, approve/reject
/// buttons are displayed.
class InspectionDetailScreen extends StatefulWidget {
  const InspectionDetailScreen({
    super.key,
    required this.controller,
    required this.inspectCode,
  });

  final AppController controller;
  final String inspectCode;

  @override
  State<InspectionDetailScreen> createState() =>
      _InspectionDetailScreenState();
}

class _InspectionDetailScreenState extends State<InspectionDetailScreen> {
  InspectionRecord? _record;
  bool _loading = true;
  String? _error;
  bool _acting = false;

  bool get _isInspector {
    final roles = (widget.controller.user?.roles ?? '').toLowerCase();
    return roles.contains('inspect') || roles.contains('admin');
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await widget.controller.api
          .getInspectionDetail(widget.inspectCode);
      if (!mounted) return;
      setState(() {
        _record = r;
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

  Future<void> _approve() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.bgCard,
        title: const Text(
          'ອານຸມັດການກວດ?',
          style: TextStyle(color: AppTheme.textBright),
        ),
        content: const Text(
          'ຢືນຢັນການອານຸມັດລາຍການກວດສະພາບລົດນີ້.',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('ຍົກເລີກ'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: AppTheme.success),
            child: const Text('ອານຸມັດ'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _doAction('approved', null);
  }

  Future<void> _reject() async {
    final noteCtrl = TextEditingController();
    final note = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppTheme.bgCard,
        title: const Text(
          'ປະຕິເສດການກວດ',
          style: TextStyle(color: AppTheme.textBright),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'ກະລຸນາລະບຸເຫດຜົນ:',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: noteCtrl,
              decoration: const InputDecoration(
                hintText: 'ເຫດຜົນ...',
                filled: true,
                fillColor: AppTheme.bgSurface,
                border: OutlineInputBorder(),
              ),
              style: const TextStyle(color: AppTheme.textBright),
              maxLines: 3,
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('ຍົກເລີກ'),
          ),
          FilledButton(
            onPressed: () {
              if (noteCtrl.text.trim().isEmpty) return;
              Navigator.pop(context, noteCtrl.text.trim());
            },
            style: FilledButton.styleFrom(backgroundColor: AppTheme.error),
            child: const Text('ປະຕິເສດ'),
          ),
        ],
      ),
    );
    noteCtrl.dispose();
    if (note == null || note.isEmpty || !mounted) return;
    await _doAction('rejected', note);
  }

  Future<void> _doAction(String action, String? note) async {
    setState(() => _acting = true);
    try {
      await widget.controller.api.approveInspection(
        inspectCode: widget.inspectCode,
        action: action,
        note: note,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            action == 'approved' ? 'ອານຸມັດສຳເລັດ' : 'ປະຕິເສດສຳເລັດ',
          ),
          backgroundColor:
              action == 'approved' ? AppTheme.success : AppTheme.error,
        ),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e is ApiException ? e.message : '$e'),
          backgroundColor: AppTheme.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgDark,
      appBar: AppBar(
        backgroundColor: AppTheme.bgMid,
        title: Text(widget.inspectCode),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _errorView()
              : _detailView(),
    );
  }

  Widget _errorView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: AppTheme.error, size: 48),
          const SizedBox(height: 12),
          Text(
            _error!,
            style: const TextStyle(color: AppTheme.textSecondary),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('ລອງໃໝ່'),
          ),
        ],
      ),
    );
  }

  Widget _detailView() {
    final r = _record!;
    final statusColor = r.isPending
        ? AppTheme.warning
        : r.isApproved
            ? AppTheme.success
            : AppTheme.error;
    final statusLabel = r.isPending
        ? 'ລໍຖ້າອານຸມັດ'
        : r.isApproved
            ? 'ອານຸມັດແລ້ວ'
            : 'ປະຕິເສດ';

    return Stack(
      children: [
        ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 120),
          children: [
            // Status banner
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                border: Border.all(color: statusColor.withValues(alpha: 0.4)),
              ),
              child: Row(
                children: [
                  Icon(
                    r.isPending
                        ? Icons.pending_outlined
                        : r.isApproved
                            ? Icons.check_circle_outline
                            : Icons.cancel_outlined,
                    color: statusColor,
                    size: 22,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          statusLabel,
                          style: TextStyle(
                            color: statusColor,
                            fontWeight: FontWeight.w800,
                            fontSize: 14,
                          ),
                        ),
                        if (!r.isPending && r.approvedByName != null)
                          Text(
                            'ໂດຍ ${r.approvedByName}${r.approvedAt != null ? ' · ${r.approvedAt}' : ''}',
                            style: TextStyle(
                              color: statusColor.withValues(alpha: 0.8),
                              fontSize: 11,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (r.isRejected && r.approvalNote != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.error.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.info_outline,
                        color: AppTheme.error, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        r.approvalNote!,
                        style: const TextStyle(
                            color: AppTheme.error, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            // Vehicle info
            _section('ຂໍ້ມູນ'),
            _infoRow('ລົດ', r.vehicleName.isNotEmpty
                ? '${r.vehicleCode} · ${r.vehicleName}'
                : r.vehicleCode),
            _infoRow('ວັນທີ', '${r.inspectDate}${r.inspectTime != null ? ' ${r.inspectTime}' : ''}'),
            if (r.employeeName.isNotEmpty)
              _infoRow('ຜູ້ກວດ', r.employeeName),
            if (r.driverName.isNotEmpty)
              _infoRow('ຄົນຂັບ', r.driverName),
            if (r.odometer != null)
              _infoRow('ໄມລ໌', r.odometer!.toStringAsFixed(0)),
            if (r.note != null && r.note!.isNotEmpty)
              _infoRow('ໝາຍເຫດ', r.note!),
            const SizedBox(height: 16),
            // Checklist items
            if (r.details.isNotEmpty) ...[
              _section('ລາຍການກວດ'),
              ...r.details.asMap().entries.map(
                    (e) => _detailRow(e.key + 1, e.value),
                  ),
            ],
          ],
        ),
        // Approve / reject action bar (inspector + pending only)
        if (_isInspector && r.isPending)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              decoration: BoxDecoration(
                color: AppTheme.bgMid,
                border: const Border(
                  top: BorderSide(color: AppTheme.surfaceBorder),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _acting ? null : _reject,
                      icon: const Icon(Icons.close_rounded,
                          color: AppTheme.error, size: 18),
                      label: const Text(
                        'ປະຕິເສດ',
                        style: TextStyle(color: AppTheme.error),
                      ),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(46),
                        side: const BorderSide(color: AppTheme.error),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _acting ? null : _approve,
                      icon: _acting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.check_rounded, size: 18),
                      label: const Text('ອານຸມັດ'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(46),
                        backgroundColor: AppTheme.success,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _section(String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        label,
        style: const TextStyle(
          color: AppTheme.textMuted,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: const TextStyle(
                color: AppTheme.textMuted,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: AppTheme.textBright,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(int no, InspectionDetail d) {
    // status_code 0 is typically "pass/normal" — first status in the list
    final isPassed = d.statusCode == 0;
    final statusColor = isPassed ? AppTheme.success : AppTheme.error;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppTheme.surfaceBorder),
      ),
      child: Row(
        children: [
          Text(
            '$no.',
            style: const TextStyle(
              color: AppTheme.textMuted,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              d.itemName,
              style: const TextStyle(
                color: AppTheme.textBright,
                fontSize: 13,
              ),
            ),
          ),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(AppTheme.radiusFull),
            ),
            child: Text(
              d.statusName,
              style: TextStyle(
                color: statusColor,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
