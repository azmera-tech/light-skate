/// GET /auth/me. The permissions array is the single source of truth for what the UI shows —
/// never branch on `role` directly (backend/src/permissions.ts assigns a fixed permission set per
/// role, but the UI should stay correct even if those sets are ever tuned server-side).
library;

class Me {
  final String id;
  final String email;
  final String fullName;
  final String role;
  final Set<String> permissions;
  final String venueId;
  final String? deviceId;

  Me({
    required this.id,
    required this.email,
    required this.fullName,
    required this.role,
    required this.permissions,
    required this.venueId,
    required this.deviceId,
  });

  bool can(String perm) => permissions.contains(perm);
  bool canAny(List<String> perms) => perms.any(permissions.contains);

  factory Me.fromJson(Map<String, dynamic> j) => Me(
        id: j['id'] as String,
        email: j['email'] as String,
        fullName: j['fullName'] as String,
        role: j['role'] as String,
        permissions: ((j['permissions'] as List?) ?? const []).map((e) => e as String).toSet(),
        venueId: j['venueId'] as String,
        deviceId: j['deviceId'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'email': email,
        'fullName': fullName,
        'role': role,
        'permissions': permissions.toList(),
        'venueId': venueId,
        'deviceId': deviceId,
      };
}

/// Permission codes a management/admin area needs any of to be shown at all, mirroring
/// web/src/App.tsx's MANAGEMENT_PERMS.
const managementPerms = [
  'reports.read', 'staff.manage', 'settings.manage', 'pricing.manage',
  'capacity.manage', 'audit.read', 'device.manage', 'dayclose.manage', 'equipment.manage',
];
