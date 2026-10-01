/// Data models for GET /dashboard and GET /config. Field names match the backend's
/// camelCase JSON exactly (backend/src/modules/dashboard.ts, backend/src/routes.ts).
library;

class Warning {
  final int minutes;
  final String level; // YELLOW | ORANGE | RED
  Warning(this.minutes, this.level);
  factory Warning.fromJson(Map<String, dynamic> j) => Warning(j['minutes'] as int, j['level'] as String);
}

class VenueConfig {
  final String venueName;
  final String currency;
  final int expiringMinutes;
  final List<Warning> warnings;

  VenueConfig({required this.venueName, required this.currency, required this.expiringMinutes, required this.warnings});

  factory VenueConfig.fromJson(Map<String, dynamic> j) {
    final settings = j['settings'] as Map<String, dynamic>;
    return VenueConfig(
      venueName: (j['venue'] as Map<String, dynamic>)['name'] as String,
      currency: (j['venue'] as Map<String, dynamic>)['currency'] as String,
      expiringMinutes: settings['expiringMinutes'] as int,
      warnings: (settings['warnings'] as List).map((w) => Warning.fromJson(w as Map<String, dynamic>)).toList(),
    );
  }
}

class LiveSession {
  final String id;
  final String status;
  final String customerName;
  final String? photoId;
  final String productName;
  final String? wristband;
  final String equipment;
  final DateTime? startedAt;
  final DateTime? scheduledEndAt;
  final DateTime? pausedAt;
  final bool pauseCountsTowardTime;

  LiveSession({
    required this.id, required this.status, required this.customerName, required this.photoId,
    required this.productName, required this.wristband, required this.equipment,
    required this.startedAt, required this.scheduledEndAt, required this.pausedAt, required this.pauseCountsTowardTime,
  });

  factory LiveSession.fromJson(Map<String, dynamic> j) => LiveSession(
        id: j['id'] as String,
        status: j['status'] as String,
        customerName: j['customerName'] as String,
        photoId: j['photoId'] as String?,
        productName: j['productName'] as String,
        wristband: j['wristband'] as String?,
        equipment: (j['equipment'] as String?) ?? '',
        startedAt: j['startedAt'] == null ? null : DateTime.parse(j['startedAt'] as String),
        scheduledEndAt: j['scheduledEndAt'] == null ? null : DateTime.parse(j['scheduledEndAt'] as String),
        pausedAt: j['pausedAt'] == null ? null : DateTime.parse(j['pausedAt'] as String),
        pauseCountsTowardTime: (j['pauseCountsTowardTime'] as bool?) ?? false,
      );

  /// Same rule as backend/src/modules/sessions.ts remainingSeconds() and web/src/components/ui.tsx
  /// remainingFor(): derived from the authoritative end timestamp, not a counter anyone decrements.
  int? remainingSeconds(DateTime now) {
    if (scheduledEndAt == null) return null;
    final ref = (status == 'PAUSED' && !pauseCountsTowardTime && pausedAt != null) ? pausedAt! : now;
    return scheduledEndAt!.difference(ref).inSeconds;
  }
}

class Alert {
  final String id;
  final String severity; // INFO | WARNING | CRITICAL
  final String title;
  final String? body;
  Alert({required this.id, required this.severity, required this.title, required this.body});
  factory Alert.fromJson(Map<String, dynamic> j) => Alert(id: j['id'] as String, severity: j['severity'] as String, title: j['title'] as String, body: j['body'] as String?);
}

class Dashboard {
  final DateTime serverTime;
  final String currency;
  final int occupancy;
  final int maxCapacity;
  final int available;
  final bool full;
  final int visitorsToday;
  final int? revenueMinorToday;
  final int normal, expiring, expired;
  final int waiting;
  final int equipmentOut;
  final int equipmentNeedsAttention;
  final int? openIncidents;
  final List<Alert> alerts;
  final List<LiveSession> liveSessions;

  Dashboard({
    required this.serverTime, required this.currency, required this.occupancy, required this.maxCapacity,
    required this.available, required this.full, required this.visitorsToday, required this.revenueMinorToday,
    required this.normal, required this.expiring, required this.expired, required this.waiting,
    required this.equipmentOut, required this.equipmentNeedsAttention, required this.openIncidents,
    required this.alerts, required this.liveSessions,
  });

  factory Dashboard.fromJson(Map<String, dynamic> j) {
    final cap = j['capacity'] as Map<String, dynamic>;
    final today = j['today'] as Map<String, dynamic>;
    final rink = j['rink'] as Map<String, dynamic>;
    final eq = j['equipment'] as Map<String, dynamic>;
    return Dashboard(
      serverTime: DateTime.parse(j['serverTime'] as String),
      currency: j['currency'] as String,
      occupancy: cap['occupancy'] as int,
      maxCapacity: cap['max'] as int,
      available: cap['available'] as int,
      full: cap['full'] as bool,
      visitorsToday: today['visitors'] as int,
      revenueMinorToday: today['revenueMinor'] as int?,
      normal: rink['normal'] as int,
      expiring: rink['expiring'] as int,
      expired: rink['expired'] as int,
      waiting: j['waiting'] as int,
      equipmentOut: eq['out'] as int,
      equipmentNeedsAttention: eq['needsAttention'] as int,
      openIncidents: j['openIncidents'] as int?,
      alerts: (j['alerts'] as List).map((a) => Alert.fromJson(a as Map<String, dynamic>)).toList(),
      liveSessions: (j['liveSessions'] as List).map((s) => LiveSession.fromJson(s as Map<String, dynamic>)).toList(),
    );
  }
}
