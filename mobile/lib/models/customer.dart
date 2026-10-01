/// Models for /customers* endpoints. Field names match backend/src/modules/customers.ts responses.
library;

class EmergencyContact {
  final String? id;
  final String name;
  final String phone;
  final String? relationship;
  final bool isGuardian;
  EmergencyContact({this.id, required this.name, required this.phone, this.relationship, this.isGuardian = false});
  factory EmergencyContact.fromJson(Map<String, dynamic> j) => EmergencyContact(
        id: j['id'] as String?,
        name: (j['name'] as String?) ?? '',
        phone: (j['phone'] as String?) ?? '',
        relationship: j['relationship'] as String?,
        isGuardian: (j['isGuardian'] as bool?) ?? false,
      );
  Map<String, dynamic> toJson() => {'name': name, 'phone': phone, 'relationship': relationship, 'isGuardian': isGuardian};
}

/// A row from search/list results — lighter than the full profile.
class CustomerSummary {
  final String id;
  final String customerCode;
  final String fullName;
  final String phoneE164;
  final String? status;
  final DateTime? lastVisitAt;
  final int visitCount;
  final String? photoId;

  CustomerSummary({
    required this.id, required this.customerCode, required this.fullName, required this.phoneE164,
    required this.status, required this.lastVisitAt, required this.visitCount, required this.photoId,
  });

  factory CustomerSummary.fromJson(Map<String, dynamic> j) => CustomerSummary(
        id: j['id'] as String,
        customerCode: (j['customerCode'] as String?) ?? '',
        fullName: j['fullName'] as String,
        phoneE164: (j['phoneE164'] as String?) ?? '',
        status: j['status'] as String?,
        lastVisitAt: j['lastVisitAt'] == null ? null : DateTime.tryParse(j['lastVisitAt'] as String),
        visitCount: (j['visitCount'] as int?) ?? 0,
        photoId: j['photoId'] as String?,
      );
}

class CustomerStats {
  final int visitCount;
  final DateTime? lastVisitAt;
  final int totalSkatingSeconds;
  final int totalSpentMinor;
  final int equipmentIssuedCount;
  CustomerStats({required this.visitCount, required this.lastVisitAt, required this.totalSkatingSeconds, required this.totalSpentMinor, required this.equipmentIssuedCount});
  factory CustomerStats.fromJson(Map<String, dynamic> j) => CustomerStats(
        visitCount: (j['visitCount'] as int?) ?? 0,
        lastVisitAt: j['lastVisitAt'] == null ? null : DateTime.tryParse(j['lastVisitAt'] as String),
        totalSkatingSeconds: (j['totalSkatingSeconds'] as int?) ?? 0,
        totalSpentMinor: (j['totalSpentMinor'] as int?) ?? 0,
        equipmentIssuedCount: (j['equipmentIssuedCount'] as int?) ?? 0,
      );
}

class CustomerWaiverStatus {
  final bool required;
  final String? currentVersionId;
  final int? currentVersion;
  final bool isMinor;
  final bool accepted;
  final DateTime? acceptedAt;
  CustomerWaiverStatus({required this.required, required this.currentVersionId, required this.currentVersion, required this.isMinor, required this.accepted, required this.acceptedAt});
  factory CustomerWaiverStatus.fromJson(Map<String, dynamic> j) => CustomerWaiverStatus(
        required: (j['required'] as bool?) ?? true,
        currentVersionId: j['currentVersionId'] as String?,
        currentVersion: j['currentVersion'] as int?,
        isMinor: (j['isMinor'] as bool?) ?? false,
        accepted: (j['accepted'] as bool?) ?? false,
        acceptedAt: j['acceptedAt'] == null ? null : DateTime.tryParse(j['acceptedAt'] as String),
      );
}

class CustomerCurrentSession {
  final String id;
  final String status;
  final DateTime? startedAt;
  final DateTime? scheduledEndAt;
  CustomerCurrentSession({required this.id, required this.status, required this.startedAt, required this.scheduledEndAt});
  factory CustomerCurrentSession.fromJson(Map<String, dynamic> j) => CustomerCurrentSession(
        id: j['id'] as String,
        status: j['status'] as String,
        startedAt: j['startedAt'] == null ? null : DateTime.tryParse(j['startedAt'] as String),
        scheduledEndAt: j['scheduledEndAt'] == null ? null : DateTime.tryParse(j['scheduledEndAt'] as String),
      );
}

class CustomerProfile {
  final String id;
  final int customerNo;
  final String fullName;
  final String phoneE164;
  final String? email;
  final DateTime? dateOfBirth;
  final String? notes;
  final String status;
  final DateTime registeredAt;
  final String customerCode;
  final bool isMinor;
  final String? photoId;
  final List<EmergencyContact> emergencyContacts;
  final CustomerStats stats;
  final CustomerWaiverStatus waiver;
  final CustomerCurrentSession? currentSession;

  CustomerProfile({
    required this.id, required this.customerNo, required this.fullName, required this.phoneE164,
    required this.email, required this.dateOfBirth, required this.notes, required this.status,
    required this.registeredAt, required this.customerCode, required this.isMinor, required this.photoId,
    required this.emergencyContacts, required this.stats, required this.waiver, required this.currentSession,
  });

  factory CustomerProfile.fromJson(Map<String, dynamic> j) => CustomerProfile(
        id: j['id'] as String,
        customerNo: (j['customerNo'] as int?) ?? 0,
        fullName: j['fullName'] as String,
        phoneE164: (j['phoneE164'] as String?) ?? '',
        email: j['email'] as String?,
        dateOfBirth: j['dateOfBirth'] == null ? null : DateTime.tryParse(j['dateOfBirth'] as String),
        notes: j['notes'] as String?,
        status: (j['status'] as String?) ?? 'ACTIVE',
        registeredAt: DateTime.tryParse((j['registeredAt'] as String?) ?? '') ?? DateTime.now(),
        customerCode: (j['customerCode'] as String?) ?? '',
        isMinor: (j['isMinor'] as bool?) ?? false,
        photoId: j['photoId'] as String?,
        emergencyContacts: ((j['emergencyContacts'] as List?) ?? const [])
            .map((e) => EmergencyContact.fromJson(e as Map<String, dynamic>))
            .toList(),
        stats: CustomerStats.fromJson((j['stats'] as Map<String, dynamic>?) ?? const {}),
        waiver: CustomerWaiverStatus.fromJson((j['waiver'] as Map<String, dynamic>?) ?? const {}),
        currentSession: j['currentSession'] == null ? null : CustomerCurrentSession.fromJson(j['currentSession'] as Map<String, dynamic>),
      );
}

class CustomerHistoryEntry {
  final String visitId;
  final int visitNumber;
  final String localDate;
  final String visitStatus;
  final DateTime createdAt;
  final String? sessionId;
  final String? sessionStatus;
  final String? productName;
  final DateTime? startedAt;
  final DateTime? scheduledEndAt;
  final DateTime? actualEndAt;
  final int? currentDurationSeconds;
  final int? paidMinor;
  final String? equipment;

  CustomerHistoryEntry({
    required this.visitId, required this.visitNumber, required this.localDate, required this.visitStatus,
    required this.createdAt, required this.sessionId, required this.sessionStatus, required this.productName,
    required this.startedAt, required this.scheduledEndAt, required this.actualEndAt,
    required this.currentDurationSeconds, required this.paidMinor, required this.equipment,
  });

  factory CustomerHistoryEntry.fromJson(Map<String, dynamic> j) => CustomerHistoryEntry(
        visitId: j['visitId'] as String,
        visitNumber: (j['visitNumber'] as int?) ?? 0,
        localDate: (j['localDate'] as String?) ?? '',
        visitStatus: (j['visitStatus'] as String?) ?? '',
        createdAt: DateTime.tryParse((j['createdAt'] as String?) ?? '') ?? DateTime.now(),
        sessionId: j['sessionId'] as String?,
        sessionStatus: j['sessionStatus'] as String?,
        productName: j['productName'] as String?,
        startedAt: j['startedAt'] == null ? null : DateTime.tryParse(j['startedAt'] as String),
        scheduledEndAt: j['scheduledEndAt'] == null ? null : DateTime.tryParse(j['scheduledEndAt'] as String),
        actualEndAt: j['actualEndAt'] == null ? null : DateTime.tryParse(j['actualEndAt'] as String),
        currentDurationSeconds: j['currentDurationSeconds'] as int?,
        paidMinor: j['paidMinor'] as int?,
        equipment: j['equipment'] as String?,
      );
}
