import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../services/offline_outbox.dart';

/// Outbox detail — lets the driver see queued POST actions, retry them
/// manually, or clear stuck items. Useful in low-signal areas where actions
/// were queued automatically and the driver wants to verify they sent.
class OutboxScreen extends StatefulWidget {
  const OutboxScreen({super.key});

  @override
  State<OutboxScreen> createState() => _OutboxScreenState();
}

class _OutboxScreenState extends State<OutboxScreen> {
  bool _flushing = false;

  @override
  void initState() {
    super.initState();
    OfflineOutbox.instance.addListener(_onChange);
  }

  @override
  void dispose() {
    OfflineOutbox.instance.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  Future<void> _retry() async {
    if (_flushing) return;
    setState(() => _flushing = true);
    try {
      await OfflineOutbox.instance.flush();
    } finally {
      if (mounted) setState(() => _flushing = false);
    }
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ລ້າງ outbox?'),
        content: const Text(
          'ການກະທຳທີ່ຄ້າງຢູ່ຈະບໍ່ຖືກສົ່ງໄປ server. ໃຊ້ສະເພາະຖ້າຄ້າງດົນ.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('ຍົກເລີກ'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('ລ້າງ'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await OfflineOutbox.instance.clear();
    }
  }

  String _actionLabel(OutboxAction action) {
    final raw = action.body['action']?.toString() ?? action.path;
    return switch (raw) {
      'receive' => 'ຮັບຖ້ຽວ',
      'pickup_bill' => 'ເບີກບິນ',
      'receive_customer_bill' => 'ຮັບສິນຄ້າຈາກລູກຄ້າ',
      'start_dispatch' => 'ເລີ່ມຈັດສົ່ງ',
      'checkin_bill' => 'Check-in ບິນ',
      'complete_bill' => 'ສຳເລັດບິນ',
      'cancel_bill' => 'ຍົກເລີກບິນ',
      'revert_complete_bill' => 'ຍ້ອນກັບບິນສຳເລັດ',
      'edit_complete_bill' => 'ແກ້ໄຂບິນສຳເລັດ',
      'complete_job' => 'ປິດຖ້ຽວ',
      'fuel_refill' => 'ເຕີມນ້ຳມັນ',
      'attach_bill_image' => 'ອັບໂຫຼດຮູບບິນ',
      'attach_job_image' => 'ອັບໂຫຼດຮູບຖ້ຽວ',
      _ => raw,
    };
  }

  String _targetLabel(OutboxAction action) {
    final body = action.body;
    final parts = [
      body['doc_no']?.toString(),
      body['bill_no']?.toString(),
      body['car']?.toString(),
      body['kind'] == null ? null : 'kind: ${body['kind']}',
    ].where((v) => v != null && v.trim().isNotEmpty).cast<String>().toList();
    return parts.isEmpty ? action.path : parts.join(' · ');
  }

  String _createdLabel(String iso) {
    final parsed = DateTime.tryParse(iso)?.toLocal();
    if (parsed == null) return iso;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(parsed.day)}/${two(parsed.month)} ${two(parsed.hour)}:${two(parsed.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final outbox = OfflineOutbox.instance;
    final items = outbox.items;
    return Scaffold(
      backgroundColor: AppTheme.bgDark,
      appBar: AppBar(
        title: const Text('Outbox ການກະທຳຄ້າງ'),
        actions: [
          if (items.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'ລ້າງທັງໝົດ',
              onPressed: _confirmClear,
            ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: items.isEmpty
                  ? AppTheme.success.withValues(alpha: 0.08)
                  : AppTheme.warning.withValues(alpha: 0.10),
              border: const Border(
                bottom: BorderSide(color: AppTheme.surfaceBorder),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      items.isEmpty ? Icons.check_circle : Icons.cloud_off,
                      color: items.isEmpty
                          ? AppTheme.success
                          : AppTheme.warning,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      items.isEmpty
                          ? 'ບໍ່ມີຄ້າງ ทุกຢ່າງສົ່ງສຳເລັດ'
                          : 'ມີ ${items.length} ການກະທຳຄ້າງ',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                if (outbox.lastError != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    'ຂໍ້ຜິດພາດຫຼ້າສຸດ: ${outbox.lastError}',
                    style: const TextStyle(color: AppTheme.error, fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
          if (items.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _flushing ? null : _retry,
                  icon: _flushing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  label: Text(_flushing ? 'ກຳລັງສົ່ງ...' : 'ລອງສົ່ງໃໝ່'),
                ),
              ),
            ),
          Expanded(
            child: items.isEmpty
                ? const Center(
                    child: Text(
                      'ບໍ່ມີຂໍ້ມູນ',
                      style: TextStyle(color: AppTheme.textMuted),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 6, 12, 18),
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final a = items[i];
                      final isImage =
                          a.body['action'] == 'attach_bill_image' ||
                          a.body['action'] == 'attach_job_image';
                      return Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppTheme.bgSurface,
                          borderRadius: BorderRadius.circular(
                            AppTheme.radiusMd,
                          ),
                          border: Border.all(color: AppTheme.surfaceBorder),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color:
                                    (isImage ? AppTheme.info : AppTheme.warning)
                                        .withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(
                                  AppTheme.radiusSm,
                                ),
                              ),
                              child: Icon(
                                isImage
                                    ? Icons.image_outlined
                                    : Icons.cloud_upload_outlined,
                                color: isImage
                                    ? AppTheme.info
                                    : AppTheme.warning,
                                size: 18,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _actionLabel(a),
                                    style: const TextStyle(
                                      color: AppTheme.textBright,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    _targetLabel(a),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: AppTheme.textMuted,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    'ສ້າງ ${_createdLabel(a.createdAt)} · retry ${a.retries}',
                                    style: const TextStyle(
                                      fontSize: 10,
                                      color: AppTheme.textDim,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
