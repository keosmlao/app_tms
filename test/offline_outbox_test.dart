import 'package:flutter_test/flutter_test.dart';
import 'package:odgtms/src/services/offline_outbox.dart';
import 'package:shared_preferences/shared_preferences.dart';

// OfflineOutbox is a singleton — these tests verify the persistence boundary
// (enqueue → SharedPreferences → restart → reload). The actual HTTP send is
// covered indirectly: with no baseUrl set, flush is a no-op.

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await OfflineOutbox.instance.clear();
  });

  test('starts empty', () {
    expect(OfflineOutbox.instance.pendingCount, 0);
  });

  test('enqueue persists to SharedPreferences', () async {
    await OfflineOutbox.instance.enqueue(
      path: '/api/mobile/jobs',
      body: {'action': 'receive', 'doc_no': 'D1'},
    );
    expect(OfflineOutbox.instance.pendingCount, 1);

    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('tms_outbox_v1');
    expect(raw, isNotNull);
    expect(raw, contains('"path":"/api/mobile/jobs"'));
    expect(raw, contains('"action":"receive"'));
  });

  test('clear empties the queue and persists', () async {
    await OfflineOutbox.instance.enqueue(
      path: '/api/mobile/jobs',
      body: {'action': 'receive', 'doc_no': 'D1'},
    );
    await OfflineOutbox.instance.clear();
    expect(OfflineOutbox.instance.pendingCount, 0);
  });

  test('flush is a no-op when baseUrl is unset', () async {
    OfflineOutbox.instance.setBaseUrl(null);
    await OfflineOutbox.instance.enqueue(
      path: '/api/mobile/jobs',
      body: {'action': 'receive', 'doc_no': 'D1'},
    );
    await OfflineOutbox.instance.flush();
    expect(OfflineOutbox.instance.pendingCount, 1);
  });

  test('OutboxAction.toJson is structurally stable', () {
    final action = OutboxAction(
      id: 'abc',
      path: '/api/mobile/jobs',
      body: const {'action': 'receive', 'doc_no': 'D1'},
      createdAt: '2026-05-05T10:00:00.000',
      retries: 2,
    );
    final json = action.toJson();
    expect(json['id'], 'abc');
    expect(json['path'], '/api/mobile/jobs');
    expect(json['retries'], 2);
    expect(json['body'], isA<Map>());

    final back = OutboxAction.fromJson(json);
    expect(back.id, 'abc');
    expect(back.retries, 2);
    expect(back.body['action'], 'receive');
  });
}
