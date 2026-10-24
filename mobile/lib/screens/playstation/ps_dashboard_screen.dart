import 'dart:async';
import 'package:flutter/material.dart';
import '../../alarm/expiry_alarm_service.dart';
import '../../api/api_client.dart';
import '../../api/realtime_bus.dart';
import '../../format.dart';
import '../../models/playstation.dart';
import '../../theme.dart';
import 'ps_history_screen.dart';
import 'ps_new_session_sheet.dart';
import 'ps_session_screen.dart';

/// The PlayStation Manager's live board: today's numbers, sessions about to end, and every console
/// with its state and countdown. Tapping a free console opens a session; tapping a busy one opens it.
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
  DateTime _fetchedAt = DateTime.now();
  String? _error;
  Timer? _tick;
  Timer? _poll;

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
    RealtimeBus.last.removeListener(_onRealtime);
    super.dispose();
  }

  void _onRealtime() {
    final e = RealtimeBus.last.value;
    if (e == null) return;
    if (e.event == 'RESYNC' || e.event.startsWith('PS_')) _load();
    if ((e.event == 'PS_SESSION_WARNING' || e.event == 'PS_SESSION_TIME_UP') && mounted) {
      final p = (e.data['payload'] as Map?)?.cast<String, dynamic>() ?? const {};
      final up = e.event == 'PS_SESSION_TIME_UP';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: up ? LsColors.red : LsColors.orange,
        duration: const Duration(seconds: 8),
        content: Text(up ? '${p['consoleCode'] ?? 'A console'}: time is up' : '${p['consoleCode'] ?? 'A console'}: ending soon'),
        action: e.data['aggregateId'] == null
            ? null
            : SnackBarAction(label: 'Open', textColor: Colors.white, onPressed: () => _openSession(e.data['aggregateId'] as String)),
      ));
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
      if (!mounted) return;
      final consoles = ((c['consoles'] as List?) ?? const []).map((e) => PsConsole.fromJson(e as Map<String, dynamic>)).toList();
      setState(() {
        _ov = ov;
        _consoles = consoles;
        _fetchedAt = DateTime.now();
        _error = null;
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

  void _openSession(String id) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => PsSessionScreen(sessionId: id))).then((_) => _load());
  }

  Future<void> _tapConsole(PsConsole c) async {
    if (c.session != null) return _openSession(c.session!.id);
    if (c.state != 'AVAILABLE') {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${c.code} is ${c.state == 'MAINTENANCE' ? 'under maintenance' : 'inactive'}.')));
      return;
    }
    final id = await showNewGamingSessionSheet(context, c);
    await _load();
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
    final ending = ((ov['endingSoon'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final recent = ((ov['recentActivity'] as List?) ?? const []).cast<Map<String, dynamic>>();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(12), children: [
        Row(children: [
          Text('PlayStation', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          const Spacer(),
          if (widget.showHistoryButton)
            TextButton.icon(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const Scaffold(appBar: _HistoryBar(), body: PsHistoryScreen()))),
              icon: const Icon(Icons.history),
              label: const Text('History'),
            ),
        ]),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: [
          _Stat('Consoles', '${cs['total']}', LsColors.slate),
          _Stat('Available', '${cs['available']}', LsColors.green),
          _Stat('In use', '${cs['inUse']}', LsColors.brand),
          _Stat('Ending soon', '${ending.length}', ending.isEmpty ? LsColors.gray : LsColors.orange),
          _Stat('Active sessions', '${ss['active']}', LsColors.brand),
          _Stat('Finished today', '${ss['completedToday']}', LsColors.slate),
          _Stat('Collected today', formatMoney((rev['netMinor'] as num).toInt(), 'ETB'), LsColors.green),
          if ((out['sessions'] as num) > 0) _Stat('Unpaid', '${out['sessions']} · ${formatMoney((out['minor'] as num).toInt(), 'ETB')}', LsColors.red),
        ]),
        if (ending.isNotEmpty) ...[
          const SizedBox(height: 12),
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
        const SizedBox(height: 14),
        if (_consoles.isEmpty)
          const Card(child: Padding(padding: EdgeInsets.all(20), child: Text('No consoles yet. An admin adds consoles under Admin → PlayStation → Consoles.', textAlign: TextAlign.center))),
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: MediaQuery.of(context).size.width > 700 ? 4 : 2,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 1.05,
          children: [for (final c in _consoles) _ConsoleTile(c: c, remaining: c.session == null ? null : _remaining(c.session!), onTap: () => _tapConsole(c))],
        ),
        if (recent.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Recent activity', style: Theme.of(context).textTheme.titleMedium),
          for (final r in recent.take(12))
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text('${r['consoleCode']} · ${psEventLabel[r['eventType']] ?? r['eventType']}'),
              subtitle: Text('${fmtHHMM(DateTime.tryParse(r['occurredAt'] as String? ?? '')?.toLocal())}${r['actorName'] != null ? ' · ${r['actorName']}' : ''}'),
              onTap: () => _openSession(r['sessionId'] as String),
            ),
        ],
      ]),
    );
  }
}

class _HistoryBar extends StatelessWidget implements PreferredSizeWidget {
  const _HistoryBar();
  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
  @override
  Widget build(BuildContext context) => AppBar(title: const Text('Gaming history'));
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

class _ConsoleTile extends StatelessWidget {
  final PsConsole c;
  final int? remaining;
  final VoidCallback onTap;
  const _ConsoleTile({required this.c, required this.remaining, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final s = c.session;
    late Color fg, bg;
    String headline;
    switch (c.state) {
      case 'AVAILABLE':
        (fg, bg, headline) = (LsColors.green, LsColors.greenSoft, 'Available');
      case 'MAINTENANCE':
        (fg, bg, headline) = (LsColors.orange, LsColors.orangeSoft, 'Maintenance');
      case 'INACTIVE':
        (fg, bg, headline) = (LsColors.gray, LsColors.graySoft, 'Inactive');
      default:
        final over = remaining != null && remaining! <= 0;
        final soon = remaining != null && remaining! <= 300;
        fg = s?.status == 'PAUSED' ? LsColors.slate : over ? LsColors.red : soon ? LsColors.orange : LsColors.brandStrong;
        bg = s?.status == 'PAUSED' ? LsColors.slateSoft : over ? LsColors.redSoft : soon ? LsColors.orangeSoft : LsColors.brandSoft;
        headline = psStatusLabel[s?.status] ?? 'In use';
    }
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.sports_esports, color: fg),
              const SizedBox(width: 6),
              Expanded(child: Text(c.code, style: TextStyle(fontWeight: FontWeight.w900, color: fg, fontSize: 16), overflow: TextOverflow.ellipsis)),
            ]),
            Text(c.name, style: const TextStyle(color: LsColors.muted, fontSize: 12), overflow: TextOverflow.ellipsis),
            const Spacer(),
            Text(headline, style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 12.5)),
            if (s != null) ...[
              if (s.pricingType == 'DURATION' && remaining != null)
                Text(fmtClock(remaining!), style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: fg))
              else if (s.pricingType == 'PER_GAME')
                Text('${s.gamesCompleted}/${s.gamesPurchased} games', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: fg)),
              Text('${s.playerName ?? ''}${s.paymentStatus != 'PAID' ? ' · ${psPaymentLabel[s.paymentStatus]}' : ''}',
                  style: TextStyle(fontSize: 12, color: s.paymentStatus != 'PAID' ? LsColors.red : LsColors.text), overflow: TextOverflow.ellipsis),
            ] else if (c.state == 'AVAILABLE')
              const Text('Tap to start a session', style: TextStyle(fontSize: 12)),
          ]),
        ),
      ),
    );
  }
}
