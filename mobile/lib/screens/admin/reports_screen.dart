import 'package:flutter/material.dart';
import '../../api/api_client.dart';
import '../../format.dart';
import '../../models/report.dart';
import '../../theme.dart';

enum _Mode { daily, range }

/// GET /reports/daily and GET /reports/range (requires reports.read). Daily mode: date nav +
/// KPI tiles + revenue-by-method table. Range mode: from/to pickers + group-by + totals + a
/// per-period table, with a "Copy as CSV" dialog in place of a (nonexistent) server CSV endpoint.
class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});
  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  late ApiClient _api;
  _Mode _mode = _Mode.daily;
  bool _booted = false;

  DateTime _date = DateTime.now();
  DailyReport? _daily;
  bool _dailyLoading = false;
  String? _dailyError;

  DateTime _from = DateTime.now().subtract(const Duration(days: 6));
  DateTime _to = DateTime.now();
  String _group = 'day';
  RangeReport? _range;
  bool _rangeLoading = false;
  String? _rangeError;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    _api = await ApiClient.instance();
    _date = _api.serverNow();
    _to = _api.serverNow();
    _from = _to.subtract(const Duration(days: 6));
    _booted = true;
    await _loadDaily();
  }

  Future<void> _loadDaily() async {
    setState(() {
      _dailyLoading = true;
      _dailyError = null;
    });
    try {
      final json = await _api.get('/reports/daily?date=${fmtDate(_date)}');
      if (!mounted) return;
      setState(() {
        _daily = DailyReport.fromJson(json as Map<String, dynamic>);
        _dailyLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _dailyError = e.toString();
        _dailyLoading = false;
      });
    }
  }

  Future<void> _loadRange() async {
    setState(() {
      _rangeLoading = true;
      _rangeError = null;
    });
    try {
      final json = await _api.get('/reports/range?from=${fmtDate(_from)}&to=${fmtDate(_to)}&group=$_group');
      if (!mounted) return;
      setState(() {
        _range = RangeReport.fromJson(json as Map<String, dynamic>);
        _rangeLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _rangeError = e.toString();
        _rangeLoading = false;
      });
    }
  }

  Future<void> _pickDate() async {
    final now = _api.serverNow();
    final picked = await showDatePicker(context: context, initialDate: _date, firstDate: DateTime(2020), lastDate: now);
    if (picked != null) {
      setState(() => _date = picked);
      _loadDaily();
    }
  }

  Future<void> _pickFrom() async {
    final picked = await showDatePicker(context: context, initialDate: _from, firstDate: DateTime(2020), lastDate: _to);
    if (picked != null) setState(() => _from = picked);
  }

  Future<void> _pickTo() async {
    final now = _api.serverNow();
    final picked = await showDatePicker(context: context, initialDate: _to, firstDate: _from, lastDate: now);
    if (picked != null) setState(() => _to = picked);
  }

  void _shiftDay(int delta) {
    setState(() => _date = _date.add(Duration(days: delta)));
    _loadDaily();
  }

  String _toCsv(RangeReport r) {
    final buf = StringBuffer();
    buf.writeln('Period,Sessions started,Sessions completed,Unique customers,Revenue (net minor),Refunds (minor),Discounts (minor),Avg session (s)');
    for (final row in r.rows) {
      buf.writeln('${row.period},${row.sessionsStarted},${row.sessionsCompleted},${row.uniqueCustomers},${row.revenueMinor},${row.refundsMinor},${row.discountsMinor},${row.averageSessionSeconds}');
    }
    return buf.toString();
  }

  void _showCsvDialog(RangeReport r) {
    final csv = _toCsv(r);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Range report CSV'),
        content: SizedBox(
          width: 480,
          child: TextField(
            controller: TextEditingController(text: csv),
            readOnly: true,
            maxLines: 12,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reports')),
      body: !_booted
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: SegmentedButton<_Mode>(
                    segments: const [
                      ButtonSegment(value: _Mode.daily, label: Text('Daily'), icon: Icon(Icons.today_outlined)),
                      ButtonSegment(value: _Mode.range, label: Text('Range'), icon: Icon(Icons.date_range_outlined)),
                    ],
                    selected: {_mode},
                    onSelectionChanged: (s) {
                      setState(() => _mode = s.first);
                      if (_mode == _Mode.range && _range == null) _loadRange();
                    },
                  ),
                ),
                Expanded(child: _mode == _Mode.daily ? _buildDaily() : _buildRange()),
              ],
            ),
    );
  }

  Widget _buildDaily() {
    if (_dailyLoading && _daily == null) return const Center(child: CircularProgressIndicator());
    if (_dailyError != null && _daily == null) return _ErrorView(message: _dailyError!, onRetry: _loadDaily);
    final r = _daily;
    return RefreshIndicator(
      onRefresh: _loadDaily,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        children: [
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            IconButton(onPressed: () => _shiftDay(-1), icon: const Icon(Icons.chevron_left)),
            TextButton(onPressed: _pickDate, child: Text(fmtDate(_date), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
            IconButton(
              onPressed: fmtDate(_date) == fmtDate(_api.serverNow()) ? null : () => _shiftDay(1),
              icon: const Icon(Icons.chevron_right),
            ),
          ]),
          if (r == null)
            const SizedBox.shrink()
          else ...[
            const SizedBox(height: 8),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 2.1,
              children: [
                _kpi('Visitors', '${r.visitors}'),
                _kpi('New customers', '${r.newCustomers}'),
                _kpi('Sessions started', '${r.sessionsStarted}'),
                _kpi('Sessions completed', '${r.sessionsCompleted}'),
                _kpi('Net revenue', formatMoney(r.netMinor, r.currency)),
                _kpi('Refunds', formatMoney(r.refundsMinor, r.currency)),
                _kpi('Discounts', formatMoney(r.discountsMinor, r.currency)),
                _kpi('Avg. session', formatDuration(r.averageSessionSeconds)),
                _kpi('Capacity utilisation', '${r.capacityUtilizationPercent.toStringAsFixed(1)}%'),
                _kpi('Cancelled / no-shows', '${r.cancelled} / ${r.noShows}'),
                _kpi('Extensions', '${r.extensions}'),
                _kpi('Incidents', '${r.incidentsTotal}'),
              ],
            ),
            const SizedBox(height: 18),
            Text('Revenue by payment method', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Card(
              margin: EdgeInsets.zero,
              child: r.byMethod.isEmpty
                  ? const Padding(padding: EdgeInsets.all(16), child: Text('No charges today.', style: TextStyle(color: LsColors.muted)))
                  : SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        columns: const [
                          DataColumn(label: Text('Method')),
                          DataColumn(label: Text('Count')),
                          DataColumn(label: Text('Charges')),
                          DataColumn(label: Text('Refunds')),
                        ],
                        rows: r.byMethod
                            .map((m) => DataRow(cells: [
                                  DataCell(Text(titleCase(m.method))),
                                  DataCell(Text('${m.count}')),
                                  DataCell(Text(formatMoney(m.chargesMinor, r.currency))),
                                  DataCell(Text(formatMoney(m.refundsMinor, r.currency))),
                                ]))
                            .toList(),
                      ),
                    ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildRange() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
      children: [
        Row(children: [
          Expanded(child: OutlinedButton(onPressed: _pickFrom, child: Text('From: ${fmtDate(_from)}'))),
          const SizedBox(width: 8),
          Expanded(child: OutlinedButton(onPressed: _pickTo, child: Text('To: ${fmtDate(_to)}'))),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: _group,
              decoration: const InputDecoration(labelText: 'Group by'),
              items: const [
                DropdownMenuItem(value: 'day', child: Text('Day')),
                DropdownMenuItem(value: 'week', child: Text('Week')),
                DropdownMenuItem(value: 'month', child: Text('Month')),
              ],
              onChanged: (v) => setState(() => _group = v ?? 'day'),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(onPressed: _rangeLoading ? null : _loadRange, child: const Text('Run')),
        ]),
        const SizedBox(height: 14),
        if (_rangeLoading && _range == null)
          const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
        else if (_rangeError != null)
          _ErrorView(message: _rangeError!, onRetry: _loadRange)
        else if (_range != null) ...[
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text('Totals', style: Theme.of(context).textTheme.titleMedium),
            TextButton.icon(onPressed: () => _showCsvDialog(_range!), icon: const Icon(Icons.copy_all_outlined), label: const Text('Copy as CSV')),
          ]),
          _totalsGrid(_range!),
          const SizedBox(height: 14),
          Text('By period', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            margin: EdgeInsets.zero,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: const [
                  DataColumn(label: Text('Period')),
                  DataColumn(label: Text('Started')),
                  DataColumn(label: Text('Completed')),
                  DataColumn(label: Text('Customers')),
                  DataColumn(label: Text('Revenue')),
                  DataColumn(label: Text('Refunds')),
                  DataColumn(label: Text('Avg')),
                ],
                rows: _range!.rows
                    .map((row) => DataRow(cells: [
                          DataCell(Text(row.period)),
                          DataCell(Text('${row.sessionsStarted}')),
                          DataCell(Text('${row.sessionsCompleted}')),
                          DataCell(Text('${row.uniqueCustomers}')),
                          DataCell(Text(formatMoney(row.revenueMinor, _range!.currency))),
                          DataCell(Text(formatMoney(row.refundsMinor, _range!.currency))),
                          DataCell(Text(formatDuration(row.averageSessionSeconds))),
                        ]))
                    .toList(),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _totalsGrid(RangeReport r) {
    int _int(String k) => (r.totals[k] as num?)?.toInt() ?? 0;
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 2.4,
      children: [
        _kpi('Sessions started', '${_int('sessionsStarted')}'),
        _kpi('Sessions completed', '${_int('sessionsCompleted')}'),
        _kpi('Unique customers', '${_int('uniqueCustomers')}'),
        _kpi('Revenue', formatMoney(_int('revenueMinor'), r.currency)),
        _kpi('Refunds', formatMoney(_int('refundsMinor'), r.currency)),
        _kpi('Discounts', formatMoney(_int('discountsMinor'), r.currency)),
      ],
    );
  }

  Widget _kpi(String label, String value) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
            Text(label.toUpperCase(), style: const TextStyle(color: LsColors.muted, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
            const SizedBox(height: 4),
            Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          ]),
        ),
      );
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
