import 'package:flutter_test/flutter_test.dart';
import 'package:odgtms/src/models/auth_user.dart';

void main() {
  group('AuthUser.fromJson', () {
    test('uses fallback username when none provided', () {
      final user = AuthUser.fromJson(const {}, fallbackUsername: 'fallback');
      expect(user.username, 'fallback');
      expect(user.displayName, 'fallback');
    });

    test('prefers name_1 for displayName', () {
      final user = AuthUser.fromJson(
        const {
          'username': 'u1',
          'code': 'C1',
          'name_1': 'Alice Driver',
          'driver_id': 'D1',
          'token': 't',
        },
        fallbackUsername: 'fallback',
      );
      expect(user.displayName, 'Alice Driver');
      expect(user.driverId, 'D1');
      expect(user.token, 't');
    });

    test('falls back to code for driverId when driver_id is empty', () {
      final user = AuthUser.fromJson(
        const {'username': 'u1', 'code': 'C1', 'driver_id': ''},
        fallbackUsername: 'fallback',
      );
      expect(user.driverId, 'C1');
    });

    test('falls back to username when code and driver_id are empty', () {
      final user = AuthUser.fromJson(
        const {'username': 'u1'},
        fallbackUsername: 'fallback',
      );
      expect(user.driverId, 'u1');
    });
  });

  group('AuthUser roundtrip', () {
    test('toJson + fromStoredJson preserves all fields', () {
      const original = AuthUser(
        username: 'u1',
        code: 'C1',
        displayName: 'Alice',
        department: 'Logistics',
        roles: 'driver',
        driverId: 'D1',
        token: 'tk-123',
      );
      final restored = AuthUser.fromStoredJson(original.toJson());
      expect(restored.username, original.username);
      expect(restored.code, original.code);
      expect(restored.displayName, original.displayName);
      expect(restored.department, original.department);
      expect(restored.roles, original.roles);
      expect(restored.driverId, original.driverId);
      expect(restored.token, original.token);
    });
  });

  group('AuthUser.copyWith', () {
    test('overrides only the provided fields', () {
      const original = AuthUser(
        username: 'u1',
        code: 'C1',
        displayName: 'Alice',
        department: 'Logistics',
        roles: 'driver',
        driverId: 'D1',
        token: 'tk',
      );
      final copy = original.copyWith(token: 'new-token');
      expect(copy.token, 'new-token');
      expect(copy.username, 'u1');
      expect(copy.driverId, 'D1');
    });
  });
}
