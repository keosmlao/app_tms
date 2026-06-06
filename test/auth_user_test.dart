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
      final user = AuthUser.fromJson(const {
        'username': 'u1',
        'code': 'C1',
        'name_1': 'Alice Driver',
        'driver_id': 'D1',
        'token': 't',
      }, fallbackUsername: 'fallback');
      expect(user.displayName, 'Alice Driver');
      expect(user.driverId, 'D1');
      expect(user.token, 't');
    });

    test('falls back to code for driverId when driver_id is empty', () {
      final user = AuthUser.fromJson(const {
        'username': 'u1',
        'code': 'C1',
        'driver_id': '',
      }, fallbackUsername: 'fallback');
      expect(user.driverId, 'C1');
    });

    test('falls back to username when code and driver_id are empty', () {
      final user = AuthUser.fromJson(const {
        'username': 'u1',
      }, fallbackUsername: 'fallback');
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
        isDriver: true,
      );
      final restored = AuthUser.fromStoredJson(original.toJson());
      expect(restored.username, original.username);
      expect(restored.code, original.code);
      expect(restored.displayName, original.displayName);
      expect(restored.department, original.department);
      expect(restored.roles, original.roles);
      expect(restored.driverId, original.driverId);
      expect(restored.token, original.token);
      expect(restored.isDriver, original.isDriver);
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
        isDriver: true,
      );
      final copy = original.copyWith(token: 'new-token');
      expect(copy.token, 'new-token');
      expect(copy.username, 'u1');
      expect(copy.driverId, 'D1');
      expect(copy.isDriver, isTrue);
    });
  });

  group('AuthUser supervisor routing', () {
    test('non-driver (is_driver:false) is treated as supervisor', () {
      final user = AuthUser.fromJson(const {
        'username': 'boss',
        'code': 'M1',
        'is_driver': false,
      }, fallbackUsername: 'boss');
      expect(user.isSupervisor, isTrue);
      expect(user.isDriverOnly, isFalse);
    });

    test('driver (is_driver:true) stays in driver mode', () {
      final user = AuthUser.fromJson(const {
        'username': 'd',
        'code': 'D1',
        'is_driver': true,
      }, fallbackUsername: 'd');
      expect(user.isSupervisor, isFalse);
      expect(user.isDriverOnly, isTrue);
    });

    test('legacy: no flag + office role → supervisor', () {
      final user = AuthUser.fromJson(const {
        'username': 'm',
        'code': 'M2',
        'roles': 'manager',
      }, fallbackUsername: 'm');
      expect(user.isSupervisor, isTrue);
      expect(user.isManager, isTrue);
      expect(user.roleLabel, 'ຜູ້ຈັດການ');
    });

    test('legacy: no flag + plain driver role → driver', () {
      final user = AuthUser.fromJson(const {
        'username': 'd',
        'code': 'D2',
        'roles': 'driver',
      }, fallbackUsername: 'd');
      expect(user.isSupervisor, isFalse);
      expect(user.roleLabel, 'ຄົນຂັບ');
    });

    test('supervisor and manager are distinct operations roles', () {
      final supervisor = AuthUser.fromJson(const {
        'username': 'head',
        'roles': 'transport_head',
        'is_driver': false,
      }, fallbackUsername: 'head');
      final manager = AuthUser.fromJson(const {
        'username': 'manager',
        'roles': 'transport_manager',
        'is_driver': false,
      }, fallbackUsername: 'manager');

      expect(supervisor.isOperationsUser, isTrue);
      expect(supervisor.isTeamSupervisor, isTrue);
      expect(supervisor.isManager, isFalse);
      expect(supervisor.roleLabel, 'ຫົວໜ້າ');
      expect(manager.isOperationsUser, isTrue);
      expect(manager.isTeamSupervisor, isFalse);
      expect(manager.isManager, isTrue);
      expect(manager.roleLabel, 'ຜູ້ຈັດການ');
    });

    test('office role overrides incorrect is_driver true flag', () {
      final user = AuthUser.fromJson(const {
        'username': 'boss',
        'roles': 'transport_manager',
        'is_driver': true,
      }, fallbackUsername: 'boss');

      expect(user.isDriver, isFalse);
      expect(user.isManager, isTrue);
      expect(user.isOperationsUser, isTrue);
    });

    test('Lao management title routes to operations dashboard', () {
      final user = AuthUser.fromJson(const {
        'username': 'head',
        'title': 'ຫົວໜ້າຂົນສົ່ງ',
        'is_driver': true,
      }, fallbackUsername: 'head');

      expect(user.isDriver, isFalse);
      expect(user.isTeamSupervisor, isTrue);
    });

    test('team_lead worker profile routes to supervisor dashboard', () {
      final user = AuthUser.fromJson(const {
        'username': '7001',
        'roles': 'team_lead',
        'is_driver': false,
      }, fallbackUsername: '7001');

      expect(user.isDriver, isFalse);
      expect(user.isTeamSupervisor, isTrue);
      expect(user.modeTitle, 'Supervisor Mode');
    });
  });
}
