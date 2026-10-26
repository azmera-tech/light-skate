import 'package:flutter/material.dart';
import '../../api/api_client.dart';
import '../../api/realtime_bus.dart';
import '../../format.dart';
import '../../models/playstation.dart';
import '../../theme.dart';
import '../../widgets/ps_proof_image.dart';
import '../../widgets/ps_sheet.dart';
import '../../widgets/reason_dialog.dart';

/// Admin payment verification: non-cash payments waiting for a decision, with their evidence.
/// Verify records who and when and re-computes the session balance; Reject needs a reason and keeps the
/// evidence. The server refuses self-verification and double decisions; this screen only reflects that.
class PsVerificationScreen extends StatefulWidget {
  const PsVerificationScreen({super.key});
  @override
  State<PsVerificationScreen> createState() => _PsVerificationScreenState();
}

class _PsVerificationScreenState extends State<PsVerificationScreen> {
  late ApiClient _api;
  String _status = 'PENDING';
  List<PsPayment>? _rows;
  Map<String, dynamic> _counts = const {};
  String? _error;
  final Set<String> _busy = {};

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
    if (e != null && (e.event == 'RESYNC' || e.event.startsWith('PS_PAYMENT'))) _load();
  }

  Future<void> _boot() async {
    _api = await ApiClient.instance();
    await _load();
  }

  Future<void> _load() async {
    try {
      final j = await _api.get('/playstation/payments?status=$_status') as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _rows = ((j['payments'] as List?) ?? const []).map((e) => PsPayment.fromJson(e as Map<String, dynamic>)).toList();
        _counts = (j['counts'] as Map?)?.cast<String, dynamic>() ?? const {};
        _error = null;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<void> _decide(PsPayment p, bool verify) async {
    String? reason;
    if (!verify) {
      reason = await showReasonDialog(context, title: 'Reject payment', label: 'Why is it rejected? (the employee sees this)', minLength: 3, confirmLabel: 'Reject', danger: true);
      if (reason == null) return;
    } else {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Verify this payment?'),
          content: Text('Confirm that ${formatMoney(p.amountMinor, 'ETB')} (${titleCaseLabel(p.method.toLowerCase())}${p.reference != null ? ', ref ${p.reference}' : ''}) really reached the venue account. It is then counted as received.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not yet')),
            FilledButton(style: FilledButton.styleFrom(backgroundColor: LsColors.green), onPressed: () => Navigator.pop(ctx, true), child: const Text('Verify')),
          ],
        ),
      );
      if (ok != true) return;
    }
    setState(() => _busy.add(p.id));
    try {
      await _api.post('/playstation/payments/${p.id}/${verify ? 'verify' : 'reject'}', verify ? {} : {'reason': reason});
      _snack(verify ? 'Payment verified.' : 'Payment rejected — the employee is notified.');
    } on ApiException catch (e) {
      _snack(e.message);
    } finally {
      if (mounted) setState(() => _busy.remove(p.id));
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
        child: Row(children: [
          Expanded(
            child: SegmentedButton<String>(
              segments: [
                ButtonSegment(value: 'PENDING', label: Text('Pending${(_counts['pending'] ?? 0) > 0 ? ' (${_counts['pending']})' : ''}')),
                const ButtonSegment(value: 'PAID', label: Text('Verified')),
                const ButtonSegment(value: 'REJECTED', label: Text('Rejected')),
              ],
              selected: {_status},
              onSelectionChanged: (v) {
                setState(() {
                  _status = v.first;
                  _rows = null;
                });
                _load();
              },
            ),
          ),
        ]),
      ),
      if ((_counts['pendingMinor'] ?? 0) is num && (_counts['pendingMinor'] as num) > 0 && _status == 'PENDING')
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Align(alignment: Alignment.centerLeft, child: Text('${formatMoney((_counts['pendingMinor'] as num).toInt(), 'ETB')} waiting for a decision', style: const TextStyle(color: LsColors.orange, fontWeight: FontWeight.w700))),
        ),
      Expanded(
        child: rows == null
            ? Center(child: _error != null ? Padding(padding: const EdgeInsets.all(20), child: Text(_error!, style: const TextStyle(color: LsColors.red))) : const CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(padding: scrollPadding(context), children: [
                  if (rows.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 48),
                      child: Text(_status == 'PENDING' ? 'Nothing is waiting for verification.' : 'No payments here.', textAlign: TextAlign.center, style: const TextStyle(color: LsColors.muted)),
                    ),
                  for (final p in rows) _tile(p),
                ]),
              ),
      ),
    ]);
  }

  Widget _tile(PsPayment p) {
    final working = _busy.contains(p.id);
    final mine = _api.me?.id == p.recordedBy;
    String t(DateTime? d) => d == null ? '—' : '${fmtDate(d)} ${fmtHHMM(d)}';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(formatMoney(p.amountMinor, 'ETB'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900))),
            Text(p.statusLabel, style: TextStyle(fontWeight: FontWeight.w800, color: p.isPending ? LsColors.orange : p.status == 'REJECTED' ? LsColors.red : LsColors.green)),
          ]),
          const SizedBox(height: 2),
          Text('${p.consoleCode ?? ''} · ${p.sessionNumber ?? ''} · ${p.playerName ?? 'Walk-in'}${p.packageName != null ? ' · ${p.packageName}' : ''}', style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            [
              titleCaseLabel(p.method.toLowerCase()),
              if (p.reference != null) 'ref ${p.reference}',
              'by ${p.recordedByName ?? '—'}',
              t(p.createdAt),
            ].join(' · '),
            style: const TextStyle(color: LsColors.muted, fontSize: 12.5),
          ),
          if (p.status == 'REJECTED' && p.rejectReason != null)
            Padding(padding: const EdgeInsets.only(top: 6), child: Text('Rejected by ${p.rejectedByName ?? 'admin'}: ${p.rejectReason}', style: const TextStyle(color: LsColors.red, fontWeight: FontWeight.w600))),
          if (p.status == 'PAID' && p.confirmedByName != null)
            Padding(padding: const EdgeInsets.only(top: 6), child: Text('Verified by ${p.confirmedByName} · ${t(p.paidAt)}', style: const TextStyle(color: LsColors.green, fontWeight: FontWeight.w600))),
          const SizedBox(height: 8),
          if (p.hasProof) PsProofImage(paymentId: p.id, height: 160) else const Text('No evidence image attached.', style: TextStyle(color: LsColors.red, fontWeight: FontWeight.w600)),
          if (p.isPending) ...[
            const SizedBox(height: 8),
            if (mine) const Text('You recorded this payment, so another admin has to verify it.', style: TextStyle(color: LsColors.muted, fontSize: 12.5)),
            Row(children: [
              Expanded(child: OutlinedButton.icon(style: OutlinedButton.styleFrom(foregroundColor: LsColors.red), onPressed: working ? null : () => _decide(p, false), icon: const Icon(Icons.close), label: const Text('Reject'))),
              const SizedBox(width: 10),
              Expanded(child: FilledButton.icon(style: FilledButton.styleFrom(backgroundColor: LsColors.green), onPressed: working ? null : () => _decide(p, true), icon: working ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.check), label: const Text('Verify'))),
            ]),
          ],
        ]),
      ),
    );
  }
}

/// Standalone page wrapper (opened from Quick Actions and from the admin module).
class PsVerificationPage extends StatelessWidget {
  const PsVerificationPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: const Text('Payment verification')), body: const PsVerificationScreen());
}
