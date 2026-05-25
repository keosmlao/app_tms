class AuthUser {
  const AuthUser({
    required this.username,
    required this.code,
    required this.displayName,
    required this.department,
    required this.roles,
    required this.driverId,
    required this.token,
  });

  final String username;
  final String code;
  final String displayName;
  final String department;
  final String roles;
  final String driverId;
  final String token;

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
    );
  }

  factory AuthUser.fromStoredJson(Map<String, dynamic> json) {
    return AuthUser(
      username: (json['username'] ?? '').toString(),
      code: (json['code'] ?? '').toString(),
      displayName: (json['displayName'] ?? '').toString(),
      department: (json['department'] ?? '').toString(),
      roles: (json['roles'] ?? '').toString(),
      driverId: (json['driverId'] ?? '').toString(),
      token: (json['token'] ?? '').toString(),
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
  }) {
    return AuthUser(
      username: username ?? this.username,
      code: code ?? this.code,
      displayName: displayName ?? this.displayName,
      department: department ?? this.department,
      roles: roles ?? this.roles,
      driverId: driverId ?? this.driverId,
      token: token ?? this.token,
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
    };
  }
}
