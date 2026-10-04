import 'dart:async';
import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../models/equipment.dart';
import '../models/me.dart';
import '../theme.dart';
import '../widgets/status_badge.dart';
import '../widgets/reason_dialog.dart';
import '../widgets/cleaning_checklist_dialog.dart';
import '../format.dart';
import 'equipment/equipment_detail_sheet.dart';

/// Canonical status order so the filter chips are always in the same place regardless of
/// what the summary map from the server happens to contain.
const _statusOrder = ['AVAILABLE', 'ISSUED', 'NEEDS_CLEANING', 'CLEANING', 'RETURNED', 'DAMAGED', 'MAINTENANCE', 'OUT_OF_SERVICE', 'RESERVED'];

const _statusLabels = {
  'AVAILABLE': 'Available',
  'ISSUED': 'Issued',
  'NEEDS_CLEANING': 'Needs cleaning',
  'CLEANING': 'Cleaning',
  'RETURNED': 'Returned',
  'DAMAGED': 'Damaged',
  'MAINTENANCE': 'Maintenance',
  'OUT_OF_SERVICE': 'Out of service',
  'RESERVED': 'Reserved',
};

(String, IconData) _statusLevel(String status) => switch (status) {
      'AVAILABLE' => ('normal', Icons.check_circle_outline),
      'ISSUED' => ('info', Icons.directions_walk),
      'NEEDS_CLEANING' => ('orange', Icons.cleaning_services_outlined),
      'CLEANING' => ('info', Icons.cleaning_services_outlined),
      'RETURNED' => ('yellow', Icons.undo),
      'DAMAGED' => ('red', Icons.warning_amber_rounded),
      'MAINTENANCE' => ('orange', Icons.build_outlined),
      'OUT_OF_SERVICE' => ('red', Icons.block),
      'RESERVED' => ('gray', Icons.event_available_outlined),
      _ => ('gray', Icons.circle),
    };

/// Equipment management tab — bare body widget hosted inside AppShell's IndexedStack
/// (same convention as DashboardScreen / IncidentsScreen: no Scaffold/AppBar of its own).
class EquipmentScreen extends StatefulWidget {
  const EquipmentScreen({super.key});
  @override
  State<EquipmentScreen> createState() => _EquipmentScreenState();
}

class _EquipmentScreenState extends State<EquipmentScreen> {
  late ApiClient _api;
  Me? _me;
  EquipmentListResponse? _data;
  String? _error;
  String _statusFilter = 'ALL';
  String _query = '';
  Timer? _poll;
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    _api = await ApiClient.instance();
    _me = _api.me;
    await _load();
    _poll = Timer.periodic(const Duration(seconds: 8), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    final params = <String, String>{};
    if (_statusFilter != 'ALL') params['status'] = _statusFilter;
    if (_query.trim().isNotEmpty) params['q'] = _query.trim();
    final qs = params.entries.map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}').join('&');
    try {
      final json = await _api.get('/equipment${qs.isEmpty ? '' : '?$qs'}');
      if (!mounted) return;
      setState(() {
        _data = EquipmentListResponse.fromJson(json as Map<String, dynamic>);
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      if (!silent) setState(() => _error = e.toString());
    }
  }

  Future<void> _openDetail(String id) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => EquipmentDetailSheet(equipmentId: id, me: _me!),
    );
    _load(silent: true);
  }

  Future<void> _addEquipment() async {
    final created = await showDialog<bool>(
      context: context,
      builder: (_) => _AddEquipmentDialog(api: _api),
    );
    if (created == true) _load(silent: true);
  }

  Future<void> _quickAction(Future<void> Function() action) async {
    try {
      await action();
      _load(silent: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    final me = _me;
    final d = _data;
    if (me == null) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: () => _load(),
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          Row(children: [
            Expanded(child: Text('Equipment', style: Theme.of(context).textTheme.headlineSmall)),
            if (me.can('equipment.manage'))
              FilledButton.icon(onPressed: _addEquipment, icon: const Icon(Icons.add), label: const Text('Add')),
          ]),
          const SizedBox(height: 12),
          TextField(
            controller: _searchController,
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search by code, category, size…'),
            onChanged: (v) {
              _query = v;
              _load(silent: true);
            },
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 36,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                _FilterChip(
                  label: 'All',
                  count: d?.summary.values.fold<int>(0, (a, b) => a + b),
                  selected: _statusFilter == 'ALL',
                  onTap: () {
                    setState(() => _statusFilter = 'ALL');
                    _load(silent: true);
                  },
                ),
                for (final s in _statusOrder)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: _FilterChip(
                      label: _statusLabels[s]!,
                      count: d?.summary[s] ?? 0,
                      selected: _statusFilter == s,
                      onTap: () {
                        setState(() => _statusFilter = s);
                        _load(silent: true);
                      },
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          if (_error != null && d == null)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(children: [
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 10),
                OutlinedButton(onPressed: () => _load(), child: const Text('Retry')),
              ]),
            )
          else if (d == null)
            const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
          else if (d.items.isEmpty)
            const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('No equipment matches this filter.', style: TextStyle(color: LsColors.muted))))
          else
            ...d.items.map((it) => _EquipmentCard(
                  item: it,
                  me: me,
                  onTap: () => _openDetail(it.id),
                  onReturnOk: () => _quickAction(() => _api.post('/equipment/${it.id}/return', {'condition': 'GOOD'})),
                  onReturnDamaged: () async {
                    final note = await showReasonDialog(context, title: 'Equipment returned damaged', label: 'Describe the damage', minLength: 3, confirmLabel: 'Return as damaged', danger: true);
                    if (note == null) return;
                    await _quickAction(() => _api.post('/equipment/${it.id}/return', {'condition': 'DAMAGED', 'note': note}));
                  },
                  onInspectOk: () => _quickAction(() => _api.post('/equipment/${it.id}/inspect')),
                  onReportDamage: () async {
                    final issue = await showReasonDialog(context, title: 'Report damage', label: 'What is wrong with it?', minLength: 3, confirmLabel: 'Report & start maintenance', danger: true);
                    if (issue == null) return;
                    await _quickAction(() => _api.post('/equipment/${it.id}/damage', {'issue': issue, 'startMaintenance': true}));
                  },
                  onStartCleaning: () => _quickAction(() => _api.post('/equipment/${it.id}/cleaning/start')),
                  onMarkCleaned: () async {
                    final result = await showCleaningChecklistDialog(context, code: it.code);
                    if (result == null) return;
                    await _quickAction(() => _api.post('/equipment/${it.id}/cleaning/complete', {'checklist': result.checklist, 'notes': result.notes}));
                  },
                )),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final int? count;
  final bool selected;
  final VoidCallback onTap;
  const _FilterChip({required this.label, required this.count, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return ChoiceChip(
      label: Text(count == null ? label : '$label ($count)'),
      selected: selected,
      onSelected: (_) => onTap(),
    );
  }
}

class _EquipmentCard extends StatelessWidget {
  final EquipmentItem item;
  final Me me;
  final VoidCallback onTap;
  final Future<void> Function() onReturnOk;
  final Future<void> Function() onReturnDamaged;
  final Future<void> Function() onInspectOk;
  final Future<void> Function() onReportDamage;
  final Future<void> Function() onStartCleaning;
  final Future<void> Function() onMarkCleaned;
  const _EquipmentCard({
    required this.item,
    required this.me,
    required this.onTap,
    required this.onReturnOk,
    required this.onReturnDamaged,
    required this.onInspectOk,
    required this.onReportDamage,
    required this.onStartCleaning,
    required this.onMarkCleaned,
  });

  @override
  Widget build(BuildContext context) {
    final (level, icon) = _statusLevel(item.status);
    final actions = <Widget>[];
    if (item.status == 'ISSUED' && me.can('equipment.return')) {
      actions.add(OutlinedButton(onPressed: onReturnOk, child: const Text('Return OK')));
      actions.add(OutlinedButton(onPressed: onReturnDamaged, child: const Text('Damaged')));
    } else if (item.status == 'NEEDS_CLEANING' && me.can('equipment.cleaning')) {
      actions.add(FilledButton.tonal(onPressed: onStartCleaning, child: const Text('Start cleaning')));
    } else if (item.status == 'CLEANING' && me.can('equipment.cleaning')) {
      actions.add(FilledButton.tonal(style: FilledButton.styleFrom(backgroundColor: LsColors.greenSoft, foregroundColor: LsColors.green), onPressed: onMarkCleaned, child: const Text('Mark Cleaned')));
    } else if (item.status == 'RETURNED' && me.can('equipment.return')) {
      actions.add(FilledButton.tonal(onPressed: onInspectOk, child: const Text('Inspected OK')));
    } else if (item.status == 'AVAILABLE' && me.can('equipment.maintenance')) {
      actions.add(OutlinedButton(onPressed: onReportDamage, child: const Text('Report damage')));
    } else if ((item.status == 'DAMAGED' || item.status == 'MAINTENANCE' || item.status == 'OUT_OF_SERVICE') && me.can('equipment.maintenance')) {
      actions.add(OutlinedButton(onPressed: onTap, child: const Text('Manage')));
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(item.code, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
              LsBadge(label: _statusLabels[item.status] ?? item.status, level: level, icon: icon),
            ]),
            const SizedBox(height: 4),
            Text(
              '${titleCase(item.category)}${item.size != null ? ' · size ${item.size}' : ''} · ${titleCase(item.condition)}${item.location != null ? ' · ${item.location}' : ''}',
              style: const TextStyle(color: LsColors.muted, fontSize: 13),
            ),
            if (item.status == 'ISSUED') ...[
              const SizedBox(height: 6),
              Text(
                'With ${item.issuedTo ?? 'a customer'}'
                '${item.issuedUntil != null ? ' · until ${fmtHHMM(item.issuedUntil)}' : item.issuedAt != null ? ' · since ${fmtHHMM(item.issuedAt)}' : ''}',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ],
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 6, children: actions),
            ],
          ]),
        ),
      ),
    );
  }
}

class _AddEquipmentDialog extends StatefulWidget {
  final ApiClient api;
  const _AddEquipmentDialog({required this.api});
  @override
  State<_AddEquipmentDialog> createState() => _AddEquipmentDialogState();
}

class _AddEquipmentDialogState extends State<_AddEquipmentDialog> {
  final _codeCtrl = TextEditingController();
  final _sizeCtrl = TextEditingController();
  final _locationCtrl = TextEditingController();
  String _category = 'SKATE';
  String _condition = 'NEW';
  bool _busy = false;
  String? _error;

  static const _categories = ['SKATE', 'HELMET', 'PADS', 'GUARD', 'OTHER'];
  static const _conditions = ['NEW', 'GOOD', 'FAIR', 'POOR'];

  @override
  void dispose() {
    _codeCtrl.dispose();
    _sizeCtrl.dispose();
    _locationCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_codeCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Code is required.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.post('/equipment', {
        'code': _codeCtrl.text.trim(),
        'category': _category,
        'size': _sizeCtrl.text.trim().isEmpty ? null : _sizeCtrl.text.trim(),
        'condition': _condition,
        'location': _locationCtrl.text.trim().isEmpty ? null : _locationCtrl.text.trim(),
      });
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add equipment'),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(controller: _codeCtrl, autofocus: true, decoration: const InputDecoration(labelText: 'Code')),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: _category,
            decoration: const InputDecoration(labelText: 'Category'),
            items: _categories.map((c) => DropdownMenuItem(value: c, child: Text(titleCase(c)))).toList(),
            onChanged: (v) => setState(() => _category = v ?? _category),
          ),
          const SizedBox(height: 10),
          TextField(controller: _sizeCtrl, decoration: const InputDecoration(labelText: 'Size (optional)')),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: _condition,
            decoration: const InputDecoration(labelText: 'Condition'),
            items: _conditions.map((c) => DropdownMenuItem(value: c, child: Text(titleCase(c)))).toList(),
            onChanged: (v) => setState(() => _condition = v ?? _condition),
          ),
          const SizedBox(height: 10),
          TextField(controller: _locationCtrl, decoration: const InputDecoration(labelText: 'Location (optional)')),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!, style: const TextStyle(color: LsColors.red)),
          ],
        ]),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(onPressed: _busy ? null : _submit, child: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Add')),
      ],
    );
  }
}
