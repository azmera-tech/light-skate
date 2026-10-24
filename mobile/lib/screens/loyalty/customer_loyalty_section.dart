import 'dart:async';
import 'package:flutter/material.dart';
import '../../api/api_client.dart';
import '../../api/realtime_bus.dart';
import '../../format.dart';
import '../../models/loyalty.dart';
import '../../models/me.dart';
import '../../theme.dart';
import '../../widgets/loyalty_card_view.dart';
import '../../widgets/reason_dialog.dart';
import '../../widgets/reward_earned_dialog.dart';
import 'customer_card_screen.dart';

String _d(DateTime? t) => t == null ? '—' : '${fmtDate(t)} ${fmtHHMM(t)}';

/// ['50% OFF', '1 FREE SESSION', '1 FREE SESSION'] -> '50% OFF + 2 FREE SESSIONS'
String _summarize(List<String> labels) {
  final counts = <String, int>{};
  for (final l in labels) {
    counts[l] = (counts[l] ?? 0) + 1;
  }
  return counts.entries.map((e) => e.value == 1 ? e.key : '${e.value} ${e.key.replaceFirst(RegExp(r'^1 '), '')}S').join(' + ');
}

/// The Customer Loyalty Progress section of a customer's profile. Everything shown comes from
/// GET /loyalty/customers/:id; actions are offered only for the permissions the staff member holds,
/// and the server re-checks every one of them.
class CustomerLoyaltySection extends StatefulWidget {
  final String customerId;
  final String customerName;
  const CustomerLoyaltySection({super.key, required this.customerId, required this.customerName});
  @override
  State<CustomerLoyaltySection> createState() => _CustomerLoyaltySectionState();
}

class _CustomerLoyaltySectionState extends State<CustomerLoyaltySection> {
  late ApiClient _api;
  Me? _me;
  LoyaltyOverview? _o;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    RealtimeBus.last.addListener(_onRealtime);
    _boot();
  }

  @override
  void dispose() {
    RealtimeBus.last.removeListener(_onRealtime);
    super.dispose();
  }

  void _onRealtime() {
    final e = RealtimeBus.last.value;
    if (e == null) return;
    if (e.event == 'RESYNC' || (e.event == 'LOYALTY_UPDATED' && e.data['aggregateId'] == widget.customerId)) _load();
  }

  Future<void> _boot() async {
    _api = await ApiClient.instance();
    _me = _api.me;
    await _load();
  }

  Future<void> _load() async {
    try {
      final j = await _api.get('/loyalty/customers/${widget.customerId}') as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _o = LoyaltyOverview.fromJson(j);
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _act(Future<void> Function() fn, {String? ok}) async {
    setState(() => _busy = true);
    try {
      await fn();
      await _load();
      if (ok != null && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok)));
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- actions ---------------------------------------------------------------------------------

  Future<void> _awardStamp() async {
    final res = await _api.get('/loyalty/customers/${widget.customerId}/eligible-sessions') as Map<String, dynamic>;
    final list = ((res['sessions'] as List?) ?? const []).cast<Map<String, dynamic>>();
    if (!mounted) return;
    final chosen = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Award a stamp for a verified session', style: Theme.of(ctx).textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text('Stamps are normally added automatically when a paid session ends. Use this only for a recent paid session that has no stamp yet.',
                style: TextStyle(color: LsColors.muted, fontSize: 12.5)),
            const SizedBox(height: 10),
            if (list.isEmpty) const Padding(padding: EdgeInsets.all(12), child: Text('No recent sessions without a stamp.')),
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                for (final s in list)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(s['eligible'] == true ? Icons.verified_outlined : Icons.block, color: s['eligible'] == true ? LsColors.green : LsColors.muted),
                    title: Text('${s['productName']} · ${_d(DateTime.tryParse(s['endedAt'] as String? ?? '')?.toLocal())}'),
                    subtitle: Text(s['eligible'] == true ? 'Paid ${formatMoney((s['paidMinor'] as num?)?.toInt(), (s['currency'] as String?) ?? 'ETB')}' : (s['message'] as String? ?? 'Not eligible')),
                    enabled: s['eligible'] == true,
                    onTap: () => Navigator.pop(ctx, s['sessionId'] as String),
                  ),
              ]),
            ),
          ]),
        ),
      ),
    );
    if (chosen == null) return;
    setState(() => _busy = true);
    try {
      final r = await _api.post('/loyalty/customers/${widget.customerId}/stamps', {'sessionId': chosen}) as Map<String, dynamic>;
      await _load();
      final st = StampResult.fromJson(r);
      if (st != null && mounted) await showStampResult(context, st, customerName: widget.customerName);
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handOverBurger(LoyaltyReward r) async {
    final note = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Hand over FREE BURGER'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Confirm that ${widget.customerName} has received their burger. Reward code ${r.code}.'),
          const SizedBox(height: 10),
          TextField(controller: note, decoration: const InputDecoration(labelText: 'Note (optional), e.g. which burger')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Burger handed over')),
        ],
      ),
    );
    if (ok != true) return;
    await _act(() => _api.post('/loyalty/rewards/${r.id}/redeem', {'note': note.text.trim().isEmpty ? null : note.text.trim()}), ok: 'Free burger marked as redeemed.');
  }

  Future<void> _voidReward(LoyaltyReward r) async {
    final reason = await showReasonDialog(context, title: 'Void ${r.label}', label: 'Reason (recorded in the audit log)', minLength: 3, confirmLabel: 'Void reward', danger: true);
    if (reason == null) return;
    await _act(() => _api.post('/loyalty/rewards/${r.id}/void', {'reason': reason}), ok: 'Reward voided.');
  }

  Future<void> _voidLastStamp(LoyaltyPosition p) async {
    final reason = await showReasonDialog(context, title: 'Void stamp ${p.position}', label: 'Reason, e.g. the payment was refunded', minLength: 3, confirmLabel: 'Void stamp', danger: true);
    if (reason == null) return;
    await _act(() => _api.post('/loyalty/stamps/${p.stampId}/void', {'reason': reason}), ok: 'Stamp voided.');
  }

  void _openCustomerView() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => CustomerCardScreen(customerId: widget.customerId)));
  }

  // ---- UI --------------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final o = _o;
    final head = Text('Loyalty', style: Theme.of(context).textTheme.titleMedium);
    if (_error != null && o == null) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        head,
        const SizedBox(height: 6),
        Card(child: ListTile(title: const Text('Loyalty details could not be loaded.'), subtitle: Text(_error!), trailing: TextButton(onPressed: _load, child: const Text('Retry')))),
      ]);
    }
    if (o == null) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [head, const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator()))]);
    }
    final me = _me;
    final pr = o.progress;
    final color = tierColor(o.tier.code);
    final available = o.availableRewards;
    final used = o.rewards.where((r) => !r.isAvailable).toList();
    final last = o.currentCard.status == 'ACTIVE' ? o.currentCard.lastStamp : null;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(child: head),
        if (_busy) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(20)),
          child: Text(o.tier.title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            o.hasAccount ? 'Member since ${fmtDate(o.joinedAt!)} · ${o.totalStamps} stamps total' : 'Not joined yet — joins automatically with the first paid session',
            style: const TextStyle(color: LsColors.muted, fontSize: 12.5),
          ),
        ),
      ]),
      const SizedBox(height: 10),
      GestureDetector(
        onTap: _openCustomerView,
        child: LoyaltyCardView(tier: o.tier.code, positions: o.currentCard.positions, name: o.customerName, completedVip: o.isMaxTierCompleted),
      ),
      const SizedBox(height: 10),
      Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (o.isMaxTierCompleted) ...[
              Row(children: [
                const Icon(Icons.workspace_premium, color: Color(0xFFD4A21A)),
                const SizedBox(width: 8),
                Expanded(child: Text('Maximum Light VIP status${o.maxTierCompletedAt != null ? ' since ${fmtDate(o.maxTierCompletedAt!)}' : ''}', style: const TextStyle(fontWeight: FontWeight.w800))),
              ]),
              const SizedBox(height: 4),
              const Text('All four cards are complete. Unused rewards stay available.', style: TextStyle(color: LsColors.muted)),
            ] else ...[
              Text('Card ${o.currentCard.cardNumber}: ${o.currentCard.stampsEarned} of 10 stamps', style: const TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(
                pr.isFinalTier ? 'Final VIP card — ${pr.stampsToCompleteCard} more stamps to complete the program' : '${pr.completedCardsInTier} of ${pr.cardsRequired} ${o.tier.title}s completed',
                style: const TextStyle(color: LsColors.muted),
              ),
              const SizedBox(height: 8),
              TierProgressIndicator(tier: o.tier.code, completed: pr.completedCardsInTier, required: pr.cardsRequired, stampsOnCard: pr.stampsOnCard),
              if (pr.nextTierTitle != null) ...[
                const SizedBox(height: 10),
                Text('Next: ${pr.nextTierTitle} in ${pr.stampsToNextTier} stamps', style: TextStyle(fontWeight: FontWeight.w700, color: tierColor(pr.nextTierCode!))),
                Text('Each ${pr.nextTierTitle} gives: ${_summarize(pr.nextTierRewards)}', style: const TextStyle(color: LsColors.muted, fontSize: 12.5)),
              ],
            ],
          ]),
        ),
      ),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton.icon(onPressed: _openCustomerView, icon: const Icon(Icons.qr_code_2), label: const Text('Show to customer')),
        if (me?.can('loyalty.stamp') == true && !o.isMaxTierCompleted)
          OutlinedButton.icon(onPressed: _busy ? null : _awardStamp, icon: const Icon(Icons.approval_outlined), label: const Text('Award stamp')),
        if (me?.can('loyalty.correct') == true && last != null)
          TextButton.icon(onPressed: _busy ? null : () => _voidLastStamp(last), icon: const Icon(Icons.undo, color: LsColors.red), label: Text('Void stamp ${last.position}', style: const TextStyle(color: LsColors.red))),
      ]),
      const SizedBox(height: 14),
      Text('Rewards wallet (${available.length} available)', style: const TextStyle(fontWeight: FontWeight.w700)),
      const SizedBox(height: 6),
      if (o.rewards.isEmpty)
        const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('No rewards earned yet.', style: TextStyle(color: LsColors.muted))),
      for (final r in available) _rewardTile(r, me),
      if (used.isNotEmpty)
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text('Used and voided rewards (${used.length})'),
          children: used.map((r) => _rewardTile(r, me)).toList(),
        ),
      if (o.completedCards.isNotEmpty)
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text('Completed cards (${o.completedCards.length})'),
          children: [
            for (final c in o.completedCards)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.style, color: tierColor(c.tier)),
                title: Text('${c.tierTitle} #${c.cardNumber}'),
                subtitle: Text('Completed ${_d(c.completedAt)} · ${c.rewardsEarned} reward(s)'),
              ),
          ],
        ),
      if (o.events.isNotEmpty)
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Loyalty history'),
          children: [for (final e in o.events.take(60)) _eventTile(e)],
        ),
    ]);
  }

  Widget _rewardTile(LoyaltyReward r, Me? me) {
    final statusColor = switch (r.status) { 'AVAILABLE' => LsColors.green, 'REDEEMED' => LsColors.gray, _ => LsColors.red };
    final detail = <String>[
      '${r.tierTitle}${r.cardNumber != null ? ' #${r.cardNumber}' : ''}, stamp ${r.position}',
      'earned ${_d(r.earnedAt)}',
      if (r.redeemedAt != null) 'used ${_d(r.redeemedAt)}${r.redeemedByName != null ? ' by ${r.redeemedByName}' : ''}',
      if (r.redemptionNote != null) r.redemptionNote!,
      if (r.voidReason != null) 'voided: ${r.voidReason}',
    ];
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        leading: Icon(r.type == 'free_burger' ? Icons.lunch_dining : r.type == 'free_session' ? Icons.celebration_outlined : Icons.percent, color: statusColor),
        title: Row(children: [
          Flexible(child: Text(r.label, style: const TextStyle(fontWeight: FontWeight.w800))),
          const SizedBox(width: 8),
          Text(r.status == 'AVAILABLE' ? 'Available' : r.status == 'REDEEMED' ? 'Redeemed' : 'Voided', style: TextStyle(color: statusColor, fontWeight: FontWeight.w700, fontSize: 12.5)),
        ]),
        subtitle: Text('${r.isAvailable && r.code != null ? 'Code ${r.code} · ' : ''}${detail.join(' · ')}'),
        isThreeLine: true,
        trailing: !r.isAvailable
            ? null
            : PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'burger') _handOverBurger(r);
                  if (v == 'void') _voidReward(r);
                  if (v == 'howto') {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Apply this reward at check-in, on the payment step, before taking payment.')));
                  }
                },
                itemBuilder: (_) => [
                  if (r.type == 'free_burger' && me?.can('loyalty.redeem') == true) const PopupMenuItem(value: 'burger', child: Text('Hand over burger')),
                  if (r.needsSession) const PopupMenuItem(value: 'howto', child: Text('How to use')),
                  if (me?.can('loyalty.correct') == true) const PopupMenuItem(value: 'void', child: Text('Void reward…')),
                ],
              ),
      ),
    );
  }

  Widget _eventTile(LoyaltyEvent e) {
    final m = e.metadata;
    final text = switch (e.action) {
      'account.joined' => 'Joined the loyalty program',
      'card.started' => 'Started ${m['tier'] ?? ''} card #${m['cardNumber'] ?? ''}',
      'stamp.awarded' => 'Stamp ${m['position']} on ${m['tier']} card #${m['cardNumber']}${m['method'] == 'STAFF_VERIFIED' ? ' (staff-verified)' : ''}',
      'reward.earned' => 'Earned ${m['rewardType'] ?? 'a reward'}',
      'reward.redeemed' => 'Redeemed ${m['rewardType'] ?? 'a reward'}',
      'reward.restored' => 'Reward returned (${m['reason'] ?? ''})',
      'reward.voided' => 'Reward voided: ${m['reason'] ?? ''}',
      'stamp.voided' => 'Stamp ${m['position']} voided: ${m['reason'] ?? ''}',
      'card.completed' => 'Completed ${m['tier']} card #${m['cardNumber']}',
      'tier.advanced' => 'Advanced from ${m['from']} to ${m['to']}',
      'program.completed' => 'Reached maximum Light VIP status',
      'card_link.issued' => 'Customer card link created',
      'card_link.rotated' => 'Customer card link replaced',
      _ => e.action,
    };
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(text.replaceAll('discount_50_percent', '50% OFF').replaceAll('free_session', 'FREE SESSION').replaceAll('free_burger', 'FREE BURGER')),
      subtitle: Text('${_d(e.createdAt)}${e.actorName != null ? ' · ${e.actorName}' : ''}'),
    );
  }
}
