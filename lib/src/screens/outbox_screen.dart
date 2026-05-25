import 'package:flutter/material.dart';

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
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('ຍົກເລີກ')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('ລ້າງ')),
        ],
      ),
    );
    if (ok == true) {
      await OfflineOutbox.instance.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final outbox = OfflineOutbox.instance;
    final items = outbox.items;
    return Scaffold(
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
            color: items.isEmpty
                ? Colors.green.withValues(alpha: 0.08)
                : Colors.orange.withValues(alpha: 0.10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      items.isEmpty ? Icons.check_circle : Icons.cloud_off,
                      color: items.isEmpty ? Colors.green : Colors.orange,
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
                    style: const TextStyle(color: Colors.red, fontSize: 12),
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
                    child: Text('ບໍ່ມີຂໍ້ມູນ', style: TextStyle(color: Colors.grey)),
                  )
                : ListView.separated(
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final a = items[i];
                      return ListTile(
                        leading: const Icon(Icons.cloud_upload_outlined),
                        title: Text(a.path, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
                        subtitle: Text(
                          'ສ້າງ ${a.createdAt} · retry ${a.retries}',
                          style: const TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                        dense: true,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
