/// PlayStation gaming module data, as returned by /playstation/*. Prices are integer minor units
/// (santim); times are server timestamps; remaining time is computed against server time.
library;

DateTime? _dt(dynamic v) => v == null ? null : DateTime.tryParse(v as String)?.toLocal();
int _int(dynamic v) => v == null ? 0 : (v as num).toInt();
int? _intN(dynamic v) => v == null ? null : (v as num).toInt();

class PsPackage {
  final String id;
  final String name;
  final String? description;
  final String pricingType; // DURATION | PER_GAME
  final int? durationMinutes;
  final int? gamesPerUnit;
  final String? gameLabel;
  final int priceMinor;
  final bool active;
  final int sortOrder;
  final int timesSold;

  PsPackage({required this.id, required this.name, this.description, required this.pricingType, this.durationMinutes, this.gamesPerUnit, this.gameLabel,
      required this.priceMinor, required this.active, required this.sortOrder, required this.timesSold});

  bool get isTimed => pricingType == 'DURATION';
  String get unitLabel => isTimed ? '$durationMinutes min' : '$gamesPerUnit ${gameLabel ?? 'game'}${(gamesPerUnit ?? 1) > 1 ? 's' : ''}';

  factory PsPackage.fromJson(Map<String, dynamic> j) => PsPackage(
        id: j['id'] as String,
        name: j['name'] as String,
        description: j['description'] as String?,
        pricingType: j['pricingType'] as String,
        durationMinutes: _intN(j['durationMinutes']),
        gamesPerUnit: _intN(j['gamesPerUnit']),
        gameLabel: j['gameLabel'] as String?,
        priceMinor: _int(j['priceMinor']),
        active: j['active'] == true,
        sortOrder: _int(j['sortOrder']),
        timesSold: _int(j['timesSold']),
      );
}

class PsLiveSession {
  final String id;
  final String sessionNumber;
  final String status;
  final String pricingType;
  final DateTime? startedAt;
  final DateTime? expectedEndAt;
  final int? remainingSeconds;
  final int gamesPurchased;
  final int gamesCompleted;
  final String paymentStatus;
  final int totalMinor;
  final String? playerName;
  final String? operatorName;
  final int version;
  final int quantity;
  final int gamesCount;
  final String? packageName;
  final int unitPriceMinor;
  final int paidMinor;
  final int pendingMinor;
  final int balanceMinor;

  PsLiveSession({required this.id, required this.sessionNumber, required this.status, required this.pricingType, this.startedAt, this.expectedEndAt, this.remainingSeconds,
      required this.gamesPurchased, required this.gamesCompleted, required this.paymentStatus, required this.totalMinor, this.playerName, this.operatorName,
      this.version = 0, this.quantity = 0, this.gamesCount = 0, this.packageName, this.unitPriceMinor = 0, this.paidMinor = 0, this.pendingMinor = 0, this.balanceMinor = 0});

  bool get isPerGame => pricingType == 'PER_GAME';
  bool get isOpenPlay => status == 'ACTIVE' || status == 'PAUSED';

  factory PsLiveSession.fromJson(Map<String, dynamic> j) => PsLiveSession(
        id: j['id'] as String,
        sessionNumber: j['sessionNumber'] as String,
        status: j['status'] as String,
        pricingType: j['pricingType'] as String,
        startedAt: _dt(j['startedAt']),
        expectedEndAt: _dt(j['expectedEndAt']),
        remainingSeconds: _intN(j['remainingSeconds']),
        gamesPurchased: _int(j['gamesPurchased']),
        gamesCompleted: _int(j['gamesCompleted']),
        paymentStatus: j['paymentStatus'] as String,
        totalMinor: _int(j['totalMinor']),
        playerName: j['playerName'] as String?,
        operatorName: j['operatorName'] as String?,
        version: _int(j['version']),
        quantity: _int(j['quantity']),
        gamesCount: _int(j['gamesCount']),
        packageName: j['packageName'] as String?,
        unitPriceMinor: _int(j['unitPriceMinor']),
        paidMinor: _int(j['paidMinor']),
        pendingMinor: _int(j['pendingMinor']),
        balanceMinor: _int(j['balanceMinor']),
      );
}

class PsConsole {
  final String id;
  final String code;
  final String name;
  final String? model;
  final String? location;
  final String status; // admin-set: ACTIVE | MAINTENANCE | INACTIVE
  final String state; // derived: AVAILABLE | IN_USE | MAINTENANCE | INACTIVE | ARCHIVED
  final String? notes;
  final PsLiveSession? session;

  PsConsole({required this.id, required this.code, required this.name, this.model, this.location, required this.status, required this.state, this.notes, this.session});

  factory PsConsole.fromJson(Map<String, dynamic> j) => PsConsole(
        id: j['id'] as String,
        code: j['code'] as String,
        name: j['name'] as String,
        model: j['model'] as String?,
        location: j['location'] as String?,
        status: j['status'] as String,
        state: j['state'] as String,
        notes: j['notes'] as String?,
        session: j['session'] == null ? null : PsLiveSession.fromJson(j['session'] as Map<String, dynamic>),
      );
}

class PsItem {
  final String id;
  final String kind;
  final String packageName;
  final String pricingType;
  final int unitPriceMinor;
  final int quantity;
  final int addedSeconds;
  final int addedGames;
  final int totalMinor;
  final String? addedByName;
  final DateTime? createdAt;
  PsItem({required this.id, required this.kind, required this.packageName, required this.pricingType, required this.unitPriceMinor, required this.quantity,
      required this.addedSeconds, required this.addedGames, required this.totalMinor, this.addedByName, this.createdAt});
  factory PsItem.fromJson(Map<String, dynamic> j) => PsItem(
        id: j['id'] as String,
        kind: j['kind'] as String,
        packageName: j['packageName'] as String,
        pricingType: j['pricingType'] as String,
        unitPriceMinor: _int(j['unitPriceMinor']),
        quantity: _int(j['quantity']),
        addedSeconds: _int(j['addedSeconds']),
        addedGames: _int(j['addedGames']),
        totalMinor: _int(j['totalMinor']),
        addedByName: j['addedByName'] as String?,
        createdAt: _dt(j['createdAt']),
      );
}

class PsPayment {
  final String id;
  final String? sessionId;
  final int amountMinor;
  final int refundedMinor;
  final String method;
  final String? reference;
  final String status; // PENDING (= pending verification) | PAID | REJECTED | CANCELLED | PARTIALLY_REFUNDED | REFUNDED
  final DateTime? paidAt;
  final DateTime? createdAt;
  final String? recordedBy;
  final String? recordedByName;
  final String? confirmedByName;
  final String? rejectedByName;
  final String? rejectReason;
  final DateTime? rejectedAt;
  final bool verificationRequired;
  final bool hasProof;
  final int? tenderedMinor;
  final String? note;
  // review-queue context
  final String? sessionNumber;
  final String? consoleCode;
  final String? playerName;
  final String? packageName;
  PsPayment({required this.id, this.sessionId, required this.amountMinor, required this.refundedMinor, required this.method, this.reference, required this.status, this.paidAt, this.createdAt,
      this.recordedBy, this.recordedByName, this.confirmedByName, this.rejectedByName, this.rejectReason, this.rejectedAt, required this.verificationRequired, required this.hasProof,
      this.tenderedMinor, this.note, this.sessionNumber, this.consoleCode, this.playerName, this.packageName});

  bool get isPending => status == 'PENDING';
  bool get isReceived => const ['PAID', 'PARTIALLY_REFUNDED', 'REFUNDED'].contains(status);
  String get statusLabel => switch (status) {
        'PENDING' => 'Pending verification',
        'PAID' => verificationRequired ? 'Verified' : 'Received',
        'REJECTED' => 'Rejected',
        'CANCELLED' => 'Withdrawn',
        'PARTIALLY_REFUNDED' => 'Partly refunded',
        'REFUNDED' => 'Refunded',
        _ => titleCaseLabel(status),
      };

  factory PsPayment.fromJson(Map<String, dynamic> j) => PsPayment(
        id: j['id'] as String,
        sessionId: j['sessionId'] as String?,
        amountMinor: _int(j['amountMinor']),
        refundedMinor: _int(j['refundedMinor']),
        method: j['method'] as String,
        reference: j['reference'] as String?,
        status: j['status'] as String,
        paidAt: _dt(j['paidAt']),
        createdAt: _dt(j['createdAt']),
        recordedBy: j['recordedBy'] as String?,
        recordedByName: j['recordedByName'] as String?,
        confirmedByName: j['confirmedByName'] as String?,
        rejectedByName: j['rejectedByName'] as String?,
        rejectReason: j['rejectReason'] as String?,
        rejectedAt: _dt(j['rejectedAt']),
        verificationRequired: j['verificationRequired'] == true,
        hasProof: j['hasProof'] == true,
        tenderedMinor: _intN(j['tenderedMinor']),
        note: j['note'] as String?,
        sessionNumber: j['sessionNumber'] as String?,
        consoleCode: j['consoleCode'] as String?,
        playerName: j['playerName'] as String?,
        packageName: j['packageName'] as String?,
      );
}

String titleCaseLabel(String s) => s.split('_').map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}').join(' ');

class PsEvent {
  final int id;
  final String eventType;
  final DateTime? occurredAt;
  final Map<String, dynamic> metadata;
  final String? actorName;
  PsEvent({required this.id, required this.eventType, this.occurredAt, required this.metadata, this.actorName});
  factory PsEvent.fromJson(Map<String, dynamic> j) => PsEvent(
        id: _int(j['id']),
        eventType: j['eventType'] as String,
        occurredAt: _dt(j['occurredAt']),
        metadata: (j['metadata'] as Map?)?.cast<String, dynamic>() ?? const {},
        actorName: j['actorName'] as String?,
      );
}

class PsSessionDetail {
  final String id;
  final String sessionNumber;
  final String status;
  final String paymentStatus;
  final String pricingType;
  final String consoleId;
  final String consoleCode;
  final String consoleName;
  final String? playerName;
  final String? customerId;
  final String? customerCode;
  final String? walkInPhone;
  final String? operatorName;
  final int totalMinor;
  final int paidMinor;
  final int pendingMinor;
  final int refundedMinor;
  final int dueMinor;
  final String currency;
  final int purchasedSeconds;
  final int gamesPurchased;
  final int gamesCompleted;
  final int gamesRemaining;
  final DateTime? createdAt;
  final DateTime? startedAt;
  final DateTime? expectedEndAt;
  final DateTime? endedAt;
  final int? remainingSeconds;
  final String? endReason;
  final String? notes;
  final bool canRefund;
  final bool canVerify;
  final bool canCorrect;
  final String packageName;
  final int unitPriceMinor;
  final int quantity;
  final int gamesCount;
  final int version;
  final int toCollectMinor;
  final int balanceMinor;
  final int settledMinor;
  final List<PsItem> items;
  final List<PsPayment> payments;
  final List<PsEvent> events;
  final Map<String, dynamic> receipt;
  final DateTime fetchedAt;

  PsSessionDetail({
    required this.id, required this.sessionNumber, required this.status, required this.paymentStatus, required this.pricingType, required this.consoleId,
    required this.consoleCode, required this.consoleName, this.playerName, this.customerId, this.customerCode, this.walkInPhone, this.operatorName,
    required this.totalMinor, required this.paidMinor, required this.pendingMinor, required this.refundedMinor, required this.dueMinor, required this.currency,
    required this.purchasedSeconds, required this.gamesPurchased, required this.gamesCompleted, required this.gamesRemaining, this.createdAt, this.startedAt,
    this.expectedEndAt, this.endedAt, this.remainingSeconds, this.endReason, this.notes, required this.canRefund, required this.canVerify, required this.canCorrect,
    required this.packageName, required this.unitPriceMinor, required this.quantity, required this.gamesCount, required this.version, required this.toCollectMinor, required this.balanceMinor, required this.settledMinor,
    required this.items, required this.payments,
    required this.events, required this.receipt, required this.fetchedAt,
  });

  bool get isTimed => pricingType == 'DURATION';
  bool get isOpen => const ['PENDING_PAYMENT', 'READY', 'ACTIVE', 'PAUSED'].contains(status);
  bool get isPlaying => status == 'ACTIVE' || status == 'PAUSED';
  bool get isEnded => status == 'COMPLETED';
  /// Played and finished, but money is still owed: the checkout is waiting.
  bool get needsCheckout => isEnded && balanceMinor > 0;

  /// Remaining seconds now, counted down locally from the server's value at fetch time (frozen while paused).
  int? liveRemaining(DateTime now) {
    if (remainingSeconds == null) return null;
    if (status != 'ACTIVE') return remainingSeconds;
    return remainingSeconds! - now.difference(fetchedAt).inSeconds;
  }

  factory PsSessionDetail.fromJson(Map<String, dynamic> j) {
    final s = j['session'] as Map<String, dynamic>;
    return PsSessionDetail(
      id: s['id'] as String,
      sessionNumber: s['sessionNumber'] as String,
      status: s['status'] as String,
      paymentStatus: s['paymentStatus'] as String,
      pricingType: s['pricingType'] as String,
      consoleId: s['consoleId'] as String,
      consoleCode: (s['consoleCode'] as String?) ?? '',
      consoleName: (s['consoleName'] as String?) ?? '',
      playerName: s['playerName'] as String?,
      customerId: s['customerId'] as String?,
      customerCode: s['customerCode'] as String?,
      walkInPhone: s['walkInPhone'] as String?,
      operatorName: s['operatorName'] as String?,
      totalMinor: _int(s['totalMinor']),
      paidMinor: _int(s['paidMinor']),
      pendingMinor: _int(s['pendingMinor']),
      refundedMinor: _int(s['refundedMinor']),
      dueMinor: _int(s['dueMinor']),
      currency: (s['currency'] as String?) ?? 'ETB',
      purchasedSeconds: _int(s['purchasedSeconds']),
      gamesPurchased: _int(s['gamesPurchased']),
      gamesCompleted: _int(s['gamesCompleted']),
      gamesRemaining: _int(s['gamesRemaining']),
      createdAt: _dt(s['createdAt']),
      startedAt: _dt(s['startedAt']),
      expectedEndAt: _dt(s['expectedEndAt']),
      endedAt: _dt(s['endedAt']),
      remainingSeconds: _intN(s['remainingSeconds']),
      endReason: s['endReason'] as String?,
      notes: s['notes'] as String?,
      canRefund: s['canRefund'] == true,
      canVerify: s['canVerify'] == true,
      canCorrect: s['canCorrect'] == true,
      packageName: (s['packageName'] as String?) ?? '',
      unitPriceMinor: _int(s['unitPriceMinor']),
      quantity: _int(s['quantity']),
      gamesCount: _int(s['gamesCount']),
      version: _int(s['version']),
      toCollectMinor: _int(s['toCollectMinor']),
      balanceMinor: _int(s['balanceMinor']),
      settledMinor: _int(s['settledMinor']),
      items: ((j['items'] as List?) ?? const []).map((e) => PsItem.fromJson(e as Map<String, dynamic>)).toList(),
      payments: ((j['payments'] as List?) ?? const []).map((e) => PsPayment.fromJson(e as Map<String, dynamic>)).toList(),
      events: ((j['events'] as List?) ?? const []).map((e) => PsEvent.fromJson(e as Map<String, dynamic>)).toList(),
      receipt: (j['receipt'] as Map?)?.cast<String, dynamic>() ?? const {},
      fetchedAt: DateTime.now(),
    );
  }
}

const psStatusLabel = {
  'PENDING_PAYMENT': 'Awaiting payment', 'READY': 'Ready to start', 'ACTIVE': 'Playing', 'PAUSED': 'Paused', 'COMPLETED': 'Ended', 'CANCELLED': 'Cancelled',
};
const psPaymentLabel = {
  'UNPAID': 'Unpaid', 'PENDING': 'Pending verification', 'PARTIALLY_PAID': 'Partly paid', 'PAID': 'Paid', 'PARTIALLY_REFUNDED': 'Partly refunded', 'REFUNDED': 'Refunded',
};
const psEventLabel = {
  'SESSION_CREATED': 'Session opened', 'PAYMENT_RECEIVED': 'Payment received', 'PAYMENT_SUBMITTED': 'Payment submitted for verification', 'PAYMENT_PROOF_ADDED': 'Evidence added',
  'PAYMENT_VERIFIED': 'Payment verified', 'PAYMENT_REJECTED': 'Payment rejected', 'PAYMENT_CANCELLED': 'Pending payment withdrawn', 'PAYMENT_REFUNDED': 'Refund issued',
  'SESSION_STARTED': 'Started', 'SESSION_PAUSED': 'Paused', 'SESSION_RESUMED': 'Resumed', 'SESSION_EXTENDED': 'Time added', 'GAMES_ADDED': 'Game added', 'GAMES_CORRECTED': 'Game count corrected',
  'SESSION_FINISHED': 'Session ended', 'SESSION_CANCELLED': 'Cancelled', 'TIME_WARNING': 'Ending-soon warning', 'TIME_UP': 'Time up',
};

String fmtClock(int seconds) {
  final neg = seconds < 0;
  final s = seconds.abs();
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  final body = h > 0 ? '$h:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}' : '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  return neg ? '+$body over' : body;
}
