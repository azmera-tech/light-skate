import 'dart:convert';
import 'dart:math';
import '../api/api_client.dart';

/// A complete, self-contained, in-memory stand-in for the real backend, used when
/// `kDemoMode` is on. It answers the exact same request shapes (method + path + body) with
/// the exact same JSON shapes the real API returns, documented field-for-field against the
/// models in `lib/models/`, so every screen built against the real API works unmodified.
///
/// It is a demo convenience, not a spec implementation: business-rule enforcement (capacity,
/// duplicate-active-session, payment-provider state machines, etc) is deliberately light or
/// absent, since the goal is a smooth walkthrough, not re-proving the backend's own test suite.
class MockBackend {
  MockBackend._() {
    _seed();
  }
  static final MockBackend instance = MockBackend._();

  final _rng = Random();
  int _seq = 1;
  String _id(String prefix) => '$prefix-${(_seq++).toString().padLeft(4, '0')}';

  // ---- seeded state --------------------------------------------------------------------------

  late List<Map<String, dynamic>> customers;
  late List<Map<String, dynamic>> equipment;
  late List<Map<String, dynamic>> sessions; // includes CREATED/PAYMENT_PENDING/READY/CHECKED_IN/ACTIVE/PAUSED/EXPIRING/EXPIRED/COMPLETED/EARLY_EXIT/CANCELLED
  late List<Map<String, dynamic>> visits;
  late List<Map<String, dynamic>> payments;
  late List<Map<String, dynamic>> incidents;
  late List<Map<String, dynamic>> incidentAttachments;
  late List<Map<String, dynamic>> devices;
  late List<Map<String, dynamic>> staff;
  late List<Map<String, dynamic>> pricing;
  late List<Map<String, dynamic>> auditLog;
  late List<Map<String, dynamic>> dayCloses;
  late List<Map<String, dynamic>> waiverVersions;
  late Map<String, dynamic> settings;
  late Map<String, dynamic> emergency;
  int maxCapacity = 60;

  String get _nowIso => DateTime.now().toUtc().toIso8601String();

  void _seed() {
    final now = DateTime.now();

    const names = [
      'Abebe Kebede', 'Biruk Fikre', 'Sara Tesfaye', 'Dawit Alemu', 'Hana Girma',
      'Yared Bekele', 'Marta Haile', 'Samuel Worku', 'Ruth Mengistu', 'Kebede Tadesse',
      'Lily Admasu', 'Nathnael Yohannes', 'Selam Fisseha', 'Mikiyas Tsegaye', 'Betelhem Assefa',
    ];
    customers = List.generate(names.length, (i) {
      final n = i + 1;
      return {
        'id': 'cust-${n.toString().padLeft(4, '0')}',
        'customerNo': n,
        'fullName': 'Demo ${names[i]}',
        'phoneE164': '+25191100${n.toString().padLeft(4, '0')}',
        'email': null,
        'dateOfBirth': n == 3 ? '2015-04-12' : null, // one minor, for the guardian-flow demo
        'notes': null,
        'status': 'ACTIVE',
        'registeredAt': now.subtract(Duration(days: 30 + n)).toUtc().toIso8601String(),
        'customerCode': 'LS-C${n.toString().padLeft(6, '0')}',
        'photoId': null,
        'emergencyContacts': n == 3
            ? [
                {'id': 'ec-1', 'name': 'Demo Guardian Kebede', 'phone': '+251911099001', 'relationship': 'Parent', 'isGuardian': true}
              ]
            : <Map<String, dynamic>>[],
        'visitCount': 2 + (n % 7),
        'lastVisitAt': now.subtract(Duration(days: n % 10)).toUtc().toIso8601String(),
        'totalSkatingSeconds': (2 + (n % 7)) * 3000,
        'totalSpentMinor': (2 + (n % 7)) * 15000,
        'equipmentIssuedCount': 2 + (n % 5),
        'waiverAccepted': n != 5 && n != 9, // a couple of customers still need the waiver, for that step of the demo
        'waiverAcceptedAt': now.subtract(const Duration(days: 20)).toUtc().toIso8601String(),
      };
    });

    equipment = [
      for (var i = 1; i <= 22; i++)
        {
          'id': 'eq-${i.toString().padLeft(4, '0')}',
          'code': 'SKATE-${i.toString().padLeft(3, '0')}',
          'category': 'SKATE',
          'size': ['33', '34', '35', '36', '37', '38', '39', '40', '41', '42', '43', '44'][i % 12],
          'condition': i == 18 ? 'POOR' : 'GOOD',
          'location': 'Rack ${1 + (i % 3)}',
          'status': i == 17
              ? 'DAMAGED'
              : i == 18
                  ? 'MAINTENANCE'
                  : i == 19
                      ? 'OUT_OF_SERVICE'
                      : 'AVAILABLE',
          'issuedSessionId': null,
          'issuedAt': null,
          'issuedTo': null,
          'issuedUntil': null,
        },
      {
        'id': 'eq-helmet-1',
        'code': 'HELMET-001',
        'category': 'HELMET',
        'size': 'M',
        'condition': 'GOOD',
        'location': 'Rack 1',
        'status': 'AVAILABLE',
        'issuedSessionId': null,
        'issuedAt': null,
        'issuedTo': null,
        'issuedUntil': null,
      },
    ];

    pricing = [
      {'id': 'price-30', 'kind': 'SESSION', 'name': 'Quick Skate', 'durationMinutes': 30, 'priceMinor': 10000, 'currency': 'ETB', 'dayType': 'ANY', 'customerType': 'ANY', 'active': true, 'sortOrder': 0},
      {'id': 'price-60', 'kind': 'SESSION', 'name': 'Standard', 'durationMinutes': 60, 'priceMinor': 20000, 'currency': 'ETB', 'dayType': 'ANY', 'customerType': 'ANY', 'active': true, 'sortOrder': 1},
      {'id': 'price-90', 'kind': 'SESSION', 'name': 'Extended', 'durationMinutes': 90, 'priceMinor': 28000, 'currency': 'ETB', 'dayType': 'ANY', 'customerType': 'ANY', 'active': true, 'sortOrder': 2},
      {'id': 'price-120', 'kind': 'SESSION', 'name': 'Two Hours', 'durationMinutes': 120, 'priceMinor': 35000, 'currency': 'ETB', 'dayType': 'ANY', 'customerType': 'ANY', 'active': true, 'sortOrder': 3},
      {'id': 'ext-15', 'kind': 'EXTENSION', 'name': '+15 min', 'durationMinutes': 15, 'priceMinor': 5000, 'currency': 'ETB', 'dayType': 'ANY', 'customerType': 'ANY', 'active': true, 'sortOrder': 0},
      {'id': 'ext-30', 'kind': 'EXTENSION', 'name': '+30 min', 'durationMinutes': 30, 'priceMinor': 9000, 'currency': 'ETB', 'dayType': 'ANY', 'customerType': 'ANY', 'active': true, 'sortOrder': 1},
      {'id': 'ext-60', 'kind': 'EXTENSION', 'name': '+60 min', 'durationMinutes': 60, 'priceMinor': 16000, 'currency': 'ETB', 'dayType': 'ANY', 'customerType': 'ANY', 'active': true, 'sortOrder': 2},
    ];

    settings = {
      'paymentMethods': [
        {'code': 'CASH', 'label': 'Cash', 'requiresReference': false, 'enabled': true},
        {'code': 'BANK_TRANSFER', 'label': 'Bank transfer', 'requiresReference': true, 'enabled': true},
        {'code': 'TELEBIRR', 'label': 'Telebirr', 'requiresReference': true, 'enabled': true},
        {'code': 'CARD', 'label': 'Card', 'requiresReference': false, 'enabled': true},
        {'code': 'OTHER', 'label': 'Other', 'requiresReference': false, 'enabled': true},
      ],
      'warnings': [
        {'minutes': 15, 'level': 'YELLOW'},
        {'minutes': 5, 'level': 'ORANGE'},
        {'minutes': 1, 'level': 'RED'},
      ],
      'expiringMinutes': 15,
      'pause': {'enabled': true, 'countsTowardTime': false},
      'extensionOptionsMinutes': [15, 30, 60],
      'earlyExitGraceSeconds': 60,
      'noShowMinutes': 20,
      'waiverRequired': true,
      'minorAgeYears': 18,
      'photoCapture': 'NEW_CUSTOMER',
      'wristbands': {'enabled': false, 'colors': <String>['BLUE', 'GREEN', 'ORANGE', 'RED']},
      'equipmentRequiredForStart': false,
      'inspectOnReturn': false,
      'enforceOperatingHours': false,
      'operatingHours': <String, dynamic>{},
      'weekendDays': [0, 6],
      'holidays': <String>[],
      'retention': {'profilePhotoDays': null, 'visitPhotoDays': 180, 'incidentAttachmentDays': 365},
    };
    emergency = {
      'ambulance': '907',
      'police': '991',
      'fire': '939',
      'venueContact': '+251911234567',
      'manager': '+251911234568',
      'address': 'Bole Road, Addis Ababa',
      'firstAid': 'First-aid kit is behind the front desk. AED is on the north wall near the rink entrance.',
    };
    waiverVersions = [
      {
        'id': 'waiver-v2',
        'version': 2,
        'title': 'Light Skate Rink Rules & Waiver',
        'body': 'By skating at Light Skate, you acknowledge the inherent risks of ice/roller skating, '
            'agree to follow staff instructions and posted rink rules, and release Light Skate from liability '
            'for injuries not caused by our negligence. Guests under 18 require a parent or guardian to accept '
            'on their behalf. Photos taken for identification are kept private and used only by venue staff.',
        'language': 'en',
        'isCurrent': true,
        'publishedAt': now.subtract(const Duration(days: 60)).toUtc().toIso8601String(),
      },
    ];

    staff = [
      {'id': 'staff-1', 'email': 'owner@lightskate.demo', 'fullName': 'Demo Owner', 'status': 'ACTIVE', 'lastLoginAt': _nowIso, 'roleId': 'role-owner', 'roleCode': 'OWNER', 'roleName': 'Owner', 'phone': null, 'employeeNo': 'E001'},
      {'id': 'staff-2', 'email': 'manager@lightskate.demo', 'fullName': 'Demo Manager (Hana)', 'status': 'ACTIVE', 'lastLoginAt': _nowIso, 'roleId': 'role-manager', 'roleCode': 'MANAGER', 'roleName': 'Manager', 'phone': null, 'employeeNo': 'E002'},
      {'id': 'staff-3', 'email': 'frontdesk@lightskate.demo', 'fullName': 'Demo Front Desk (Dawit)', 'status': 'ACTIVE', 'lastLoginAt': _nowIso, 'roleId': 'role-frontdesk', 'roleCode': 'FRONT_DESK', 'roleName': 'Front Desk', 'phone': null, 'employeeNo': 'E003'},
      {'id': 'staff-4', 'email': 'rental@lightskate.demo', 'fullName': 'Demo Rental Staff (Sara)', 'status': 'ACTIVE', 'lastLoginAt': _nowIso, 'roleId': 'role-rental', 'roleCode': 'RENTAL_STAFF', 'roleName': 'Rental Staff', 'phone': null, 'employeeNo': 'E004'},
    ];

    devices = [
      {'id': 'dev-1', 'name': 'FRONT DESK TABLET', 'deviceType': 'FRONT_DESK', 'status': 'ACTIVE', 'lastSeenAt': _nowIso, 'registeredAt': now.subtract(const Duration(days: 90)).toUtc().toIso8601String()},
    ];

    visits = [];
    payments = [];
    sessions = [];
    incidents = [];
    incidentAttachments = [];
    auditLog = [];
    dayCloses = [
      {
        'id': 'close-1',
        'localDate': now.subtract(const Duration(days: 1)).toUtc().toIso8601String().substring(0, 10),
        'expectedCashMinor': 185000,
        'countedCashMinor': 185000,
        'differenceMinor': 0,
        'checks': {'activeSessions': 0, 'unreturnedSkates': 0, 'unresolvedIncidents': 0, 'unpaidSessions': 0, 'pendingPayments': 0},
        'notes': null,
        'closedBy': 'Demo Manager (Hana)',
        'closedAt': now.subtract(const Duration(days: 1, hours: -2)).toUtc().toIso8601String(),
      },
    ];

    // --- a handful of live visits/sessions so the dashboard looks like a real operating venue ---
    void seedSession({
      required Map<String, dynamic> customer,
      required String status,
      required Map<String, dynamic> product,
      Duration elapsed = Duration.zero,
      bool paused = false,
    }) {
      final visitId = _id('visit');
      final sessionId = _id('sess');
      final startedAt = now.subtract(elapsed);
      final scheduledEndAt = startedAt.add(Duration(minutes: product['durationMinutes'] as int));
      visits.add({
        'id': visitId,
        'visitNumber': visits.length + 1,
        'customerId': customer['id'],
        'status': 'OPEN',
        'createdAt': startedAt.toUtc().toIso8601String(),
      });
      sessions.add({
        'id': sessionId,
        'visitId': visitId,
        'customerId': customer['id'],
        'customerName': customer['fullName'],
        'photoId': customer['photoId'],
        'status': status,
        'productName': product['name'],
        'priceMinor': product['priceMinor'],
        'discountMinor': 0,
        'currency': 'ETB',
        'wristband': null,
        'startedAt': status == 'READY' || status == 'PAYMENT_PENDING' ? null : startedAt.toUtc().toIso8601String(),
        'scheduledEndAt': status == 'READY' || status == 'PAYMENT_PENDING' ? null : scheduledEndAt.toUtc().toIso8601String(),
        'pausedAt': paused ? now.toUtc().toIso8601String() : null,
        'pauseCountsTowardTime': false,
        'totalPausedSeconds': 0,
        'equipmentIds': <String>[],
        'paidMinor': status == 'READY' || status == 'PAYMENT_PENDING' ? 0 : (product['priceMinor'] as int),
      });
    }

    final live = [
      (customers[0], pricing[1], const Duration(minutes: 20), false), // 60min, 20 elapsed -> ~40 left, normal
      (customers[1], pricing[0], const Duration(minutes: 28), false), // 30min, 28 elapsed -> ~2 left, red/expiring
      (customers[2], pricing[2], const Duration(minutes: 10), false), // 90min, normal
      (customers[3], pricing[1], const Duration(minutes: 65), false), // 60min, overdue -> expired
      (customers[4], pricing[3], const Duration(minutes: 5), false), // 120min, normal
      (customers[5], pricing[1], const Duration(minutes: 30), true), // paused halfway
      (customers[6], pricing[0], const Duration(minutes: 35), false), // 30min, overdue -> expired
    ];
    for (final (cust, prod, elapsed, paused) in live) {
      seedSession(customer: cust, status: paused ? 'PAUSED' : 'ACTIVE', product: prod, elapsed: elapsed, paused: paused);
    }
    // two "waiting" sessions: one awaiting payment, one paid-and-ready (equipment/start pending)
    seedSession(customer: customers[7], status: 'PAYMENT_PENDING', product: pricing[1]);
    seedSession(customer: customers[8], status: 'READY', product: pricing[0]);

    // a couple of seeded payments so today's revenue looks real
    for (final s in sessions.where((s) => (s['paidMinor'] as int) > 0)) {
      payments.add({
        'id': _id('pay'),
        'sessionId': s['id'],
        'visitId': s['visitId'],
        'customerId': s['customerId'],
        'customerName': s['customerName'],
        'amountMinor': s['paidMinor'],
        'refundedMinor': 0,
        'currency': 'ETB',
        'method': 'CASH',
        'status': 'PAID',
        'purpose': 'SESSION',
        'providerReference': null,
        'reference': null,
        'note': null,
        'staffName': 'Demo Front Desk (Dawit)',
        'createdAt': now.toUtc().toIso8601String(),
      });
    }
    // one completed visit earlier today, for History
    seedSession(customer: customers[9], status: 'COMPLETED', product: pricing[1], elapsed: const Duration(hours: 3));
    sessions.last['actualEndAt'] = now.subtract(const Duration(hours: 2)).toUtc().toIso8601String();
    payments.add({
      'id': _id('pay'),
      'sessionId': sessions.last['id'],
      'visitId': sessions.last['visitId'],
      'customerId': sessions.last['customerId'],
      'customerName': sessions.last['customerName'],
      'amountMinor': sessions.last['paidMinor'],
      'refundedMinor': 0,
      'currency': 'ETB',
      'method': 'TELEBIRR',
      'status': 'PAID',
      'purpose': 'SESSION',
      'providerReference': 'TB-993214',
      'reference': 'TB-993214',
      'note': null,
      'staffName': 'Demo Front Desk (Dawit)',
      'createdAt': now.subtract(const Duration(hours: 3)).toUtc().toIso8601String(),
    });

    incidents = [
      {
        'id': 'inc-1',
        'incidentNumber': 'INC-${_dateStr(now)}-001',
        'customerId': customers[1]['id'],
        'customerName': customers[1]['fullName'],
        'sessionId': null,
        'occurredAt': now.subtract(const Duration(hours: 1)).toUtc().toIso8601String(),
        'incidentType': 'FALL',
        'severity': 'MINOR',
        'status': 'REPORTED',
        'location': 'Main rink',
        'description': 'Guest slipped near the entrance, minor scrape on the knee. Walked it off, declined first aid.',
        'actionTaken': 'Offered first aid, guest declined.',
        'reportedByName': 'Demo Front Desk (Dawit)',
        'managerNotified': false,
      },
      {
        'id': 'inc-2',
        'incidentNumber': 'INC-${_dateStr(now.subtract(const Duration(days: 2)))}-003',
        'customerId': null,
        'customerName': null,
        'sessionId': null,
        'occurredAt': now.subtract(const Duration(days: 2)).toUtc().toIso8601String(),
        'incidentType': 'EQUIPMENT',
        'severity': 'MODERATE',
        'status': 'CLOSED',
        'location': 'Rental desk',
        'description': 'SKATE-017 found with a cracked frame during routine check.',
        'actionTaken': 'Pulled from service, logged for repair.',
        'reportedByName': 'Demo Rental Staff (Sara)',
        'managerNotified': true,
      },
    ];
  }

  String _dateStr(DateTime d) => '${d.year.toString().padLeft(4, '0')}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
  String _fmtDate(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  // ---- derived / shape helpers ----------------------------------------------------------------

  static const _liveStatuses = {'ACTIVE', 'PAUSED', 'EXPIRING', 'EXPIRED'};
  static const _waitingStatuses = {'CREATED', 'PAYMENT_PENDING', 'READY', 'CHECKED_IN'};

  int? _remainingSeconds(Map<String, dynamic> s) {
    final endIso = s['scheduledEndAt'] as String?;
    if (endIso == null) return null;
    final end = DateTime.parse(endIso);
    final ref = (s['status'] == 'PAUSED' && s['pausedAt'] != null) ? DateTime.parse(s['pausedAt'] as String) : DateTime.now();
    return end.difference(ref).inSeconds;
  }

  String _liveStatusFor(Map<String, dynamic> s) {
    final raw = s['status'] as String;
    if (raw != 'ACTIVE') return raw;
    final remaining = _remainingSeconds(s);
    if (remaining == null) return raw;
    if (remaining <= 0) return 'EXPIRED';
    if (remaining <= (settings['expiringMinutes'] as int) * 60) return 'EXPIRING';
    return 'ACTIVE';
  }

  String _equipmentCodesFor(String sessionId) =>
      equipment.where((e) => e['issuedSessionId'] == sessionId).map((e) => e['code'] as String).join(', ');

  Map<String, dynamic> _sessionRowJson(Map<String, dynamic> s) {
    final status = _liveStatusFor(s);
    return {
      'id': s['id'],
      'visitId': s['visitId'],
      'customerId': s['customerId'],
      'customerName': s['customerName'],
      'photoId': s['photoId'],
      'status': status,
      'productName': s['productName'],
      'priceMinor': s['priceMinor'],
      'discountMinor': s['discountMinor'],
      'currency': s['currency'],
      'wristband': s['wristband'],
      'equipment': _equipmentCodesFor(s['id'] as String),
      'startedAt': s['startedAt'],
      'scheduledEndAt': s['scheduledEndAt'],
      'pausedAt': s['pausedAt'],
      'pauseCountsTowardTime': s['pauseCountsTowardTime'],
      'remainingSeconds': _remainingSeconds(s),
      'paidMinor': s['paidMinor'],
      'pendingMinor': 0,
      'dueMinor': max(0, (s['priceMinor'] as int) - (s['discountMinor'] as int) - (s['paidMinor'] as int)),
    };
  }

  List<Map<String, dynamic>> _sessionEvents(Map<String, dynamic> s) {
    final events = <Map<String, dynamic>>[];
    events.add({'eventType': 'SESSION_CREATED', 'fromStatus': null, 'toStatus': 'CREATED', 'occurredAt': s['createdAt'] ?? _nowIso, 'metadata': {}, 'actorName': 'Demo Front Desk (Dawit)', 'deviceName': 'Front Desk Tablet'});
    if (s['startedAt'] != null) {
      events.add({'eventType': 'SESSION_STARTED', 'fromStatus': 'READY', 'toStatus': 'ACTIVE', 'occurredAt': s['startedAt'], 'metadata': {}, 'actorName': 'Demo Front Desk (Dawit)', 'deviceName': 'Front Desk Tablet'});
    }
    if (s['pausedAt'] != null) {
      events.add({'eventType': 'SESSION_PAUSED', 'fromStatus': 'ACTIVE', 'toStatus': 'PAUSED', 'occurredAt': s['pausedAt'], 'metadata': {}, 'actorName': 'Demo Front Desk (Dawit)', 'deviceName': null});
    }
    for (final ext in (s['extensionLog'] as List<Map<String, dynamic>>? ?? const [])) {
      events.add({'eventType': 'SESSION_EXTENDED', 'fromStatus': null, 'toStatus': null, 'occurredAt': ext['createdAt'], 'metadata': {'addedMinutes': (ext['addedSeconds'] as int) ~/ 60}, 'actorName': 'Demo Front Desk (Dawit)', 'deviceName': null});
    }
    if (s['actualEndAt'] != null) {
      final ended = s['status'] == 'CANCELLED' ? 'SESSION_CANCELLED' : 'SESSION_ENDED';
      events.add({'eventType': ended, 'fromStatus': null, 'toStatus': s['status'], 'occurredAt': s['actualEndAt'], 'metadata': {}, 'actorName': 'Demo Front Desk (Dawit)', 'deviceName': null});
    }
    return events;
  }

  Map<String, dynamic> _sessionDetailJson(Map<String, dynamic> s) => {
        'serverTime': _nowIso,
        'session': _sessionRowJson(s),
        'events': _sessionEvents(s),
        'extensions': (s['extensionLog'] as List<Map<String, dynamic>>? ?? const [])
            .map((e) => {'addedSeconds': e['addedSeconds'], 'newEndAt': e['newEndAt'], 'priceMinor': e['priceMinor'], 'reason': e['reason']})
            .toList(),
        'equipmentAssignments': equipment
            .where((e) => e['issuedSessionId'] == s['id'] || e['_lastSessionId'] == s['id'])
            .map((e) => {'id': e['id'], 'code': e['code'], 'assignedAt': e['issuedAt'] ?? _nowIso, 'returnedAt': e['status'] == 'AVAILABLE' || e['status'] == 'RETURNED' ? (e['_returnedAt'] ?? _nowIso) : null})
            .toList(),
      };

  Map<String, dynamic>? _findCustomer(String id) => customers.cast<Map<String, dynamic>?>().firstWhere((c) => c!['id'] == id, orElse: () => null);
  Map<String, dynamic>? _findSession(String id) => sessions.cast<Map<String, dynamic>?>().firstWhere((s) => s!['id'] == id, orElse: () => null);
  Map<String, dynamic>? _findEquipment(String id) => equipment.cast<Map<String, dynamic>?>().firstWhere((e) => e!['id'] == id, orElse: () => null);
  Map<String, dynamic>? _findIncident(String id) => incidents.cast<Map<String, dynamic>?>().firstWhere((i) => i!['id'] == id, orElse: () => null);

  Map<String, dynamic> _customerProfileJson(Map<String, dynamic> c) {
    final currentSession = sessions.cast<Map<String, dynamic>?>().firstWhere(
          (s) => s!['customerId'] == c['id'] && _liveStatuses.contains(_liveStatusFor(s)),
          orElse: () => null,
        );
    final dob = c['dateOfBirth'] as String?;
    final isMinor = dob != null && DateTime.now().difference(DateTime.parse(dob)).inDays < (settings['minorAgeYears'] as int) * 365;
    return {
      'id': c['id'],
      'customerNo': c['customerNo'],
      'fullName': c['fullName'],
      'phoneE164': c['phoneE164'],
      'email': c['email'],
      'dateOfBirth': c['dateOfBirth'],
      'notes': c['notes'],
      'status': c['status'],
      'registeredAt': c['registeredAt'],
      'customerCode': c['customerCode'],
      'isMinor': isMinor,
      'photoId': c['photoId'],
      'emergencyContacts': c['emergencyContacts'],
      'stats': {
        'visitCount': c['visitCount'],
        'lastVisitAt': c['lastVisitAt'],
        'totalSkatingSeconds': c['totalSkatingSeconds'],
        'totalSpentMinor': c['totalSpentMinor'],
        'equipmentIssuedCount': c['equipmentIssuedCount'],
      },
      'waiver': {
        'required': settings['waiverRequired'],
        'currentVersionId': waiverVersions.first['id'],
        'currentVersion': waiverVersions.first['version'],
        'isMinor': isMinor,
        'accepted': c['waiverAccepted'],
        'acceptedAt': c['waiverAcceptedAt'],
      },
      'currentSession': currentSession == null
          ? null
          : {'id': currentSession['id'], 'status': _liveStatusFor(currentSession), 'startedAt': currentSession['startedAt'], 'scheduledEndAt': currentSession['scheduledEndAt']},
      'membership': null,
    };
  }

  // ---- the dispatcher --------------------------------------------------------------------------

  /// Mirrors `ApiClient._send`'s contract: returns the decoded JSON body (Map, usually) on
  /// success, or throws `ApiException` on a simulated error.
  dynamic handle(String method, String pathAndQuery, Map<String, dynamic>? body) {
    final uri = Uri.parse(pathAndQuery);
    final segs = uri.path.split('/').where((s) => s.isNotEmpty).toList();
    final q = uri.queryParameters;
    body ??= const {};

    try {
      return _route(method, segs, q, body);
    } on ApiException catch (e) {
      // Same reasoning as ApiClient._send()'s JSON round-trip: a hand-built `details` map
      // literal can infer as Map<String, Object>, which fails a later `as Map<String, dynamic>`
      // cast at the call site. Normalize it here so every throw site doesn't have to.
      throw ApiException(e.status, e.code, e.message, e.details == null ? null : jsonDecode(jsonEncode(e.details)));
    } catch (e) {
      throw ApiException(500, 'DEMO_ERROR', 'Demo data error: $e');
    }
  }

  dynamic _route(String method, List<String> segs, Map<String, String> q, Map<String, dynamic> body) {
    if (segs.isEmpty) return {'serverTime': _nowIso};

    switch (segs[0]) {
      case 'auth':
        if (segs.length == 2 && segs[1] == 'logout') return {'ok': true};
        break;

      case 'config':
        return {
          'serverTime': _nowIso,
          'venue': {'id': 'venue-demo', 'name': 'Light Skate (Demo)', 'timezone': 'Africa/Addis_Ababa', 'currency': 'ETB'},
          'maxCapacity': maxCapacity,
          'settings': settings,
          'emergency': emergency,
        };

      case 'emergency':
        return emergency;

      case 'time':
      case 'health':
        return {'serverTime': _nowIso, 'status': 'ok'};

      case 'products':
        final customerId = q['customerId'];
        final isChild = customerId != null && (_customerProfileJson(_findCustomer(customerId) ?? customers.first)['isMinor'] as bool);
        return {
          'sessions': pricing.where((p) => p['kind'] == 'SESSION' && p['active'] == true && (!isChild || p['customerType'] != 'ADULT')).toList(),
          'extensions': pricing.where((p) => p['kind'] == 'EXTENSION' && p['active'] == true).toList(),
        };

      case 'customers':
        return _customers(method, segs, q, body);

      case 'waivers':
        return _waivers(method, segs, body);

      case 'visits':
        return _visits(method, segs, q, body);

      case 'sessions':
        return _sessions(method, segs, q, body);

      case 'payments':
        return _payments(method, segs, body);

      case 'equipment':
        return _equipment(method, segs, body);

      case 'incidents':
        return _incidents(method, segs, q, body);

      case 'incident-attachments':
        return {'ok': true};

      case 'photos':
        throw ApiException(404, 'NOT_FOUND', 'No photo in demo mode.');

      case 'dashboard':
        return _dashboard();

      case 'reports':
        return _reports(segs, q);

      case 'audit':
        return _audit(q);

      case 'devices':
        return _devices(method, segs, body);

      case 'settings':
        if (method == 'GET') {
          return {'settings': settings, 'venue': {'name': 'Light Skate (Demo)', 'currency': 'ETB'}, 'maxCapacity': maxCapacity};
        }
        return {'settings': settings}; // not reached; PUT handled in 'settings'-as-root below

      case 'capacity':
        if (method == 'PUT') {
          maxCapacity = (body['maxCapacity'] as num).toInt();
          return {'maxCapacity': maxCapacity, 'occupancy': sessions.where((s) => _liveStatuses.contains(_liveStatusFor(s))).length};
        }
        break;

      case 'pricing':
        return _pricing(method, segs, body);

      case 'staff':
        return _staff(method, segs, body);

      case 'roles':
        return {
          'roles': [
            {'id': 'role-owner', 'code': 'OWNER', 'name': 'Owner', 'permissions': allPermissionCodes},
            {'id': 'role-manager', 'code': 'MANAGER', 'name': 'Manager', 'permissions': allPermissionCodes.where((p) => !p.startsWith('staff.') && p != 'settings.manage' && p != 'pricing.manage' && p != 'customer.delete').toList()},
            {'id': 'role-supervisor', 'code': 'SUPERVISOR', 'name': 'Supervisor', 'permissions': ['customer.read', 'customer.create', 'customer.update', 'visit.read', 'session.read', 'session.create', 'session.pause', 'session.extend', 'session.end', 'session.cancel', 'session.correct', 'payment.create', 'payment.read', 'payment.discount', 'payment.refund', 'equipment.read', 'equipment.assign', 'equipment.return', 'equipment.maintenance', 'incident.create', 'incident.read', 'incident.manage']},
            {'id': 'role-frontdesk', 'code': 'FRONT_DESK', 'name': 'Front Desk', 'permissions': ['customer.read', 'customer.create', 'customer.update', 'visit.read', 'session.read', 'session.create', 'session.pause', 'session.extend', 'session.end', 'session.cancel', 'payment.create', 'payment.read', 'equipment.read', 'equipment.assign', 'equipment.return', 'incident.create']},
            {'id': 'role-rental', 'code': 'RENTAL_STAFF', 'name': 'Rental Staff', 'permissions': ['customer.read', 'visit.read', 'session.read', 'equipment.read', 'equipment.assign', 'equipment.return', 'equipment.maintenance', 'incident.create']},
          ],
          'permissions': {for (final p in allPermissionCodes) p: p},
        };

      case 'day-close':
        if (segs.length == 2 && segs[1] == 'preview') return _dayClosePreview(q);
        if (method == 'POST') return _closeDay(body);
        break;

      case 'day-closes':
        return {'closes': dayCloses};

      case 'notifications':
        if (segs.length == 2 && segs[1] == 'ack') return {'id': segs[0], 'status': body['resolve'] == true ? 'RESOLVED' : 'ACKNOWLEDGED'};
        return {'notifications': <Map<String, dynamic>>[]};

      case 'sync':
        return {'serverTime': _nowIso, 'results': <Map<String, dynamic>>[]};
    }
    throw ApiException(404, 'NOT_FOUND', 'No demo handler for $method /${segs.join('/')}');
  }

  // ---- customers ---------------------------------------------------------------------------

  dynamic _customers(String method, List<String> segs, Map<String, String> q, Map<String, dynamic> body) {
    if (segs.length == 1) {
      if (method == 'POST') {
        final phone = _normalizePhone(body['phone'] as String? ?? '');
        final existing = customers.cast<Map<String, dynamic>?>().firstWhere((c) => c!['phoneE164'] == phone, orElse: () => null);
        if (existing != null && body['confirmDistinct'] != true) {
          throw ApiException(409, 'POSSIBLE_DUPLICATE', 'A customer with this phone number already exists.', {
            'candidates': [_customerSummaryJson(existing)],
          });
        }
        final n = customers.length + 1;
        final newCust = {
          'id': 'cust-${n.toString().padLeft(4, '0')}-${_seq++}',
          'customerNo': n,
          'fullName': body['fullName'],
          'phoneE164': phone,
          'email': body['email'],
          'dateOfBirth': body['dateOfBirth'],
          'notes': body['notes'],
          'status': 'ACTIVE',
          'registeredAt': _nowIso,
          'customerCode': 'LS-C${n.toString().padLeft(6, '0')}',
          'photoId': null,
          'emergencyContacts': body['emergencyContact'] != null ? [{'id': _id('ec'), ...(body['emergencyContact'] as Map<String, dynamic>)}] : <Map<String, dynamic>>[],
          'visitCount': 0,
          'lastVisitAt': null,
          'totalSkatingSeconds': 0,
          'totalSpentMinor': 0,
          'equipmentIssuedCount': 0,
          'waiverAccepted': false,
          'waiverAcceptedAt': null,
        };
        customers.add(newCust);
        return {'id': newCust['id'], 'customerCode': newCust['customerCode'], 'phone': phone};
      }
      // GET (search or list)
      final qp = q['q'];
      if (qp != null && qp.isNotEmpty) {
        final norm = _normalizePhone(qp);
        final matches = customers.where((c) {
          final name = (c['fullName'] as String).toLowerCase();
          final phone = c['phoneE164'] as String;
          final code = c['customerCode'] as String;
          return name.contains(qp.toLowerCase()) || phone.contains(qp.replaceAll(RegExp(r'[^0-9]'), '')) || code.toLowerCase().contains(qp.toLowerCase()) || phone == norm;
        }).map(_customerSummaryJson).toList();
        return {'customers': matches, 'normalizedPhone': norm};
      }
      return {'customers': customers.map(_customerSummaryJson).toList()};
    }

    final id = segs[1];
    final c = _findCustomer(id);
    if (c == null) throw ApiException(404, 'NOT_FOUND', 'Customer not found.');

    if (segs.length == 2) {
      if (method == 'PATCH') {
        body.forEach((k, v) {
          if (k != 'confirmDistinct') c[k] = v;
        });
        return {'id': c['id']};
      }
      return _customerProfileJson(c);
    }

    if (segs.length == 3 && segs[2] == 'history') {
      final rows = sessions.where((s) => s['customerId'] == id).map((s) {
        return {
          'visitId': s['visitId'],
          'visitNumber': visits.indexWhere((v) => v['id'] == s['visitId']) + 1,
          'localDate': _fmtDate(DateTime.parse((s['startedAt'] ?? s['createdAt'] ?? _nowIso) as String)),
          'visitStatus': 'COMPLETED',
          'createdAt': s['startedAt'] ?? _nowIso,
          'sessionId': s['id'],
          'sessionStatus': _liveStatusFor(s),
          'productName': s['productName'],
          'startedAt': s['startedAt'],
          'scheduledEndAt': s['scheduledEndAt'],
          'actualEndAt': s['actualEndAt'],
          'currentDurationSeconds': s['startedAt'] != null ? DateTime.now().difference(DateTime.parse(s['startedAt'] as String)).inSeconds : null,
          'paidMinor': s['paidMinor'],
          'equipment': _equipmentCodesFor(s['id'] as String),
        };
      }).toList();
      return {'history': rows};
    }

    if (segs.length == 3 && segs[2] == 'waiver') {
      final isMinor = (_customerProfileJson(c)['isMinor'] as bool);
      return {
        'required': settings['waiverRequired'],
        'currentVersionId': waiverVersions.first['id'],
        'currentVersion': waiverVersions.first['version'],
        'isMinor': isMinor,
        'accepted': c['waiverAccepted'],
        'acceptedAt': c['waiverAcceptedAt'],
      };
    }

    if (segs.length == 3 && segs[2] == 'waiver-acceptance') {
      c['waiverAccepted'] = true;
      c['waiverAcceptedAt'] = _nowIso;
      return {'id': _id('waiver-accept'), 'acceptedAt': _nowIso, 'waiverVersion': waiverVersions.first['version']};
    }

    if (segs.length == 3 && segs[2] == 'erase') {
      final activeSession = sessions.cast<Map<String, dynamic>?>().firstWhere((s) => s!['customerId'] == id && _liveStatuses.contains(_liveStatusFor(s)), orElse: () => null);
      if (activeSession != null) throw ApiException(409, 'CUSTOMER_ACTIVE', 'This customer is currently skating — end their session before erasing their data.');
      c['fullName'] = 'Erased customer';
      c['phoneE164'] = '+000000000000';
      c['email'] = null;
      c['notes'] = null;
      c['photoId'] = null;
      return {'id': c['id'], 'photosDeleted': 0, 'retained': ['visits', 'sessions', 'payments', 'audit_logs']};
    }

    if (segs.length == 3 && segs[2] == 'photos') return {'id': _id('photo'), 'customerId': id};

    throw ApiException(404, 'NOT_FOUND', 'No demo handler for customers/${segs.skip(1).join('/')}');
  }

  Map<String, dynamic> _customerSummaryJson(Map<String, dynamic> c) => {
        'id': c['id'],
        'customerCode': c['customerCode'],
        'fullName': c['fullName'],
        'phoneE164': c['phoneE164'],
        'status': c['status'],
        'lastVisitAt': c['lastVisitAt'],
        'visitCount': c['visitCount'],
        'photoId': c['photoId'],
      };

  String _normalizePhone(String raw) {
    var digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.startsWith('2519') || digits.startsWith('2517')) digits = digits.substring(3);
    if (digits.startsWith('09') || digits.startsWith('07')) digits = digits.substring(1);
    if (digits.startsWith('9') || digits.startsWith('7')) return '+251$digits';
    return '+251${digits.padLeft(9, '0')}';
  }

  // ---- waivers -------------------------------------------------------------------------------

  dynamic _waivers(String method, List<String> segs, Map<String, dynamic> body) {
    if (segs.length == 2 && segs[1] == 'current') return {'waiver': waiverVersions.first};
    if (segs.length == 2 && segs[1] == 'versions') {
      if (method == 'POST') {
        final v = {
          'id': _id('waiver'),
          'version': (waiverVersions.first['version'] as int) + 1,
          'title': body['title'],
          'body': body['body'],
          'language': body['language'] ?? 'en',
          'isCurrent': true,
          'publishedAt': _nowIso,
        };
        for (final w in waiverVersions) {
          w['isCurrent'] = false;
        }
        waiverVersions.insert(0, v);
        return {'id': v['id'], 'version': v['version']};
      }
      return {
        'versions': waiverVersions.map((w) => {'id': w['id'], 'version': w['version'], 'title': w['title'], 'isCurrent': w['isCurrent'], 'publishedAt': w['publishedAt']}).toList(),
      };
    }
    throw ApiException(404, 'NOT_FOUND', 'No demo handler for waivers/${segs.skip(1).join('/')}');
  }

  // ---- visits ---------------------------------------------------------------------------------

  dynamic _visits(String method, List<String> segs, Map<String, String> q, Map<String, dynamic> body) {
    if (segs.length == 1) {
      if (method == 'POST') {
        final customerId = body['customerId'] as String;
        final visitId = _id('visit');
        visits.add({'id': visitId, 'visitNumber': visits.length + 1, 'customerId': customerId, 'status': 'OPEN', 'createdAt': _nowIso});
        return {'id': visitId, 'visitNumber': visits.length, 'reused': false};
      }
      final date = q['date'] ?? _fmtDate(DateTime.now());
      final filter = q['filter'] ?? 'all';
      final rows = <Map<String, dynamic>>[];
      for (final v in visits) {
        if (_fmtDate(DateTime.parse(v['createdAt'] as String)) != date) continue;
        final s = sessions.cast<Map<String, dynamic>?>().firstWhere((s) => s!['visitId'] == v['id'], orElse: () => null);
        final cust = _findCustomer(v['customerId'] as String);
        final status = s == null ? 'OPEN' : _liveStatusFor(s);
        if (filter == 'completed' && status != 'COMPLETED') continue;
        if (filter == 'active' && !_liveStatuses.contains(status)) continue;
        if (filter == 'cancelled' && status != 'CANCELLED') continue;
        if (filter == 'expired' && status != 'EXPIRED') continue;
        rows.add({
          'visitId': v['id'],
          'visitNumber': v['visitNumber'],
          'visitStatus': status,
          'createdAt': v['createdAt'],
          'customerId': v['customerId'],
          'fullName': cust?['fullName'],
          'phoneE164': cust?['phoneE164'],
          'photoId': cust?['photoId'],
          'sessionId': s?['id'],
          'sessionStatus': s == null ? null : status,
          'productName': s?['productName'],
          'startedAt': s?['startedAt'],
          'scheduledEndAt': s?['scheduledEndAt'],
          'actualEndAt': s?['actualEndAt'],
          'currentDurationSeconds': s?['startedAt'] != null ? DateTime.now().difference(DateTime.parse(s!['startedAt'] as String)).inSeconds : null,
          'paidMinor': s?['paidMinor'],
          'staffName': 'Demo Front Desk (Dawit)',
          'equipment': s == null ? '' : _equipmentCodesFor(s['id'] as String),
          'hasIncident': incidents.any((i) => i['sessionId'] == s?['id']),
        });
      }
      return {'date': date, 'timezone': 'Africa/Addis_Ababa', 'visits': rows};
    }
    if (segs.length == 2) {
      final v = visits.cast<Map<String, dynamic>?>().firstWhere((v) => v!['id'] == segs[1], orElse: () => null);
      if (v == null) throw ApiException(404, 'NOT_FOUND', 'Visit not found.');
      final s = sessions.cast<Map<String, dynamic>?>().firstWhere((s) => s!['visitId'] == v['id'], orElse: () => null);
      final cust = _findCustomer(v['customerId'] as String);
      final pays = payments.where((p) => p['visitId'] == v['id']).toList();
      return {
        'visit': {'id': v['id'], 'visitNumber': v['visitNumber'], 'customerId': v['customerId'], 'fullName': cust?['fullName'], 'phoneE164': cust?['phoneE164'], 'photoId': cust?['photoId'], 'customerCode': cust?['customerCode'], 'visitStatus': s == null ? 'OPEN' : _liveStatusFor(s), 'createdAt': v['createdAt']},
        'sessions': s == null ? <Map<String, dynamic>>[] : [_sessionRowJson(s)],
        'payments': pays,
        'equipment': s == null ? <Map<String, dynamic>>[] : equipment.where((e) => e['issuedSessionId'] == s['id']).toList(),
        'timeline': s == null ? <Map<String, dynamic>>[] : _sessionEvents(s),
      };
    }
    throw ApiException(404, 'NOT_FOUND', 'No demo handler for visits/${segs.skip(1).join('/')}');
  }

  // ---- sessions -------------------------------------------------------------------------------

  dynamic _sessions(String method, List<String> segs, Map<String, String> q, Map<String, dynamic> body) {
    if (segs.length == 1) {
      if (method == 'POST') {
        final visitId = body['visitId'] as String;
        final v = visits.firstWhere((v) => v['id'] == visitId);
        final cust = _findCustomer(v['customerId'] as String)!;
        final rule = pricing.firstWhere((p) => p['id'] == body['pricingRuleId']);
        final discount = (body['discountMinor'] as num?)?.toInt() ?? 0;
        final sessionId = _id('sess');
        final price = rule['priceMinor'] as int;
        final status = (price - discount) <= 0 ? 'READY' : 'PAYMENT_PENDING';
        sessions.add({
          'id': sessionId,
          'visitId': visitId,
          'customerId': cust['id'],
          'customerName': cust['fullName'],
          'photoId': cust['photoId'],
          'status': status,
          'productName': rule['name'],
          'priceMinor': price,
          'discountMinor': discount,
          'currency': 'ETB',
          'wristband': body['wristband'],
          'startedAt': null,
          'scheduledEndAt': null,
          '_durationMinutes': rule['durationMinutes'],
          'pausedAt': null,
          'pauseCountsTowardTime': settings['pause']['countsTowardTime'],
          'paidMinor': 0,
          'createdAt': _nowIso,
          'extensionLog': <Map<String, dynamic>>[],
        });
        return {'id': sessionId, 'status': status};
      }
      final group = q['group'] ?? 'live';
      Iterable<Map<String, dynamic>> filtered;
      if (group == 'waiting') {
        filtered = sessions.where((s) => _waitingStatuses.contains(s['status']));
      } else if (group == 'expiring') {
        filtered = sessions.where((s) => {'EXPIRING', 'EXPIRED'}.contains(_liveStatusFor(s)));
      } else {
        filtered = sessions.where((s) => _liveStatuses.contains(_liveStatusFor(s)));
      }
      return {'serverTime': _nowIso, 'sessions': filtered.map(_sessionRowJson).toList()};
    }

    final id = segs[1];
    final s = _findSession(id);
    if (s == null) throw ApiException(404, 'NOT_FOUND', 'Session not found.');

    if (segs.length == 2) return _sessionDetailJson(s);

    final action = segs[2];
    switch (action) {
      case 'start':
        s['status'] = 'ACTIVE';
        final startedAt = DateTime.now();
        s['startedAt'] = startedAt.toUtc().toIso8601String();
        s['scheduledEndAt'] = startedAt.add(Duration(minutes: s['_durationMinutes'] as int)).toUtc().toIso8601String();
        for (final eqId in (body['equipmentIds'] as List? ?? const [])) {
          final eq = _findEquipment(eqId as String);
          if (eq != null) {
            eq['status'] = 'ISSUED';
            eq['issuedSessionId'] = s['id'];
            eq['issuedAt'] = _nowIso;
            eq['issuedTo'] = s['customerName'];
          }
        }
        return {
          ..._sessionRowJson(s),
          'equipment': (body['equipmentIds'] as List? ?? const []).map((id) => {'id': id, 'code': _findEquipment(id as String)?['code']}).toList(),
          'occupancy': sessions.where((s) => _liveStatuses.contains(_liveStatusFor(s))).length,
          'maxCapacity': maxCapacity,
        };
      case 'pause':
        s['status'] = 'PAUSED';
        s['pausedAt'] = _nowIso;
        return _sessionRowJson(s);
      case 'resume':
        final pausedAt = DateTime.parse(s['pausedAt'] as String);
        if (s['pauseCountsTowardTime'] != true) {
          final pausedFor = DateTime.now().difference(pausedAt);
          final end = DateTime.parse(s['scheduledEndAt'] as String).add(pausedFor);
          s['scheduledEndAt'] = end.toUtc().toIso8601String();
        }
        s['status'] = 'ACTIVE';
        s['pausedAt'] = null;
        return _sessionRowJson(s);
      case 'extend':
        final minutes = (body['minutes'] as num).toInt();
        final currentEnd = DateTime.parse(s['scheduledEndAt'] as String);
        final newEnd = currentEnd.add(Duration(minutes: minutes));
        s['scheduledEndAt'] = newEnd.toUtc().toIso8601String();
        final rule = pricing.cast<Map<String, dynamic>?>().firstWhere((p) => p!['kind'] == 'EXTENSION' && p['durationMinutes'] == minutes, orElse: () => null);
        final price = (body['complimentary'] == true) ? 0 : (rule?['priceMinor'] as int? ?? 0);
        (s['extensionLog'] as List<Map<String, dynamic>>).add({'addedSeconds': minutes * 60, 'newEndAt': s['scheduledEndAt'], 'priceMinor': price, 'reason': body['reason'], 'createdAt': _nowIso});
        if (price > 0) s['paidMinor'] = (s['paidMinor'] as int) + price;
        return _sessionRowJson(s);
      case 'end':
        final now = DateTime.now();
        final scheduledEnd = s['scheduledEndAt'] != null ? DateTime.parse(s['scheduledEndAt'] as String) : now;
        final early = now.isBefore(scheduledEnd.subtract(Duration(seconds: settings['earlyExitGraceSeconds'] as int)));
        s['status'] = early ? 'EARLY_EXIT' : 'COMPLETED';
        s['actualEndAt'] = now.toUtc().toIso8601String();
        final outstanding = <String>[];
        for (final e in equipment.where((e) => e['issuedSessionId'] == s['id'])) {
          outstanding.add(e['code'] as String);
        }
        return {..._sessionRowJson(s), 'equipmentOutstanding': outstanding, 'visitCompleted': true, 'occupancy': sessions.where((s) => _liveStatuses.contains(_liveStatusFor(s))).length};
      case 'cancel':
        s['status'] = 'CANCELLED';
        s['actualEndAt'] = _nowIso;
        return {..._sessionRowJson(s), 'refundDueMinor': 0};
      case 'correct':
        if (body['action'] == 'REOPEN') {
          s['status'] = 'ACTIVE';
          s['actualEndAt'] = null;
        } else if (body['action'] == 'CHANGE_DURATION') {
          final start = DateTime.parse(s['startedAt'] as String);
          s['scheduledEndAt'] = start.add(Duration(minutes: (body['newDurationMinutes'] as num).toInt())).toUtc().toIso8601String();
        }
        return _sessionRowJson(s);
    }
    throw ApiException(404, 'NOT_FOUND', 'No demo handler for sessions/$id/$action');
  }

  // ---- payments -------------------------------------------------------------------------------

  dynamic _payments(String method, List<String> segs, Map<String, dynamic> body) {
    if (segs.length == 1 && method == 'POST') {
      final sessionId = body['sessionId'] as String;
      final s = _findSession(sessionId)!;
      final amount = (body['amountMinor'] as num).toInt();
      s['paidMinor'] = (s['paidMinor'] as int) + amount;
      if ((s['paidMinor'] as int) >= (s['priceMinor'] as int) - (s['discountMinor'] as int)) s['status'] = 'READY';
      final p = {
        'id': _id('pay'),
        'sessionId': sessionId,
        'visitId': s['visitId'],
        'customerId': s['customerId'],
        'customerName': s['customerName'],
        'amountMinor': amount,
        'refundedMinor': 0,
        'currency': 'ETB',
        'method': body['method'],
        'status': body['confirmed'] == false ? 'PENDING' : 'PAID',
        'purpose': 'SESSION',
        'providerReference': body['reference'],
        'reference': body['reference'],
        'note': null,
        'staffName': 'Demo Front Desk (Dawit)',
        'createdAt': _nowIso,
        'canRefund': true,
      };
      payments.add(p);
      return p;
    }
    if (segs.length == 1) {
      return {'payments': payments};
    }
    final id = segs[1];
    final p = payments.cast<Map<String, dynamic>?>().firstWhere((p) => p!['id'] == id, orElse: () => null);
    if (p == null) throw ApiException(404, 'NOT_FOUND', 'Payment not found.');
    if (segs.length == 2) return {...p, 'transactions': <Map<String, dynamic>>[], 'events': <Map<String, dynamic>>[], 'refunds': <Map<String, dynamic>>[], 'canRefund': (p['amountMinor'] as int) > (p['refundedMinor'] as int)};
    if (segs[2] == 'refund') {
      final amt = (body['amountMinor'] as num?)?.toInt() ?? ((p['amountMinor'] as int) - (p['refundedMinor'] as int));
      p['refundedMinor'] = (p['refundedMinor'] as int) + amt;
      return {'refundId': _id('refund'), 'paymentId': id, 'status': p['refundedMinor'] == p['amountMinor'] ? 'REFUNDED' : 'PARTIALLY_REFUNDED', 'refundedMinor': p['refundedMinor'], 'refundMinor': amt, 'remainingRefundableMinor': (p['amountMinor'] as int) - (p['refundedMinor'] as int)};
    }
    if (segs[2] == 'confirm' || segs[2] == 'cancel' || segs[2] == 'fail') {
      p['status'] = segs[2] == 'confirm' ? 'PAID' : segs[2] == 'cancel' ? 'CANCELLED' : 'FAILED';
      return p;
    }
    throw ApiException(404, 'NOT_FOUND', 'No demo handler for payments/$id/${segs.skip(2).join('/')}');
  }

  // ---- equipment ------------------------------------------------------------------------------

  dynamic _equipment(String method, List<String> segs, Map<String, dynamic> body) {
    if (segs.length == 1) {
      if (method == 'POST') {
        final item = {
          'id': _id('eq'),
          'code': body['code'],
          'category': body['category'] ?? 'SKATE',
          'size': body['size'],
          'condition': body['condition'] ?? 'NEW',
          'location': body['location'],
          'status': 'AVAILABLE',
          'issuedSessionId': null,
          'issuedAt': null,
          'issuedTo': null,
          'issuedUntil': null,
        };
        equipment.add(item);
        return item;
      }
      final summary = <String, int>{};
      for (final e in equipment) {
        summary[e['status'] as String] = (summary[e['status'] as String] ?? 0) + 1;
      }
      return {'items': equipment, 'summary': summary};
    }
    final id = segs[1];
    final e = _findEquipment(id);
    if (e == null) throw ApiException(404, 'NOT_FOUND', 'Equipment not found.');
    if (segs.length == 2) {
      return {
        ...e,
        'events': <Map<String, dynamic>>[
          {'eventType': 'CREATED', 'occurredAt': _nowIso, 'actorName': 'Demo Admin'},
        ],
        'maintenance': (e['maintenance'] as List<Map<String, dynamic>>? ?? const []),
        'usage': {'timesIssued': e['_timesIssued'] ?? 0, 'timesRepaired': e['_timesRepaired'] ?? 0},
      };
    }
    final action = segs[2];
    switch (action) {
      case 'assign':
        e['status'] = 'ISSUED';
        e['issuedSessionId'] = body['sessionId'];
        final s = _findSession(body['sessionId'] as String);
        e['issuedTo'] = s?['customerName'];
        e['issuedAt'] = _nowIso;
        e['_timesIssued'] = (e['_timesIssued'] as int? ?? 0) + 1;
        return {'equipmentId': id, 'code': e['code'], 'sessionId': body['sessionId']};
      case 'return':
        final damaged = body['condition'] == 'DAMAGED';
        e['status'] = damaged ? 'DAMAGED' : 'RETURNED';
        e['issuedSessionId'] = null;
        e['issuedTo'] = null;
        e['_returnedAt'] = _nowIso;
        if (damaged) {
          (e['maintenance'] ??= <Map<String, dynamic>>[]) as List<Map<String, dynamic>>;
          (e['maintenance'] as List<Map<String, dynamic>>).add({'id': _id('maint'), 'issue': body['note'] ?? 'Returned damaged', 'status': 'OPEN', 'reportedAt': _nowIso, 'startedAt': null, 'completedAt': null, 'resolution': null, 'hasPhoto': false});
        }
        return {'equipmentId': id, 'code': e['code'], 'status': e['status'], 'visitCompleted': false};
      case 'inspect':
        e['status'] = 'AVAILABLE';
        return {'equipmentId': id, 'status': 'AVAILABLE'};
      case 'damage':
        e['status'] = 'MAINTENANCE';
        (e['maintenance'] ??= <Map<String, dynamic>>[]) as List<Map<String, dynamic>>;
        final rec = {'id': _id('maint'), 'issue': body['issue'], 'status': 'OPEN', 'reportedAt': _nowIso, 'startedAt': body['startMaintenance'] == true ? _nowIso : null, 'completedAt': null, 'resolution': null, 'hasPhoto': false};
        (e['maintenance'] as List<Map<String, dynamic>>).add(rec);
        return {'equipmentId': id, 'status': 'MAINTENANCE', 'maintenanceRecordId': rec['id']};
      case 'maintenance':
        if (segs.length >= 4 && segs[3] == 'start') {
          e['status'] = 'MAINTENANCE';
          return {'equipmentId': id, 'status': 'MAINTENANCE'};
        }
        if (segs.length >= 4 && segs[3] == 'complete') {
          e['status'] = 'AVAILABLE';
          e['_timesRepaired'] = (e['_timesRepaired'] as int? ?? 0) + 1;
          final maint = (e['maintenance'] as List<Map<String, dynamic>>?);
          if (maint != null && maint.isNotEmpty) {
            maint.last['status'] = 'RESOLVED';
            maint.last['completedAt'] = _nowIso;
            maint.last['resolution'] = body['resolution'];
          }
          return {'equipmentId': id, 'status': 'AVAILABLE'};
        }
        if (segs.length >= 4 && segs[3] == 'photo') return {'id': _id('photo')};
        break;
      case 'out-of-service':
        e['status'] = 'OUT_OF_SERVICE';
        return {'equipmentId': id, 'status': 'OUT_OF_SERVICE'};
    }
    throw ApiException(404, 'NOT_FOUND', 'No demo handler for equipment/$id/${segs.skip(2).join('/')}');
  }

  // ---- incidents ------------------------------------------------------------------------------

  dynamic _incidents(String method, List<String> segs, Map<String, String> q, Map<String, dynamic> body) {
    if (segs.length == 1) {
      if (method == 'POST') {
        final n = incidents.length + 1;
        final incidentCustomerId = body['customerId'] as String?;
        final incidentCustomer = incidentCustomerId == null ? null : _findCustomer(incidentCustomerId);
        final rec = {
          'id': _id('inc'),
          'incidentNumber': 'INC-${_dateStr(DateTime.now())}-${n.toString().padLeft(3, '0')}',
          'customerId': body['customerId'],
          'customerName': incidentCustomer?['fullName'],
          'sessionId': body['sessionId'],
          'occurredAt': body['occurredAt'] ?? _nowIso,
          'incidentType': body['incidentType'],
          'severity': body['severity'],
          'status': 'REPORTED',
          'location': body['location'],
          'description': body['description'],
          'actionTaken': body['actionTaken'],
          'reportedByName': 'Demo Front Desk (Dawit)',
          'managerNotified': body['managerNotified'] ?? false,
        };
        incidents.add(rec);
        return rec;
      }
      final openOnly = q['open'] == 'true';
      final rows = incidents.where((i) => !openOnly || i['status'] != 'CLOSED').toList();
      return {'redacted': false, 'incidents': rows};
    }
    final id = segs[1];
    final inc = _findIncident(id);
    if (inc == null) throw ApiException(404, 'NOT_FOUND', 'Incident not found.');
    if (segs.length == 2) {
      return {
        'redacted': false,
        'incident': inc,
        'events': <Map<String, dynamic>>[
          {'eventType': 'INCIDENT_REPORTED', 'occurredAt': inc['occurredAt'], 'actorName': inc['reportedByName']},
          if (inc['status'] != 'REPORTED') {'eventType': 'INCIDENT_UPDATED', 'occurredAt': _nowIso, 'actorName': 'Demo Manager (Hana)'},
        ],
        'attachments': incidentAttachments.where((a) => a['incidentId'] == id).toList(),
      };
    }
    if (segs[2] == 'transition') {
      inc['status'] = body['to'];
      return {'id': id, 'status': inc['status']};
    }
    if (segs[2] == 'attachments') {
      final att = {'id': _id('att'), 'incidentId': id, 'mimeType': 'image/jpeg', 'sizeBytes': 12345, 'uploadedAt': _nowIso};
      incidentAttachments.add(att);
      return {'id': att['id']};
    }
    throw ApiException(404, 'NOT_FOUND', 'No demo handler for incidents/$id/${segs.skip(2).join('/')}');
  }

  // ---- dashboard ------------------------------------------------------------------------------

  Map<String, dynamic> _dashboard() {
    final live = sessions.where((s) => _liveStatuses.contains(_liveStatusFor(s))).toList();
    final waiting = sessions.where((s) => _waitingStatuses.contains(s['status'])).length;
    final today = _fmtDate(DateTime.now());
    final visitorsToday = visits.where((v) => _fmtDate(DateTime.parse(v['createdAt'] as String)) == today).length;
    final revenueToday = payments.where((p) => _fmtDate(DateTime.parse(p['createdAt'] as String)) == today && p['status'] == 'PAID').fold<int>(0, (a, p) => a + (p['amountMinor'] as int) - (p['refundedMinor'] as int));
    int normal = 0, expiring = 0, expired = 0;
    for (final s in live) {
      final lvl = _liveStatusFor(s);
      if (lvl == 'EXPIRED') {
        expired++;
      } else if (lvl == 'EXPIRING') {
        expiring++;
      } else {
        normal++;
      }
    }
    final equipmentOut = equipment.where((e) => e['status'] == 'ISSUED').length;
    final equipmentNeedsAttention = equipment.where((e) => ['DAMAGED', 'MAINTENANCE'].contains(e['status'])).length;
    return {
      'serverTime': _nowIso,
      'localDate': today,
      'timezone': 'Africa/Addis_Ababa',
      'currency': 'ETB',
      'capacity': {'occupancy': live.length, 'max': maxCapacity, 'available': maxCapacity - live.length, 'full': live.length >= maxCapacity},
      'today': {'visitors': visitorsToday, 'revenueMinor': revenueToday},
      'rink': {'normal': normal, 'expiring': expiring, 'expired': expired},
      'waiting': waiting,
      'awaitingPayment': sessions.where((s) => s['status'] == 'PAYMENT_PENDING').length,
      'equipment': {'out': equipmentOut, 'needsAttention': equipmentNeedsAttention},
      'openIncidents': incidents.where((i) => i['status'] != 'CLOSED').length,
      'alerts': expired > 0
          ? [
              {'id': 'alert-expired', 'type': 'SESSION_EXPIRED', 'severity': 'WARNING', 'title': '$expired session(s) have run out of time', 'body': null, 'entityType': 'session', 'entityId': null, 'createdAt': _nowIso},
            ]
          : <Map<String, dynamic>>[],
      'liveSessions': live.map(_sessionRowJson).toList(),
    };
  }

  // ---- reports --------------------------------------------------------------------------------

  Map<String, dynamic> _reports(List<String> segs, Map<String, String> q) {
    if (segs.length == 2 && segs[1] == 'daily') {
      final date = q['date'] ?? _fmtDate(DateTime.now());
      final dayPayments = payments.where((p) => _fmtDate(DateTime.parse(p['createdAt'] as String)) == date && p['status'] == 'PAID');
      final charges = dayPayments.fold<int>(0, (a, p) => a + (p['amountMinor'] as int));
      final refunds = dayPayments.fold<int>(0, (a, p) => a + (p['refundedMinor'] as int));
      final byMethod = <String, Map<String, dynamic>>{};
      for (final p in dayPayments) {
        final m = p['method'] as String;
        final e = byMethod.putIfAbsent(m, () => {'method': m, 'chargesMinor': 0, 'refundsMinor': 0, 'count': 0});
        e['chargesMinor'] = (e['chargesMinor'] as int) + (p['amountMinor'] as int);
        e['refundsMinor'] = (e['refundsMinor'] as int) + (p['refundedMinor'] as int);
        e['count'] = (e['count'] as int) + 1;
      }
      final completed = sessions.where((s) => s['status'] == 'COMPLETED' || s['status'] == 'EARLY_EXIT').length;
      final active = sessions.where((s) => _liveStatuses.contains(_liveStatusFor(s))).length;
      final hourly = <int, int>{};
      for (final s in sessions.where((s) => s['startedAt'] != null)) {
        final h = DateTime.parse(s['startedAt'] as String).hour;
        hourly[h] = (hourly[h] ?? 0) + 1;
      }
      return {
        'date': date,
        'timezone': 'Africa/Addis_Ababa',
        'currency': 'ETB',
        'visitors': visits.where((v) => _fmtDate(DateTime.parse(v['createdAt'] as String)) == date).length,
        'newCustomers': 1,
        'sessions': {'started': sessions.length, 'completed': completed, 'earlyExits': sessions.where((s) => s['status'] == 'EARLY_EXIT').length, 'active': active, 'cancelled': sessions.where((s) => s['status'] == 'CANCELLED').length, 'noShows': 0, 'extensions': sessions.fold<int>(0, (a, s) => a + ((s['extensionLog'] as List?)?.length ?? 0))},
        'revenue': {'chargesMinor': charges, 'refundsMinor': refunds, 'netMinor': charges - refunds, 'discountsMinor': 0, 'byMethod': byMethod.values.toList()},
        'equipment': {'issues': equipment.where((e) => e['status'] == 'ISSUED').length, 'distinctUnits': equipment.length},
        'incidents': {'total': incidents.length, 'bySeverity': {for (final i in incidents) (i['severity'] as String): (incidents.where((x) => x['severity'] == i['severity']).length)}},
        'averageSessionSeconds': 3200,
        'capacityUtilizationPercent': (active / maxCapacity * 100),
        'maxCapacity': maxCapacity,
        'hourlyStarts': hourly.entries.map((e) => {'hour': e.key, 'sessions': e.value}).toList(),
      };
    }
    if (segs.length == 2 && segs[1] == 'range') {
      final from = q['from'] ?? _fmtDate(DateTime.now().subtract(const Duration(days: 7)));
      final to = q['to'] ?? _fmtDate(DateTime.now());
      final fromDate = DateTime.parse(from);
      final toDate = DateTime.parse(to);
      final rows = <Map<String, dynamic>>[];
      for (var d = fromDate; !d.isAfter(toDate); d = d.add(const Duration(days: 1))) {
        final isToday = _fmtDate(d) == _fmtDate(DateTime.now());
        rows.add({
          'period': _fmtDate(d),
          'sessionsStarted': isToday ? sessions.length : 8 + _rng.nextInt(10),
          'sessionsCompleted': isToday ? sessions.where((s) => s['status'] == 'COMPLETED').length : 7 + _rng.nextInt(8),
          'uniqueCustomers': isToday ? customers.length : 6 + _rng.nextInt(8),
          'revenueMinor': isToday ? payments.fold<int>(0, (a, p) => a + (p['amountMinor'] as int)) : (150000 + _rng.nextInt(200000)),
          'refundsMinor': 0,
          'discountsMinor': 0,
          'averageSessionSeconds': 3000 + _rng.nextInt(1200),
        });
      }
      final totals = {
        'sessionsStarted': rows.fold<int>(0, (a, r) => a + (r['sessionsStarted'] as int)),
        'sessionsCompleted': rows.fold<int>(0, (a, r) => a + (r['sessionsCompleted'] as int)),
        'revenueMinor': rows.fold<int>(0, (a, r) => a + (r['revenueMinor'] as int)),
        'refundsMinor': 0,
        'discountsMinor': 0,
      };
      return {'from': from, 'to': to, 'currency': 'ETB', 'rows': rows, 'totals': totals};
    }
    throw ApiException(404, 'NOT_FOUND', 'No demo handler for reports/${segs.skip(1).join('/')}');
  }

  // ---- audit, devices, settings, pricing, staff, day-close -----------------------------------

  Map<String, dynamic> _audit(Map<String, String> q) {
    final prefix = q['action'];
    final rows = auditLog.where((e) => prefix == null || prefix.isEmpty || (e['action'] as String).startsWith(prefix)).toList();
    return {'entries': rows};
  }

  dynamic _devices(String method, List<String> segs, Map<String, dynamic> body) {
    if (segs.length == 1) {
      if (method == 'POST') {
        final d = {'id': _id('dev'), 'name': body['name'], 'deviceType': body['deviceType'], 'status': 'ACTIVE', 'lastSeenAt': _nowIso, 'registeredAt': _nowIso};
        devices.add(d);
        return d;
      }
      return {'devices': devices};
    }
    final d = devices.cast<Map<String, dynamic>?>().firstWhere((d) => d!['id'] == segs[1], orElse: () => null);
    if (d == null) throw ApiException(404, 'NOT_FOUND', 'Device not found.');
    body.forEach((k, v) => d[k] = v);
    return {'id': d['id']};
  }

  dynamic _pricing(String method, List<String> segs, Map<String, dynamic> body) {
    if (segs.length == 1) {
      if (method == 'POST') {
        final rule = {'id': _id('price'), 'kind': body['kind'], 'name': body['name'], 'durationMinutes': body['durationMinutes'], 'priceMinor': body['priceMinor'], 'currency': 'ETB', 'dayType': body['dayType'] ?? 'ANY', 'customerType': body['customerType'] ?? 'ANY', 'active': body['active'] ?? true, 'sortOrder': pricing.length};
        pricing.add(rule);
        return rule;
      }
      return {'rules': pricing};
    }
    final rule = pricing.cast<Map<String, dynamic>?>().firstWhere((p) => p!['id'] == segs[1], orElse: () => null);
    if (rule == null) throw ApiException(404, 'NOT_FOUND', 'Pricing rule not found.');
    body.forEach((k, v) => rule[k] = v);
    return {'id': rule['id']};
  }

  dynamic _staff(String method, List<String> segs, Map<String, dynamic> body) {
    if (segs.length == 1) {
      if (method == 'POST') {
        final s = {'id': _id('staff'), 'email': body['email'], 'fullName': body['fullName'], 'status': 'ACTIVE', 'lastLoginAt': null, 'roleId': body['roleId'], 'roleCode': 'FRONT_DESK', 'roleName': 'Front Desk', 'phone': body['phone'], 'employeeNo': body['employeeNo']};
        staff.add(s);
        return {'id': s['id']};
      }
      return {'staff': staff};
    }
    if (segs.length == 2) {
      final s = staff.cast<Map<String, dynamic>?>().firstWhere((s) => s!['id'] == segs[1], orElse: () => null);
      if (s == null) throw ApiException(404, 'NOT_FOUND', 'Staff member not found.');
      body.forEach((k, v) => s[k] = v);
      return {'id': s['id'], 'role': s['roleCode']};
    }
    if (segs.length == 3 && segs[2] == 'reset-password') return {'id': segs[1]};
    throw ApiException(404, 'NOT_FOUND', 'No demo handler for staff/${segs.skip(1).join('/')}');
  }

  Map<String, dynamic> _dayClosePreview(Map<String, String> q) {
    final date = q['date'] ?? _fmtDate(DateTime.now());
    final activeSessions = sessions.where((s) => _liveStatuses.contains(_liveStatusFor(s))).length;
    final unreturned = equipment.where((e) => e['status'] == 'ISSUED').length;
    final unresolvedIncidents = incidents.where((i) => i['status'] != 'CLOSED').length;
    final unpaid = sessions.where((s) => s['status'] == 'PAYMENT_PENDING').length;
    final expected = payments.where((p) => _fmtDate(DateTime.parse(p['createdAt'] as String)) == date && p['status'] == 'PAID' && p['method'] == 'CASH').fold<int>(0, (a, p) => a + (p['amountMinor'] as int));
    final blockers = <String>[
      if (activeSessions > 0) '$activeSessions active session(s)',
      if (unreturned > 0) '$unreturned unreturned item(s)',
      if (unpaid > 0) '$unpaid unpaid session(s)',
    ];
    final warnings = <String>[if (unresolvedIncidents > 0) '$unresolvedIncidents open incident(s)'];
    final alreadyClosed = dayCloses.any((c) => c['localDate'] == date);
    return {
      'date': date,
      'checks': {'activeSessions': activeSessions, 'unreturnedSkates': unreturned, 'unresolvedIncidents': unresolvedIncidents, 'unpaidSessions': unpaid, 'pendingPayments': unpaid},
      'expectedCashMinor': expected,
      'blockers': blockers,
      'warnings': warnings,
      'alreadyClosed': alreadyClosed,
      'closedAt': alreadyClosed ? dayCloses.firstWhere((c) => c['localDate'] == date)['closedAt'] : null,
    };
  }

  Map<String, dynamic> _closeDay(Map<String, dynamic> body) {
    final date = body['date'] as String? ?? _fmtDate(DateTime.now());
    if (dayCloses.any((c) => c['localDate'] == date)) throw ApiException(409, 'DAY_ALREADY_CLOSED', 'This day has already been closed.');
    final preview = _dayClosePreview({'date': date});
    if ((preview['blockers'] as List).isNotEmpty) throw ApiException(409, 'DAY_CLOSE_BLOCKED', 'Cannot close: ${(preview['blockers'] as List).join(', ')}', preview);
    final expected = preview['expectedCashMinor'] as int;
    final counted = (body['countedCashMinor'] as num).toInt();
    if (counted != expected && (body['notes'] as String? ?? '').isEmpty) throw ApiException(422, 'NOTES_REQUIRED', 'Please explain the cash difference in the notes.');
    final close = {
      'id': _id('close'),
      'localDate': date,
      'expectedCashMinor': expected,
      'countedCashMinor': counted,
      'differenceMinor': counted - expected,
      'checks': preview['checks'],
      'notes': body['notes'],
      'closedBy': 'Demo Manager (Hana)',
      'closedAt': _nowIso,
    };
    dayCloses.insert(0, close);
    return close;
  }

  // ---- permission codes (mirrors backend/src/permissions.ts) ---------------------------------

  static const allPermissionCodes = [
    'customer.read', 'customer.create', 'customer.update', 'customer.delete',
    'waiver.manage', 'visit.read',
    'session.read', 'session.create', 'session.pause', 'session.extend', 'session.end', 'session.cancel', 'session.correct', 'session.override_capacity',
    'payment.create', 'payment.read', 'payment.discount', 'payment.refund',
    'equipment.read', 'equipment.assign', 'equipment.return', 'equipment.maintenance', 'equipment.manage',
    'incident.create', 'incident.read', 'incident.manage',
    'reports.read', 'staff.manage', 'settings.manage', 'pricing.manage', 'capacity.manage',
    'audit.read', 'device.manage', 'dayclose.manage',
  ];
}
