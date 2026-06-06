import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../core/app_theme.dart';
import '../models/chat_models.dart';

/// 1:1 chat thread with an office user / dispatcher. Polls for new messages
/// while open.
class ChatConversationScreen extends StatefulWidget {
  const ChatConversationScreen({
    super.key,
    required this.controller,
    required this.person,
  });

  final AppController controller;
  final ChatPerson person;

  @override
  State<ChatConversationScreen> createState() => _ChatConversationScreenState();
}

class _ChatConversationScreenState extends State<ChatConversationScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  List<ChatMessage> _messages = const [];
  String _me = '';
  bool _loading = true;
  bool _sending = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 4), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    try {
      final r = await widget.controller.api.getChatMessages(
        widget.person.recordId,
      );
      if (!mounted) return;
      final atBottom = !_scroll.hasClients ||
          _scroll.position.pixels >= _scroll.position.maxScrollExtent - 80;
      setState(() {
        _messages = r.messages;
        _me = r.me;
        _loading = false;
      });
      if (atBottom) _jumpToBottom();
    } catch (_) {
      if (mounted && !silent) setState(() => _loading = false);
    }
  }

  void _jumpToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return;
    HapticFeedback.selectionClick();
    setState(() => _sending = true);
    _input.clear();
    try {
      await widget.controller.api.sendChatMessage(widget.person.recordId, text);
      await _load(silent: true);
    } catch (e) {
      if (mounted) {
        _input.text = text;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('ສົ່ງບໍ່ໄດ້: $e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Server returns newest-first; show oldest-first (chat order).
    final ordered = _messages.reversed.toList();
    return Scaffold(
      backgroundColor: AppTheme.bgDark,
      appBar: AppBar(
        backgroundColor: AppTheme.bgDark,
        foregroundColor: AppTheme.textBright,
        elevation: 0,
        titleSpacing: 0,
        title: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: AppTheme.primary.withValues(alpha: 0.2),
              child: Text(
                widget.person.name.isNotEmpty ? widget.person.name[0] : '?',
                style: const TextStyle(
                  color: AppTheme.primary,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.person.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    widget.person.online ? 'ອອນລາຍ' : 'ອອບລາຍ',
                    style: TextStyle(
                      fontSize: 11,
                      color: widget.person.online
                          ? AppTheme.success
                          : AppTheme.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(color: AppTheme.primary),
                  )
                : ordered.isEmpty
                ? const Center(
                    child: Text(
                      'ຍັງບໍ່ມີຂໍ້ຄວາມ — ເລີ່ມສົນທະນາ',
                      style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
                    ),
                  )
                : ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.all(12),
                    itemCount: ordered.length,
                    itemBuilder: (_, i) => _bubble(ordered[i]),
                  ),
          ),
          _composer(),
        ],
      ),
    );
  }

  Widget _bubble(ChatMessage m) {
    final mine = m.authorCode.isNotEmpty && m.authorCode == _me;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.76,
        ),
        decoration: BoxDecoration(
          color: mine ? AppTheme.primary : AppTheme.bgSurface,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              m.body,
              style: TextStyle(
                color: mine ? Colors.white : AppTheme.textBright,
                fontSize: 13.5,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              m.createdAtDisplay,
              style: TextStyle(
                color: mine ? Colors.white70 : AppTheme.textMuted,
                fontSize: 9,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _composer() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _input,
                style: const TextStyle(color: AppTheme.textBright, fontSize: 14),
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                decoration: InputDecoration(
                  hintText: 'ພິມຂໍ້ຄວາມ...',
                  hintStyle: const TextStyle(color: AppTheme.textDim),
                  filled: true,
                  fillColor: AppTheme.bgSurface,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Material(
              color: AppTheme.primary,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _sending ? null : _send,
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: _sending
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.send_rounded, color: Colors.white, size: 20),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
