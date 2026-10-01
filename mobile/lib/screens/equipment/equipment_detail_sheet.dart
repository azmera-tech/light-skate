import 'package:flutter/material.dart';
import '../../api/api_client.dart';
import '../../models/equipment.dart';
import '../../models/me.dart';
import '../../theme.dart';
import '../../widgets/status_badge.dart';
import '../../widgets/reason_dialog.dart';
import '../../widgets/camera_capture.dart';
import '../../format.dart';

const _detailStatusLabels = {
  'AVAILABLE': 'Available',
  'ISSUED': 'Issued',
  'RETURNED': 'Returned',
  'DAMAGED': 'Damaged',
  'MAINTENANCE': 'Maintenance',
  'OUT_OF_SERVICE': 'Out of service',
  'RESERVED': 'Reserved',
};

(String, IconData) _detailStatusLevel(String status) => switch (status) {
      'AVAILABLE' => ('normal', Icons.check_circle_outline),
      'ISSUED' => ('info', Icons.directions_walk),
      'RETURNED' => ('yellow', Icons.undo),
      'DAMAGED' => ('red', Icons.warning_amber_rounded),
      'MAINTENANCE' => ('orange', Icons.build_outlined),
      'OUT_OF_SERVICE' => ('red', Icons.block),
      'RESERVED' => ('gray', Icons.event_available_outlined),
      _ => ('gray', Icons.circle),
    };

/// Bottom-sheet detail view for one equipment item: status, usage stats, the actions valid for
/// its current state, maintenance records and the full event timeline.
class EquipmentDetailSheet extends StatefulWidget {
  final String equipmentId;
  final Me me;
  const EquipmentDetailSheet({super.key, required this.equipmentId, required this.me});

  @override
  State<EquipmentDetailSheet> createState() => _EquipmentDetailSheetState();
}

class _EquipmentDetailSheetState extends State<EquipmentDetailSheet> {
  late ApiClient _api;
  EquipmentDetail? _detail;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    _api = await ApiClient.instance();
    await _load();
  }

  Future<void> _load() async {
    try {
      final json = await _api.get('/equipment/${widget.equipmentId}');
      if (!mounted) return;
      setState(() {
        _detail = EquipmentDetail.fromJson(json as Map<String, dynamic>);
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reportDamage() async {
    final issue = await showReasonDialog(context, title: 'Report damage', label: 'What is wrong with it?', minLength: 3, confirmLabel: 'Report & start maintenance', danger: true);
    if (issue == null) return;
    await _run(() => _api.post('/equipment/${widget.equipmentId}/damage', {'issue': issue, 'startMaintenance': true}));
  }

  Future<void> _startMaintenance() => _run(() => _api.post('/equipment/${widget.equipmentId}/maintenance/start'));

  Future<void> _completeMaintenance() async {
    final resolution = await showReasonDialog(context, title: 'Return to service', label: 'Resolution (optional)', minLength: 0, confirmLabel: 'Mark repaired');
    if (resolution == null) return;
    await _run(() => _api.post('/equipment/${widget.equipmentId}/maintenance/complete', {'resolution': resolution.isEmpty ? null : resolution}));
  }

  Future<void> _outOfService() async {
    final reason = await showReasonDialog(context, title: 'Take out of service', label: 'Reason', minLength: 3, confirmLabel: 'Take out of service', danger: true);
    if (reason == null) return;
    await _run(() => _api.post('/equipment/${widget.equipmentId}/out-of-service', {'reason': reason}));
  }

  Future<void> _returnOk() => _run(() => _api.post('/equipment/${widget.equipmentId}/return', {'condition': 'GOOD'}));

  Future<void> _returnDamaged() async {
    final note = await showReasonDialog(context, title: 'Equipment returned damaged', label: 'Describe the damage', minLength: 3, confirmLabel: 'Return as damaged', danger: true);
    if (note == null) return;
    await _run(() => _api.post('/equipment/${widget.equipmentId}/return', {'condition': 'DAMAGED', 'note': note}));
  }

  Future<void> _inspectOk() => _run(() => _api.post('/equipment/${widget.equipmentId}/inspect'));

  Future<void> _attachPhoto() async {
    final bytes = await captureCustomerPhoto(context, title: 'Maintenance photo');
    if (bytes == null) return;
    await _run(() => _api.postRawImage('/equipment/${widget.equipmentId}/maintenance/photo', bytes));
  }

  List<Widget> _actionButtons() {
    final item = _detail!.item;
    final me = widget.me;
    final buttons = <Widget>[];
    if (item.status == 'AVAILABLE' && me.can('equipment.maintenance')) {
      buttons.add(OutlinedButton.icon(onPressed: _busy ? null : _reportDamage, icon: const Icon(Icons.report_problem_outlined), label: const Text('Report damage')));
    }
    if (item.status == 'ISSUED' && me.can('equipment.return')) {
      buttons.add(FilledButton.tonal(onPressed: _busy ? null : _returnOk, child: const Text('Return OK')));
      buttons.add(OutlinedButton(onPressed: _busy ? null : _returnDamaged, child: const Text('Return — damaged')));
    }
    if (item.status == 'RETURNED' && me.can('equipment.return')) {
      buttons.add(FilledButton.tonal(onPressed: _busy ? null : _inspectOk, child: const Text('Inspected OK')));
    }
    if (item.status == 'DAMAGED' && me.can('equipment.maintenance')) {
      buttons.add(FilledButton.tonal(onPressed: _busy ? null : _startMaintenance, child: const Text('Start maintenance')));
    }
    if (item.status == 'MAINTENANCE' && me.can('equipment.maintenance')) {
      buttons.add(FilledButton.tonal(onPressed: _busy ? null : _completeMaintenance, child: const Text('Mark repaired')));
      buttons.add(OutlinedButton(onPressed: _busy ? null : _outOfService, child: const Text('Take out of service')));
    }
    if ((item.status == 'MAINTENANCE' || item.status == 'DAMAGED') && me.can('equipment.maintenance')) {
      buttons.add(OutlinedButton.icon(onPressed: _busy ? null : _attachPhoto, icon: const Icon(Icons.camera_alt_outlined), label: const Text('Attach photo')));
    }
    return buttons;
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scrollController) {
        return Container(
          decoration: const BoxDecoration(color: LsColors.bg, borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
          child: _detail == null
              ? Center(child: _error != null ? _ErrorBox(message: _error!, onRetry: _load) : const CircularProgressIndicator())
              : ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(18, 10, 18, 24),
                  children: [
                    Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: LsColors.border, borderRadius: BorderRadius.circular(2)))),
                    const SizedBox(height: 14),
                    _buildHeader(),
                    const SizedBox(height: 16),
                    _buildStats(),
                    const SizedBox(height: 16),
                    if (_actionButtons().isNotEmpty) ...[
                      Text('Actions', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Wrap(spacing: 8, runSpacing: 8, children: _actionButtons()),
                      const SizedBox(height: 18),
                    ],
                    Text('Maintenance history', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    if (_detail!.maintenance.isEmpty)
                      const Text('No maintenance records.', style: TextStyle(color: LsColors.muted))
                    else
                      ..._detail!.maintenance.map((m) => _MaintenanceTile(record: m)),
                    const SizedBox(height: 18),
                    Text('Event history', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    if (_detail!.events.isEmpty)
                      const Text('No events recorded.', style: TextStyle(color: LsColors.muted))
                    else
                      ...([..._detail!.events]..sort((a, b) => b.occurredAt.compareTo(a.occurredAt))).map((e) => _EventTile(event: e)),
                  ],
                ),
        );
      },
    );
  }

  Widget _buildHeader() {
    final item = _detail!.item;
    final (level, icon) = _detailStatusLevel(item.status);
    return Row(children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(item.code, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text(
            '${titleCase(item.category)}${item.size != null ? ' · size ${item.size}' : ''} · ${titleCase(item.condition)}${item.location != null ? ' · ${item.location}' : ''}',
            style: const TextStyle(color: LsColors.muted),
          ),
          if (item.status == 'ISSUED')
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'With ${item.issuedTo ?? 'a customer'}'
                '${item.issuedUntil != null ? ' · until ${fmtHHMM(item.issuedUntil)}' : item.issuedAt != null ? ' · since ${fmtHHMM(item.issuedAt)}' : ''}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
        ]),
      ),
      LsBadge(label: _detailStatusLabels[item.status] ?? item.status, level: level, icon: icon),
    ]);
  }

  Widget _buildStats() {
    final d = _detail!;
    return Row(children: [
      Expanded(
        child: Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              Text('${d.timesIssued}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              const Text('times issued', style: TextStyle(color: LsColors.muted, fontSize: 12)),
            ]),
          ),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              Text('${d.timesRepaired}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              const Text('times repaired', style: TextStyle(color: LsColors.muted, fontSize: 12)),
            ]),
          ),
        ),
      ),
    ]);
  }
}

class _MaintenanceTile extends StatelessWidget {
  final MaintenanceRecord record;
  const _MaintenanceTile({required this.record});
  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(record.issue, style: const TextStyle(fontWeight: FontWeight.w700))),
            LsBadge(label: titleCase(record.status), level: record.status == 'COMPLETE' || record.status == 'COMPLETED' ? 'normal' : 'orange', icon: Icons.build_outlined),
          ]),
          const SizedBox(height: 4),
          Text('Reported ${fmtDate(record.reportedAt)} ${fmtHHMM(record.reportedAt)}', style: const TextStyle(color: LsColors.muted, fontSize: 12)),
          if (record.startedAt != null) Text('Started ${fmtDate(record.startedAt!)} ${fmtHHMM(record.startedAt)}', style: const TextStyle(color: LsColors.muted, fontSize: 12)),
          if (record.completedAt != null) Text('Completed ${fmtDate(record.completedAt!)} ${fmtHHMM(record.completedAt)}', style: const TextStyle(color: LsColors.muted, fontSize: 12)),
          if (record.resolution != null && record.resolution!.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text('Resolution: ${record.resolution}')),
          if (record.hasPhoto) const Padding(padding: EdgeInsets.only(top: 4), child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.photo_outlined, size: 14, color: LsColors.muted), SizedBox(width: 4), Text('Photo attached', style: TextStyle(color: LsColors.muted, fontSize: 12))])),
        ]),
      ),
    );
  }
}

class _EventTile extends StatelessWidget {
  final EquipmentEvent event;
  const _EventTile({required this.event});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        const Icon(Icons.circle, size: 8, color: LsColors.muted),
        const SizedBox(width: 10),
        Expanded(child: Text(titleCase(event.eventType))),
        Text('${fmtDate(event.occurredAt)} ${fmtHHMM(event.occurredAt)}', style: const TextStyle(color: LsColors.muted, fontSize: 12)),
        if (event.actorName != null) Padding(padding: const EdgeInsets.only(left: 8), child: Text(event.actorName!, style: const TextStyle(color: LsColors.muted, fontSize: 12))),
      ]),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorBox({required this.message, required this.onRetry});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.error_outline, color: LsColors.red, size: 32),
        const SizedBox(height: 10),
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: 12),
        OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
      ]),
    );
  }
}
