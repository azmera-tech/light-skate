import 'package:flutter/material.dart';
import '../../api/api_client.dart';
import '../../format.dart';
import '../../models/dashboard.dart';
import '../../models/report.dart';
import '../../theme.dart';

/// Admin landing/summary page: composes GET /dashboard (live numbers) with GET /reports/daily
/// for today (end-of-day-shaped numbers that /dashboard doesn't carry, e.g. completed sessions,
/// average duration, capacity utilisation). Every tile is independently null-safe so a user
/// missing the underlying read permission for a field (server omits it) just doesn't see that tile.
class AdminOverviewScreen extends StatefulWidget {
  const AdminOverviewScreen({super.key});
  @override
  State<AdminOverviewScreen> createState() => _AdminOverviewScreenState();
}

class _AdminOverviewScreenState extends State<AdminOverviewScreen> {
  late ApiClient _api;
  Dashboard? _dash;
  DailyReport? _daily;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      _api = await ApiClient.instance();
      final dashJson = await _api.get('/dashboard');
      Dashboard? dash = Dashboard.fromJson(dashJson as Map<String, dynamic>);
      DailyReport? daily;
      try {
        final today = fmtDate(_api.serverNow());
        final dailyJson = await _api.get('/reports/daily?date=$today');
        daily = DailyReport.fromJson(dailyJson as Map<String, dynamic>);
      } on ApiException {
        // staff with reports.read missing — dashboard tiles still render without the second row
        daily = null;
      }
      if (!mounted) return;
      setState(() {
        _dash = dash;
        _daily = daily;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Overview')),
      body: _loading && _dash == null
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _dash == null
              ? _ErrorView(message: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(14),
                    children: [
                      Text('Right now', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      _liveTiles(),
                      if (_daily != null) ...[
                        const SizedBox(height: 18),
                        Text('Today so far', style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 8),
                        _dailyTiles(_daily!),
                        const SizedBox(height: 18),
                        Text('Sessions by start hour', style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 8),
                        _HourlyChart(hourly: _daily!.hourlyStarts),
                      ],
                    ],
                  ),
                ),
    );
  }

  Widget _liveTiles() {
    final d = _dash;
    if (d == null) return const SizedBox.shrink();
    final cur = d.currency;
    final tiles = <_Tile>[
      _Tile('Visitors today', '${d.visitorsToday}'),
      if (d.revenueMinorToday != null) _Tile('Revenue today', formatMoney(d.revenueMinorToday, cur)),
      _Tile('Active now', '${d.occupancy} / ${d.maxCapacity}'),
      _Tile('Waiting', '${d.waiting}'),
      _Tile('Ending soon / time up', '${d.expiring} / ${d.expired}'),
      _Tile('Skates out', '${d.equipmentOut}'),
      if (d.openIncidents != null) _Tile('Open incidents', '${d.openIncidents}'),
    ];
    return _TileGrid(tiles: tiles);
  }

  Widget _dailyTiles(DailyReport r) {
    final tiles = <_Tile>[
      _Tile('Completed sessions', '${r.sessionsCompleted}'),
      _Tile('Avg. session duration', formatDuration(r.averageSessionSeconds)),
      _Tile('Capacity utilisation', '${r.capacityUtilizationPercent.toStringAsFixed(1)}%'),
      _Tile('Refunds today', formatMoney(r.refundsMinor, r.currency)),
      _Tile('Cancelled / no-shows', '${r.cancelled} / ${r.noShows}'),
      _Tile('Extensions', '${r.extensions}'),
    ];
    return _TileGrid(tiles: tiles);
  }
}

class _Tile {
  final String label;
  final String value;
  const _Tile(this.label, this.value);
}

class _TileGrid extends StatelessWidget {
  final List<_Tile> tiles;
  const _TileGrid({required this.tiles});
  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 2.1,
      children: tiles
          .map((t) => Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text(t.label.toUpperCase(), style: const TextStyle(color: LsColors.muted, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
                    const SizedBox(height: 4),
                    Text(t.value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                  ]),
                ),
              ))
          .toList(),
    );
  }
}

/// A simple self-drawn bar chart (no new chart dependency) of session starts by hour.
class _HourlyChart extends StatelessWidget {
  final List<HourlyStart> hourly;
  const _HourlyChart({required this.hourly});
  @override
  Widget build(BuildContext context) {
    if (hourly.isEmpty) {
      return const Padding(padding: EdgeInsets.all(12), child: Text('No sessions yet today.', style: TextStyle(color: LsColors.muted)));
    }
    final maxV = hourly.map((h) => h.sessions).fold<int>(0, (a, b) => a > b ? a : b).clamp(1, 1 << 30);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
        child: SizedBox(
          height: 120,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: hourly
                .map((h) => Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Tooltip(
                          message: '${h.hour}:00 — ${h.sessions}',
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              Container(
                                height: 84 * (h.sessions / maxV),
                                decoration: BoxDecoration(color: LsColors.brand, borderRadius: BorderRadius.circular(3)),
                              ),
                              const SizedBox(height: 4),
                              Text('${h.hour}', style: const TextStyle(fontSize: 9, color: LsColors.muted)),
                            ],
                          ),
                        ),
                      ),
                    ))
                .toList(),
          ),
        ),
      ),
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
