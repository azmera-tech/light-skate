import 'package:flutter/material.dart';
import '../../api/api_client.dart';
import '../../format.dart';
import '../../models/me.dart';
import '../../models/playstation.dart';
import '../../theme.dart';
import 'ps_session_screen.dart';

/// Gaming session history with filters. Operators can narrow to their own sessions; staff who
/// manage accounts can also filter by employee.
class PsHistoryScreen extends StatefulWidget {
  const PsHistoryScreen({super.key});
  @override
  State<PsHistoryScreen> createState() => _PsHistoryScreenState();
}

class _PsHistoryScreenState extends State<PsHistoryScreen> {
  late ApiClient _api;
  Me? _me;
  DateTimeRange? _range;
  String? _status;
  String? _payment;
  String? _consoleId;
  String? _packageId;
  String? _operatorId;
  bool _mine = false;
  List<PsConsole> _consoles = [];
  List<PsPackage> _packages = [];
  List<Map<String, dynamic>> _staff = [];
  List<Map<String, dynamic>> _rows = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _range = DateTimeRange(start: DateTime(now.year, now.month, now.day), end: DateTime(now.year, now.month, now.day));
    _boot();
  }

  Future<void> _boot() async {
    _api = await ApiClient.instance();
    _me = _api.me;
    try {
      final c = await _api.get('/playstation/consoles?archived=true') as Map<String, dynamic>;
      _consoles = ((c['consoles'] as List?) ?? const []).map((e) => PsConsole.fromJson(e as Map<String, dynamic>)).toList();
      final p = await _api.get('/playstation/packages${_me?.can('playstation.manage') == true ? '?all=true' : ''}') as Map<String, dynamic>;
      _packages = ((p['packages'] as List?) ?? const []).map((e) => PsPackage.fromJson(e as Map<String, dynamic>)).toList();
      if (_me?.can('staff.manage') == true) {
        final s = await _api.get('/staff') as Map<String, dynamic>;
        _staff = ((s['staff'] as List?) ?? const []).cast<Map<String, dynamic>>();
      }
    } catch (_) {}
    await _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final q = <String>[
      'from=${fmtDate(_range!.start)}',
      'to=${fmtDate(_range!.end)}',
      if (_status != null) 'status=$_status',
      if (_payment != null) 'paymentStatus=$_payment',
      if (_consoleId != null) 'consoleId=$_consoleId',
      if (_packageId != null) 'packageId=$_packageId',
      if (_operatorId != null) 'operatorId=$_operatorId',
      if (_mine) 'mine=true',
    ];
    try {
      final r = await _api.get('/playstation/sessions?${q.join('&')}') as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _rows = ((r['sessions'] as List?) ?? const []).cast<Map<String, dynamic>>();
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final r = await showDateRangePicker(context: context, firstDate: DateTime(now.year - 2), lastDate: now, initialDateRange: _range);
    if (r != null) {
      setState(() => _range = r);
      _load();
    }
  }

  Widget _dd<T>(String label, T? value, List<(T?, String)> items, void Function(T?) set) => Padding(
        padding: const EdgeInsets.only(right: 8, bottom: 8),
        child: SizedBox(
          width: 165,
          child: DropdownButtonFormField<T?>(
            initialValue: value,
            isExpanded: true,
            decoration: InputDecoration(labelText: label, isDense: true),
            items: items.map((i) => DropdownMenuItem<T?>(value: i.$1, child: Text(i.$2, overflow: TextOverflow.ellipsis))).toList(),
            onChanged: (v) {
              set(v);
              _load();
            },
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final collected = _rows.fold<int>(0, (a, r) => a + ((r['paidMinor'] as num?)?.toInt() ?? 0));
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(12), children: [
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _pickRange,
              icon: const Icon(Icons.date_range),
              label: Text(_range == null ? 'Dates' : _range!.start == _range!.end ? fmtDate(_range!.start) : '${fmtDate(_range!.start)} → ${fmtDate(_range!.end)}'),
            ),
          ),
          const SizedBox(width: 8),
          FilterChip(label: const Text('Mine'), selected: _mine, onSelected: (v) { setState(() => _mine = v); _load(); }),
        ]),
        const SizedBox(height: 10),
        Wrap(children: [
          _dd<String>('Status', _status, [(null, 'Any status'), for (final e in psStatusLabel.entries) (e.key, e.value)], (v) => _status = v),
          _dd<String>('Payment', _payment, [(null, 'Any payment'), for (final e in psPaymentLabel.entries) (e.key, e.value)], (v) => _payment = v),
          _dd<String>('Console', _consoleId, [(null, 'Any console'), for (final c in _consoles) (c.id, c.code)], (v) => _consoleId = v),
          _dd<String>('Package', _packageId, [(null, 'Any package'), for (final p in _packages) (p.id, p.name)], (v) => _packageId = v),
          if (_staff.isNotEmpty) _dd<String>('Employee', _operatorId, [(null, 'Any employee'), for (final s in _staff) (s['id'] as String, s['fullName'] as String)], (v) => _operatorId = v),
        ]),
        Text('${_rows.length} session(s) · ${formatMoney(collected, 'ETB')} paid', style: const TextStyle(color: LsColors.muted)),
        const SizedBox(height: 6),
        if (_loading) const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator())),
        if (_error != null) Text(_error!, style: const TextStyle(color: LsColors.red)),
        if (!_loading && _rows.isEmpty) const Padding(padding: EdgeInsets.all(20), child: Text('No gaming sessions match these filters.', textAlign: TextAlign.center, style: TextStyle(color: LsColors.muted))),
        for (final r in _rows)
          Card(
            margin: const EdgeInsets.only(bottom: 6),
            child: ListTile(
              title: Text('${r['consoleCode']} · ${r['playerName'] ?? '—'}', style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text([
                '${r['sessionNumber']} · ${r['packages'] ?? ''}',
                '${psStatusLabel[r['status']] ?? r['status']} · ${psPaymentLabel[r['paymentStatus']] ?? r['paymentStatus']}',
                '${fmtHHMM(DateTime.tryParse(r['startedAt'] as String? ?? r['createdAt'] as String? ?? '')?.toLocal())}–${fmtHHMM(DateTime.tryParse(r['endedAt'] as String? ?? '')?.toLocal())}'
                    '${r['pricingType'] == 'DURATION' ? ' · played ${formatDuration((r['playedSeconds'] as num? ?? 0).toInt())}' : ' · ${r['gamesCompleted']}/${r['gamesPurchased']} games'}'
                    '${r['operatorName'] != null ? ' · ${r['operatorName']}' : ''}',
              ].join('\n')),
              isThreeLine: true,
              trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(formatMoney((r['totalMinor'] as num).toInt(), 'ETB'), style: const TextStyle(fontWeight: FontWeight.w800)),
                if ((r['paidMinor'] as num) != (r['totalMinor'] as num)) Text('paid ${formatMoney((r['paidMinor'] as num).toInt(), 'ETB')}', style: const TextStyle(fontSize: 11, color: LsColors.red)),
              ]),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => PsSessionScreen(sessionId: r['id'] as String))).then((_) => _load()),
            ),
          ),
      ]),
    );
  }
}
