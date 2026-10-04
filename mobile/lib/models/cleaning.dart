/// Rental-skate cleaning workflow (GET /equipment/cleaning-queue, /equipment/health,
/// POST /equipment/:id/cleaning/*).
library;

class CleaningItem {
  final String id;
  final String code;
  final String? size;
  final String status; // current equipment status: NEEDS_CLEANING | CLEANING | ...
  final DateTime? returnedAt;
  final String? lastCustomerName;
  final DateTime? lastCleanedAt;
  final String? lastCleanedByName;
  final DateTime? cleaningDueAt;

  CleaningItem({
    required this.id, required this.code, required this.size, required this.status, required this.returnedAt,
    required this.lastCustomerName, required this.lastCleanedAt, required this.lastCleanedByName, required this.cleaningDueAt,
  });

  factory CleaningItem.fromJson(Map<String, dynamic> j) => CleaningItem(
        id: j['id'] as String,
        code: (j['code'] as String?) ?? '',
        size: j['size'] as String?,
        status: (j['status'] as String?) ?? 'NEEDS_CLEANING',
        returnedAt: j['returnedAt'] == null ? null : DateTime.tryParse(j['returnedAt'] as String),
        lastCustomerName: j['lastCustomerName'] as String?,
        lastCleanedAt: j['lastCleanedAt'] == null ? null : DateTime.tryParse(j['lastCleanedAt'] as String),
        lastCleanedByName: j['lastCleanedByName'] as String?,
        cleaningDueAt: j['cleaningDueAt'] == null ? null : DateTime.tryParse(j['cleaningDueAt'] as String),
      );
}

class CleaningRules {
  final bool afterUseRequired;
  final int deepCleanDays;
  final int inspectionDays;
  CleaningRules({required this.afterUseRequired, required this.deepCleanDays, required this.inspectionDays});
  factory CleaningRules.fromJson(Map<String, dynamic> j) => CleaningRules(
        afterUseRequired: (j['afterUseRequired'] as bool?) ?? true,
        deepCleanDays: (j['deepCleanDays'] as int?) ?? 7,
        inspectionDays: (j['inspectionDays'] as int?) ?? 30,
      );
}

class CleaningQueue {
  final List<CleaningItem> needsCleaning;
  final List<CleaningItem> cleaning;
  final List<CleaningItem> completed;
  final List<CleaningItem> overdueScheduled;
  final CleaningRules rules;
  CleaningQueue({required this.needsCleaning, required this.cleaning, required this.completed, required this.overdueScheduled, required this.rules});
  factory CleaningQueue.fromJson(Map<String, dynamic> j) => CleaningQueue(
        needsCleaning: ((j['needsCleaning'] as List?) ?? const []).map((e) => CleaningItem.fromJson(e as Map<String, dynamic>)).toList(),
        cleaning: ((j['cleaning'] as List?) ?? const []).map((e) => CleaningItem.fromJson(e as Map<String, dynamic>)).toList(),
        completed: ((j['completed'] as List?) ?? const []).map((e) => CleaningItem.fromJson(e as Map<String, dynamic>)).toList(),
        overdueScheduled: ((j['overdueScheduled'] as List?) ?? const []).map((e) => CleaningItem.fromJson(e as Map<String, dynamic>)).toList(),
        rules: CleaningRules.fromJson((j['rules'] as Map<String, dynamic>?) ?? const {}),
      );
}

class EquipmentHealth {
  final int total, available, inUse, needsCleaning, cleaning, maintenance, outOfService, overdue;
  final int cleanedToday, pendingCleaning, cleaningCompliancePct;
  EquipmentHealth({
    required this.total, required this.available, required this.inUse, required this.needsCleaning, required this.cleaning,
    required this.maintenance, required this.outOfService, required this.overdue,
    required this.cleanedToday, required this.pendingCleaning, required this.cleaningCompliancePct,
  });
  factory EquipmentHealth.fromJson(Map<String, dynamic> j) => EquipmentHealth(
        total: (j['total'] as int?) ?? 0,
        available: (j['available'] as int?) ?? 0,
        inUse: (j['inUse'] as int?) ?? 0,
        needsCleaning: (j['needsCleaning'] as int?) ?? 0,
        cleaning: (j['cleaning'] as int?) ?? 0,
        maintenance: (j['maintenance'] as int?) ?? 0,
        outOfService: (j['outOfService'] as int?) ?? 0,
        overdue: (j['overdue'] as int?) ?? 0,
        cleanedToday: (j['cleanedToday'] as int?) ?? 0,
        pendingCleaning: (j['pendingCleaning'] as int?) ?? 0,
        cleaningCompliancePct: (j['cleaningCompliancePct'] as int?) ?? 100,
      );
}

/// Mirrors backend/src/modules/equipment.ts CLEANING_CHECKLIST_ITEMS.
const cleaningChecklistItems = <String, String>{
  'interior': 'Interior cleaned/sanitized',
  'exterior': 'Exterior cleaned',
  'wheels': 'Wheels checked',
  'laces': 'Laces/straps checked',
  'noDamage': 'No obvious damage',
};
