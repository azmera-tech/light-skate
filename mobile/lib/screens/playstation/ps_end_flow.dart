import 'package:flutter/material.dart';
import '../../api/api_client.dart';
import '../../format.dart';
import '../../theme.dart';
import '../../widgets/reason_dialog.dart';
import 'ps_checkout_sheet.dart';

/// End Session → Checkout, shared by the dashboard card and the session screen.
/// Ending only stops play and bills the final total; payment is a separate step ([showPsCheckoutSheet]) the
/// employee can also leave for later — the session then waits under "Awaiting payment".
/// Returns true when the session was ended (whether or not payment was taken).
Future<bool> endSessionAndCheckout(
  BuildContext context,
  ApiClient api, {
  required String sessionId,
  required String consoleCode,
  required bool perGame,
  required int quantity,
  required int unitPriceMinor,
  required int totalMinor,
  int? remainingSeconds,
}) async {
  String? reason;
  if (remainingSeconds != null && remainingSeconds > 60) {
    reason = await showReasonDialog(context, title: 'End early', label: '${formatDuration(remainingSeconds)} of paid time are left — why end now?', minLength: 3, confirmLabel: 'End session');
    if (reason == null) return false;
  } else {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('End $consoleCode?'),
        content: Text(perGame
            ? '$quantity ${quantity == 1 ? 'game' : 'games'} × ${formatMoney(unitPriceMinor, 'ETB')} = ${formatMoney(totalMinor, 'ETB')}.\nThe console is released and checkout opens.'
            : 'Total ${formatMoney(totalMinor, 'ETB')}. The console is released and checkout opens.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep playing')),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: LsColors.red), onPressed: () => Navigator.pop(ctx, true), child: const Text('End & check out')),
        ],
      ),
    );
    if (ok != true) return false;
  }
  try {
    await api.post('/playstation/sessions/$sessionId/finish', {'reason': reason});
  } on ApiException catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    return false;
  }
  if (context.mounted) await showPsCheckoutSheet(context, sessionId);
  return true;
}
