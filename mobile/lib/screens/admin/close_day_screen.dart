import 'package:flutter/material.dart';
import '../../api/api_client.dart';
import '../../format.dart';
import '../../theme.dart';

class _Preview {
  final String date;
  final int activeSessions;
  final int unreturnedSkates;
  final int unresolvedIncidents;
  final int unpaidSessions;
  final int pendingPayments;
  final int expectedCashMinor;
  final List<dynamic> blockers;
  final List<dynamic> warnings;
  final bool alreadyClosed;
  final String? closedAt;
  _Preview({
    required this.date, required this.activeSessions, required this.unreturnedSkates, required this.unresolvedIncidents,
    required this.unpaidSessions, required this.pendingPayments, required this.expectedCashMinor, required this.blockers,
    required this.warnings, required this.alreadyClosed, required this.closedAt,
  });
  factory _Preview.fromJson(Map<String, dynamic> j) {
    final checks = (j['checks'] as Map<String, dynamic>?) ?? const {};
    return _Preview(
      date: j['date'] as String,
      activeSessions: (checks['activeSessions'] as num?)?.toInt() ?? 0,
      unreturnedSkates: (checks['unreturnedSkates'] as num?)?.toInt() ?? 0,
      unresolvedIncidents: (checks['unresolvedIncidents'] as num?)?.toInt() ?? 0,
      unpaidSessions: (checks['unpaidSessions'] as num?)?.toInt() ?? 0,
      pendingPayments: (checks['pendingPayments'] as num?)?.toInt() ?? 0,
      expectedCashMinor: (j['expectedCashMinor'] as num?)?.toInt() ?? 0,
      blockers: (j['blockers'] as List?) ?? const [],
      warnings: (j['warnings'] as List?) ?? const [],
      alreadyClosed: (j['alreadyClosed'] as bool?) ?? false,
      closedAt: j['closedAt'] as String?,
    );
  }
}

String _describe(dynamic item) {
  if (item is String) return item;
  if (item is Map) return (item['message'] ?? item['reason'] ?? item['code'] ?? item.toString()).toString();
  return item.toString();
}

/// GET /day-close/preview, POST /day-close, GET /day-closes (dayclose.manage). Blockers hard-gate
/// the Close button; warnings require an explicit "close anyway" acknowledgement; notes are
/// required whenever counted cash differs from expected (server enforces this too, 422
/// NOTES_REQUIRED, surfaced verbatim if the client-side check is somehow bypassed).
class CloseDayScreen extends StatefulWidget {
  const CloseDayScreen({super.key});
  @override
  State<CloseDayScreen> createState() => _CloseDayScreenState();
}

class _CloseDayScreenState extends State<CloseDayScreen> {
  late ApiClient _api;
  String _currency = 'ETB';
  DateTime _date = DateTime.now();
  _Preview? _preview;
  bool _loading = true;
  String? _error;

  final _countedCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  bool _acknowledgeWarnings = false;
  bool _closing = false;

  List<Map<String, dynamic>> _history = [];
  bool _loadingHistory = true;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _countedCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    _api = await ApiClient.instance();
    _date = _api.serverNow();
    try {
      final cfg = await _api.get('/config') as Map<String, dynamic>;
      _currency = (cfg['venue'] as Map<String, dynamic>)['currency'] as String? ?? _currency;
    } catch (_) {
      // non-fatal
    }
    await Future.wait([_loadPreview(), _loadHistory()]);
  }

  Future<void> _loadPreview() async {
    setState(() {
      _loading = true;
      _error = null;
      _acknowledgeWarnings = false;
    });
    try {
      final json = await _api.get('/day-close/preview?date=${fmtDate(_date)}') as Map<String, dynamic>;
      final preview = _Preview.fromJson(json);
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _countedCtrl.text = (preview.expectedCashMinor / 100).toStringAsFixed(2);
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

  Future<void> _loadHistory() async {
    setState(() => _loadingHistory = true);
    try {
      final json = await _api.get('/day-closes') as Map<String, dynamic>;
      final closes = ((json['closes'] as List?) ?? const []).cast<Map<String, dynamic>>();
      if (!mounted) return;
      setState(() {
        _history = closes;
        _loadingHistory = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingHistory = false);
    }
  }

  Future<void> _pickDate() async {
    final now = _api.serverNow();
    final picked = await showDatePicker(context: context, initialDate: _date, firstDate: DateTime(2020), lastDate: now);
    if (picked != null) {
      setState(() => _date = picked);
      _loadPreview();
    }
  }

  int get _countedMinor => ((double.tryParse(_countedCtrl.text) ?? 0) * 100).round();
  int get _difference => _countedMinor - (_preview?.expectedCashMinor ?? 0);

  bool get _canClose {
    final p = _preview;
    if (p == null || p.alreadyClosed) return false;
    if (p.blockers.isNotEmpty) return false;
    if (p.warnings.isNotEmpty && !_acknowledgeWarnings) return false;
    if (_difference != 0 && _notesCtrl.text.trim().isEmpty) return false;
    return true;
  }

  Future<void> _close() async {
    setState(() => _closing = true);
    try {
      await _api.post('/day-close', {
        'date': fmtDate(_date),
        'countedCashMinor': _countedMinor,
        'notes': _notesCtrl.text.trim(),
        'acknowledgeWarnings': _acknowledgeWarnings,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Day closed.')));
      _notesCtrl.clear();
      await Future.wait([_loadPreview(), _loadHistory()]);
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _closing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Close day')),
      body: _loading && _preview == null
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _preview == null
              ? _ErrorView(message: _error!, onRetry: _loadPreview)
              : RefreshIndicator(
                  onRefresh: () => Future.wait([_loadPreview(), _loadHistory()]),
                  child: ListView(
                    padding: const EdgeInsets.all(14),
                    children: [
                      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        const Icon(Icons.calendar_today_outlined, size: 18),
                        const SizedBox(width: 8),
                        TextButton(onPressed: _pickDate, child: Text(fmtDate(_date), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
                      ]),
                      if (_preview != null) ..._previewBody(_preview!),
                      const SizedBox(height: 24),
                      Text('Recent closes', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      _historyTable(),
                    ],
                  ),
                ),
    );
  }

  List<Widget> _previewBody(_Preview p) {
    return [
      if (p.alreadyClosed)
        Container(
          margin: const EdgeInsets.only(top: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: LsColors.greenSoft, borderRadius: BorderRadius.circular(8)),
          child: Row(children: [
            const Icon(Icons.check_circle_outline, color: LsColors.green),
            const SizedBox(width: 8),
            Expanded(child: Text('Already closed${p.closedAt != null ? ' at ${p.closedAt}' : ''}.', style: const TextStyle(color: LsColors.green, fontWeight: FontWeight.w600))),
          ]),
        ),
      const SizedBox(height: 14),
      GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 2.3,
        children: [
          _checkTile('Active sessions', p.activeSessions, danger: p.activeSessions > 0),
          _checkTile('Unreturned skates', p.unreturnedSkates, danger: p.unreturnedSkates > 0),
          _checkTile('Unresolved incidents', p.unresolvedIncidents, warning: p.unresolvedIncidents > 0),
          _checkTile('Unpaid sessions', p.unpaidSessions, danger: p.unpaidSessions > 0),
          _checkTile('Pending payments', p.pendingPayments, danger: p.pendingPayments > 0),
        ],
      ),
      const SizedBox(height: 14),
      if (p.blockers.isNotEmpty)
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: LsColors.redSoft, borderRadius: BorderRadius.circular(8)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Row(children: [Icon(Icons.block, color: LsColors.red), SizedBox(width: 8), Text('Blockers — must be resolved before closing', style: TextStyle(color: LsColors.red, fontWeight: FontWeight.w700))]),
            const SizedBox(height: 6),
            ...p.blockers.map((b) => Padding(padding: const EdgeInsets.only(top: 2), child: Text('• ${_describe(b)}', style: const TextStyle(color: LsColors.red)))),
          ]),
        ),
      if (p.warnings.isNotEmpty) ...[
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: LsColors.yellowSoft, borderRadius: BorderRadius.circular(8)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Row(children: [Icon(Icons.warning_amber_rounded, color: LsColors.yellow), SizedBox(width: 8), Text('Warnings', style: TextStyle(color: LsColors.yellow, fontWeight: FontWeight.w700))]),
            const SizedBox(height: 6),
            ...p.warnings.map((w) => Padding(padding: const EdgeInsets.only(top: 2), child: Text('• ${_describe(w)}', style: const TextStyle(color: LsColors.yellow)))),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _acknowledgeWarnings,
              onChanged: (v) => setState(() => _acknowledgeWarnings = v ?? false),
              title: const Text('Close anyway, acknowledging these warnings'),
            ),
          ]),
        ),
      ],
      const SizedBox(height: 14),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Cash reconciliation', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: _readOnlyField('Expected', formatMoney(p.expectedCashMinor, _currency))),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _countedCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: 'Counted ($_currency)'),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Text(
              'Difference: ${formatMoney(_difference, _currency)}',
              style: TextStyle(fontWeight: FontWeight.w700, color: _difference == 0 ? LsColors.green : LsColors.red),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _notesCtrl,
              minLines: 1,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: _difference != 0 ? 'Notes (required — counted differs from expected)' : 'Notes (optional)',
              ),
              onChanged: (_) => setState(() {}),
            ),
          ]),
        ),
      ),
      const SizedBox(height: 14),
      SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: _canClose && !_closing ? _close : null,
          style: FilledButton.styleFrom(backgroundColor: LsColors.red),
          child: _closing ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : Text(p.alreadyClosed ? 'Already closed' : 'Close day'),
        ),
      ),
    ];
  }

  Widget _checkTile(String label, int value, {bool danger = false, bool warning = false}) {
    final color = value == 0 ? LsColors.green : (danger ? LsColors.red : (warning ? LsColors.yellow : LsColors.gray));
    final bg = value == 0 ? LsColors.greenSoft : (danger ? LsColors.redSoft : (warning ? LsColors.yellowSoft : LsColors.graySoft));
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
        Text(label.toUpperCase(), style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
        const SizedBox(height: 4),
        Text('$value', style: TextStyle(color: color, fontSize: 20, fontWeight: FontWeight.w800)),
      ]),
    );
  }

  Widget _readOnlyField(String label, String value) => InputDecorator(
        decoration: InputDecoration(labelText: label),
        child: Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
      );

  Widget _historyTable() {
    if (_loadingHistory) return const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator()));
    if (_history.isEmpty) return const Padding(padding: EdgeInsets.all(16), child: Text('No closes yet.', style: TextStyle(color: LsColors.muted)));
    return Card(
      margin: EdgeInsets.zero,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columns: const [
            DataColumn(label: Text('Date')),
            DataColumn(label: Text('Expected')),
            DataColumn(label: Text('Counted')),
            DataColumn(label: Text('Difference')),
            DataColumn(label: Text('Closed at')),
          ],
          rows: _history.map((c) {
            final expected = (c['expectedCashMinor'] as num?)?.toInt() ?? 0;
            final counted = (c['countedCashMinor'] as num?)?.toInt() ?? 0;
            return DataRow(cells: [
              DataCell(Text('${c['date'] ?? ''}')),
              DataCell(Text(formatMoney(expected, _currency))),
              DataCell(Text(formatMoney(counted, _currency))),
              DataCell(Text(formatMoney(counted - expected, _currency))),
              DataCell(Text('${c['closedAt'] ?? ''}')),
            ]);
          }).toList(),
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
