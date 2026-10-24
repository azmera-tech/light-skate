import 'dart:async';
import 'package:flutter/material.dart';
import '../../api/api_client.dart';
import '../../format.dart';
import '../../theme.dart';
import '../../widgets/loyalty_card_view.dart';
import '../customers/customer_profile_screen.dart';

const _tiers = ['STANDARD', 'GOLDEN', 'DIAMOND', 'LIGHT'];
const _tierTitle = {'STANDARD': 'Standard', 'GOLDEN': 'Golden', 'DIAMOND': 'Diamond', 'LIGHT': 'Light'};

/// Admin view of the loyalty program: members per tier, member search, reward validation by
/// code, and the venue-wide stamp/redemption/correction history.
class LoyaltyAdminScreen extends StatefulWidget {
  const LoyaltyAdminScreen({super.key});
  @override
  State<LoyaltyAdminScreen> createState() => _LoyaltyAdminScreenState();
}

class _LoyaltyAdminScreenState extends State<LoyaltyAdminScreen> {
  late ApiClient _api;
  Map<String, dynamic>? _data;
  List<Map<String, dynamic>> _events = [];
  String? _tier;
  final _q = TextEditingController();
  Timer? _debounce;
  String? _error;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _boot() async {
    _api = await ApiClient.instance();
    await _load();
  }

  Future<void> _load() async {
    try {
      final params = <String>[if (_tier != null) 'tier=$_tier', if (_q.text.trim().isNotEmpty) 'q=${Uri.encodeQueryComponent(_q.text.trim())}'];
      final j = await _api.get('/loyalty/members${params.isEmpty ? '' : '?${params.join('&')}'}') as Map<String, dynamic>;
      final a = await _api.get('/loyalty/activity?limit=60') as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _data = j;
        _events = ((a['events'] as List?) ?? const []).cast<Map<String, dynamic>>();
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _lookupReward() async {
    final ctrl = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Validate a reward code'),
        content: TextField(controller: ctrl, autofocus: true, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(labelText: 'Code, e.g. K7QF-2MXA')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Check')),
        ],
      ),
    );
    if (code == null || code.isEmpty || !mounted) return;
    try {
      final r = await _api.get('/loyalty/rewards/lookup?code=${Uri.encodeQueryComponent(code)}') as Map<String, dynamic>;
      final reward = r['reward'] as Map<String, dynamic>;
      final cust = r['customer'] as Map<String, dynamic>;
      final blocker = r['blocker'] as Map<String, dynamic>?;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: Icon(blocker == null ? Icons.verified : Icons.block, color: blocker == null ? LsColors.green : LsColors.red, size: 40),
          title: Text('${reward['label']} — ${blocker == null ? 'valid' : 'cannot be used'}'),
          content: Text([
            'Belongs to ${cust['fullName']} (${cust['customerCode']}).',
            'Earned on the ${reward['tierTitle']} #${reward['cardNumber']}, stamp ${reward['position']}.',
            'Status: ${reward['status']}.',
            if (blocker != null) blocker['message'] as String,
            if (blocker == null && r['needsSession'] == true) 'Apply it during check-in on the payment step.',
          ].join('\n\n')),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => CustomerProfileScreen(customerId: cust['id'] as String)));
              },
              child: const Text('Open customer'),
            ),
          ],
        ),
      );
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.status == 404 ? 'No reward has that code.' : e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final tiers = ((d?['tiers'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final members = ((d?['members'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final rewards = (d?['rewards'] as Map?)?.cast<String, dynamic>() ?? const {};
    return Scaffold(
      appBar: AppBar(title: const Text('Loyalty program'), actions: [
        IconButton(onPressed: _lookupReward, icon: const Icon(Icons.qr_code_scanner), tooltip: 'Validate a reward code'),
      ]),
      body: d == null
          ? Center(child: _error != null ? Text(_error!) : const CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.all(14), children: [
                Row(children: [
                  for (final t in tiers)
                    Expanded(
                      child: Card(
                        color: tierColor(t['code'] as String).withValues(alpha: 0.10),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
                          child: Column(children: [
                            Text('${t['members']}', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: tierColor(t['code'] as String))),
                            Text(_tierTitle[t['code']] ?? '', style: const TextStyle(fontSize: 12)),
                            if ((t['completed'] as num? ?? 0) > 0) Text('${t['completed']} VIP', style: const TextStyle(fontSize: 11, color: LsColors.muted)),
                          ]),
                        ),
                      ),
                    ),
                ]),
                const SizedBox(height: 6),
                Text('Rewards: ${rewards['available'] ?? 0} available · ${rewards['redeemed'] ?? 0} redeemed · ${rewards['voided'] ?? 0} voided', style: const TextStyle(color: LsColors.muted)),
                const SizedBox(height: 12),
                TextField(
                  controller: _q,
                  decoration: const InputDecoration(prefixIcon: Icon(Icons.search), labelText: 'Search members by name or phone'),
                  onChanged: (_) {
                    _debounce?.cancel();
                    _debounce = Timer(const Duration(milliseconds: 350), _load);
                  },
                ),
                const SizedBox(height: 8),
                Wrap(spacing: 6, children: [
                  ChoiceChip(label: const Text('All tiers'), selected: _tier == null, onSelected: (_) { setState(() => _tier = null); _load(); }),
                  for (final t in _tiers)
                    ChoiceChip(label: Text(_tierTitle[t]!), selected: _tier == t, onSelected: (_) { setState(() => _tier = t); _load(); }),
                ]),
                const SizedBox(height: 8),
                if (members.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('No loyalty members yet. Customers join automatically with their first paid session.', style: TextStyle(color: LsColors.muted))),
                for (final m in members)
                  Card(
                    margin: const EdgeInsets.only(bottom: 6),
                    child: ListTile(
                      leading: CircleAvatar(backgroundColor: tierColor(m['tier'] as String), child: Text((m['fullName'] as String).isEmpty ? '?' : (m['fullName'] as String)[0], style: const TextStyle(color: Colors.white))),
                      title: Text(m['fullName'] as String, style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text('${m['tierTitle']} #${m['cardNumber'] ?? 1} · ${m['stampsOnCard'] ?? 0}/10 · ${m['totalStamps']} stamps total${(m['availableRewards'] as num? ?? 0) > 0 ? ' · ${m['availableRewards']} reward(s) to use' : ''}${m['isMaxTierCompleted'] == true ? ' · VIP complete' : ''}'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => CustomerProfileScreen(customerId: m['customerId'] as String))).then((_) => _load()),
                    ),
                  ),
                const SizedBox(height: 14),
                Text('Recent loyalty activity', style: Theme.of(context).textTheme.titleMedium),
                for (final e in _events)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text('${e['customerName']}: ${_label(e)}'),
                    subtitle: Text('${_fmt(e['createdAt'])}${e['actorName'] != null ? ' · ${e['actorName']}' : ' · automatic'}'),
                  ),
              ]),
            ),
    );
  }

  String _fmt(dynamic iso) {
    final t = iso == null ? null : DateTime.tryParse(iso as String)?.toLocal();
    return t == null ? '' : '${fmtDate(t)} ${fmtHHMM(t)}';
  }

  String _label(Map<String, dynamic> e) {
    final m = (e['metadata'] as Map?)?.cast<String, dynamic>() ?? const {};
    final reward = (m['rewardType'] as String? ?? '').replaceAll('discount_50_percent', '50% OFF').replaceAll('free_session', 'FREE SESSION').replaceAll('free_burger', 'FREE BURGER');
    return switch (e['action']) {
      'stamp.awarded' => 'stamp ${m['position']} (${m['tier']} #${m['cardNumber']})',
      'reward.earned' => 'earned $reward',
      'reward.redeemed' => 'redeemed $reward',
      'reward.voided' => 'reward voided — ${m['reason'] ?? ''}',
      'reward.restored' => 'reward returned — ${m['reason'] ?? ''}',
      'stamp.voided' => 'stamp voided — ${m['reason'] ?? ''}',
      'card.completed' => 'completed ${m['tier']} card #${m['cardNumber']}',
      'tier.advanced' => 'advanced to ${m['to']}',
      'program.completed' => 'reached Light VIP',
      'account.joined' => 'joined the program',
      'card.started' => 'started ${m['tier']} card #${m['cardNumber']}',
      _ => e['action'] as String,
    };
  }
}
