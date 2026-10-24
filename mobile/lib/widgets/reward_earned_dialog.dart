import 'package:flutter/material.dart';
import '../models/loyalty.dart';
import '../theme.dart';
import 'loyalty_card_view.dart';

const _tierTitles = {'STANDARD': 'Loyalty Card', 'GOLDEN': 'Golden Loyalty Card', 'DIAMOND': 'Diamond Loyalty Card', 'LIGHT': 'Light Loyalty Card'};

/// Shown once, straight from the server's response to the action that earned it (ending a paid
/// session or a staff-verified stamp) — never re-shown on refresh, because it is not driven by
/// stored state at all. Returns true if staff tapped "View loyalty card".
Future<bool> showStampResult(BuildContext context, StampResult r, {required String customerName}) async {
  if (!r.awarded) return false;
  if (!r.isNoteworthy) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Loyalty stamp ${r.stampPosition} of 10 added for $customerName.')));
    return false;
  }
  final headline = r.maxTierCompleted
      ? 'Light card complete — VIP status!'
      : r.tierAdvancedTo != null
          ? 'Promoted to the ${_tierTitles[r.tierAdvancedTo] ?? r.tierAdvancedTo}!'
          : r.rewardType != null
              ? 'Reward earned: ${r.rewardLabel}'
              : 'Card complete!';
  final tier = r.tierAdvancedTo ?? '';
  final res = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: Icon(r.rewardType == 'free_burger' ? Icons.lunch_dining : r.rewardType == 'free_session' ? Icons.celebration : r.rewardType != null ? Icons.percent : Icons.workspace_premium,
          size: 44, color: tier.isNotEmpty ? tierColor(tier) : LsColors.green),
      title: Text(headline, textAlign: TextAlign.center),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('$customerName got stamp ${r.stampPosition} of 10.', textAlign: TextAlign.center),
        if (r.rewardType != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: LsColors.greenSoft, borderRadius: BorderRadius.circular(10)),
            child: Column(children: [
              Text(r.rewardLabel ?? '', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: LsColors.green)),
              const SizedBox(height: 4),
              Text(r.rewardDescription ?? '', textAlign: TextAlign.center),
              if (r.rewardCode != null) ...[
                const SizedBox(height: 8),
                SelectableText('Reward code ${r.rewardCode}', style: const TextStyle(fontWeight: FontWeight.w700, letterSpacing: 1)),
              ],
            ]),
          ),
          const SizedBox(height: 8),
          const Text('Added to the rewards wallet — it stays available until it is used.', textAlign: TextAlign.center, style: TextStyle(color: LsColors.muted, fontSize: 12.5)),
        ],
        if (r.cardCompleted && !r.maxTierCompleted && r.tierAdvancedTo == null) ...[
          const SizedBox(height: 10),
          const Text('A new card has started.', style: TextStyle(color: LsColors.muted)),
        ],
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Close')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('View loyalty card')),
      ],
    ),
  );
  return res == true;
}
