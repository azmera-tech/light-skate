import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../alarm/expiry_alarm_service.dart';
import '../../api/api_client.dart';
import '../../api/realtime_bus.dart';
import '../../format.dart';
import '../../models/me.dart';
import '../../models/playstation.dart';
import '../../theme.dart';
import '../../widgets/ps_proof_image.dart';
import '../../widgets/ps_sheet.dart';
import '../../widgets/reason_dialog.dart';
import 'ps_checkout_sheet.dart';
import 'ps_end_flow.dart';

String _t(DateTime? t) => t == null ? '—' : '${fmtDate(t)} ${fmtHHMM(t)}';

/// One gaming session: live billing, the one-tap **+ Add Game**, End Session → checkout, and payment status.
/// Every number comes from the server; taps are applied immediately and reconciled with the server's answer.
class PsSessionScreen extends StatefulWidget {
  final String sessionId;
  const PsSessionScreen({super.key, required this.sessionId});
  @override
  State<PsSessionScreen> createState() => _PsSessionScreenState();
}

class _PsSessionScreenState extends State<PsSessionScreen> {
  late ApiClient _api;
  Me? _me;
  PsSessionDetail? _d;
  int _warningMinutes = 5;
  bool _pauseEnabled = true;
  String? _error;
  bool _busy = false;
  Timer? _tick;
  int _pendingAdds = 0;
  Future<void> _chain = Future.value();
  Timer? _reloadSoon;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => mounted && _d?.status == 'ACTIVE' ? setState(() {}) : null);
    RealtimeBus.last.addListener(_onRealtime);
    _boot();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _reloadSoon?.cancel();
    RealtimeBus.last.removeListener(_onRealtime);
    super.dispose();
  }

  void _onRealtime() {
    final e = RealtimeBus.last.value;
    if (e == null) return;
    if (e.event == 'RESYNC' || e.data['aggregateId'] == widget.sessionId || (e.data['payload'] as Map?)?['sessionId'] == widget.sessionId) {
      _reloadSoon?.cancel();
      _reloadSoon = Timer(const Duration(milliseconds: 350), () {
        if (_pendingAdds == 0) _load();
      });
    }
  }

  Future<void> _boot() async {
    _api = await ApiClient.instance();
    _me = _api.me;
    try {
      final st = await _api.get('/playstation/settings') as Map<String, dynamic>;
      final s = (st['settings'] as Map?)?.cast<String, dynamic>() ?? const {};
      _warningMinutes = (s['warningMinutes'] as num?)?.toInt() ?? 5;
      _pauseEnabled = s['pauseEnabled'] != false;
    } catch (_) {}
    await _load();
  }

  Future<void> _load() async {
    try {
      final j = await _api.get('/playstation/sessions/${widget.sessionId}') as Map<String, dynamic>;
      final d = PsSessionDetail.fromJson(j);
      if (!mounted) return;
      setState(() {
        _d = d;
        _error = null;
      });
      if (d.status == 'ACTIVE' && d.isTimed && d.expectedEndAt != null) {
        unawaited(ExpiryAlarmService.instance.scheduleGamingAlerts(
            sessionId: d.id, consoleCode: d.consoleCode, playerName: d.playerName ?? 'Player', expectedEndAt: d.expectedEndAt!, warningMinutes: _warningMinutes));
      } else {
        unawaited(ExpiryAlarmService.instance.cancelGamingAlerts(d.id));
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  Future<T?> _run<T>(Future<T> Function() fn, {String? ok}) async {
    setState(() => _busy = true);
    try {
      final r = await fn();
      await _load();
      if (ok != null && mounted) _snack(ok);
      return r;
    } on ApiException catch (e) {
      if (mounted) _snack(e.message);
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- + Add Game: optimistic, strictly ordered, reconciled with the server's total ---------------

  void _addGame() {
    HapticFeedback.mediumImpact();
    setState(() => _pendingAdds++);
    _chain = _chain.then((_) async {
      try {
        await _api.post('/playstation/sessions/${widget.sessionId}/games', {'delta': 1});
      } on ApiException catch (e) {
        if (mounted) _snack(e.message);
      } finally {
        if (mounted) setState(() => _pendingAdds = (_pendingAdds - 1).clamp(0, 1 << 30));
        if (_pendingAdds == 0) await _load();
      }
    });
  }

  Future<void> _removeGame() async {
    final d = _d!;
    if (d.quantity + _pendingAdds <= 0) return;
    final reason = await showReasonDialog(context, title: 'Correct the game count', label: 'Why remove a game? (recorded)', minLength: 3, confirmLabel: 'Remove 1 game');
    if (reason == null) return;
    await _chain;
    await _run(() => _api.post('/playstation/sessions/${d.id}/games', {'delta': -1, 'reason': reason}), ok: 'Game removed — total updated.');
  }

  // ---- end + checkout -----------------------------------------------------------------------------

  Future<void> _endAndCheckout() async {
    await _chain;
    final d = _d!;
    setState(() => _busy = true);
    if (!mounted) return;
    await endSessionAndCheckout(context, _api,
        sessionId: d.id, consoleCode: d.consoleCode, perGame: d.pricingType == 'PER_GAME', quantity: d.quantity, unitPriceMinor: d.unitPriceMinor, totalMinor: d.totalMinor, remainingSeconds: d.liveRemaining(_api.serverNow()));
    if (mounted) setState(() => _busy = false);
    await _load();
  }

  Future<void> _checkout() async {
    await showPsCheckoutSheet(context, widget.sessionId);
    await _load();
  }

  Future<void> _extend() async {
    final d = _d!;
    final pj = await _api.get('/playstation/packages') as Map<String, dynamic>;
    final pkgs = ((pj['packages'] as List?) ?? const []).map((e) => PsPackage.fromJson(e as Map<String, dynamic>)).where((p) => p.pricingType == 'DURATION').toList();
    if (!mounted) return;
    PsPackage? pkg = pkgs.firstOrNull;
    int qty = 1;
    final picked = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
            title: const Text('Add time'),
            content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (pkgs.isEmpty) const Text('No active time packages.'),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final p in pkgs) ChoiceChip(label: Text('${p.unitLabel} · ${formatMoney(p.priceMinor, 'ETB')}'), selected: pkg?.id == p.id, onSelected: (_) => setD(() => pkg = p)),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                const Text('Quantity'),
                const Spacer(),
                IconButton(onPressed: qty > 1 ? () => setD(() => qty--) : null, icon: const Icon(Icons.remove_circle_outline)),
                Text('$qty', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                IconButton(onPressed: qty < 50 ? () => setD(() => qty++) : null, icon: const Icon(Icons.add_circle_outline)),
              ]),
              if (pkg != null) Text('Adds ${formatMoney(pkg!.priceMinor * qty, 'ETB')} to the bill (paid at checkout).', style: const TextStyle(fontWeight: FontWeight.w700)),
            ]),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(onPressed: pkg == null ? null : () => Navigator.pop(ctx, true), child: const Text('Add time')),
            ],
          )),
    );
    if (picked != true || pkg == null) return;
    await _run(() => _api.post('/playstation/sessions/${d.id}/extend', {'packageId': pkg!.id, 'quantity': qty}), ok: 'Time added.');
  }

  Future<void> _cancel() async {
    final reason = await showReasonDialog(context, title: 'Cancel this session', label: 'Reason', minLength: 3, confirmLabel: 'Cancel session', danger: true);
    if (reason == null) return;
    await _run(() => _api.post('/playstation/sessions/${widget.sessionId}/cancel', {'reason': reason}), ok: 'Session cancelled.');
  }

  Future<void> _correctEnded(int delta) async {
    final reason = await showReasonDialog(context, title: delta > 0 ? 'Add a missed game' : 'Remove a game', label: 'Reason (admin correction, recorded)', minLength: 3, confirmLabel: 'Apply correction');
    if (reason == null) return;
    await _run(() => _api.post('/playstation/sessions/${widget.sessionId}/games', {'delta': delta, 'reason': reason}), ok: 'Bill corrected.');
  }

  Future<void> _refund(PsPayment p) async {
    final amount = TextEditingController(text: ((p.amountMinor - p.refundedMinor) / 100).toStringAsFixed(2));
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Refund payment'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Amount (ETB)')),
          const SizedBox(height: 8),
          TextField(controller: reason, decoration: const InputDecoration(labelText: 'Reason')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: LsColors.red), onPressed: () => Navigator.pop(ctx, true), child: const Text('Refund')),
        ],
      ),
    );
    if (ok != true) return;
    final minor = ((double.tryParse(amount.text.trim()) ?? 0) * 100).round();
    await _run(() => _api.post('/playstation/payments/${p.id}/refund', {'amountMinor': minor, 'reason': reason.text.trim()}), ok: 'Refund recorded.');
  }

  Future<void> _withdraw(PsPayment p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Withdraw this payment?'),
        content: Text('${formatMoney(p.amountMinor, 'ETB')} (${titleCase(p.method)}) is still waiting for verification. Withdrawing keeps the record but it will no longer be reviewed.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Withdraw')),
        ],
      ),
    );
    if (ok == true) await _run(() => _api.post('/playstation/payments/${p.id}/cancel', {}), ok: 'Payment withdrawn.');
  }

  void _showReceipt() {
    final r = _d!.receipt;
    final lines = ((r['lines'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final pays = ((r['payments'] as List?) ?? const []).cast<Map<String, dynamic>>();
    int n(dynamic v) => (v as num?)?.toInt() ?? 0;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${r['venueName'] ?? 'Light Skate'} — PlayStation'),
        content: SingleChildScrollView(
          child: DefaultTextStyle.merge(
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text('Receipt ${r['sessionNumber']}'),
              Text('${r['console']}'),
              Text('Player: ${r['player'] ?? '—'}'),
              Text('Served by: ${r['operator'] ?? '—'}'),
              Text('Started: ${_t(DateTime.tryParse(r['startedAt'] as String? ?? '')?.toLocal())}'),
              if (r['endedAt'] != null) Text('Ended: ${_t(DateTime.tryParse(r['endedAt'] as String)?.toLocal())}'),
              const Divider(),
              for (final l in lines) Text('${l['description']}${n(l['quantity']) != 1 ? ' ×${l['quantity']}' : ''}${l['kind'] == 'EXTENSION' ? ' (ext.)' : ''}\n   ${formatMoney(n(l['unitPriceMinor']), 'ETB')} each = ${formatMoney(n(l['totalMinor']), 'ETB')}'),
              const Divider(),
              Text('TOTAL    ${formatMoney(n(r['totalMinor']), 'ETB')}', style: const TextStyle(fontWeight: FontWeight.w900)),
              Text('PAID     ${formatMoney(n(r['paidMinor']), 'ETB')}'),
              if (n(r['pendingMinor']) > 0) Text('PENDING  ${formatMoney(n(r['pendingMinor']), 'ETB')} (awaiting verification)'),
              if (n(r['refundedMinor']) > 0) Text('REFUNDED ${formatMoney(n(r['refundedMinor']), 'ETB')}'),
              if (n(r['balanceMinor']) > 0) Text('BALANCE  ${formatMoney(n(r['balanceMinor']), 'ETB')}', style: const TextStyle(color: LsColors.red)),
              const SizedBox(height: 6),
              for (final p in pays) Text('${titleCase(p['method'] as String)} ${formatMoney(n(p['amountMinor']), 'ETB')} · ${titleCase(p['status'] as String)}${p['reference'] != null ? ' · ref ${p['reference']}' : ''}'),
            ]),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')), TextButton(onPressed: () { Clipboard.setData(ClipboardData(text: r.toString())); Navigator.pop(ctx); }, child: const Text('Copy'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    return Scaffold(
      appBar: AppBar(title: Text(d == null ? 'Gaming session' : '${d.consoleCode} · ${d.sessionNumber}'), actions: [
        if (d != null) IconButton(onPressed: _showReceipt, icon: const Icon(Icons.receipt_long_outlined), tooltip: 'Receipt'),
      ]),
      body: d == null
          ? Center(child: _error != null ? Text(_error!) : const CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: scrollPadding(context), children: [_hero(d), const SizedBox(height: 12), _money(d), const SizedBox(height: 12), _actions(d), const SizedBox(height: 16), ..._details(d)]),
            ),
    );
  }

  // Live numbers = what the server last confirmed + taps still on their way.
  int _units(PsSessionDetail d) => d.quantity + _pendingAdds;
  int _total(PsSessionDetail d) => d.totalMinor + _pendingAdds * d.unitPriceMinor;

  Widget _hero(PsSessionDetail d) {
    final rem = d.liveRemaining(_api.serverNow());
    final warn = rem != null && rem <= _warningMinutes * 60;
    final playing = d.status == 'ACTIVE';
    final bg = playing ? (rem != null && rem <= 0 ? LsColors.redSoft : warn ? LsColors.orangeSoft : LsColors.greenSoft) : d.status == 'PAUSED' ? LsColors.slateSoft : LsColors.surface2;
    final fg = playing ? (rem != null && rem <= 0 ? LsColors.red : warn ? LsColors.orange : LsColors.green) : LsColors.slate;
    final label = d.isEnded ? (d.balanceMinor > 0 ? (d.pendingMinor > 0 && d.toCollectMinor == 0 ? 'Ended · payment pending verification' : 'Ended · awaiting payment') : 'Ended · paid') : (psStatusLabel[d.status] ?? d.status);
    return Card(
      color: bg,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Text(label, style: TextStyle(color: fg, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          if (d.pricingType == 'PER_GAME') ...[
            Semantics(
              liveRegion: true,
              label: '${_units(d)} games, total ${formatMoney(_total(d), 'ETB')}',
              child: Text('${_units(d)} ${_units(d) == 1 ? 'game' : 'games'}', style: TextStyle(fontSize: 46, fontWeight: FontWeight.w900, color: fg)),
            ),
            Text('${formatMoney(d.unitPriceMinor, 'ETB')} each · running total ${formatMoney(_total(d), 'ETB')}', style: const TextStyle(color: LsColors.muted, fontWeight: FontWeight.w600)),
          ] else if (rem != null && d.isPlaying) ...[
            Text(fmtClock(rem), style: TextStyle(fontSize: 46, fontWeight: FontWeight.w900, color: fg, fontFeatures: const [FontFeature.tabularFigures()])),
            if (d.expectedEndAt != null) Text('Ends ${fmtHHMM(d.expectedEndAt)} (server time)', style: const TextStyle(color: LsColors.muted)),
          ] else
            Text(formatDuration(d.purchasedSeconds), style: TextStyle(fontSize: 38, fontWeight: FontWeight.w900, color: fg)),
          const SizedBox(height: 6),
          Text('${d.playerName ?? '—'}${d.customerCode != null ? ' · ${d.customerCode}' : ''} · ${d.packageName}', style: const TextStyle(fontWeight: FontWeight.w700), textAlign: TextAlign.center),
          if (d.pricingType == 'PER_GAME' && d.isPlaying) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 64,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: LsColors.green, textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                onPressed: d.status == 'ACTIVE' ? _addGame : null,
                icon: const Icon(Icons.add_circle_outline, size: 30),
                label: const Text('+ Add Game'),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(onPressed: _busy || _units(d) <= 0 ? null : _removeGame, icon: const Icon(Icons.remove_circle_outline, size: 18), label: const Text('Remove a game (correction)')),
            ),
          ],
        ]),
      ),
    );
  }

  Widget _money(PsSessionDetail d) {
    Widget row(String l, String v, {bool bold = false, Color? c}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [Expanded(child: Text(l, style: const TextStyle(color: LsColors.muted))), Text(v, style: TextStyle(fontWeight: bold ? FontWeight.w900 : FontWeight.w700, fontSize: bold ? 17 : 14.5, color: c))]),
        );
    final bal = math.max(0, _total(d) - d.settledMinor);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(children: [
          if (d.pricingType == 'PER_GAME') row('Unit price', formatMoney(d.unitPriceMinor, 'ETB')),
          row('Total charge', formatMoney(_total(d), 'ETB'), bold: true),
          row('Amount paid', formatMoney(d.settledMinor, 'ETB')),
          if (d.pendingMinor > 0) row('Awaiting verification', formatMoney(d.pendingMinor, 'ETB'), c: LsColors.orange),
          const Divider(height: 14),
          row('Outstanding balance', formatMoney(bal, 'ETB'), bold: true, c: bal > 0 ? LsColors.red : LsColors.green),
        ]),
      ),
    );
  }

  Widget _actions(PsSessionDetail d) {
    final can = _me?.can('playstation.operate') ?? false;
    final b = <Widget>[
      if (can && d.status == 'ACTIVE' && _pauseEnabled) OutlinedButton.icon(onPressed: _busy ? null : () => _run(() => _api.post('/playstation/sessions/${d.id}/pause', {}), ok: 'Paused — time is frozen.'), icon: const Icon(Icons.pause), label: const Text('Pause')),
      if (can && d.status == 'PAUSED') FilledButton.icon(onPressed: _busy ? null : () => _run(() => _api.post('/playstation/sessions/${d.id}/resume'), ok: 'Resumed.'), icon: const Icon(Icons.play_arrow), label: const Text('Resume')),
      if (can && d.isTimed && d.isPlaying) OutlinedButton.icon(onPressed: _busy ? null : _extend, icon: const Icon(Icons.more_time), label: const Text('Add time')),
      if (can && ['READY', 'PENDING_PAYMENT'].contains(d.status)) FilledButton.icon(onPressed: _busy ? null : () => _run(() => _api.post('/playstation/sessions/${d.id}/start'), ok: 'Started.'), icon: const Icon(Icons.play_arrow), label: const Text('Start')),
      if (can && d.isPlaying) FilledButton.icon(style: FilledButton.styleFrom(backgroundColor: LsColors.red), onPressed: _busy ? null : _endAndCheckout, icon: const Icon(Icons.stop), label: const Text('End Session')),
      if (can && d.status != 'CANCELLED' && (d.toCollectMinor > 0 && (d.isEnded || d.isPlaying))) FilledButton.icon(onPressed: _busy ? null : _checkout, icon: const Icon(Icons.payments_outlined), label: Text(d.isEnded ? 'Checkout · ${formatMoney(d.toCollectMinor, 'ETB')}' : 'Take payment')),
      if (can && d.isPlaying && ((d.pricingType == 'PER_GAME' && d.gamesCount == 0) || d.isPlaying) && d.settledMinor == 0 && d.pendingMinor == 0) TextButton.icon(onPressed: _busy ? null : _cancel, icon: const Icon(Icons.close, color: LsColors.red), label: const Text('Cancel (started by mistake)', style: TextStyle(color: LsColors.red))),
      if (d.isEnded && d.canCorrect && d.pricingType == 'PER_GAME') TextButton.icon(onPressed: _busy ? null : () => _correctEnded(1), icon: const Icon(Icons.add), label: const Text('Add a missed game')),
      if (d.isEnded && d.canCorrect && d.pricingType == 'PER_GAME' && d.quantity > 0) TextButton.icon(onPressed: _busy ? null : () => _correctEnded(-1), icon: const Icon(Icons.remove), label: const Text('Remove a game')),
    ];
    return Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: b);
  }

  List<Widget> _details(PsSessionDetail d) => [
        Text('Purchases', style: Theme.of(context).textTheme.titleMedium),
        for (final i in d.items)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(i.kind == 'EXTENSION' ? Icons.more_time : Icons.shopping_bag_outlined),
            title: Text('${i.packageName}${i.quantity != 1 ? ' ×${i.quantity}' : ''}${i.kind == 'EXTENSION' ? ' (added time)' : ''}'),
            subtitle: Text('${formatMoney(i.unitPriceMinor, 'ETB')} each · ${_t(i.createdAt)}${i.addedByName != null ? ' · ${i.addedByName}' : ''}'),
            trailing: Text(formatMoney(i.totalMinor, 'ETB'), style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
        const SizedBox(height: 8),
        Text('Payments', style: Theme.of(context).textTheme.titleMedium),
        if (d.payments.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Text('Nothing paid yet — payment is taken when the session ends.', style: TextStyle(color: LsColors.muted))),
        for (final p in d.payments) _paymentTile(d, p),
        const SizedBox(height: 8),
        Text('Timeline', style: Theme.of(context).textTheme.titleMedium),
        for (final e in d.events)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(psEventLabel[e.eventType] ?? titleCase(e.eventType)),
            subtitle: Text('${_t(e.occurredAt)}${e.actorName != null ? ' · ${e.actorName}' : ''}${e.metadata['reason'] != null ? ' · ${e.metadata['reason']}' : ''}'),
          ),
      ];

  Widget _paymentTile(PsSessionDetail d, PsPayment p) {
    final color = switch (p.status) { 'PENDING' => LsColors.orange, 'REJECTED' => LsColors.red, 'CANCELLED' => LsColors.muted, _ => LsColors.green };
    final mine = _me?.id == p.recordedBy;
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(p.status == 'PENDING' ? Icons.hourglass_top : p.status == 'REJECTED' ? Icons.cancel_outlined : p.status == 'CANCELLED' ? Icons.block : Icons.check_circle_outline, color: color),
            const SizedBox(width: 8),
            Expanded(child: Text('${formatMoney(p.amountMinor, 'ETB')} · ${titleCase(p.method)}', style: const TextStyle(fontWeight: FontWeight.w800))),
            Text(p.statusLabel, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12.5)),
          ]),
          Text([
            _t(p.paidAt ?? p.createdAt),
            if (p.reference != null) 'ref ${p.reference}',
            if (p.recordedByName != null) 'by ${p.recordedByName}',
            if (p.tenderedMinor != null && p.tenderedMinor! > p.amountMinor) 'received ${formatMoney(p.tenderedMinor, 'ETB')}, change ${formatMoney(p.tenderedMinor! - p.amountMinor, 'ETB')}',
            if (p.refundedMinor > 0) 'refunded ${formatMoney(p.refundedMinor, 'ETB')}',
            if (p.confirmedByName != null && p.verificationRequired) 'verified by ${p.confirmedByName}',
          ].join(' · '), style: const TextStyle(color: LsColors.muted, fontSize: 12.5)),
          if (p.status == 'REJECTED')
            Container(
              margin: const EdgeInsets.only(top: 6),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: LsColors.redSoft, borderRadius: BorderRadius.circular(8)),
              child: Text('Rejected by ${p.rejectedByName ?? 'an admin'}: ${p.rejectReason ?? ''}\nThe balance is still owed — take a corrected payment.', style: const TextStyle(color: LsColors.red, fontWeight: FontWeight.w600)),
            ),
          if (p.hasProof) ...[const SizedBox(height: 8), PsProofImage(paymentId: p.id, height: 110)],
          Wrap(spacing: 8, children: [
            if (p.status == 'PENDING' && (mine || d.canCorrect) && (_me?.can('playstation.operate') ?? false)) TextButton(onPressed: _busy ? null : () => _withdraw(p), child: const Text('Withdraw')),
            if (d.canRefund && (p.status == 'PAID' || p.status == 'PARTIALLY_REFUNDED')) TextButton(onPressed: _busy ? null : () => _refund(p), child: const Text('Refund')),
          ]),
        ]),
      ),
    );
  }
}
