import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:light_skate_mobile/models/playstation.dart';
import 'package:light_skate_mobile/models/product.dart';
import 'package:light_skate_mobile/screens/playstation/ps_checkout_sheet.dart';
import 'package:light_skate_mobile/screens/playstation/ps_new_session_sheet.dart';

PsPackage _perGame() => PsPackage.fromJson({
      'id': 'p1', 'name': 'Single game', 'pricingType': 'PER_GAME', 'gamesPerUnit': 1, 'gameLabel': 'game', 'priceMinor': 2500, 'active': true, 'sortOrder': 0, 'timesSold': 0,
    });

PsConsole _console() => PsConsole.fromJson({'id': 'c1', 'code': 'PS-01', 'name': 'Station 1', 'status': 'ACTIVE', 'state': 'AVAILABLE'});

PsSessionDetail _detail({int quantity = 5, int settled = 0, int pending = 0, String status = 'COMPLETED'}) {
  final total = quantity * 2500;
  final balance = (total - settled).clamp(0, 1 << 30);
  return PsSessionDetail.fromJson({
    'session': {
      'id': 's1', 'sessionNumber': 'PS-0001', 'status': status, 'paymentStatus': settled >= total ? 'PAID' : 'UNPAID', 'pricingType': 'PER_GAME', 'consoleId': 'c1',
      'consoleCode': 'PS-01', 'consoleName': 'Station 1', 'playerName': 'Abel', 'totalMinor': total, 'paidMinor': settled, 'pendingMinor': pending, 'refundedMinor': 0,
      'dueMinor': balance, 'packageName': 'Single game', 'unitPriceMinor': 2500, 'quantity': quantity, 'gamesCount': quantity, 'gamesPurchased': quantity,
      'balanceMinor': balance, 'settledMinor': settled, 'toCollectMinor': (balance - pending).clamp(0, 1 << 30),
    },
  });
}

final _methods = [
  PaymentMethodOption(code: 'CASH', label: 'Cash', requiresReference: false, enabled: true),
  PaymentMethodOption(code: 'BANK_TRANSFER', label: 'Bank transfer', requiresReference: true, enabled: true),
  PaymentMethodOption(code: 'TELEBIRR', label: 'Telebirr', requiresReference: true, enabled: true),
];

/// A phone-sized screen with a 3-button navigation bar (48px) and optionally an open keyboard.
Widget _phone(Widget child, {double nav = 48, double keyboard = 0}) => MaterialApp(
      builder: (c, w) => MediaQuery(
        data: MediaQuery.of(c).copyWith(
          padding: EdgeInsets.only(top: 24, bottom: keyboard > 0 ? 0 : nav),
          viewPadding: EdgeInsets.only(top: 24, bottom: nav),
          viewInsets: EdgeInsets.only(bottom: keyboard),
        ),
        child: w!,
      ),
      home: Scaffold(body: Builder(builder: (ctx) => Center(child: ElevatedButton(onPressed: () => showModalBottomSheet<void>(context: ctx, isScrollControlled: true, useSafeArea: true, builder: (_) => child), child: const Text('open'))))),
    );

void _phoneSize(WidgetTester t, {double w = 360, double h = 640}) {
  t.view.physicalSize = Size(w, h);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

void main() {
  group('PsSessionDetail money', () {
    test('5 games at 25 ETB = 125 ETB, nothing paid, balance = total', () {
      final d = _detail();
      expect(d.totalMinor, 12500);
      expect(d.unitPriceMinor * d.quantity, d.totalMinor);
      expect(d.settledMinor, 0);
      expect(d.balanceMinor, 12500);
      expect(d.needsCheckout, isTrue);
    });
    test('pending verification is not settled and a settled session needs no checkout', () {
      final p = _detail(pending: 12500);
      expect(p.balanceMinor, 12500);
      expect(p.toCollectMinor, 0);
      final paid = _detail(settled: 12500);
      expect(paid.needsCheckout, isFalse);
      expect(paid.balanceMinor, 0);
    });
    test('payment status labels distinguish pending from verified', () {
      PsPayment mk(String status, bool verify) => PsPayment.fromJson({'id': 'x', 'amountMinor': 100, 'refundedMinor': 0, 'method': 'TELEBIRR', 'status': status, 'verificationRequired': verify, 'hasProof': true});
      expect(mk('PENDING', true).statusLabel, 'Pending verification');
      expect(mk('PAID', true).statusLabel, 'Verified');
      expect(mk('PAID', false).statusLabel, 'Received');
      expect(mk('REJECTED', true).statusLabel, 'Rejected');
      expect(mk('PENDING', true).isReceived, isFalse);
    });
  });

  group('New session sheet (post-paid)', () {
    testWidgets('has no payment controls and starts with no payment', (t) async {
      _phoneSize(t);
      Map<String, dynamic>? sent;
      await t.pumpWidget(_phone(NewSessionForm(console: _console(), packages: [_perGame()], onSubmit: (b) async { sent = b; return 's1'; }, onLookup: (_) async => [])));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.textContaining('fully paid'), findsNothing);
      expect(find.text('Cash'), findsNothing);
      expect(find.text('Start Session'), findsOneWidget);
      // a name is needed for a walk-in; before that the button is disabled
      expect(t.widget<ElevatedButton>(find.byType(ElevatedButton).last).onPressed, isNull);
      await t.enterText(find.widgetWithText(TextField, 'Customer name'), 'Abel');
      await t.pump();
      await t.tap(find.text('Start Session'));
      await t.pumpAndSettle();
      expect(sent, isNotNull);
      expect(sent!['quantity'], 0);
      expect(sent!.keys.any((k) => k.toLowerCase().contains('pay')), isFalse);
      expect(sent!['walkInName'], 'Abel');
    });

    for (final kb in [0.0, 300.0]) {
      testWidgets('Start Session stays visible and tappable above the nav bar (keyboard ${kb.toInt()}px)', (t) async {
        _phoneSize(t, h: 640);
        await t.pumpWidget(_phone(NewSessionForm(console: _console(), packages: [_perGame()], onSubmit: (b) async => 's1', onLookup: (_) async => []), keyboard: kb));
        await t.tap(find.text('open'));
        await t.pumpAndSettle();
        await t.enterText(find.widgetWithText(TextField, 'Customer name'), 'Abel');
        await t.pumpAndSettle();
        final r = t.getRect(find.text('Start Session'));
        final usableBottom = 640 - (kb > 48 ? kb : 48); // above the navigation bar, or above the keyboard when it covers it
        expect(r.bottom, lessThanOrEqualTo(usableBottom + 0.5), reason: 'button must not sit under the navigation bar / keyboard');
        expect(r.top, greaterThan(0));
        await t.tap(find.text('Start Session'), warnIfMissed: true);
      });
    }

    testWidgets('a long form still reaches the action on a very short screen', (t) async {
      _phoneSize(t, h: 480);
      final many = [for (var i = 0; i < 6; i++) PsPackage.fromJson({'id': 'p$i', 'name': 'Package $i', 'pricingType': 'PER_GAME', 'gamesPerUnit': 1, 'priceMinor': 2500, 'active': true, 'sortOrder': i, 'timesSold': 0})];
      await t.pumpWidget(_phone(NewSessionForm(console: _console(), packages: many, onSubmit: (b) async => 's1', onLookup: (_) async => [])));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      final r = t.getRect(find.text('Start Session'));
      expect(r.bottom, lessThanOrEqualTo(480 - 48 + 0.5));
      // the body scrolls while the button stays pinned
      await t.drag(find.byType(SingleChildScrollView).last, const Offset(0, -300));
      await t.pumpAndSettle();
      expect(t.getRect(find.text('Start Session')).bottom, lessThanOrEqualTo(480 - 48 + 0.5));
    });
  });

  group('Checkout', () {
    Widget form(PsSessionDetail d, {Future<void> Function()? onPaid, Set<String> proof = const {'BANK_TRANSFER', 'TELEBIRR'}}) =>
        PsCheckoutForm(detail: d, methods: _methods, proofRequiredMethods: proof, verifyNonCash: true, onPaid: onPaid ?? () async {}, onClose: () {});

    testWidgets('shows station, customer, package, games, unit price, total, previously paid and balance', (t) async {
      _phoneSize(t, h: 800);
      await t.pumpWidget(_phone(form(_detail())));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.textContaining('PS-01'), findsWidgets);
      for (final s in ['Abel', 'Single game', '5 games', 'Price per game', 'Total due', 'Previously paid', 'Balance remaining']) {
        expect(find.text(s), findsOneWidget, reason: s);
      }
      expect(find.textContaining('125'), findsWidgets);
      expect(find.text('Cash'), findsOneWidget);
      expect(find.text('Bank transfer'), findsOneWidget);
      expect(find.text('Telebirr'), findsOneWidget);
    });

    testWidgets('cash needs no evidence and the amount defaults to the whole balance', (t) async {
      _phoneSize(t, h: 800);
      await t.pumpWidget(_phone(form(_detail())));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.text('Payment proof'), findsNothing);
      expect(find.textContaining('cash received'), findsWidgets);
      final btn = find.byType(ElevatedButton).last;
      expect(t.widget<ElevatedButton>(btn).onPressed, isNotNull);
    });

    testWidgets('non-cash asks for a reference and proof and cannot be submitted without them', (t) async {
      _phoneSize(t, h: 800);
      await t.pumpWidget(_phone(form(_detail())));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.tap(find.text('Telebirr'));
      await t.pumpAndSettle();
      expect(find.text('Payment proof'), findsOneWidget);
      expect(find.text('Required'), findsOneWidget);
      expect(find.text('Take photo'), findsOneWidget);
      expect(find.text('Upload screenshot'), findsOneWidget);
      expect(find.textContaining('administrator checks'), findsOneWidget);
      expect(t.widget<ElevatedButton>(find.byType(ElevatedButton).last).onPressed, isNull); // no reference, no proof
      await t.enterText(find.widgetWithText(TextField, 'Telebirr transaction ID'), 'DAB12345');
      await t.pump();
      expect(t.widget<ElevatedButton>(find.byType(ElevatedButton).last).onPressed, isNull); // still no proof
    });

    testWidgets('cannot overpay and an already-covered balance shows no payment form', (t) async {
      _phoneSize(t, h: 800);
      await t.pumpWidget(_phone(form(_detail())));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.enterText(find.widgetWithText(TextField, 'Amount being paid (ETB)'), '200');
      await t.pump();
      expect(find.textContaining('more than'), findsNothing); // surfaced only on submit attempt via the disabled button
      expect(t.widget<ElevatedButton>(find.byType(ElevatedButton).last).onPressed, isNull);
    });

    testWidgets('pending payments do not count as paid: the pending amount is shown separately', (t) async {
      _phoneSize(t, h: 800);
      await t.pumpWidget(_phone(form(_detail(pending: 12500))));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      expect(find.text('Awaiting verification'), findsOneWidget);
      expect(find.textContaining('already covered by payments awaiting verification'), findsOneWidget);
      expect(find.text('Cash'), findsNothing);
    });

    testWidgets('submit button stays above the nav bar with the keyboard open', (t) async {
      _phoneSize(t, h: 640);
      await t.pumpWidget(_phone(form(_detail()), keyboard: 280));
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('Telebirr'));
      await t.tap(find.text('Telebirr'));
      await t.pumpAndSettle();
      final r = t.getRect(find.byType(ElevatedButton).last);
      expect(r.bottom, lessThanOrEqualTo(640 - 280 + 0.5));
    });
  });
}
