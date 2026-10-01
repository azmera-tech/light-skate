import 'package:flutter/material.dart';
import '../../api/api_client.dart';
import '../../format.dart';
import '../../models/me.dart';
import '../../theme.dart';

class _PriceRule {
  final String id;
  final String kind; // SESSION | EXTENSION
  String name;
  int? durationMinutes;
  int priceMinor;
  String? dayType;
  String? customerType;
  bool active;
  int sortOrder;
  _PriceRule({
    required this.id, required this.kind, required this.name, required this.durationMinutes, required this.priceMinor,
    required this.dayType, required this.customerType, required this.active, required this.sortOrder,
  });
  factory _PriceRule.fromJson(Map<String, dynamic> j) => _PriceRule(
        id: j['id'] as String,
        kind: j['kind'] as String,
        name: j['name'] as String,
        durationMinutes: j['durationMinutes'] as int?,
        priceMinor: (j['priceMinor'] as num).toInt(),
        dayType: j['dayType'] as String?,
        customerType: j['customerType'] as String?,
        active: (j['active'] as bool?) ?? true,
        sortOrder: (j['sortOrder'] as int?) ?? 0,
      );
}

/// GET/POST/PATCH /pricing (pricing.manage to write; readable with pricing.manage, settings.manage
/// or reports.read). Two tables (session / extension prices), inline edit via dialog, active
/// toggle saves immediately.
class PricingScreen extends StatefulWidget {
  const PricingScreen({super.key});
  @override
  State<PricingScreen> createState() => _PricingScreenState();
}

class _PricingScreenState extends State<PricingScreen> {
  late ApiClient _api;
  late Me _me;
  String _currency = 'ETB';
  List<_PriceRule> _rules = [];
  bool _loading = true;
  String? _error;

  bool get _canWrite => _me.can('pricing.manage');

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    _api = await ApiClient.instance();
    _me = _api.me!;
    await _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final json = await _api.get('/pricing') as Map<String, dynamic>;
      final rules = ((json['rules'] as List?) ?? const []).map((e) => _PriceRule.fromJson(e as Map<String, dynamic>)).toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
      String currency = _currency;
      try {
        final cfg = await _api.get('/config') as Map<String, dynamic>;
        currency = (cfg['venue'] as Map<String, dynamic>)['currency'] as String? ?? currency;
      } catch (_) {
        // non-fatal — fall back to the default currency label
      }
      if (!mounted) return;
      setState(() {
        _rules = rules;
        _currency = currency;
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

  Future<void> _toggleActive(_PriceRule r, bool value) async {
    setState(() => r.active = value);
    try {
      await _api.patch('/pricing/${r.id}', {'active': value});
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => r.active = !value);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _editRule(_PriceRule r) async {
    final nameCtrl = TextEditingController(text: r.name);
    final priceCtrl = TextEditingController(text: (r.priceMinor / 100).toStringAsFixed(2));
    final durationCtrl = TextEditingController(text: r.durationMinutes?.toString() ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Edit ${r.kind == 'SESSION' ? 'session' : 'extension'} price'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Name')),
          const SizedBox(height: 10),
          TextField(controller: durationCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Duration (minutes)')),
          const SizedBox(height: 10),
          TextField(controller: priceCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Price ($_currency)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true) return;
    final priceMinor = ((double.tryParse(priceCtrl.text) ?? r.priceMinor / 100) * 100).round();
    final duration = int.tryParse(durationCtrl.text);
    try {
      await _api.patch('/pricing/${r.id}', {'name': nameCtrl.text.trim(), 'priceMinor': priceMinor, 'durationMinutes': duration});
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _addRule(String kind) async {
    final nameCtrl = TextEditingController();
    final priceCtrl = TextEditingController();
    final durationCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Add ${kind == 'SESSION' ? 'session' : 'extension'} price'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Name')),
          const SizedBox(height: 10),
          TextField(controller: durationCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Duration (minutes)')),
          const SizedBox(height: 10),
          TextField(controller: priceCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Price ($_currency)')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Add')),
        ],
      ),
    );
    if (ok != true) return;
    if (nameCtrl.text.trim().isEmpty) return;
    final priceMinor = ((double.tryParse(priceCtrl.text) ?? 0) * 100).round();
    final duration = int.tryParse(durationCtrl.text);
    try {
      await _api.post('/pricing', {
        'kind': kind,
        'name': nameCtrl.text.trim(),
        'durationMinutes': duration,
        'priceMinor': priceMinor,
        'dayType': 'ANY',
        'customerType': 'ANY',
        'active': true,
        'sortOrder': _rules.where((r) => r.kind == kind).length,
      });
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final sessionRules = _rules.where((r) => r.kind == 'SESSION').toList();
    final extensionRules = _rules.where((r) => r.kind == 'EXTENSION').toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Pricing')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorView(message: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(14),
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(color: LsColors.brandSoft, borderRadius: BorderRadius.circular(8)),
                        child: const Text('Changes apply to new sales only.', style: TextStyle(color: LsColors.brandStrong, fontWeight: FontWeight.w600)),
                      ),
                      const SizedBox(height: 14),
                      _priceTable('Session prices', sessionRules, 'SESSION'),
                      const SizedBox(height: 18),
                      _priceTable('Extension prices', extensionRules, 'EXTENSION'),
                    ],
                  ),
                ),
    );
  }

  Widget _priceTable(String title, List<_PriceRule> rules, String kind) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            if (_canWrite) TextButton.icon(onPressed: () => _addRule(kind), icon: const Icon(Icons.add), label: const Text('Add price')),
          ]),
          if (rules.isEmpty)
            const Padding(padding: EdgeInsets.all(12), child: Text('No prices defined.', style: TextStyle(color: LsColors.muted)))
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: const [
                  DataColumn(label: Text('Name')),
                  DataColumn(label: Text('Duration')),
                  DataColumn(label: Text('Price')),
                  DataColumn(label: Text('Active')),
                  DataColumn(label: Text('')),
                ],
                rows: rules
                    .map((r) => DataRow(cells: [
                          DataCell(Text(r.name)),
                          DataCell(Text(r.durationMinutes != null ? '${r.durationMinutes} min' : '—')),
                          DataCell(Text(formatMoney(r.priceMinor, _currency))),
                          DataCell(Switch(value: r.active, onChanged: _canWrite ? (v) => _toggleActive(r, v) : null)),
                          DataCell(_canWrite ? IconButton(icon: const Icon(Icons.edit_outlined), onPressed: () => _editRule(r)) : const SizedBox.shrink()),
                        ]))
                    .toList(),
              ),
            ),
        ]),
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
