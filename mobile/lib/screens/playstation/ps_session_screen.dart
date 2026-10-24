import 'dart:async';
import 'package:flutter/material.dart';
import '../../alarm/expiry_alarm_service.dart';
import '../../api/api_client.dart';
import '../../api/realtime_bus.dart';
import '../../format.dart';
import '../../models/me.dart';
import '../../models/playstation.dart';
import '../../models/product.dart';
import '../../theme.dart';
import '../../widgets/reason_dialog.dart';

String _t(DateTime? t) => t == null ? '—' : '${fmtDate(t)} ${fmtHHMM(t)}';

/// One gaming session: live time/games, payment state, and the operator's actions. Every action
/// is a server call; the screen only shows what the server confirms.
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
  List<PaymentMethodOption> _methods = [];
  int _warningMinutes = 5;
  bool _pauseEnabled = true;
  String? _error;
  bool _busy = false;
  Timer? _tick;

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
    RealtimeBus.last.removeListener(_onRealtime);
    super.dispose();
  }

  void _onRealtime() {
    final e = RealtimeBus.last.value;
    if (e != null && (e.event == 'RESYNC' || e.data['aggregateId'] == widget.sessionId)) _load();
  }

  Future<void> _boot() async {
    _api = await ApiClient.instance();
    _me = _api.me;
    try {
      final st = await _api.get('/playstation/settings') as Map<String, dynamic>;
      _methods = ((st['paymentMethods'] as List?) ?? const []).map((e) => PaymentMethodOption.fromJson(e as Map<String, dynamic>)).toList();
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

  Future<void> _run(Future<dynamic> Function() fn, {String? ok}) async {
    setState(() => _busy = true);
    try {
      final r = await fn();
      if (r is Map<String, dynamic> && r['session'] is Map) {
        final d = PsSessionDetail.fromJson(r);
        setState(() => _d = d);
        if (r['autoFinished'] == true && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('All purchased games played — session finished and console released.')));
        }
      }
      await _load();
      if (ok != null && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok)));
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- payment input shared by "record payment" and "extend" -----------------------------------
  Future<Map<String, dynamic>?> _askPayment({required int amountMinor, required String title, bool allowPending = true}) async {
    String? method = _methods.where((m) => m.code == 'CASH').firstOrNull?.code ?? _methods.firstOrNull?.code;
    final ref = TextEditingController();
    bool pending = false;
    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
        final m = _methods.where((x) => x.code == method).firstOrNull;
        final needsRef = m?.requiresReference ?? false;
        final valid = method != null && (!needsRef || pending || ref.text.trim().isNotEmpty);
        return AlertDialog(
          title: Text(title),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(formatMoney(amountMinor, 'ETB'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
            const SizedBox(height: 10),
            Wrap(spacing: 8, children: [for (final x in _methods) ChoiceChip(label: Text(x.label), selected: method == x.code, onSelected: (_) => setD(() => method = x.code))]),
            if (needsRef) ...[
              const SizedBox(height: 8),
              TextField(controller: ref, decoration: const InputDecoration(labelText: 'Reference / receipt number'), onChanged: (_) => setD(() {})),
              if (allowPending)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: pending,
                  onChanged: (v) => setD(() => pending = v ?? false),
                  title: const Text('Not confirmed yet — record as pending'),
                ),
            ],
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: valid ? () => Navigator.pop(ctx, {'method': method, if (ref.text.trim().isNotEmpty) 'reference': ref.text.trim(), 'confirmed': !pending}) : null,
              child: Text(pending ? 'Record pending' : 'Payment received'),
            ),
          ],
        );
      }),
    );
  }

  Future<void> _recordPayment() async {
    final d = _d!;
    final p = await _askPayment(amountMinor: d.dueMinor, title: 'Record payment');
    if (p == null) return;
    await _run(() => _api.post('/playstation/sessions/${d.id}/payments', {...p, 'amountMinor': d.dueMinor}), ok: 'Payment recorded.');
  }

  Future<void> _confirmPending(PsPayment p) async {
    final ref = TextEditingController(text: p.reference ?? '');
    final ok = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Pending ${formatMoney(p.amountMinor, 'ETB')} (${titleCase(p.method)})'),
        content: TextField(controller: ref, decoration: const InputDecoration(labelText: 'Reference / receipt number')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 'cancel'), child: const Text('Payment did not arrive', style: TextStyle(color: LsColors.red))),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'confirm'), child: const Text('Confirm received')),
        ],
      ),
    );
    if (ok == null) return;
    await _run(() => _api.post('/playstation/payments/${p.id}/$ok', {'reference': ref.text.trim().isEmpty ? null : ref.text.trim()}),
        ok: ok == 'confirm' ? 'Payment confirmed.' : 'Pending payment cancelled.');
  }

  Future<void> _extend() async {
    final d = _d!;
    final pj = await _api.get('/playstation/packages') as Map<String, dynamic>;
    final pkgs = ((pj['packages'] as List?) ?? const []).map((e) => PsPackage.fromJson(e as Map<String, dynamic>)).where((p) => p.pricingType == d.pricingType).toList();
    if (!mounted) return;
    PsPackage? pkg = pkgs.firstOrNull;
    int qty = 1;
    final picked = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
            title: Text(d.isTimed ? 'Add time' : 'Add games'),
            content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (pkgs.isEmpty) const Text('No matching active packages.'),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final p in pkgs) ChoiceChip(label: Text('${p.name} · ${p.unitLabel} · ${formatMoney(p.priceMinor, 'ETB')}'), selected: pkg?.id == p.id, onSelected: (_) => setD(() => pkg = p)),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                const Text('Quantity'),
                const Spacer(),
                IconButton(onPressed: qty > 1 ? () => setD(() => qty--) : null, icon: const Icon(Icons.remove_circle_outline)),
                Text('$qty', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
                IconButton(onPressed: qty < 50 ? () => setD(() => qty++) : null, icon: const Icon(Icons.add_circle_outline)),
              ]),
              if (pkg != null) Text('Charge: ${formatMoney(pkg!.priceMinor * qty, 'ETB')} at the current price', style: const TextStyle(fontWeight: FontWeight.w700)),
            ]),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(onPressed: pkg == null ? null : () => Navigator.pop(ctx, true), child: const Text('Next: payment')),
            ],
          )),
    );
    if (picked != true || pkg == null) return;
    final pay = await _askPayment(amountMinor: pkg!.priceMinor * qty, title: 'Payment for extension');
    if (pay == null) return;
    await _run(() => _api.post('/playstation/sessions/${d.id}/extend', {'packageId': pkg!.id, 'quantity': qty, 'payment': pay}), ok: 'Session extended.');
  }

  Future<void> _completeGames() async {
    final d = _d!;
    int count = 1;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
            title: const Text('Mark games as played'),
            content: Row(children: [
              IconButton(onPressed: count > 1 ? () => setD(() => count--) : null, icon: const Icon(Icons.remove_circle_outline)),
              Text('$count', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
              IconButton(onPressed: count < d.gamesRemaining ? () => setD(() => count++) : null, icon: const Icon(Icons.add_circle_outline)),
              const SizedBox(width: 8),
              Expanded(child: Text('of ${d.gamesRemaining} remaining')),
            ]),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Mark played')),
            ],
          )),
    );
    if (ok != true) return;
    await _run(() => _api.post('/playstation/sessions/${d.id}/games-complete', {'count': count}));
  }

  Future<void> _finish() async {
    final d = _d!;
    final rem = d.liveRemaining(_api.serverNow());
    final early = (rem != null && rem > 60) || (!d.isTimed && d.gamesRemaining > 0);
    String? reason;
    if (early) {
      reason = await showReasonDialog(context, title: 'Finish early', label: d.isTimed ? '${formatDuration(rem!)} still remain — why finish now?' : '${d.gamesRemaining} game(s) remain — why finish now?', minLength: 3, confirmLabel: 'Finish session');
      if (reason == null) return;
    } else {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Finish ${d.consoleCode}?'),
          content: Text(d.paymentStatus == 'PAID' ? 'The console will be released.' : 'Payment is ${psPaymentLabel[d.paymentStatus]?.toLowerCase()}. The outstanding amount stays on record.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep playing')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Finish')),
          ],
        ),
      );
      if (ok != true) return;
    }
    await _run(() => _api.post('/playstation/sessions/${d.id}/finish', {'reason': reason}), ok: 'Session finished — console released.');
  }

  Future<void> _cancel() async {
    final reason = await showReasonDialog(context, title: 'Cancel this session', label: 'Reason', minLength: 3, confirmLabel: 'Cancel session', danger: true);
    if (reason == null) return;
    await _run(() async {
      final r = await _api.post('/playstation/sessions/${widget.sessionId}/cancel', {'reason': reason}) as Map<String, dynamic>;
      final due = (r['refundDueMinor'] as num?)?.toInt() ?? 0;
      if (due > 0 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Cancelled. ${formatMoney(due, 'ETB')} was paid — an admin must issue the refund.')));
      }
      return r;
    });
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
              Text('Opened: ${_t(DateTime.tryParse(r['createdAt'] as String? ?? '')?.toLocal())}'),
              const Divider(),
              for (final l in lines) Text('${l['description']}${n(l['quantity']) > 1 ? ' ×${l['quantity']}' : ''}${l['kind'] == 'EXTENSION' ? ' (ext.)' : ''}\n   ${formatMoney(n(l['totalMinor']), 'ETB')}'),
              const Divider(),
              Text('TOTAL   ${formatMoney(n(r['totalMinor']), 'ETB')}', style: const TextStyle(fontWeight: FontWeight.w900)),
              Text('PAID    ${formatMoney(n(r['paidMinor']), 'ETB')}'),
              if (n(r['refundedMinor']) > 0) Text('REFUND  ${formatMoney(n(r['refundedMinor']), 'ETB')}'),
              if (n(r['balanceMinor']) > 0) Text('DUE     ${formatMoney(n(r['balanceMinor']), 'ETB')}', style: const TextStyle(color: LsColors.red)),
              const SizedBox(height: 6),
              for (final p in pays) Text('${titleCase(p['method'] as String)} ${formatMoney(n(p['amountMinor']), 'ETB')} · ${psPaymentLabel[p['status']] ?? p['status']}${p['reference'] != null ? ' · ref ${p['reference']}' : ''}'),
            ]),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
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
          : RefreshIndicator(onRefresh: _load, child: ListView(padding: const EdgeInsets.all(14), children: [_status(d), const SizedBox(height: 12), _actions(d), const SizedBox(height: 16), ..._details(d)])),
    );
  }

  Widget _status(PsSessionDetail d) {
    final rem = d.liveRemaining(_api.serverNow());
    final warn = rem != null && rem <= _warningMinutes * 60;
    final bg = d.status == 'ACTIVE' ? (rem != null && rem <= 0 ? LsColors.redSoft : warn ? LsColors.orangeSoft : LsColors.greenSoft) : d.status == 'PAUSED' ? LsColors.slateSoft : LsColors.surface2;
    final fg = d.status == 'ACTIVE' ? (rem != null && rem <= 0 ? LsColors.red : warn ? LsColors.orange : LsColors.green) : LsColors.slate;
    return Card(
      color: bg,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Text(psStatusLabel[d.status] ?? d.status, style: TextStyle(color: fg, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          if (d.isTimed && rem != null)
            Text(fmtClock(rem), style: TextStyle(fontSize: 46, fontWeight: FontWeight.w900, color: fg, fontFeatures: const [FontFeature.tabularFigures()]))
          else if (d.isTimed)
            Text(formatDuration(d.purchasedSeconds), style: TextStyle(fontSize: 40, fontWeight: FontWeight.w900, color: fg))
          else
            Text('${d.gamesCompleted} / ${d.gamesPurchased} games', style: TextStyle(fontSize: 38, fontWeight: FontWeight.w900, color: fg)),
          if (d.isTimed && d.expectedEndAt != null) Text('Ends ${fmtHHMM(d.expectedEndAt)} (server time)', style: const TextStyle(color: LsColors.muted)),
          const SizedBox(height: 8),
          Text('${d.playerName ?? '—'}${d.customerCode != null ? ' · ${d.customerCode}' : ''}', style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text('${formatMoney(d.totalMinor, 'ETB')} · ${psPaymentLabel[d.paymentStatus] ?? d.paymentStatus}${d.dueMinor > 0 && d.isOpen ? ' · ${formatMoney(d.dueMinor, 'ETB')} due' : ''}',
              style: TextStyle(color: d.paymentStatus == 'PAID' ? LsColors.green : LsColors.orange, fontWeight: FontWeight.w700)),
        ]),
      ),
    );
  }

  Widget _actions(PsSessionDetail d) {
    final can = _me?.can('playstation.operate') ?? false;
    if (!can || !d.isOpen) return const SizedBox.shrink();
    final b = <Widget>[
      if (d.dueMinor > 0) FilledButton.icon(onPressed: _busy ? null : _recordPayment, icon: const Icon(Icons.payments_outlined), label: const Text('Record payment')),
      if (d.status == 'READY' || d.status == 'PENDING_PAYMENT') FilledButton.icon(onPressed: _busy ? null : () => _run(() => _api.post('/playstation/sessions/${d.id}/start'), ok: 'Started.'), icon: const Icon(Icons.play_arrow), label: const Text('Start')),
      if (d.status == 'ACTIVE' && _pauseEnabled) OutlinedButton.icon(onPressed: _busy ? null : () => _run(() => _api.post('/playstation/sessions/${d.id}/pause', {}), ok: 'Paused — time is frozen.'), icon: const Icon(Icons.pause), label: const Text('Pause')),
      if (d.status == 'PAUSED') FilledButton.icon(onPressed: _busy ? null : () => _run(() => _api.post('/playstation/sessions/${d.id}/resume'), ok: 'Resumed.'), icon: const Icon(Icons.play_arrow), label: const Text('Resume')),
      if (d.status == 'ACTIVE' && !d.isTimed) FilledButton.icon(onPressed: _busy ? null : _completeGames, icon: const Icon(Icons.sports_score), label: const Text('Game played')),
      if (['READY', 'ACTIVE', 'PAUSED'].contains(d.status)) OutlinedButton.icon(onPressed: _busy ? null : _extend, icon: const Icon(Icons.more_time), label: Text(d.isTimed ? 'Add time' : 'Add games')),
      if (['ACTIVE', 'PAUSED'].contains(d.status)) FilledButton.icon(style: FilledButton.styleFrom(backgroundColor: LsColors.red), onPressed: _busy ? null : _finish, icon: const Icon(Icons.stop), label: const Text('Finish')),
      if (['PENDING_PAYMENT', 'READY'].contains(d.status)) TextButton.icon(onPressed: _busy ? null : _cancel, icon: const Icon(Icons.close, color: LsColors.red), label: const Text('Cancel', style: TextStyle(color: LsColors.red))),
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
            title: Text('${i.packageName}${i.quantity > 1 ? ' ×${i.quantity}' : ''}${i.kind == 'EXTENSION' ? ' (extension)' : ''}'),
            subtitle: Text('${formatMoney(i.unitPriceMinor, 'ETB')} each · ${_t(i.createdAt)}${i.addedByName != null ? ' · ${i.addedByName}' : ''}'),
            trailing: Text(formatMoney(i.totalMinor, 'ETB'), style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
        const SizedBox(height: 8),
        Text('Payments', style: Theme.of(context).textTheme.titleMedium),
        if (d.payments.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Text('No payments yet.', style: TextStyle(color: LsColors.muted))),
        for (final p in d.payments)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(p.status == 'PENDING' ? Icons.hourglass_top : p.status == 'CANCELLED' ? Icons.block : Icons.check_circle_outline,
                color: p.status == 'PENDING' ? LsColors.orange : p.status == 'CANCELLED' ? LsColors.muted : LsColors.green),
            title: Text('${formatMoney(p.amountMinor, 'ETB')} · ${titleCase(p.method)} · ${psPaymentLabel[p.status] ?? titleCase(p.status)}'),
            subtitle: Text('${_t(p.paidAt ?? p.createdAt)}${p.reference != null ? ' · ref ${p.reference}' : ''}${p.refundedMinor > 0 ? ' · refunded ${formatMoney(p.refundedMinor, 'ETB')}' : ''}${p.recordedByName != null ? ' · ${p.recordedByName}' : ''}'),
            trailing: p.status == 'PENDING' && (_me?.can('playstation.operate') ?? false)
                ? TextButton(onPressed: _busy ? null : () => _confirmPending(p), child: const Text('Resolve'))
                : (d.canRefund && (p.status == 'PAID' || p.status == 'PARTIALLY_REFUNDED'))
                    ? TextButton(onPressed: _busy ? null : () => _refund(p), child: const Text('Refund'))
                    : null,
          ),
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
}
