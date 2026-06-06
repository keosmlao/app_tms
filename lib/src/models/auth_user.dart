class AuthUser {
  const AuthUser({
    required this.username,
    required this.code,
    required this.displayName,
    required this.department,
    required this.roles,
    required this.driverId,
    required this.token,
    required this.isDriver,
  });

  final String username;
  final String code;
  final String displayName;
  final String department;
  final String roles;
  final String driverId;
  final String token;

  // Server-resolved: true = driver, false = operations staff. Non-drivers use
  // the operations dashboard; their role text distinguishes supervisor/manager.
  final bool isDriver;

  bool get isManager {
    if (isDriver) return false;
    final text = roles.toLowerCase();
    return text.contains('manager') ||
        text.contains('admin') ||
        text.contains('director') ||
        text.contains('executive') ||
        text.contains('ຜູ້ຈັດການ');
  }

  bool get isTeamSupervisor => !isDriver && !isManager;

  /// Backwards-compatible operations-dashboard gate.
  bool get isSupervisor => !isDriver;
  bool get isOperationsUser => !isDriver;
  bool get isDriverOnly => isDriver;

  String get roleLabel {
    if (isDriver) return 'ຄົນຂັບ';
    if (isManager) return 'ຜູ້ຈັດການ';
    return 'ຫົວໜ້າ';
  }

  String get modeTitle {
    if (isDriver) return 'Driver Mode';
    if (isManager) return 'Manager Mode';
    return 'Supervisor Mode';
  }

  bool get canApproveJobs => isOperationsUser;

  // Legacy fallback for sessions/responses without an explicit is_driver flag:
  // a user is a driver unless their roles say they're office staff.
  static bool driverFromRoles(String roles) {
    return !hasOperationsRole(roles);
  }

  static bool hasOperationsRole(String roles) {
    final text = roles.toLowerCase();
    return text.contains('supervisor') ||
        text.contains('head') ||
        text.contains('team_lead') ||
        text.contains('manager') ||
        text.contains('admin') ||
        text.contains('director') ||
        text.contains('executive') ||
        text.contains('transport_head') ||
        text.contains('ຫົວໜ້າ') ||
        text.contains('ຜູ້ຈັດການ');
  }

  static bool resolveIsDriver({required String roles, required bool? flag}) {
    // Explicit office/management roles always win. Some legacy backends mark
    // every employee in the transport department as a driver.
    if (hasOperationsRole(roles)) return false;
    return flag ?? driverFromRoles(roles);
  }

  factory AuthUser.fromJson(
    Map<String, dynamic> json, {
    required String fallbackUsername,
  }) {
    final username = (json['username'] ?? json['code'] ?? fallbackUsername)
        .toString();
    final code = (json['code'] ?? json['username'] ?? '').toString();
    final driverId = (json['driver_id'] ?? '').toString();

    return AuthUser(
      username: username,
      code: code,
      displayName:
          (json['name_1'] ??
                  json['displayName'] ??
                  json['username'] ??
                  fallbackUsername)
              .toString(),
      department: (json['department'] ?? '').toString(),
      roles: (json['roles'] ?? '').toString(),
      driverId: driverId.isNotEmpty
          ? driverId
          : (code.isNotEmpty ? code : username),
      token: (json['token'] ?? '').toString(),
      isDriver: resolveIsDriver(
        roles: (json['roles'] ?? json['title'] ?? '').toString(),
        flag: json.containsKey('is_driver') ? json['is_driver'] == true : null,
      ),
    );
  }

  factory AuthUser.fromStoredJson(Map<String, dynamic> json) {
    final roles = (json['roles'] ?? '').toString();
    return AuthUser(
      username: (json['username'] ?? '').toString(),
      code: (json['code'] ?? '').toString(),
      displayName: (json['displayName'] ?? '').toString(),
      department: (json['department'] ?? '').toString(),
      roles: roles,
      driverId: (json['driverId'] ?? '').toString(),
      token: (json['token'] ?? '').toString(),
      isDriver: resolveIsDriver(
        roles: roles,
        flag: json.containsKey('isDriver') ? json['isDriver'] == true : null,
      ),
    );
  }

  AuthUser copyWith({
    String? username,
    String? code,
    String? displayName,
    String? department,
    String? roles,
    String? driverId,
    String? token,
    bool? isDriver,
  }) {
    return AuthUser(
      username: username ?? this.username,
      code: code ?? this.code,
      displayName: displayName ?? this.displayName,
      department: department ?? this.department,
      roles: roles ?? this.roles,
      driverId: driverId ?? this.driverId,
      token: token ?? this.token,
      isDriver: isDriver ?? this.isDriver,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'username': username,
      'code': code,
      'displayName': displayName,
      'department': department,
      'roles': roles,
      'driverId': driverId,
      'token': token,
      'isDriver': isDriver,
    };
  }
}
