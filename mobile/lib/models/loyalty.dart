/// Loyalty data exactly as the backend computes it (GET /loyalty/customers/:id). The app never
/// derives tiers, stamp counts or reward eligibility on its own — it only renders these values.
library;

DateTime? _dt(dynamic v) => v == null ? null : DateTime.tryParse(v as String)?.toLocal();
int _int(dynamic v) => v == null ? 0 : (v as num).toInt();

class LoyaltyPosition {
  final int position;
  final String? rewardType;
  final String? label;
  final bool earned;
  final DateTime? stampedAt;
  final String? stampId;
  final String? rewardId;
  final String? rewardStatus;

  LoyaltyPosition({required this.position, this.rewardType, this.label, required this.earned, this.stampedAt, this.stampId, this.rewardId, this.rewardStatus});

  bool get isReward => rewardType != null;

  factory LoyaltyPosition.fromJson(Map<String, dynamic> j) {
    final r = j['reward'] as Map<String, dynamic>?;
    return LoyaltyPosition(
      position: _int(j['position']),
      rewardType: j['rewardType'] as String?,
      label: j['label'] as String?,
      earned: j['earned'] == true,
      stampedAt: _dt(j['stampedAt']),
      stampId: j['stampId'] as String?,
      rewardId: r?['id'] as String?,
      rewardStatus: r?['status'] as String?,
    );
  }
}

class LoyaltyCardState {
  final String? id;
  final String tier;
  final int cardNumber;
  final int stampsEarned;
  final String status;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final List<LoyaltyPosition> positions;

  LoyaltyCardState({this.id, required this.tier, required this.cardNumber, required this.stampsEarned, required this.status, this.startedAt, this.completedAt, required this.positions});

  factory LoyaltyCardState.fromJson(Map<String, dynamic> j) => LoyaltyCardState(
        id: j['id'] as String?,
        tier: j['tier'] as String,
        cardNumber: _int(j['cardNumber']),
        stampsEarned: _int(j['stampsEarned']),
        status: j['status'] as String,
        startedAt: _dt(j['startedAt']),
        completedAt: _dt(j['completedAt']),
        positions: ((j['positions'] as List?) ?? const []).map((e) => LoyaltyPosition.fromJson(e as Map<String, dynamic>)).toList(),
      );

  /// The most recent stamp on this card (the only one an authorized correction can void).
  LoyaltyPosition? get lastStamp {
    final earned = positions.where((p) => p.earned).toList();
    return earned.isEmpty ? null : earned.last;
  }
}

class LoyaltyTierInfo {
  final String code;
  final String title;
  final String theme;
  final int cardsRequired;
  final bool isFinal;
  LoyaltyTierInfo({required this.code, required this.title, required this.theme, required this.cardsRequired, required this.isFinal});
  factory LoyaltyTierInfo.fromJson(Map<String, dynamic> j) => LoyaltyTierInfo(
        code: j['code'] as String,
        title: j['title'] as String,
        theme: (j['theme'] as String?) ?? '',
        cardsRequired: _int(j['cardsRequired']),
        isFinal: j['final'] == true,
      );
}

class LoyaltyProgress {
  final int completedCardsInTier;
  final int cardsRequired;
  final int cardsRemaining;
  final int stampsOnCard;
  final int stampsToCompleteCard;
  final int stampsToNextTier;
  final String? nextTierCode;
  final String? nextTierTitle;
  final List<String> nextTierRewards;
  final bool isFinalTier;
  final bool maxTierCompleted;

  LoyaltyProgress({
    required this.completedCardsInTier, required this.cardsRequired, required this.cardsRemaining, required this.stampsOnCard,
    required this.stampsToCompleteCard, required this.stampsToNextTier, this.nextTierCode, this.nextTierTitle, required this.nextTierRewards,
    required this.isFinalTier, required this.maxTierCompleted,
  });

  factory LoyaltyProgress.fromJson(Map<String, dynamic> j) {
    final n = j['nextTier'] as Map<String, dynamic>?;
    return LoyaltyProgress(
      completedCardsInTier: _int(j['completedCardsInTier']),
      cardsRequired: _int(j['cardsRequired']),
      cardsRemaining: _int(j['cardsRemaining']),
      stampsOnCard: _int(j['stampsOnCard']),
      stampsToCompleteCard: _int(j['stampsToCompleteCard']),
      stampsToNextTier: _int(j['stampsToNextTier']),
      nextTierCode: n?['code'] as String?,
      nextTierTitle: n?['title'] as String?,
      nextTierRewards: ((n?['rewardsPerCard'] as List?) ?? const []).map((e) => e as String).toList(),
      isFinalTier: j['isFinalTier'] == true,
      maxTierCompleted: j['maxTierCompleted'] == true,
    );
  }
}

class LoyaltyReward {
  final String id;
  final String type;
  final String label;
  final String description;
  final String? code;
  final String status;
  final String tier;
  final String tierTitle;
  final int? cardNumber;
  final int position;
  final DateTime? earnedAt;
  final DateTime? redeemedAt;
  final String? redeemedByName;
  final String? redeemedSessionId;
  final String? redemptionNote;
  final String? voidReason;

  LoyaltyReward({
    required this.id, required this.type, required this.label, required this.description, this.code, required this.status, required this.tier,
    required this.tierTitle, this.cardNumber, required this.position, this.earnedAt, this.redeemedAt, this.redeemedByName, this.redeemedSessionId,
    this.redemptionNote, this.voidReason,
  });

  bool get isAvailable => status == 'AVAILABLE';
  bool get needsSession => type != 'free_burger';

  factory LoyaltyReward.fromJson(Map<String, dynamic> j) => LoyaltyReward(
        id: j['id'] as String,
        type: j['type'] as String,
        label: j['label'] as String,
        description: (j['description'] as String?) ?? '',
        code: j['code'] as String?,
        status: j['status'] as String,
        tier: j['tier'] as String,
        tierTitle: (j['tierTitle'] as String?) ?? '',
        cardNumber: j['cardNumber'] == null ? null : _int(j['cardNumber']),
        position: _int(j['position']),
        earnedAt: _dt(j['earnedAt']),
        redeemedAt: _dt(j['redeemedAt']),
        redeemedByName: j['redeemedByName'] as String?,
        redeemedSessionId: j['redeemedSessionId'] as String?,
        redemptionNote: j['redemptionNote'] as String?,
        voidReason: j['voidReason'] as String?,
      );
}

class CompletedLoyaltyCard {
  final String id;
  final String tier;
  final String tierTitle;
  final int cardNumber;
  final DateTime? completedAt;
  final int rewardsEarned;
  CompletedLoyaltyCard({required this.id, required this.tier, required this.tierTitle, required this.cardNumber, this.completedAt, required this.rewardsEarned});
  factory CompletedLoyaltyCard.fromJson(Map<String, dynamic> j) => CompletedLoyaltyCard(
        id: j['id'] as String,
        tier: j['tier'] as String,
        tierTitle: (j['tierTitle'] as String?) ?? '',
        cardNumber: _int(j['cardNumber']),
        completedAt: _dt(j['completedAt']),
        rewardsEarned: _int(j['rewardsEarned']),
      );
}

class LoyaltyEvent {
  final int id;
  final String action;
  final Map<String, dynamic> metadata;
  final DateTime? createdAt;
  final String? actorName;
  LoyaltyEvent({required this.id, required this.action, required this.metadata, this.createdAt, this.actorName});
  factory LoyaltyEvent.fromJson(Map<String, dynamic> j) => LoyaltyEvent(
        id: _int(j['id']),
        action: j['action'] as String,
        metadata: (j['metadata'] as Map?)?.cast<String, dynamic>() ?? const {},
        createdAt: _dt(j['createdAt']),
        actorName: j['actorName'] as String?,
      );
}

class LoyaltyOverview {
  final String customerId;
  final String customerName;
  final String customerCode;
  final bool hasAccount;
  final DateTime? joinedAt;
  final int totalStamps;
  final bool isMaxTierCompleted;
  final DateTime? maxTierCompletedAt;
  final bool hasCardLink;
  final LoyaltyTierInfo tier;
  final LoyaltyCardState currentCard;
  final LoyaltyProgress progress;
  final List<LoyaltyReward> rewards;
  final List<CompletedLoyaltyCard> completedCards;
  final List<LoyaltyEvent> events;

  LoyaltyOverview({
    required this.customerId, required this.customerName, required this.customerCode, required this.hasAccount, this.joinedAt,
    required this.totalStamps, required this.isMaxTierCompleted, this.maxTierCompletedAt, required this.hasCardLink, required this.tier,
    required this.currentCard, required this.progress, required this.rewards, required this.completedCards, required this.events,
  });

  List<LoyaltyReward> get availableRewards => rewards.where((r) => r.isAvailable).toList();

  factory LoyaltyOverview.fromJson(Map<String, dynamic> j) {
    final c = j['customer'] as Map<String, dynamic>;
    final a = j['account'] as Map<String, dynamic>?;
    return LoyaltyOverview(
      customerId: c['id'] as String,
      customerName: c['fullName'] as String,
      customerCode: (c['customerCode'] as String?) ?? '',
      hasAccount: a != null,
      joinedAt: _dt(a?['joinedAt']),
      totalStamps: _int(a?['totalStamps']),
      isMaxTierCompleted: a?['isMaxTierCompleted'] == true,
      maxTierCompletedAt: _dt(a?['maxTierCompletedAt']),
      hasCardLink: a?['hasCardLink'] == true,
      tier: LoyaltyTierInfo.fromJson(j['tier'] as Map<String, dynamic>),
      currentCard: LoyaltyCardState.fromJson(j['currentCard'] as Map<String, dynamic>),
      progress: LoyaltyProgress.fromJson(j['progress'] as Map<String, dynamic>),
      rewards: ((j['rewards'] as List?) ?? const []).map((e) => LoyaltyReward.fromJson(e as Map<String, dynamic>)).toList(),
      completedCards: ((j['completedCards'] as List?) ?? const []).map((e) => CompletedLoyaltyCard.fromJson(e as Map<String, dynamic>)).toList(),
      events: ((j['events'] as List?) ?? const []).map((e) => LoyaltyEvent.fromJson(e as Map<String, dynamic>)).toList(),
    );
  }
}

/// The result of a stamp award (session end or staff-verified), used to celebrate a new reward once.
class StampResult {
  final bool awarded;
  final String? reason;
  final String? message;
  final int? stampPosition;
  final String? rewardType;
  final String? rewardLabel;
  final String? rewardDescription;
  final String? rewardCode;
  final bool cardCompleted;
  final String? tierAdvancedTo;
  final bool maxTierCompleted;

  StampResult({required this.awarded, this.reason, this.message, this.stampPosition, this.rewardType, this.rewardLabel, this.rewardDescription, this.rewardCode,
      required this.cardCompleted, this.tierAdvancedTo, required this.maxTierCompleted});

  bool get isNoteworthy => awarded && (rewardType != null || cardCompleted || tierAdvancedTo != null || maxTierCompleted);

  static StampResult? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final j = raw.cast<String, dynamic>();
    final r = (j['reward'] as Map?)?.cast<String, dynamic>();
    return StampResult(
      awarded: j['awarded'] == true,
      reason: j['reason'] as String?,
      message: j['message'] as String?,
      stampPosition: j['stampPosition'] == null ? null : _int(j['stampPosition']),
      rewardType: r?['type'] as String?,
      rewardLabel: r?['label'] as String?,
      rewardDescription: r?['description'] as String?,
      rewardCode: r?['code'] as String?,
      cardCompleted: j['cardCompleted'] == true,
      tierAdvancedTo: j['tierAdvancedTo'] as String?,
      maxTierCompleted: j['maxTierCompleted'] == true,
    );
  }
}
