/// GET /sessions/:id — full detail for the session-actions screen (extend/pause/end/etc).
library;
import 'dashboard.dart';

class SessionEvent {
  final String eventType;
  final String? fromStatus;
  final String? toStatus;
  final DateTime occurredAt;
  final Map<String, dynamic> metadata;
  final String? actorName;
  final String? deviceName;
  SessionEvent({required this.eventType, required this.fromStatus, required this.toStatus, required this.occurredAt, required this.metadata, required this.actorName, required this.deviceName});
  factory SessionEvent.fromJson(Map<String, dynamic> j) => SessionEvent(
        eventType: (j['eventType'] as String?) ?? '',
        fromStatus: j['fromStatus'] as String?,
        toStatus: j['toStatus'] as String?,
        occurredAt: DateTime.tryParse((j['occurredAt'] as String?) ?? '') ?? DateTime.now(),
        metadata: (j['metadata'] as Map<String, dynamic>?) ?? const {},
        actorName: j['actorName'] as String?,
        deviceName: j['deviceName'] as String?,
      );
}

class SessionExtension {
  final int addedSeconds;
  final DateTime? newEndAt;
  final int priceMinor;
  final String? reason;
  SessionExtension({required this.addedSeconds, required this.newEndAt, required this.priceMinor, required this.reason});
  factory SessionExtension.fromJson(Map<String, dynamic> j) => SessionExtension(
        addedSeconds: (j['addedSeconds'] as int?) ?? 0,
        newEndAt: j['newEndAt'] == null ? null : DateTime.tryParse(j['newEndAt'] as String),
        priceMinor: (j['priceMinor'] as int?) ?? 0,
        reason: j['reason'] as String?,
      );
}

class EquipmentAssignmentRow {
  final String id;
  final String code;
  final DateTime? assignedAt;
  final DateTime? returnedAt;
  EquipmentAssignmentRow({required this.id, required this.code, required this.assignedAt, required this.returnedAt});
  factory EquipmentAssignmentRow.fromJson(Map<String, dynamic> j) => EquipmentAssignmentRow(
        id: j['id'] as String,
        code: (j['code'] as String?) ?? '',
        assignedAt: j['assignedAt'] == null ? null : DateTime.tryParse(j['assignedAt'] as String),
        returnedAt: j['returnedAt'] == null ? null : DateTime.tryParse(j['returnedAt'] as String),
      );
}

class SessionDetail {
  final LiveSession session;
  final String status;
  final String customerId;
  final String visitId;
  final int? remainingSeconds;
  final int paidMinor;
  final int pendingMinor;
  final int dueMinor;
  final int priceMinor;
  final int discountMinor;
  final String? shoeClaimId;
  final String? shoeClaimNumber;
  final List<SessionEvent> events;
  final List<SessionExtension> extensions;
  final List<EquipmentAssignmentRow> equipmentAssignments;

  SessionDetail({
    required this.session, required this.status, required this.customerId, required this.visitId,
    required this.remainingSeconds, required this.paidMinor, required this.pendingMinor, required this.dueMinor,
    required this.priceMinor, required this.discountMinor, required this.shoeClaimId, required this.shoeClaimNumber,
    required this.events, required this.extensions, required this.equipmentAssignments,
  });

  factory SessionDetail.fromJson(Map<String, dynamic> j) {
    final s = j['session'] as Map<String, dynamic>;
    return SessionDetail(
      session: LiveSession.fromJson(s),
      status: s['status'] as String,
      customerId: (s['customerId'] as String?) ?? '',
      visitId: (s['visitId'] as String?) ?? '',
      remainingSeconds: s['remainingSeconds'] as int?,
      paidMinor: (s['paidMinor'] as int?) ?? 0,
      pendingMinor: (s['pendingMinor'] as int?) ?? 0,
      dueMinor: (s['dueMinor'] as int?) ?? 0,
      priceMinor: (s['priceMinor'] as int?) ?? 0,
      discountMinor: (s['discountMinor'] as int?) ?? 0,
      shoeClaimId: s['shoeClaimId'] as String?,
      shoeClaimNumber: s['shoeClaimNumber'] as String?,
      events: ((j['events'] as List?) ?? const []).map((e) => SessionEvent.fromJson(e as Map<String, dynamic>)).toList(),
      extensions: ((j['extensions'] as List?) ?? const []).map((e) => SessionExtension.fromJson(e as Map<String, dynamic>)).toList(),
      equipmentAssignments: ((j['equipmentAssignments'] as List?) ?? const []).map((e) => EquipmentAssignmentRow.fromJson(e as Map<String, dynamic>)).toList(),
    );
  }
}

const sessionEventLabel = <String, String>{
  'SESSION_CREATED': 'Session created',
  'PAYMENT_REQUESTED': 'Payment requested',
  'PAYMENT_CONFIRMED': 'Payment confirmed',
  'CHECKED_IN': 'Checked in',
  'SESSION_STARTED': 'Session started',
  'SESSION_PAUSED': 'Paused',
  'SESSION_RESUMED': 'Resumed',
  'SESSION_EXTENDED': 'Extended',
  'SESSION_EXPIRING': 'Entered final stretch',
  'SESSION_EXPIRED': 'Time ran out',
  'SESSION_ENDED': 'Session ended',
  'SESSION_CANCELLED': 'Cancelled',
  'SESSION_NO_SHOW': 'Marked as no-show',
  'SESSION_CORRECTED': 'Corrected by manager',
  'SESSION_REOPENED': 'Reopened by manager',
  'VISIT_COMPLETED': 'Visit completed',
};
