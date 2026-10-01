/// GET /equipment* — rental equipment (skates, helmets, protective gear).
library;

class EquipmentItem {
  final String id;
  final String code;
  final String category;
  final String? size;
  final String condition;
  final String? location;
  final String status;
  final String? issuedSessionId;
  final DateTime? issuedAt;
  final String? issuedTo;
  DateTime? issuedUntil;

  EquipmentItem({
    required this.id, required this.code, required this.category, required this.size, required this.condition,
    required this.location, required this.status, required this.issuedSessionId, required this.issuedAt,
    required this.issuedTo, required this.issuedUntil,
  });

  factory EquipmentItem.fromJson(Map<String, dynamic> j) => EquipmentItem(
        id: j['id'] as String,
        code: j['code'] as String,
        category: (j['category'] as String?) ?? 'SKATE',
        size: j['size'] as String?,
        condition: (j['condition'] as String?) ?? 'GOOD',
        location: j['location'] as String?,
        status: (j['status'] as String?) ?? 'AVAILABLE',
        issuedSessionId: j['issuedSessionId'] as String?,
        issuedAt: j['issuedAt'] == null ? null : DateTime.tryParse(j['issuedAt'] as String),
        issuedTo: j['issuedTo'] as String?,
        issuedUntil: j['issuedUntil'] == null ? null : DateTime.tryParse(j['issuedUntil'] as String),
      );
}

class EquipmentListResponse {
  final List<EquipmentItem> items;
  final Map<String, int> summary;
  EquipmentListResponse({required this.items, required this.summary});
  factory EquipmentListResponse.fromJson(Map<String, dynamic> j) => EquipmentListResponse(
        items: ((j['items'] as List?) ?? const []).map((e) => EquipmentItem.fromJson(e as Map<String, dynamic>)).toList(),
        summary: ((j['summary'] as Map<String, dynamic>?) ?? const {}).map((k, v) => MapEntry(k, v as int)),
      );
}

class MaintenanceRecord {
  final String id;
  final String issue;
  final String status;
  final DateTime reportedAt;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final String? resolution;
  final bool hasPhoto;
  MaintenanceRecord({required this.id, required this.issue, required this.status, required this.reportedAt, required this.startedAt, required this.completedAt, required this.resolution, required this.hasPhoto});
  factory MaintenanceRecord.fromJson(Map<String, dynamic> j) => MaintenanceRecord(
        id: j['id'] as String,
        issue: (j['issue'] as String?) ?? '',
        status: (j['status'] as String?) ?? '',
        reportedAt: DateTime.tryParse((j['reportedAt'] as String?) ?? '') ?? DateTime.now(),
        startedAt: j['startedAt'] == null ? null : DateTime.tryParse(j['startedAt'] as String),
        completedAt: j['completedAt'] == null ? null : DateTime.tryParse(j['completedAt'] as String),
        resolution: j['resolution'] as String?,
        hasPhoto: (j['hasPhoto'] as bool?) ?? false,
      );
}

class EquipmentEvent {
  final String eventType;
  final DateTime occurredAt;
  final String? actorName;
  EquipmentEvent({required this.eventType, required this.occurredAt, required this.actorName});
  factory EquipmentEvent.fromJson(Map<String, dynamic> j) => EquipmentEvent(
        eventType: (j['eventType'] as String?) ?? (j['type'] as String? ?? ''),
        occurredAt: DateTime.tryParse((j['occurredAt'] as String?) ?? (j['createdAt'] as String? ?? '')) ?? DateTime.now(),
        actorName: j['actorName'] as String?,
      );
}

class EquipmentDetail {
  final EquipmentItem item;
  final List<EquipmentEvent> events;
  final List<MaintenanceRecord> maintenance;
  final int timesIssued;
  final int timesRepaired;
  EquipmentDetail({required this.item, required this.events, required this.maintenance, required this.timesIssued, required this.timesRepaired});
  factory EquipmentDetail.fromJson(Map<String, dynamic> j) => EquipmentDetail(
        item: EquipmentItem.fromJson(j),
        events: ((j['events'] as List?) ?? const []).map((e) => EquipmentEvent.fromJson(e as Map<String, dynamic>)).toList(),
        maintenance: ((j['maintenance'] as List?) ?? const []).map((e) => MaintenanceRecord.fromJson(e as Map<String, dynamic>)).toList(),
        timesIssued: ((j['usage'] as Map<String, dynamic>?)?['timesIssued'] as int?) ?? 0,
        timesRepaired: ((j['usage'] as Map<String, dynamic>?)?['timesRepaired'] as int?) ?? 0,
      );
}
