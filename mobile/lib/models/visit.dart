/// GET /visits — the day's visit list, and a single visit's full timeline.
library;

class VisitRow {
  final String visitId;
  final int visitNumber;
  final String visitStatus;
  final DateTime createdAt;
  final String customerId;
  final String fullName;
  final String? phoneE164;
  final String? photoId;
  final String? sessionId;
  final String? sessionStatus;
  final String? productName;
  final DateTime? startedAt;
  final DateTime? scheduledEndAt;
  final DateTime? actualEndAt;
  final int? currentDurationSeconds;
  final int? paidMinor;
  final String? staffName;
  final String? equipment;
  final bool hasIncident;

  VisitRow({
    required this.visitId, required this.visitNumber, required this.visitStatus, required this.createdAt,
    required this.customerId, required this.fullName, required this.phoneE164, required this.photoId,
    required this.sessionId, required this.sessionStatus, required this.productName, required this.startedAt,
    required this.scheduledEndAt, required this.actualEndAt, required this.currentDurationSeconds,
    required this.paidMinor, required this.staffName, required this.equipment, required this.hasIncident,
  });

  factory VisitRow.fromJson(Map<String, dynamic> j) => VisitRow(
        visitId: j['visitId'] as String,
        visitNumber: (j['visitNumber'] as int?) ?? 0,
        visitStatus: (j['visitStatus'] as String?) ?? '',
        createdAt: DateTime.tryParse((j['createdAt'] as String?) ?? '') ?? DateTime.now(),
        customerId: j['customerId'] as String,
        fullName: (j['fullName'] as String?) ?? '',
        phoneE164: j['phoneE164'] as String?,
        photoId: j['photoId'] as String?,
        sessionId: j['sessionId'] as String?,
        sessionStatus: j['sessionStatus'] as String?,
        productName: j['productName'] as String?,
        startedAt: j['startedAt'] == null ? null : DateTime.tryParse(j['startedAt'] as String),
        scheduledEndAt: j['scheduledEndAt'] == null ? null : DateTime.tryParse(j['scheduledEndAt'] as String),
        actualEndAt: j['actualEndAt'] == null ? null : DateTime.tryParse(j['actualEndAt'] as String),
        currentDurationSeconds: j['currentDurationSeconds'] as int?,
        paidMinor: j['paidMinor'] as int?,
        staffName: j['staffName'] as String?,
        equipment: j['equipment'] as String?,
        hasIncident: (j['hasIncident'] as bool?) ?? false,
      );
}

class TimelineEntry {
  final String source;
  final String eventType;
  final DateTime occurredAt;
  final Map<String, dynamic> metadata;
  final String? actorName;
  final String? deviceName;
  TimelineEntry({required this.source, required this.eventType, required this.occurredAt, required this.metadata, required this.actorName, required this.deviceName});
  factory TimelineEntry.fromJson(Map<String, dynamic> j) => TimelineEntry(
        source: (j['source'] as String?) ?? '',
        eventType: (j['eventType'] as String?) ?? '',
        occurredAt: DateTime.tryParse((j['occurredAt'] as String?) ?? '') ?? DateTime.now(),
        metadata: (j['metadata'] as Map<String, dynamic>?) ?? const {},
        actorName: j['actorName'] as String?,
        deviceName: j['deviceName'] as String?,
      );
}

class VisitDetail {
  final Map<String, dynamic> visit;
  final List<PaymentLike> payments;
  final List<TimelineEntry> timeline;
  VisitDetail({required this.visit, required this.payments, required this.timeline});
}

/// Minimal shape used inside a visit's payment list.
class PaymentLike {
  final String id;
  final int amountMinor;
  final int refundedMinor;
  final String method;
  final String status;
  final String? purpose;
  PaymentLike({required this.id, required this.amountMinor, required this.refundedMinor, required this.method, required this.status, required this.purpose});
  factory PaymentLike.fromJson(Map<String, dynamic> j) => PaymentLike(
        id: j['id'] as String,
        amountMinor: (j['amountMinor'] as int?) ?? 0,
        refundedMinor: (j['refundedMinor'] as int?) ?? 0,
        method: (j['method'] as String?) ?? '',
        status: (j['status'] as String?) ?? '',
        purpose: j['purpose'] as String?,
      );
}
