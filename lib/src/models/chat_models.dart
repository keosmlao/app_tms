/// A person the driver can DM (from the server's listDmPeople).
class ChatPerson {
  const ChatPerson({
    required this.code,
    required this.name,
    required this.title,
    required this.recordId,
    required this.online,
    required this.lastSeen,
    required this.lastBody,
    required this.unread,
  });

  final String code;
  final String name;
  final String title;
  final String recordId; // dm:<a>|<b>
  final bool online;
  final String lastSeen;
  final String lastBody;
  final int unread;

  factory ChatPerson.fromJson(Map<String, dynamic> j) {
    String s(String k) => (j[k] ?? '').toString();
    return ChatPerson(
      code: s('code'),
      name: s('name').isEmpty ? s('code') : s('name'),
      title: s('title'),
      recordId: s('record_id'),
      online: j['online'] == true,
      lastSeen: s('last_seen'),
      lastBody: s('last_body'),
      unread: int.tryParse('${j['unread'] ?? 0}') ?? 0,
    );
  }
}

/// One chat message in a DM thread.
class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.body,
    required this.authorCode,
    required this.authorName,
    required this.createdAtDisplay,
    required this.msgType,
  });

  final String id;
  final String body;
  final String authorCode;
  final String authorName;
  final String createdAtDisplay;
  final String msgType;

  factory ChatMessage.fromJson(Map<String, dynamic> j) {
    String s(String k) => (j[k] ?? '').toString();
    return ChatMessage(
      id: s('id'),
      body: s('body'),
      authorCode: s('author_code'),
      authorName: s('author_name'),
      createdAtDisplay: s('created_at_display'),
      msgType: s('msg_type'),
    );
  }
}
