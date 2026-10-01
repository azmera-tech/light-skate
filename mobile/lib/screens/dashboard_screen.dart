import 'dart:async';
import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../models/dashboard.dart';
import '../theme.dart';
import '../widgets/session_card.dart';
import '../widgets/status_badge.dart';
import 'login_screen.dart';

String _money(int? minor, String currency) {
  if (minor == null) return '—';
  final neg = minor < 0;
  final abs = minor.abs();
  final whole = (abs ~/ 100).toString();
  final grouped = whole.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');
  final frac = abs % 100;
  return '${neg ? '-' : ''}$grouped${frac == 0 ? '' : '.${frac.toString().padLeft(2, '0')}'} $currency';
}

/// The flagship screen: answers "who is skating, how many spaces are left, who is about to
/// finish, who has expired" at a glance — the same questions the web dashboard answers,
/// against the same backend, same permissions, same live data.
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  Dashboard? _data;
  VenueConfig? _config;
  String? _error;
  Timer? _poll;
  late ApiClient _api;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    _api = await ApiClient.instance();
    await _load();
    // Polling for this first mobile build; the web client additionally holds a live WebSocket
    // for instant cross-device updates (see api/realtime, not yet ported here — see README).
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _load(silent: true));
  }

  Future<void> _load({bool silent = false}) async {
    try {
      final cfgJson = await _api.get('/config');
      final dashJson = await _api.get('/dashboard');
      if (!mounted) return;
      setState(() {
        _config = VenueConfig.fromJson(cfgJson as Map<String, dynamic>);
        _data = Dashboard.fromJson(dashJson as Map<String, dynamic>);
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      if (!silent) setState(() => _error = e.toString());
    }
  }

  Future<void> _signOut() async {
    _poll?.cancel();
    await _api.setToken(null);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const LoginScreen()));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    final cfg = _config;
    return Scaffold(
      appBar: AppBar(
        title: Text(cfg?.venueName ?? 'Light Skate'),
        actions: [IconButton(onPressed: _signOut, icon: const Icon(Icons.logout), tooltip: 'Sign out')],
      ),
      body: d == null
          ? (_error != null ? _ErrorView(message: _error!, onRetry: () => _load()) : const Center(child: CircularProgressIndicator()))
          : RefreshIndicator(
              onRefresh: () => _load(),
              child: ListView(
                padding: const EdgeInsets.all(14),
                children: [
                  if (d.expired > 0)
                    _Banner(
                      color: LsColors.red,
                      icon: Icons.error_outline,
                      text: '${d.expired} session${d.expired > 1 ? 's have' : ' has'} run out of time',
                    ),
                  if (d.full) const _Banner(color: LsColors.red, icon: Icons.lock_outline, text: 'VENUE FULL — new sessions are blocked'),
                  _KpiGrid(d: d),
                  const SizedBox(height: 14),
                  _RinkSummary(d: d),
                  const SizedBox(height: 14),
                  Text('Live rink', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  if (d.liveSessions.isEmpty)
                    const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('Nobody is skating right now.', style: TextStyle(color: LsColors.muted))))
                  else
                    LayoutBuilder(builder: (context, c) {
                      final cols = c.maxWidth > 700 ? 2 : 1;
                      final sorted = [...d.liveSessions]..sort((a, b) {
                          final ra = a.remainingSeconds(_api.serverNow()) ?? 1 << 30;
                          final rb = b.remainingSeconds(_api.serverNow()) ?? 1 << 30;
                          return ra.compareTo(rb);
                        });
                      return GridView.count(
                        crossAxisCount: cols,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        mainAxisSpacing: 10,
                        crossAxisSpacing: 10,
                        childAspectRatio: cols == 1 ? 1.55 : 1.7,
                        children: sorted
                            .map((s) => SessionCard(
                                  session: s,
                                  warnings: cfg!.warnings.map((w) => (minutes: w.minutes, level: w.level)).toList(),
                                  now: _api.serverNow,
                                ))
                            .toList(),
                      );
                    }),
                  if (d.alerts.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    Text('Alerts', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    const Text('(stay here until resolved)', style: TextStyle(color: LsColors.muted, fontSize: 12)),
                    const SizedBox(height: 8),
                    ...d.alerts.map((a) => Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            leading: LsBadge(
                              label: a.severity.toLowerCase(),
                              level: a.severity == 'CRITICAL' ? 'red' : a.severity == 'WARNING' ? 'yellow' : 'info',
                              icon: Icons.warning_amber_rounded,
                            ),
                            title: Text(a.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                            subtitle: a.body != null ? Text(a.body!) : null,
                          ),
                        )),
                  ],
                ],
              ),
            ),
    );
  }
}

class _KpiGrid extends StatelessWidget {
  final Dashboard d;
  const _KpiGrid({required this.d});
  @override
  Widget build(BuildContext context) {
    final cur = d.currency;
    final items = <(String, String, String?)>[
      ('Inside now', '${d.occupancy} / ${d.maxCapacity}', null),
      ('Spaces left', '${d.available}', d.full ? 'FULL' : 'available'),
      ('Visitors today', '${d.visitorsToday}', null),
      if (d.revenueMinorToday != null) ('Revenue today', _money(d.revenueMinorToday, cur), null),
      ('Waiting', '${d.waiting}', null),
      ('Skates out', '${d.equipmentOut}', d.equipmentNeedsAttention > 0 ? '${d.equipmentNeedsAttention} need attention' : null),
    ];
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 1.9,
      children: items
          .map((it) => Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text(it.$1.toUpperCase(), style: const TextStyle(color: LsColors.muted, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
                    const SizedBox(height: 4),
                    Text(it.$2, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                    if (it.$3 != null) Text(it.$3!, style: const TextStyle(color: LsColors.muted, fontSize: 12)),
                  ]),
                ),
              ))
          .toList(),
    );
  }
}

class _RinkSummary extends StatelessWidget {
  final Dashboard d;
  const _RinkSummary({required this.d});
  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Text('Live rink', style: TextStyle(fontWeight: FontWeight.w700)),
          Wrap(spacing: 6, children: [
            LsBadge(label: '${d.normal} normal', level: 'normal', icon: Icons.play_circle_outline),
            LsBadge(label: '${d.expiring} ending soon', level: 'yellow', icon: Icons.warning_amber_rounded),
            LsBadge(label: '${d.expired} time up', level: 'expired', icon: Icons.stop_circle_outlined),
          ]),
        ]),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String text;
  const _Banner({required this.color, required this.icon, required this.text});
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 10),
        Expanded(child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w700))),
      ]),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.error_outline, color: LsColors.red, size: 36),
          const SizedBox(height: 10),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 14),
          OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
        ]),
      ),
    );
  }
}
