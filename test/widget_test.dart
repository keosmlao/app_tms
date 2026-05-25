import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:odgtms/src/app_controller.dart';
import 'package:odgtms/src/models/auth_user.dart';
import 'package:odgtms/src/screens/login_screen.dart';
import 'package:odgtms/src/services/auth_storage.dart';

class FakeAuthStorage extends AuthStorage {
  StoredSession? _session;

  @override
  Future<StoredSession?> readSession() async => _session;

  @override
  Future<void> saveSession({
    required String baseUrl,
    required AuthUser user,
  }) async {
    _session = StoredSession(baseUrl: baseUrl, user: user);
  }

  @override
  Future<void> clear() async {
    _session = null;
  }
}

void main() {
  testWidgets('Login screen renders expected fields', (
    WidgetTester tester,
  ) async {
    final controller = AppController(storage: FakeAuthStorage());

    await tester.pumpWidget(
      MaterialApp(home: LoginScreen(controller: controller)),
    );

    expect(find.text('ເຂົ້າສູ່ລະບົບ'), findsWidgets);
    expect(find.byType(TextFormField), findsNWidgets(2));
    expect(find.text('ຈື່ຂ້ອຍໄວ້'), findsOneWidget);
    expect(find.textContaining('ODG TMS'), findsOneWidget);
    expect(find.text('ເລີ່ມພາລະກິດ'), findsOneWidget);
  });
}
