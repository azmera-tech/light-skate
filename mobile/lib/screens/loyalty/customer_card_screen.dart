import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../api/api_client.dart';
import '../../models/loyalty.dart';
import '../../theme.dart';
import '../../widgets/loyalty_card_view.dart';

/// The customer-facing view: the card as the customer sees it (no staff data), their rewards with
/// codes, and a QR code for their private link so they can follow their progress on their phone.
class CustomerCardScreen extends StatefulWidget {
  final String customerId;
  const CustomerCardScreen({super.key, required this.customerId});
  @override
  State<CustomerCardScreen> createState() => _CustomerCardScreenState();
}

class _CustomerCardScreenState extends State<CustomerCardScreen> {
  late ApiClient _api;
  LoyaltyOverview? _o;
  String? _link;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    _api = await ApiClient.instance();
    try {
      final j = await _api.get('/loyalty/customers/${widget.customerId}') as Map<String, dynamic>;
      if (mounted) setState(() => _o = LoyaltyOverview.fromJson(j));
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<void> _issueLink({bool rotate = false}) async {
    if (rotate) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Replace the customer link?'),
          content: const Text('The old link and QR code will stop working immediately. Use this if the link was shared with the wrong person.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Replace link')),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _busy = true);
    try {
      final r = await _api.post('/loyalty/customers/${widget.customerId}/card-link', {'rotate': rotate}) as Map<String, dynamic>;
      if (mounted) setState(() => _link = '${_api.baseUrl}${r['path']}');
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = _o;
    return Scaffold(
      backgroundColor: const Color(0xFF0E1116),
      appBar: AppBar(backgroundColor: const Color(0xFF0E1116), foregroundColor: Colors.white, title: const Text('Customer loyalty card')),
      body: o == null
          ? Center(child: _error != null ? Text(_error!, style: const TextStyle(color: Colors.white)) : const CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              LoyaltyCardView(tier: o.tier.code, positions: o.currentCard.positions, name: o.customerName.split(RegExp(r'\s+')).first, completedVip: o.isMaxTierCompleted),
              const SizedBox(height: 14),
              Text(
                o.isMaxTierCompleted
                    ? 'You have completed every card — Light VIP!'
                    : '${o.tier.title} · ${o.currentCard.stampsEarned} of 10 stamps${o.progress.nextTierTitle != null ? ' · ${o.progress.stampsToNextTier} stamps to ${o.progress.nextTierTitle}' : ''}',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 14),
              if (o.availableRewards.isNotEmpty) ...[
                const Text('Your rewards', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                for (final r in o.availableRewards)
                  Card(
                    color: const Color(0xFF1B212B),
                    child: ListTile(
                      leading: const Icon(Icons.card_giftcard, color: Color(0xFF4ADE80)),
                      title: Text(r.label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800)),
                      subtitle: Text('Code ${r.code ?? ''}', style: const TextStyle(color: Colors.white70, letterSpacing: 1)),
                    ),
                  ),
              ],
              const SizedBox(height: 14),
              Card(
                color: Colors.white,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: _link == null
                      ? Column(children: [
                          const Text('Let the customer follow their card on their own phone.', textAlign: TextAlign.center),
                          const SizedBox(height: 10),
                          FilledButton.icon(onPressed: _busy ? null : () => _issueLink(), icon: const Icon(Icons.qr_code_2), label: const Text('Show QR code')),
                        ])
                      : Column(children: [
                          QrImageView(data: _link!, size: 220, backgroundColor: Colors.white),
                          const SizedBox(height: 8),
                          const Text('Scan to open your Light Skate card', style: TextStyle(fontWeight: FontWeight.w700)),
                          const SizedBox(height: 4),
                          SelectableText(_link!, textAlign: TextAlign.center, style: const TextStyle(color: LsColors.muted, fontSize: 12)),
                          const SizedBox(height: 8),
                          Wrap(spacing: 8, children: [
                            OutlinedButton.icon(
                              onPressed: () async {
                                await Clipboard.setData(ClipboardData(text: _link!));
                                if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Link copied.')));
                              },
                              icon: const Icon(Icons.copy),
                              label: const Text('Copy link'),
                            ),
                            TextButton(onPressed: _busy ? null : () => _issueLink(rotate: true), child: const Text('Replace link')),
                          ]),
                        ]),
                ),
              ),
            ]),
    );
  }
}
