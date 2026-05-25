import 'package:flutter_test/flutter_test.dart';
import 'package:odgtms/src/models/auth_user.dart';
import 'package:odgtms/src/services/auth_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('returns null when nothing is saved', () async {
    final storage = AuthStorage();
    expect(await storage.readSession(), isNull);
  });

  test('save then read returns the same baseUrl + user', () async {
    final storage = AuthStorage();
    const user = AuthUser(
      username: 'u1',
      code: 'C1',
      displayName: 'Alice',
      department: 'Logistics',
      roles: 'driver',
      driverId: 'D1',
      token: 'tk',
    );
    await storage.saveSession(baseUrl: 'https://api.example/', user: user);

    final session = await storage.readSession();
    expect(session, isNotNull);
    expect(session!.baseUrl, 'https://api.example/');
    expect(session.user.username, 'u1');
    expect(session.user.token, 'tk');
  });

  test('clear removes the session', () async {
    final storage = AuthStorage();
    const user = AuthUser(
      username: 'u1',
      code: 'C1',
      displayName: 'Alice',
      department: '',
      roles: '',
      driverId: 'D1',
      token: 'tk',
    );
    await storage.saveSession(baseUrl: 'http://x', user: user);

    await storage.clear();
    expect(await storage.readSession(), isNull);
  });
}
