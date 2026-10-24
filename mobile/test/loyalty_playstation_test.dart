import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_skate_mobile/models/loyalty.dart';
import 'package:light_skate_mobile/models/playstation.dart';
import 'package:light_skate_mobile/widgets/loyalty_card_view.dart';

Map<String, dynamic> _overviewJson({int stamps = 5, String rewardStatus = 'AVAILABLE'}) => {
      'customer': {'id': 'c1', 'fullName': 'Selam Tesfaye', 'customerCode': 'LS-C000001'},
      'account': {'id': 'a1', 'joinedAt': '2026-10-01T08:00:00Z', 'currentTier': 'GOLDEN', 'totalStamps': 25, 'isMaxTierCompleted': false, 'hasCardLink': true},
      'tier': {'code': 'GOLDEN', 'title': 'Golden Loyalty Card', 'theme': 'gold', 'cardsRequired': 3, 'final': false},
      'currentCard': {
        'id': 'card1', 'tier': 'GOLDEN', 'cardNumber': 1, 'stampsEarned': stamps, 'status': 'ACTIVE',
        'positions': [
          for (var p = 1; p <= 10; p++)
            {
              'position': p,
              'rewardType': {4: 'discount_50_percent', 8: 'free_session', 9: 'free_session', 10: 'free_session'}[p],
              'label': {4: '50% OFF', 8: '1 FREE SESSION', 9: '1 FREE SESSION', 10: '1 FREE SESSION'}[p],
              'earned': p <= stamps,
              'stampId': p <= stamps ? 's$p' : null,
              'reward': p == 4 && stamps >= 4 ? {'id': 'r4', 'status': rewardStatus, 'code': 'ABCD-EFGH'} : null,
            },
        ],
      },
      'progress': {
        'completedCardsInTier': 0, 'cardsRequired': 3, 'cardsRemaining': 3, 'stampsOnCard': stamps, 'stampsToCompleteCard': 10 - stamps,
        'stampsToNextTier': 30 - stamps, 'nextTier': {'code': 'DIAMOND', 'title': 'Diamond Loyalty Card', 'rewardsPerCard': ['1 FREE SESSION']}, 'isFinalTier': false, 'maxTierCompleted': false,
      },
      'rewards': [
        {'id': 'r4', 'type': 'discount_50_percent', 'label': '50% OFF', 'description': 'd', 'code': 'ABCD-EFGH', 'status': rewardStatus, 'tier': 'GOLDEN', 'tierTitle': 'Golden Loyalty Card', 'cardNumber': 1, 'position': 4, 'earnedAt': '2026-10-02T10:00:00Z'},
        {'id': 'rb', 'type': 'free_burger', 'label': '1 FREE BURGER', 'description': 'd', 'code': 'WXYZ-2345', 'status': 'AVAILABLE', 'tier': 'LIGHT', 'tierTitle': 'Light Loyalty Card', 'cardNumber': 1, 'position': 10},
      ],
      'completedCards': [],
      'events': [],
    };

void main() {
  test('parses the loyalty overview exactly as the server sends it', () {
    final o = LoyaltyOverview.fromJson(_overviewJson());
    expect(o.tier.code, 'GOLDEN');
    expect(o.currentCard.positions, hasLength(10));
    expect(o.currentCard.positions.where((p) => p.isReward).map((p) => p.position), [4, 8, 9, 10]);
    expect(o.currentCard.lastStamp?.position, 5);
    expect(o.availableRewards, hasLength(2));
    expect(o.availableRewards.where((r) => r.needsSession), hasLength(1)); // the burger needs no session
    expect(o.progress.stampsToNextTier, 25);
  });

  test('a redeemed reward is not reported as available', () {
    final o = LoyaltyOverview.fromJson(_overviewJson(rewardStatus: 'REDEEMED'));
    expect(o.availableRewards.map((r) => r.type), ['free_burger']);
    expect(o.currentCard.positions[3].rewardStatus, 'REDEEMED');
  });

  test('stamp results only celebrate rewards, completed cards and tier changes', () {
    expect(StampResult.fromJson({'awarded': true, 'stampPosition': 3, 'cardCompleted': false, 'maxTierCompleted': false})!.isNoteworthy, isFalse);
    final r = StampResult.fromJson({'awarded': true, 'stampPosition': 5, 'reward': {'type': 'discount_50_percent', 'label': '50% OFF', 'code': 'X'}, 'cardCompleted': false, 'maxTierCompleted': false})!;
    expect(r.isNoteworthy, isTrue);
    expect(StampResult.fromJson({'awarded': false, 'reason': 'SESSION_NOT_PAID'})!.awarded, isFalse);
    expect(StampResult.fromJson(null), isNull);
  });

  test('every tier artwork has 10 stamp positions inside the image', () {
    for (final t in ['STANDARD', 'GOLDEN', 'DIAMOND', 'LIGHT']) {
      final a = TierArt.of(t);
      for (var p = 1; p <= 10; p++) {
        final o = a.slot(p);
        expect(o.dx - a.radius, greaterThan(0));
        expect(o.dx + a.radius, lessThan(a.width));
        expect(o.dy - a.radius, greaterThan(0));
        expect(o.dy + a.radius, lessThan(a.height));
      }
    }
  });

  testWidgets('renders the card with stamps, EARNED marker and customer name', (tester) async {
    final o = LoyaltyOverview.fromJson(_overviewJson());
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 400, child: LoyaltyCardView(tier: o.tier.code, positions: o.currentCard.positions, name: o.customerName)))));
    await tester.pump();
    expect(find.text('Selam Tesfaye'), findsOneWidget);
    expect(find.text('EARNED'), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsNWidgets(4)); // stamps 1,2,3,5; 4 is the earned reward
  });

  test('gaming countdown formatting and local countdown from server time', () {
    expect(fmtClock(65), '01:05');
    expect(fmtClock(3725), '1:02:05');
    expect(fmtClock(-30), '+00:30 over');
    final d = PsSessionDetail.fromJson({
      'session': {
        'id': 's', 'sessionNumber': 'PS-1', 'status': 'PAUSED', 'paymentStatus': 'PAID', 'pricingType': 'DURATION', 'consoleId': 'c', 'totalMinor': 10000,
        'remainingSeconds': 600, 'gamesPurchased': 0, 'gamesCompleted': 0, 'gamesRemaining': 0,
      },
    });
    expect(d.liveRemaining(DateTime.now().add(const Duration(minutes: 5))), 600); // frozen while paused
  });
}
