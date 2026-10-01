/// Incident reporting models (POST/GET /incidents*).
library;

class IncidentRecord {
  final String id;
  final String incidentNumber;
  final DateTime occurredAt;
  final String incidentType;
  final String severity; // MINOR | MODERATE | SERIOUS | CRITICAL
  final String status; // REPORTED | ACKNOWLEDGED | ACTION_TAKEN | UNDER_REVIEW | CLOSED
  final String? location;
  final String? description;
  final String? actionTaken;
  final String? customerName;
  final String? reportedByName;
  final bool redacted;

  IncidentRecord({
    required this.id, required this.incidentNumber, required this.occurredAt, required this.incidentType,
    required this.severity, required this.status, required this.location, required this.description,
    required this.actionTaken, required this.customerName, required this.reportedByName, this.redacted = false,
  });

  factory IncidentRecord.fromJson(Map<String, dynamic> j, {bool redacted = false}) => IncidentRecord(
        id: j['id'] as String,
        incidentNumber: (j['incidentNumber'] as String?) ?? '',
        occurredAt: DateTime.tryParse((j['occurredAt'] as String?) ?? '') ?? DateTime.now(),
        incidentType: (j['incidentType'] as String?) ?? 'OTHER',
        severity: (j['severity'] as String?) ?? 'MINOR',
        status: (j['status'] as String?) ?? 'REPORTED',
        location: j['location'] as String?,
        description: j['description'] as String?,
        actionTaken: j['actionTaken'] as String?,
        customerName: j['customerName'] as String?,
        reportedByName: j['reportedByName'] as String?,
        redacted: redacted,
      );
}

class IncidentEvent {
  final String eventType;
  final DateTime occurredAt;
  final String? actorName;
  IncidentEvent({required this.eventType, required this.occurredAt, required this.actorName});
  factory IncidentEvent.fromJson(Map<String, dynamic> j) => IncidentEvent(
        eventType: (j['eventType'] as String?) ?? '',
        occurredAt: DateTime.tryParse((j['occurredAt'] as String?) ?? '') ?? DateTime.now(),
        actorName: j['actorName'] as String?,
      );
}

class IncidentAttachment {
  final String id;
  final String mimeType;
  IncidentAttachment({required this.id, required this.mimeType});
  factory IncidentAttachment.fromJson(Map<String, dynamic> j) => IncidentAttachment(id: j['id'] as String, mimeType: (j['mimeType'] as String?) ?? 'image/jpeg');
}

class IncidentDetail {
  final IncidentRecord incident;
  final List<IncidentEvent> events;
  final List<IncidentAttachment> attachments;
  IncidentDetail({required this.incident, required this.events, required this.attachments});
}

const incidentTypes = ['FALL', 'COLLISION', 'EQUIPMENT', 'MEDICAL', 'BEHAVIOUR', 'OTHER'];
const incidentSeverities = ['MINOR', 'MODERATE', 'SERIOUS', 'CRITICAL'];
const incidentTransitions = <String, List<String>>{
  'REPORTED': ['ACKNOWLEDGED', 'ACTION_TAKEN', 'UNDER_REVIEW'],
  'ACKNOWLEDGED': ['ACTION_TAKEN', 'UNDER_REVIEW', 'CLOSED'],
  'ACTION_TAKEN': ['UNDER_REVIEW', 'CLOSED'],
  'UNDER_REVIEW': ['ACTION_TAKEN', 'CLOSED'],
  'CLOSED': [],
};
