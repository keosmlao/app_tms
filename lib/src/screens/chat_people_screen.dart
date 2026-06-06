import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../core/app_theme.dart';
import '../models/chat_models.dart';
import 'chat_conversation_screen.dart';

/// People you can chat with (office / dispatchers), with unread, online, and
/// offline groups — tap to open the 1:1 thread.
class ChatPeopleScreen extends StatefulWidget {
  const ChatPeopleScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<ChatPeopleScreen> createState() => _ChatPeopleScreenState();
}

class _ChatPeopleScreenState extends State<ChatPeopleScreen> {
  List<ChatPerson> _people = const [];
  bool _loading = true;
  String _q = '';
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _load(silent: true),
    );
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    try {
      final data = await widget.controller.api.getChatPeople();
      if (!mounted) return;
      setState(() {
        _people = data;
        _loading = false;
      });
    } catch (_) {
      if (mounted && !silent) setState(() => _loading = false);
    }
  }

  Future<void> _open(ChatPerson p) async {
    HapticFeedback.selectionClick();
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            ChatConversationScreen(controller: widget.controller, person: p),
      ),
    );
    if (mounted) _load(silent: true); // refresh unread after reading
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final filtered = q.isEmpty
        ? _people
        : _people
              .where((p) =>
                  p.name.toLowerCase().contains(q) ||
                  p.title.toLowerCase().contains(q))
              .toList();
    final unread = filtered.where((p) => p.unread > 0).toList();
    final read = filtered.where((p) => p.unread == 0).toList();
    final online = read.where((p) => p.online).toList();
    final offline = read.where((p) => !p.online).toList();

    return Scaffold(
      backgroundColor: AppTheme.bgDark,
      appBar: AppBar(
        backgroundColor: AppTheme.bgDark,
        foregroundColor: AppTheme.textBright,
        elevation: 0,
        title: const Text(
          'ຂໍ້ຄວາມ',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: TextField(
              onChanged: (v) => setState(() => _q = v),
              style: const TextStyle(color: AppTheme.textBright, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'ຄົ້ນຫາຄົນ...',
                hintStyle: const TextStyle(color: AppTheme.textDim),
                prefixIcon: const Icon(Icons.search_rounded, color: AppTheme.textMuted),
                filled: true,
                fillColor: AppTheme.bgSurface,
                contentPadding: const EdgeInsets.symmetric(vertical: 4),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(color: AppTheme.primary),
                  )
                : filtered.isEmpty
                ? const Center(
                    child: Text(
                      'ບໍ່ພົບຄົນ',
                      style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
                    ),
                  )
                : RefreshIndicator(
                    color: AppTheme.primary,
                    onRefresh: () => _load(silent: true),
                    child: ListView(
                      children: [
                        if (unread.isNotEmpty) ...[
                          _header('✉ ຍັງບໍ່ໄດ້ອ່ານ ${unread.length}', AppTheme.error),
                          ...unread.map(_row),
                        ],
                        if (online.isNotEmpty) ...[
                          _header('● ອອນລາຍ ${online.length}', AppTheme.success),
                          ...online.map(_row),
                        ],
                        if (offline.isNotEmpty) ...[
                          _header('○ ອອບລາຍ ${offline.length}', AppTheme.textMuted),
                          ...offline.map(_row),
                        ],
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _header(String label, Color color) => Container(
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
    child: Text(
      label,
      style: TextStyle(
        color: color,
        fontSize: 11,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.5,
      ),
    ),
  );

  Widget _row(ChatPerson p) => InkWell(
    onTap: () => _open(p),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: Row(
        children: [
          Stack(
            children: [
              CircleAvatar(
                radius: 21,
                backgroundColor: AppTheme.primary.withValues(alpha: 0.18),
                child: Text(
                  p.name.isNotEmpty ? p.name[0] : '?',
                  style: const TextStyle(
                    color: AppTheme.primary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  width: 11,
                  height: 11,
                  decoration: BoxDecoration(
                    color: p.online ? AppTheme.success : AppTheme.textMuted,
                    shape: BoxShape.circle,
                    border: Border.all(color: AppTheme.bgDark, width: 2),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.name + (p.title.isNotEmpty ? ' · ${p.title}' : ''),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.textBright,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  p.lastBody.isNotEmpty
                      ? p.lastBody
                      : (p.online
                            ? 'ອອນລາຍ'
                            : (p.lastSeen.isNotEmpty
                                  ? 'ເຂົ້າລ່າສຸດ ${p.lastSeen}'
                                  : 'ກົດເພື່ອລົມ')),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
                ),
              ],
            ),
          ),
          if (p.unread > 0)
            Container(
              margin: const EdgeInsets.only(left: 8),
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: AppTheme.error,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${p.unread}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
