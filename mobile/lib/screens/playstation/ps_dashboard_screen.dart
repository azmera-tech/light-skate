import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../alarm/expiry_alarm_service.dart';
import '../../api/api_client.dart';
import '../../api/realtime_bus.dart';
import '../../format.dart';
import '../../models/playstation.dart';
import '../../theme.dart';
import '../../widgets/ps_sheet.dart';
import '../../widgets/reason_dialog.dart';
import 'ps_checkout_sheet.dart';
import 'ps_end_flow.dart';
import 'ps_history_screen.dart';
import 'ps_new_session_sheet.dart';
import 'ps_session_screen.dart';
import 'ps_verification_screen.dart';

/// The PlayStation board. Each busy console shows its live bill and a one-tap **+ Add Game**; ended sessions that
/// still owe money wait under "Awaiting payment" until they are settled. Every figure comes from the server —
/// taps are shown at once and reconciled with the server's answer, in order, one request at a time per session.
class PsDashboardScreen extends StatefulWidget {
  /// When embedded in the admin module, history lives in its own tab.
  final bool showHistoryButton;
  const PsDashboardScreen({super.key, this.showHistoryButton = true});
  @override
  State<PsDashboardScreen> createState() => _PsDashboardScreenState();
}

class _PsDashboardScreenState extends State<PsDashboardScreen> {
  late ApiClient _api;
  Map<String, dynamic>? _ov;
  List<PsConsole> _consoles = [];
  List<Map<String, dynamic>> _owing = [];
  DateTime _fetchedAt = DateTime.now();
  String? _error;
  Timer? _tick;
  Timer? _poll;
  Timer? _reloadSoon;

  // + Add Game bookkeeping, per session: taps not yet confirmed, the request chain, and the last server summary.
  final Map<String, int> _pending = {};
  final Map<String, Future<void>> _chains = {};
  final Map<String, Map<String, dynamic>> _confirmed = {};

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => mounted ? setState(() {}) : null);
    _poll = Timer.periodic(const Duration(seconds: 30), (_) => _load());
    RealtimeBus.last.addListener(_onRealtime);
    _boot();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _poll?.cancel();
    _reloadSoon?.cancel();
    RealtimeBus.last.removeListener(_onRealtime);
    super.dispose();
  }

  bool get _canOperate => _api.me?.can('playstation.operate') ?? false;
  bool get _canVerify => _api.me?.can('playstation.verify') ?? false;

  void _onRealtime() {
    final e = RealtimeBus.last.value;
    if (e == null) return;
    if (e.event == 'RESYNC' || e.event.startsWith('PS_')) {
      _reloadSoon?.cancel();
      _reloadSoon = Timer(const Duration(milliseconds: 300), _load);
    }
    if ((e.event == 'PS_SESSION_WARNING' || e.event == 'PS_SESSION_TIME_UP') && mounted) {
      final p = (e.data['payload'] as Map?)?.cast<String, dynamic>() ?? const {};
      final up = e.event == 'PS_SESSION_TIME_UP';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: up ? LsColors.red : LsColors.orange,
        duration: const Duration(seconds: 8),
        content: Text(up ? '${p['consoleCode'] ?? 'A console'}: time is up' : '${p['consoleCode'] ?? 'A console'}: ending soon'),
        action: e.data['aggregateId'] == null ? null : SnackBarAction(label: 'Open', textColor: Colors.white, onPressed: () => _openSession(e.data['aggregateId'] as String)),
      ));
    }
    if (e.event == 'PS_PAYMENT_REJECTED' && mounted) {
      final p = (e.data['payload'] as Map?)?.cast<String, dynamic>() ?? const {};
      if (p['recordedBy'] == _api.me?.id) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          backgroundColor: LsColors.red,
          duration: const Duration(seconds: 10),
          content: Text('A payment${p['consoleCode'] != null ? ' for ${p['consoleCode']}' : ''} was rejected — take it again.'),
          action: e.data['aggregateId'] == null ? null : SnackBarAction(label: 'Open', textColor: Colors.white, onPressed: () => _openSession(e.data['aggregateId'] as String)),
        ));
      }
    }
  }

  Future<void> _boot() async {
    _api = await ApiClient.instance();
    await _load();
  }

  Future<void> _load() async {
    try {
      final ov = await _api.get('/playstation/overview') as Map<String, dynamic>;
      final c = await _api.get('/playstation/consoles') as Map<String, dynamic>;
      final o = await _api.get('/playstation/sessions?outstanding=true&status=COMPLETED&limit=100') as Map<String, dynamic>;
      if (!mounted) return;
      final consoles = ((c['consoles'] as List?) ?? const []).map((e) => PsConsole.fromJson(e as Map<String, dynamic>)).toList();
      setState(() {
        _ov = ov;
        _consoles = consoles;
        _owing = ((o['sessions'] as List?) ?? const []).cast<Map<String, dynamic>>();
        _fetchedAt = DateTime.now();
        _error = null;
        // A fresh load supersedes any summary we were holding, unless taps are still in flight.
        _confirmed.removeWhere((id, _) => (_pending[id] ?? 0) == 0);
      });
      final warn = (ov['warningMinutes'] as num?)?.toInt() ?? 5;
      for (final k in consoles) {
        final s = k.session;
        if (s != null && s.status == 'ACTIVE' && s.pricingType == 'DURATION' && s.expectedEndAt != null) {
          unawaited(ExpiryAlarmService.instance.scheduleGamingAlerts(sessionId: s.id, consoleCode: k.code, playerName: s.playerName ?? 'Player', expectedEndAt: s.expectedEndAt!, warningMinutes: warn));
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  int? _remaining(PsLiveSession s) {
    if (s.remainingSeconds == null) return null;
    return s.status == 'ACTIVE' ? s.remainingSeconds! - DateTime.now().difference(_fetchedAt).inSeconds : s.remainingSeconds;
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  void _openSession(String id) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => PsSessionScreen(sessionId: id))).then((_) => _load());
  }

  Future<void> _startOn(PsConsole c) async {
    final id = await showNewGamingSessionSheet(context, c);
    await _load();
    if (id != null && mounted) _openSession(id);
  }

  Future<void> _tapConsole(PsConsole c) async {
    if (c.session != null) return _openSession(c.session!.id);
    if (c.state != 'AVAILABLE') {
      _snack('${c.code} is ${c.state == 'MAINTENANCE' ? 'under maintenance' : 'inactive'}.');
      return;
    }
    if (!_canOperate) return;
    await _startOn(c);
  }

  // ---- + Add Game ---------------------------------------------------------------------------------

  void _addGame(PsLiveSession s) {
    HapticFeedback.mediumImpact();
    final id = s.id;
    setState(() => _pending[id] = (_pending[id] ?? 0) + 1);
    _chains[id] = (_chains[id] ?? Future.value()).then((_) async {
      Map<String, dynamic>? summary;
      try {
        final r = await _api.post('/playstation/sessions/$id/games', {'delta': 1}) as Map<String, dynamic>;
        summary = (r['session'] as Map?)?.cast<String, dynamic>();
      } on ApiException catch (e) {
        if (mounted) _snack(e.message);
      }
      if (!mounted) return;
      setState(() {
        _pending[id] = ((_pending[id] ?? 1) - 1).clamp(0, 1 << 30);
        if (summary != null) _confirmed[id] = summary;
      });
      if ((_pending[id] ?? 0) == 0) {
        _pending.remove(id);
        unawaited(_load());
      }
    });
  }

  Future<void> _removeGame(PsLiveSession s) async {
    final reason = await showReasonDialog(context, title: 'Correct the game count', label: 'Why remove a game? (recorded)', minLength: 3, confirmLabel: 'Remove 1 game');
    if (reason == null) return;
    await _chains[s.id];
    try {
      final r = await _api.post('/playstation/sessions/${s.id}/games', {'delta': -1, 'reason': reason}) as Map<String, dynamic>;
      final sm = (r['session'] as Map?)?.cast<String, dynamic>();
      if (sm != null && mounted) setState(() => _confirmed[s.id] = sm);
      if (mounted) _snack('Game removed — total updated.');
    } on ApiException catch (e) {
      if (mounted) _snack(e.message);
    }
    await _load();
  }

  /// The numbers to show for a live session: the server's latest answer plus taps still on their way.
  _Live _live(PsLiveSession s) {
    final c = _confirmed[s.id];
    int pick(String k, int fallback) => (c?[k] as num?)?.toInt() ?? fallback;
    final p = _pending[s.id] ?? 0;
    final unit = pick('unitPriceMinor', s.unitPriceMinor);
    final qty = pick('quantity', s.quantity) + p;
    final total = pick('totalMinor', s.totalMinor) + p * unit;
    final paid = pick('paidMinor', s.paidMinor);
    final pend = pick('pendingMinor', s.pendingMinor);
    final bal = math.max(0, pick('balanceMinor', s.balanceMinor) + p * unit);
    return _Live(qty, unit, total, paid, pend, bal);
  }

  Future<void> _end(PsConsole c) async {
    final s = c.session!;
    await _chains[s.id];
    final l = _live(s);
    if (!mounted) return;
    await endSessionAndCheckout(context, _api,
        sessionId: s.id, consoleCode: c.code, perGame: s.pricingType == 'PER_GAME', quantity: l.qty, unitPriceMinor: l.unit, totalMinor: l.total, remainingSeconds: _remaining(s));
    await _load();
  }

  Future<void> _checkout(String sessionId) async {
    await showPsCheckoutSheet(context, sessionId);
    await _load();
  }

  // ---- Quick actions ------------------------------------------------------------------------------

  Future<void> _quickActions() async {
    final ov = _ov;
    final out = (ov?['outstanding'] as Map?)?.cast<String, dynamic>() ?? const {};
    final pv = (ov?['pendingVerification'] as Map?)?.cast<String, dynamic>() ?? const {};
    final free = _consoles.where((c) => c.state == 'AVAILABLE').toList();
    final playing = _consoles.where((c) => c.session?.isOpenPlay ?? false).toList();
    final act = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 4), child: Align(alignment: Alignment.centerLeft, child: Text('Quick actions', style: Theme.of(ctx).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)))),
            if (_canOperate)
              ListTile(leading: const Icon(Icons.play_circle_outline), title: const Text('Start a session'), subtitle: Text(free.isEmpty ? 'No console is free' : '${free.length} free'), enabled: free.isNotEmpty, onTap: () => Navigator.pop(ctx, 'start')),
            if (_canOperate) ListTile(leading: const Icon(Icons.person_search_outlined), title: const Text('Find a registered customer'), subtitle: const Text('Look up by phone, then start their session'), enabled: free.isNotEmpty, onTap: () => Navigator.pop(ctx, 'find')),
            ListTile(leading: const Icon(Icons.sports_esports_outlined), title: const Text('View active sessions'), subtitle: Text('${playing.length} playing now'), onTap: () => Navigator.pop(ctx, 'active')),
            ListTile(
              leading: const Icon(Icons.account_balance_wallet_outlined),
              title: const Text('Review outstanding balances'),
              subtitle: Text((out['sessions'] as num? ?? 0) > 0 ? '${out['sessions']} sessions · ${formatMoney((out['minor'] as num).toInt(), 'ETB')}' : 'Nothing owed'),
              onTap: () => Navigator.pop(ctx, 'owing'),
            ),
            if (_canVerify)
              ListTile(
                leading: const Icon(Icons.verified_outlined),
                title: const Text('Payment verification'),
                subtitle: Text((pv['count'] as num? ?? 0) > 0 ? '${pv['count']} waiting · ${formatMoney((pv['minor'] as num).toInt(), 'ETB')}' : 'Nothing waiting'),
                onTap: () => Navigator.pop(ctx, 'verify'),
              ),
          ]),
        ),
      ),
    );
    if (act == null || !mounted) return;
    switch (act) {
      case 'start':
        final c = await _pickConsole(free);
        if (c != null) await _startOn(c);
      case 'find':
        await _findCustomer(free);
      case 'active':
        await _listSheet('Active sessions', [
          for (final c in playing) (c.session!, c.code),
        ]);
      case 'owing':
        await _owingSheet();
      case 'verify':
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PsVerificationPage()));
        await _load();
    }
  }

  Future<PsConsole?> _pickConsole(List<PsConsole> free) {
    if (free.length == 1) return Future.value(free.first);
    return showModalBottomSheet<PsConsole>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const Padding(padding: EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text('Which console?', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
          for (final c in free) ListTile(leading: const Icon(Icons.sports_esports), title: Text(c.code), subtitle: Text(c.name), onTap: () => Navigator.pop(ctx, c)),
        ]),
      ),
    );
  }

  Future<void> _findCustomer(List<PsConsole> free) async {
    final ctl = TextEditingController();
    final phone = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Find a registered customer'),
        content: TextField(controller: ctl, autofocus: true, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone number'), onSubmitted: (v) => Navigator.pop(ctx, v.trim())),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text.trim()), child: const Text('Find'))],
      ),
    );
    if (phone == null || phone.length < 5 || !mounted) {
      if (phone != null && mounted) _snack('Enter at least 5 digits.');
      return;
    }
    try {
      final r = await _api.get('/playstation/customer-lookup?phone=${Uri.encodeQueryComponent(phone)}') as Map<String, dynamic>;
      final found = ((r['customers'] as List?) ?? const []).cast<Map<String, dynamic>>();
      if (!mounted) return;
      if (found.isEmpty) return _snack('No registered customer has that number.');
      final c = found.first;
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(c['fullName'] as String),
          content: Text('${c['customerCode']}\nStart a gaming session for them?'),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Close')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Start session'))],
        ),
      );
      if (go == true && mounted) {
        final console = await _pickConsole(free);
        if (console != null && mounted) await _startOn(console);
      }
    } on ApiException catch (e) {
      if (mounted) _snack(e.message);
    }
  }

  Future<void> _listSheet(String title, List<(PsLiveSession, String)> rows) async {
    final id = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text(title, style: Theme.of(ctx).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800))),
          if (rows.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('Nothing here.', style: TextStyle(color: LsColors.muted))),
          for (final (s, code) in rows)
            ListTile(
              title: Text('$code · ${s.playerName ?? ''}'),
              subtitle: Text('${s.packageName ?? ''} · ${_live(s).qty} games · ${formatMoney(_live(s).total, 'ETB')}'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.pop(ctx, s.id),
            ),
        ]),
      ),
    );
    if (id != null && mounted) _openSession(id);
  }

  Future<void> _owingSheet() async {
    final id = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text('Outstanding balances', style: Theme.of(ctx).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800))),
          if (_owing.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('Every ended session is settled.', style: TextStyle(color: LsColors.muted))),
          for (final o in _owing)
            ListTile(
              title: Text('${o['consoleCode']} · ${o['playerName'] ?? ''}'),
              subtitle: Text('${o['packages'] ?? ''}'),
              trailing: Text(formatMoney((o['balanceMinor'] as num).toInt(), 'ETB'), style: const TextStyle(fontWeight: FontWeight.w900, color: LsColors.red)),
              onTap: () => Navigator.pop(ctx, o['id'] as String),
            ),
        ]),
      ),
    );
    if (id != null && mounted) _openSession(id);
  }

  @override
  Widget build(BuildContext context) {
    final ov = _ov;
    if (ov == null) return Center(child: _error != null ? Padding(padding: const EdgeInsets.all(20), child: Text(_error!)) : const CircularProgressIndicator());
    final cs = (ov['consoles'] as Map).cast<String, dynamic>();
    final ss = (ov['sessions'] as Map).cast<String, dynamic>();
    final rev = (ov['revenueToday'] as Map).cast<String, dynamic>();
    final out = (ov['outstanding'] as Map).cast<String, dynamic>();
    final pv = (ov['pendingVerification'] as Map).cast<String, dynamic>();
    final ending = ((ov['endingSoon'] as List?) ?? const []).cast<Map<String, dynamic>>();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: scrollPadding(context, h: 12, top: 12), children: [
        Row(children: [
          Expanded(child: Text('PlayStation', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800))),
          FilledButton.tonalIcon(onPressed: _quickActions, icon: const Icon(Icons.bolt), label: const Text('Quick actions')),
          if (widget.showHistoryButton)
            IconButton(
              tooltip: 'History',
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => Scaffold(appBar: AppBar(title: const Text('Gaming history')), body: const PsHistoryScreen()))),
              icon: const Icon(Icons.history),
            ),
        ]),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: [
          _Stat('Available', '${cs['available']} / ${cs['total']}', LsColors.green),
          _Stat('Playing', '${ss['active']}', LsColors.brand),
          _Stat('Collected today', formatMoney((rev['netMinor'] as num).toInt(), 'ETB'), LsColors.green),
          if ((out['sessions'] as num) > 0) _Stat('Outstanding', formatMoney((out['minor'] as num).toInt(), 'ETB'), LsColors.red),
          if ((pv['count'] as num) > 0) _Stat('Awaiting verification', '${pv['count']} · ${formatMoney((pv['minor'] as num).toInt(), 'ETB')}', LsColors.orange),
        ]),
        if ((pv['count'] as num) > 0 && _canVerify) ...[
          const SizedBox(height: 10),
          Card(
            color: LsColors.orangeSoft,
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: const Icon(Icons.verified_outlined, color: LsColors.orange),
              title: Text('${pv['count']} payment${(pv['count'] as num) == 1 ? '' : 's'} waiting for verification', style: const TextStyle(fontWeight: FontWeight.w700)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PsVerificationPage())).then((_) => _load()),
            ),
          ),
        ],
        if (ending.isNotEmpty) ...[
          const SizedBox(height: 10),
          Card(
            color: LsColors.orangeSoft,
            margin: EdgeInsets.zero,
            child: Column(children: [
              for (final e in ending)
                ListTile(
                  dense: true,
                  leading: Icon((e['remainingSeconds'] as num) <= 0 ? Icons.alarm_on : Icons.alarm, color: (e['remainingSeconds'] as num) <= 0 ? LsColors.red : LsColors.orange),
                  title: Text('${e['consoleCode']} · ${e['playerName'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text((e['remainingSeconds'] as num) <= 0 ? 'Time is up' : 'Ends in about ${formatDuration((e['remainingSeconds'] as num).toInt())}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _openSession(e['sessionId'] as String),
                ),
            ]),
          ),
        ],
        const SizedBox(height: 12),
        if (_consoles.isEmpty)
          const Card(child: Padding(padding: EdgeInsets.all(20), child: Text('No consoles yet. An admin adds consoles under Admin → PlayStation → Consoles.', textAlign: TextAlign.center))),
        for (final c in _consoles) Padding(padding: const EdgeInsets.only(bottom: 10), child: _consoleCard(c)),
        if (_owing.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('Awaiting payment', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          for (final o in _owing) Padding(padding: const EdgeInsets.only(bottom: 8), child: _owingCard(o)),
        ],
      ]),
    );
  }

  Widget _consoleCard(PsConsole c) {
    final s = c.session;
    if (s == null) {
      final free = c.state == 'AVAILABLE';
      final (fg, bg, label) = free
          ? (LsColors.green, LsColors.greenSoft, 'Available')
          : c.state == 'MAINTENANCE'
              ? (LsColors.orange, LsColors.orangeSoft, 'Maintenance')
              : (LsColors.gray, LsColors.graySoft, 'Inactive');
      return Material(
        color: bg,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _tapConsole(c),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              Icon(Icons.sports_esports, color: fg),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(c.code, style: TextStyle(fontWeight: FontWeight.w900, color: fg, fontSize: 16)), Text(c.name, style: const TextStyle(color: LsColors.muted, fontSize: 12.5))])),
              if (free && _canOperate) FilledButton.icon(onPressed: () => _tapConsole(c), icon: const Icon(Icons.play_arrow_rounded), label: const Text('Start')) else Text(label, style: TextStyle(color: fg, fontWeight: FontWeight.w800)),
            ]),
          ),
        ),
      );
    }
    final l = _live(s);
    final rem = _remaining(s);
    final perGame = s.pricingType == 'PER_GAME';
    final over = rem != null && rem <= 0;
    final soon = rem != null && rem <= ((_ov?['warningMinutes'] as num?)?.toInt() ?? 5) * 60;
    final paused = s.status == 'PAUSED';
    final fg = paused ? LsColors.slate : over ? LsColors.red : soon ? LsColors.orange : LsColors.brandStrong;
    final bg = paused ? LsColors.slateSoft : over ? LsColors.redSoft : soon ? LsColors.orangeSoft : LsColors.brandSoft;
    final status = psStatusLabel[s.status] ?? 'In use';
    final inPlay = s.isOpenPlay;
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _tapConsole(c),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.sports_esports, color: fg),
              const SizedBox(width: 8),
              Expanded(child: Text('${c.code} · ${c.name}', style: TextStyle(fontWeight: FontWeight.w900, color: fg, fontSize: 16), overflow: TextOverflow.ellipsis)),
              Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3), decoration: BoxDecoration(color: fg, borderRadius: BorderRadius.circular(20)), child: Text(status, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 11.5))),
            ]),
            const SizedBox(height: 4),
            Text('${s.playerName ?? '—'} · ${s.packageName ?? ''}', style: const TextStyle(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
            const SizedBox(height: 6),
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              if (perGame)
                Semantics(
                  liveRegion: true,
                  label: '${c.code}: ${l.qty} games, total ${formatMoney(l.total, 'ETB')}',
                  child: Text('${l.qty} ${l.qty == 1 ? 'game' : 'games'}', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: fg)),
                )
              else if (rem != null)
                Text(fmtClock(rem), style: TextStyle(fontSize: 26, fontWeight: FontWeight.w900, color: fg)),
              const Spacer(),
              if (perGame) Text('@ ${formatMoney(l.unit, 'ETB')}', style: const TextStyle(color: LsColors.muted, fontWeight: FontWeight.w600)),
            ]),
            const SizedBox(height: 4),
            Wrap(spacing: 14, runSpacing: 2, children: [
              _kv('Total', formatMoney(l.total, 'ETB'), bold: true),
              _kv('Paid', formatMoney(l.paid, 'ETB')),
              _kv('Outstanding', formatMoney(l.bal, 'ETB'), color: l.bal > 0 ? LsColors.red : LsColors.green, bold: true),
            ]),
            if (inPlay && _canOperate) ...[
              const SizedBox(height: 10),
              Row(children: [
                if (perGame) ...[
                  Tooltip(
                    message: 'Remove a game (correction)',
                    child: IconButton.outlined(constraints: const BoxConstraints(minWidth: 48, minHeight: 48), onPressed: l.qty <= 0 ? null : () => _removeGame(s), icon: const Icon(Icons.remove)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(backgroundColor: LsColors.green, textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
                        onPressed: s.status == 'ACTIVE' ? () => _addGame(s) : null,
                        icon: const Icon(Icons.add_circle_outline),
                        label: const FittedBox(fit: BoxFit.scaleDown, child: Text('+ Add Game', maxLines: 1)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                ] else
                  Expanded(child: OutlinedButton.icon(onPressed: () => _openSession(s.id), icon: const Icon(Icons.visibility_outlined), label: const Text('View session'))),
                Expanded(
                  child: SizedBox(
                    height: 48,
                    child: FilledButton.icon(style: FilledButton.styleFrom(backgroundColor: LsColors.red), onPressed: () => _end(c), icon: const Icon(Icons.stop), label: const Text('End')),
                  ),
                ),
              ]),
              if (perGame) Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: () => _openSession(s.id), child: const Text('View session'))),
            ],
          ]),
        ),
      ),
    );
  }

  Widget _kv(String k, String v, {Color? color, bool bold = false}) => Row(mainAxisSize: MainAxisSize.min, children: [
        Text('$k ', style: const TextStyle(color: LsColors.muted, fontSize: 12.5)),
        Text(v, style: TextStyle(fontWeight: bold ? FontWeight.w900 : FontWeight.w700, color: color)),
      ]);

  Widget _owingCard(Map<String, dynamic> o) {
    int n(String k) => (o[k] as num?)?.toInt() ?? 0;
    final waiting = n('toCollectMinor') == 0 && n('pendingMinor') > 0;
    final color = waiting ? LsColors.orange : LsColors.red;
    return Material(
      color: waiting ? LsColors.orangeSoft : LsColors.redSoft,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openSession(o['id'] as String),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text('${o['consoleCode']} · ${o['playerName'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w900))),
              Text(waiting ? 'Pending verification' : 'Awaiting payment', style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12.5)),
            ]),
            Text('${o['packages'] ?? ''}', style: const TextStyle(color: LsColors.muted, fontSize: 12.5)),
            const SizedBox(height: 4),
            Wrap(spacing: 14, children: [
              _kv('Total', formatMoney(n('totalMinor'), 'ETB'), bold: true),
              _kv('Paid', formatMoney(n('paidMinor'), 'ETB')),
              if (n('pendingMinor') > 0) _kv('Pending', formatMoney(n('pendingMinor'), 'ETB'), color: LsColors.orange),
              _kv('Outstanding', formatMoney(n('balanceMinor'), 'ETB'), color: LsColors.red, bold: true),
            ]),
            if (_canOperate && n('toCollectMinor') > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SizedBox(height: 44, width: double.infinity, child: FilledButton.icon(onPressed: () => _checkout(o['id'] as String), icon: const Icon(Icons.payments_outlined), label: Text('Checkout · ${formatMoney(n('toCollectMinor'), 'ETB')}'))),
              ),
          ]),
        ),
      ),
    );
  }
}

class _Live {
  final int qty, unit, total, paid, pending, bal;
  const _Live(this.qty, this.unit, this.total, this.paid, this.pending, this.bal);
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _Stat(this.label, this.value, this.color);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(color: LsColors.surface, borderRadius: BorderRadius.circular(10), border: Border.all(color: LsColors.border)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: color)),
          Text(label, style: const TextStyle(fontSize: 11.5, color: LsColors.muted)),
        ]),
      );
}
