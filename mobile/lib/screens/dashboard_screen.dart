import 'dart:async';
import 'package:flutter/material.dart';
import '../alarm/expiry_coordinator.dart';
import '../api/api_client.dart';
import '../models/dashboard.dart';
import '../theme.dart';
import '../widgets/session_card.dart';
import '../widgets/status_badge.dart';
import 'session_detail_screen.dart';
import 'checkin/checkin_flow.dart';
import 'customers/customer_search_screen.dart';
import 'shoes/shoe_claims_screen.dart';
import 'equipment/cleaning_queue_screen.dart';

String _money(int? minor, String currency) {
  if (minor == null) return '—';
  final neg = minor < 0;
  final abs = minor.abs();
  final whole = (abs ~/ 100).toString();
  final grouped = whole.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');
  final frac = abs % 100;
  return '${neg ? '-' : ''}$grouped${frac == 0 ? '' : '.${frac.toString().padLeft(2, '0')}'} $currency';
}

/// The flagship screen content: answers "who is skating, how many spaces are left, who is about
/// to finish, who has expired" at a glance — the same questions the web dashboard answers,
/// against the same backend, same permissions, same live data. No Scaffold/AppBar of its own —
/// it's hosted inside AppShell's "Live" tab, which owns the shared app bar and bottom nav.
class DashboardScreen extends StatefulWidget {
  final VoidCallback? onDataChanged;
  const DashboardScreen({super.key, this.onDataChanged});
  @override
  State<DashboardScreen> createState() => DashboardScreenState();
}

class DashboardScreenState extends State<DashboardScreen> {
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
    // Polling for this first mobile build; a live WebSocket (api/realtime_client.dart) also
    // triggers an immediate refresh on every server event — this timer is the safety net.
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _load(silent: true));
  }

  /// Called by AppShell when a realtime event arrives, so the dashboard refreshes immediately
  /// instead of waiting for the next poll tick.
  Future<void> refreshNow() => _load(silent: true);

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
      // Fire-and-forget: reconciling the session-expiry alarm must never block the dashboard
      // render, and a failed reconcile just gets retried on the next poll/refresh tick.
      unawaited(ExpiryCoordinator.instance.reconcile(_data!, _api).catchError((_) {}));
      widget.onDataChanged?.call();
    } catch (e) {
      if (!mounted) return;
      if (!silent) setState(() => _error = e.toString());
    }
  }

  Future<void> _ackAlert(String id, {required bool resolve}) async {
    try {
      await _api.post('/notifications/$id/ack', {'resolve': resolve});
      await _load(silent: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  void _openCheckIn() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CheckInFlow())).then((_) => _load(silent: true));
  }

  void _openSearch() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CustomerSearchScreen()));
  }

  void _openSession(LiveSession s) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => SessionDetailScreen(sessionId: s.id))).then((_) => _load(silent: true));
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
    return d == null
        ? (_error != null ? _ErrorView(message: _error!, onRetry: () => _load()) : const Center(child: CircularProgressIndicator()))
        : RefreshIndicator(
            onRefresh: () => _load(),
            child: ListView(
              padding: const EdgeInsets.all(14),
              children: [
                  Row(children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _openCheckIn,
                        icon: const Icon(Icons.person_add_alt_1),
                        label: const Text('New check-in'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _openSearch,
                        icon: const Icon(Icons.search),
                        label: const Text('Search customer'),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 14),
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
                  if (d.shoesOnShelf != null || d.cleaningNeeds != null) ...[
                    const SizedBox(height: 10),
                    Row(children: [
                      if (d.shoesOnShelf != null)
                        Expanded(
                          child: _QuickLinkCard(
                            emoji: '👟',
                            title: 'Shoes on Shelf',
                            subtitle: '${d.shoesOnShelf} active claim${d.shoesOnShelf == 1 ? '' : 's'}',
                            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ShoeClaimsScreen())).then((_) => _load(silent: true)),
                          ),
                        ),
                      if (d.shoesOnShelf != null && d.cleaningNeeds != null) const SizedBox(width: 10),
                      if (d.cleaningNeeds != null)
                        Expanded(
                          child: _QuickLinkCard(
                            emoji: '🧼',
                            title: 'Cleaning',
                            subtitle: '${d.cleaningNeeds} need cleaning${(d.cleaningOverdue ?? 0) > 0 ? ', ${d.cleaningOverdue} overdue' : ''}',
                            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CleaningQueueScreen())).then((_) => _load(silent: true)),
                          ),
                        ),
                    ]),
                  ],
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
                                  onTap: () => _openSession(s),
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
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              ListTile(
                                leading: LsBadge(
                                  label: a.severity.toLowerCase(),
                                  level: a.severity == 'CRITICAL' ? 'red' : a.severity == 'WARNING' ? 'yellow' : 'info',
                                  icon: Icons.warning_amber_rounded,
                                ),
                                title: Text(a.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                                subtitle: a.body != null ? Text(a.body!) : null,
                              ),
                              Padding(
                                padding: const EdgeInsets.only(left: 8, bottom: 6, right: 8),
                                child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                                  TextButton(onPressed: () => _ackAlert(a.id, resolve: false), child: const Text('Acknowledge')),
                                  const SizedBox(width: 4),
                                  FilledButton.tonal(onPressed: () => _ackAlert(a.id, resolve: true), child: const Text('Resolve')),
                                ]),
                              ),
                            ]),
                          ),
                        )),
                  ],
                ],
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

class _QuickLinkCard extends StatelessWidget {
  final String emoji;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _QuickLinkCard({required this.emoji, required this.title, required this.subtitle, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(children: [
            Text(emoji, style: const TextStyle(fontSize: 22)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                Text(subtitle, style: const TextStyle(color: LsColors.muted, fontSize: 12)),
              ]),
            ),
            const Icon(Icons.chevron_right, color: LsColors.muted),
          ]),
        ),
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
