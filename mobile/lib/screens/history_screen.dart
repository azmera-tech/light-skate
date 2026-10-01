import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../format.dart';
import '../models/me.dart';
import '../models/visit.dart';
import '../theme.dart';
import '../widgets/authed_photo.dart';
import '../widgets/status_badge.dart';
import 'history/visit_detail_screen.dart';

const _filters = <(String, String)>[
  ('all', 'All'),
  ('completed', 'Completed'),
  ('active', 'Active'),
  ('cancelled', 'Cancelled'),
  ('expired', 'Expired'),
  ('payment_issues', 'Payment issues'),
  ('incidents', 'Incidents'),
];

/// Daily history tab. No Scaffold/AppBar of its own — hosted inside AppShell's "History" tab,
/// same bare-body pattern as DashboardScreen/CustomerSearchScreen.
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  late ApiClient _api;
  Me? _me;
  bool _booted = false;

  DateTime _date = DateTime.now();
  String _filter = 'all';
  List<VisitRow> _visits = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    _api = await ApiClient.instance();
    _me = _api.me;
    _date = _api.serverNow();
    setState(() => _booted = true);
    await _load();
  }

  bool get _isToday {
    final now = _api.serverNow();
    return _date.year == now.year &&
        _date.month == now.month &&
        _date.day == now.day;
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final dateStr = fmtDate(_date);
      final res = await _api.get(
        '/visits?date=$dateStr&filter=$_filter',
      ) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _visits = (res['visits'] as List? ?? const [])
            .map((e) => VisitRow.fromJson(e as Map<String, dynamic>))
            .toList();
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

  void _shiftDate(int days) {
    setState(() => _date = _date.add(Duration(days: days)));
    _load();
  }

  Future<void> _pickDate() async {
    final now = _api.serverNow();
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(now.year - 3),
      lastDate: now,
    );
    if (picked == null) return;
    setState(() => _date = picked);
    _load();
  }

  void _goToday() {
    setState(() => _date = _api.serverNow());
    _load();
  }

  void _setFilter(String f) {
    setState(() => _filter = f);
    _load();
  }

  void _openVisit(VisitRow v) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => VisitDetailScreen(visitId: v.visitId)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_booted) return const Center(child: CircularProgressIndicator());

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
          child: Row(
            children: [
              IconButton(
                onPressed: () => _shiftDate(-1),
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: InkWell(
                  onTap: _pickDate,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Center(
                      child: Text(
                        fmtDate(_date),
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              IconButton(
                onPressed: _isToday ? null : () => _shiftDate(1),
                icon: const Icon(Icons.chevron_right),
              ),
              if (!_isToday)
                TextButton(onPressed: _goToday, child: const Text('Today')),
            ],
          ),
        ),
        SizedBox(
          height: 40,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            itemCount: _filters.length,
            separatorBuilder: (_, _) => const SizedBox(width: 6),
            itemBuilder: (context, i) {
              final (value, label) = _filters[i];
              final selected = value == _filter;
              return ChoiceChip(
                label: Text(label),
                selected: selected,
                onSelected: (_) => _setFilter(value),
              );
            },
          ),
        ),
        const SizedBox(height: 6),
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: LsColors.red, size: 36),
              const SizedBox(height: 10),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 14),
              OutlinedButton(
                onPressed: () => _load(),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    if (_visits.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => _load(),
        child: ListView(
          children: const [
            Padding(
              padding: EdgeInsets.all(32),
              child: Center(
                child: Text(
                  'No visits for this day.',
                  style: TextStyle(color: LsColors.muted),
                ),
              ),
            ),
          ],
        ),
      );
    }
    final canSeeMoney = _me?.can('payment.read') == true;
    return RefreshIndicator(
      onRefresh: () => _load(),
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 14),
        itemCount: _visits.length,
        separatorBuilder: (_, _) => const SizedBox(height: 6),
        itemBuilder: (context, i) => _VisitRowTile(
          visit: _visits[i],
          canSeeMoney: canSeeMoney,
          now: _api.serverNow(),
          onTap: () => _openVisit(_visits[i]),
        ),
      ),
    );
  }
}

class _VisitRowTile extends StatelessWidget {
  final VisitRow visit;
  final bool canSeeMoney;
  final DateTime now;
  final VoidCallback onTap;
  const _VisitRowTile({
    required this.visit,
    required this.canSeeMoney,
    required this.now,
    required this.onTap,
  });

  String get _duration {
    if (visit.startedAt == null) return '—';
    final end = visit.actualEndAt;
    if (end != null) {
      return formatDuration(end.difference(visit.startedAt!).inSeconds);
    }
    return '${formatDuration(now.difference(visit.startedAt!).inSeconds)} so far';
  }

  String _level() {
    switch (visit.visitStatus) {
      case 'COMPLETED':
        return 'normal';
      case 'ACTIVE':
        return 'info';
      case 'CANCELLED':
      case 'NO_SHOW':
        return 'gray';
      case 'EXPIRED':
        return 'expired';
      default:
        return 'gray';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 46,
                child: Text(
                  fmtHHMM(visit.startedAt ?? visit.createdAt),
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
              AuthedPhoto(
                photoId: visit.photoId,
                name: visit.fullName,
                size: 44,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            visit.fullName,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (visit.hasIncident) ...[
                          const SizedBox(width: 6),
                          const Icon(
                            Icons.report_problem_outlined,
                            color: LsColors.red,
                            size: 16,
                          ),
                        ],
                      ],
                    ),
                    if (visit.phoneE164 != null)
                      Text(
                        formatPhoneLocal(visit.phoneE164),
                        style: const TextStyle(
                          color: LsColors.muted,
                          fontSize: 12.5,
                        ),
                      ),
                    const SizedBox(height: 2),
                    Text(
                      visit.productName ?? '—',
                      style: const TextStyle(fontSize: 12.5),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _duration,
                      style: const TextStyle(
                        color: LsColors.muted,
                        fontSize: 12.5,
                      ),
                    ),
                    if (visit.equipment != null && visit.equipment!.isNotEmpty)
                      Text(
                        visit.equipment!,
                        style: const TextStyle(
                          color: LsColors.muted,
                          fontSize: 12,
                        ),
                      ),
                    if (visit.staffName != null)
                      Text(
                        'Staff: ${visit.staffName}',
                        style: const TextStyle(
                          color: LsColors.muted,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (canSeeMoney && visit.paidMinor != null)
                    Text(
                      formatMoney(visit.paidMinor, 'ETB'),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  const SizedBox(height: 4),
                  LsBadge.forStatus(visit.visitStatus, _level()),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
