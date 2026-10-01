import 'dart:async';
import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../format.dart';
import '../models/session_detail.dart';
import '../models/product.dart';
import '../models/equipment.dart';
import '../theme.dart';
import '../widgets/authed_photo.dart';
import '../widgets/status_badge.dart';
import '../widgets/session_level.dart';
import '../widgets/reason_dialog.dart';

/// Full session-actions screen: extend / pause / resume / end / cancel / correct, equipment
/// issue/return, and the full event timeline — reached by tapping a live session card anywhere
/// in the app (dashboard, customer profile's "currently skating" link, etc).
class SessionDetailScreen extends StatefulWidget {
  final String sessionId;
  const SessionDetailScreen({super.key, required this.sessionId});
  @override
  State<SessionDetailScreen> createState() => _SessionDetailScreenState();
}

class _SessionDetailScreenState extends State<SessionDetailScreen> {
  late ApiClient _api;
  SessionDetail? _detail;
  FullConfig? _cfg;
  List<EquipmentItem> _availableEquipment = [];
  String? _error;
  bool _busy = false;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _boot();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _boot() async {
    _api = await ApiClient.instance();
    final cfgJson = await _api.get('/config') as Map<String, dynamic>;
    _cfg = FullConfig.fromJson(cfgJson);
    await _load();
  }

  Future<void> _load({bool silent = false}) async {
    try {
      final json = await _api.get('/sessions/${widget.sessionId}') as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _detail = SessionDetail.fromJson(json);
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      if (!silent) setState(() => _error = e.toString());
    }
  }

  Future<void> _run(Future<void> Function() action, {String? successMessage}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      await _load(silent: true);
      if (successMessage != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(successMessage)));
      }
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _loadAvailableEquipment() async {
    try {
      final json = await _api.get('/equipment?status=AVAILABLE') as Map<String, dynamic>;
      _availableEquipment = EquipmentListResponse.fromJson(json).items;
    } catch (_) {
      _availableEquipment = [];
    }
  }

  // ---- actions --------------------------------------------------------------------------------

  Future<void> _extend() async {
    final cfg = _cfg!;
    Product? extProduct;
    List<Product> extensions = [];
    try {
      final json = await _api.get('/products?customerId=${_detail!.customerId}') as Map<String, dynamic>;
      extensions = ProductsResponse.fromJson(json).extensions;
    } catch (_) {}
    if (!mounted) return;

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) {
        int selectedMinutes = cfg.extensionOptionsMinutes.contains(30) ? 30 : cfg.extensionOptionsMinutes.first;
        bool complimentary = false;
        String? method;
        final reasonCtrl = TextEditingController();
        final refCtrl = TextEditingController();
        return StatefulBuilder(builder: (context, setLocal) {
          extProduct = extensions.where((p) => p.durationMinutes == selectedMinutes).firstOrNull;
          final price = extProduct?.priceMinor ?? 0;
          final methodOpt = cfg.paymentMethods.where((m) => m.code == method).firstOrNull;
          final needsRef = methodOpt?.requiresReference ?? false;
          final canFree = _api.me?.can('payment.discount') ?? false;
          final valid = complimentary ? reasonCtrl.text.trim().length >= 3 : (price <= 0 || (method != null && (!needsRef || refCtrl.text.trim().isNotEmpty)));
          return AlertDialog(
            title: const Text('Extend session'),
            content: SizedBox(
              width: 340,
              child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Wrap(
                    spacing: 8,
                    children: cfg.extensionOptionsMinutes.map((m) {
                      return ChoiceChip(label: Text('+$m min'), selected: selectedMinutes == m, onSelected: (_) => setLocal(() => selectedMinutes = m));
                    }).toList(),
                  ),
                  const SizedBox(height: 10),
                  if (price > 0 && !complimentary) ...[
                    Text('Price: ${formatMoney(price, cfg.currency)}', style: const TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: cfg.paymentMethods.map((m) => ChoiceChip(label: Text(m.label), selected: method == m.code, onSelected: (_) => setLocal(() => method = m.code))).toList(),
                    ),
                    if (needsRef) ...[
                      const SizedBox(height: 8),
                      TextField(controller: refCtrl, decoration: const InputDecoration(labelText: 'Reference'), onChanged: (_) => setLocal(() {})),
                    ],
                  ],
                  if (canFree) ...[
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: complimentary,
                      onChanged: (v) => setLocal(() => complimentary = v ?? false),
                      title: const Text('Complimentary (no charge)'),
                    ),
                    if (complimentary)
                      TextField(controller: reasonCtrl, decoration: const InputDecoration(labelText: 'Reason (required)'), onChanged: (_) => setLocal(() {})),
                  ],
                  const SizedBox(height: 10),
                  const Text(
                    'New end time is calculated by the server and recorded with who extended it, from which device, and why.',
                    style: TextStyle(color: LsColors.muted, fontSize: 12),
                  ),
                ]),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              FilledButton(
                onPressed: !valid
                    ? null
                    : () => Navigator.pop(context, {
                          'minutes': selectedMinutes,
                          'complimentary': complimentary,
                          'reason': complimentary ? reasonCtrl.text.trim() : null,
                          'payment': (!complimentary && price > 0) ? {'method': method, 'reference': refCtrl.text.trim().isEmpty ? null : refCtrl.text.trim()} : null,
                        }),
                child: Text(complimentary || price <= 0 ? 'Confirm extension' : 'Confirm + ${formatMoney(price, cfg.currency)}'),
              ),
            ],
          );
        });
      },
    );
    if (result == null) return;
    await _run(
      () => _api.post('/sessions/${widget.sessionId}/extend', result),
      successMessage: 'Session extended.',
    );
  }

  Future<void> _togglePause() async {
    final isPaused = _detail!.status == 'PAUSED';
    await _run(
      () => _api.post('/sessions/${widget.sessionId}/${isPaused ? 'resume' : 'pause'}'),
      successMessage: isPaused ? 'Session resumed.' : 'Session paused.',
    );
  }

  Future<void> _end() async {
    final s = _detail!;
    final remaining = s.remainingSeconds ?? 0;
    final earlyExit = remaining > (0) && s.status != 'EXPIRED';
    final outstanding = s.equipmentAssignments.where((e) => e.returnedAt == null).toList();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text("End ${s.session.customerName}'s session?"),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Started ${fmtHHMM(s.session.startedAt)} · scheduled end ${fmtHHMM(s.session.scheduledEndAt)}'),
          const SizedBox(height: 10),
          if (earlyExit)
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: LsColors.yellowSoft, borderRadius: BorderRadius.circular(8)),
              child: Text('${formatDuration(remaining)} of paid time remain. This will be recorded as an early exit.', style: const TextStyle(color: LsColors.yellow)),
            )
          else
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: LsColors.brandSoft, borderRadius: BorderRadius.circular(8)),
              child: const Text('Time is up or nearly up — this will be recorded as completed.', style: TextStyle(color: LsColors.brandStrong)),
            ),
          if (outstanding.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('Equipment out: ${outstanding.map((e) => e.code).join(', ')}. Collect it after ending.', style: const TextStyle(color: LsColors.muted)),
            ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep skating')),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: LsColors.red), onPressed: () => Navigator.pop(context, true), child: const Text('End session')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(() => _api.post('/sessions/${widget.sessionId}/end'), successMessage: outstanding.isNotEmpty ? 'Session ended. Remember to collect: ${outstanding.map((e) => e.code).join(', ')}' : 'Session ended.');
  }

  Future<void> _cancel() async {
    final reason = await showReasonDialog(context, title: 'Cancel session', label: 'Reason', minLength: 3, confirmLabel: 'Cancel session', danger: true);
    if (reason == null) return;
    await _run(() => _api.post('/sessions/${widget.sessionId}/cancel', {'reason': reason}), successMessage: 'Session cancelled.');
  }

  Future<void> _correct() async {
    final s = _detail!;
    final ended = s.status == 'COMPLETED' || s.status == 'EARLY_EXIT';
    if (ended) {
      final reason = await showReasonDialog(context, title: 'Reopen this session', label: 'Reason (it was ended by mistake)', minLength: 3, confirmLabel: 'Reopen');
      if (reason == null) return;
      await _run(() => _api.post('/sessions/${widget.sessionId}/correct', {'action': 'REOPEN', 'reason': reason}), successMessage: 'Session reopened.');
    } else {
      final result = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (context) {
          final minutesCtrl = TextEditingController(text: '${(s.session.scheduledEndAt != null && s.session.startedAt != null) ? s.session.scheduledEndAt!.difference(s.session.startedAt!).inMinutes : ''}');
          final reasonCtrl = TextEditingController();
          return StatefulBuilder(builder: (context, setLocal) {
            final minutes = int.tryParse(minutesCtrl.text);
            final valid = minutes != null && minutes > 0 && minutes <= 600 && reasonCtrl.text.trim().length >= 3;
            return AlertDialog(
              title: const Text('Correct session'),
              content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: LsColors.brandSoft, borderRadius: BorderRadius.circular(8)),
                  child: const Text('Corrections are audited: the original value, the new value, who did it and why are all kept.', style: TextStyle(fontSize: 12)),
                ),
                const SizedBox(height: 10),
                TextField(controller: minutesCtrl, decoration: const InputDecoration(labelText: 'Correct total duration (minutes)'), keyboardType: TextInputType.number, onChanged: (_) => setLocal(() {})),
                const SizedBox(height: 10),
                TextField(controller: reasonCtrl, decoration: const InputDecoration(labelText: 'Reason'), onChanged: (_) => setLocal(() {})),
              ]),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                FilledButton(
                  onPressed: !valid ? null : () => Navigator.pop(context, {'action': 'CHANGE_DURATION', 'newDurationMinutes': minutes, 'reason': reasonCtrl.text.trim()}),
                  child: const Text('Save correction'),
                ),
              ],
            );
          });
        },
      );
      if (result == null) return;
      await _run(() => _api.post('/sessions/${widget.sessionId}/correct', result), successMessage: 'Session corrected.');
    }
  }

  Future<void> _issueEquipment() async {
    await _loadAvailableEquipment();
    if (!mounted) return;
    final picked = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Issue skates'),
        content: SizedBox(
          width: 320,
          child: _availableEquipment.isEmpty
              ? const Text('No equipment currently available.')
              : Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: _availableEquipment.map((e) => ActionChip(label: Text('#${e.code}${e.size != null ? ' (${e.size})' : ''}'), onPressed: () => Navigator.pop(context, e.id))).toList(),
                ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      ),
    );
    if (picked == null) return;
    await _run(() => _api.post('/equipment/$picked/assign', {'sessionId': widget.sessionId}), successMessage: 'Equipment issued.');
  }

  Future<void> _returnEquipment(EquipmentAssignmentRow a, {required bool damaged}) async {
    String? note;
    if (damaged) {
      note = await showReasonDialog(context, title: 'Equipment returned damaged', label: 'Describe the damage', minLength: 3, confirmLabel: 'Return as damaged', danger: true);
      if (note == null) return;
    }
    await _run(
      // The null-aware `?key:` marker checks the KEY's nullability, not the value's, so it
      // doesn't apply to this conditional-value case.
      // ignore: use_null_aware_elements
      () => _api.post('/equipment/${a.id}/return', {'condition': damaged ? 'DAMAGED' : 'GOOD', if (note != null) 'note': note}),
      successMessage: 'Equipment returned.',
    );
  }

  // ---- UI --------------------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final d = _detail;
    return Scaffold(
      appBar: AppBar(title: const Text('Session')),
      body: d == null
          ? (_error != null
              ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [Text(_error!, textAlign: TextAlign.center), const SizedBox(height: 12), OutlinedButton(onPressed: () => _load(), child: const Text('Retry'))])))
              : const Center(child: CircularProgressIndicator()))
          : RefreshIndicator(onRefresh: () => _load(), child: _buildBody(d)),
    );
  }

  Widget _buildBody(SessionDetail d) {
    final me = _api.me;
    final remaining = d.remainingSeconds;
    final level = d.session.scheduledEndAt == null ? 'gray' : levelFor(remaining, d.status, (_cfg?.warnings() ?? const []));
    final (fg, bg) = levelColors(level);
    final canExtend = me?.can('session.extend') ?? false;
    final canPause = (me?.can('session.pause') ?? false) && (_cfg?.pauseEnabled ?? true);
    final canEnd = me?.can('session.end') ?? false;
    final canCancel = (me?.can('session.cancel') ?? false) && ['CREATED', 'PAYMENT_PENDING', 'READY'].contains(d.status);
    final canCorrect = me?.can('session.correct') ?? false;
    final canAssign = me?.can('equipment.assign') ?? false;
    final canReturnEq = me?.can('equipment.return') ?? false;
    final isLiveStatus = ['ACTIVE', 'PAUSED', 'EXPIRING', 'EXPIRED'].contains(d.status);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          AuthedPhoto(photoId: d.session.photoId, name: d.session.customerName, size: 64),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(d.session.customerName, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
              Text(d.session.productName, style: const TextStyle(color: LsColors.muted)),
              const SizedBox(height: 4),
              LsBadge.forStatus(d.status, level),
            ]),
          ),
        ]),
        const SizedBox(height: 14),
        if (isLiveStatus && remaining != null)
          Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14)),
              child: Text(fmtClock(remaining), style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: 34)),
            ),
          ),
        const SizedBox(height: 14),
        Wrap(spacing: 10, runSpacing: 10, children: [
          _meta('Started', fmtHHMM(d.session.startedAt)),
          _meta('Scheduled end', fmtHHMM(d.session.scheduledEndAt)),
          _meta('Paid', formatMoney(d.paidMinor, _cfg?.currency ?? 'ETB')),
          if (d.dueMinor > 0) _meta('Due', formatMoney(d.dueMinor, _cfg?.currency ?? 'ETB')),
        ]),
        const Divider(height: 28),
        if (isLiveStatus) ...[
          Wrap(spacing: 8, runSpacing: 8, children: [
            if (canExtend) OutlinedButton.icon(onPressed: _busy ? null : _extend, icon: const Icon(Icons.add_alarm), label: const Text('Extend')),
            if (canPause)
              OutlinedButton.icon(
                onPressed: _busy ? null : _togglePause,
                icon: Icon(d.status == 'PAUSED' ? Icons.play_arrow : Icons.pause),
                label: Text(d.status == 'PAUSED' ? 'Resume' : 'Pause'),
              ),
            if (canEnd) FilledButton.icon(onPressed: _busy ? null : _end, icon: const Icon(Icons.stop_circle_outlined), label: const Text('End session')),
          ]),
          const SizedBox(height: 10),
        ],
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (canCancel) OutlinedButton.icon(onPressed: _busy ? null : _cancel, icon: const Icon(Icons.close), label: const Text('Cancel session')),
          if (canCorrect) OutlinedButton.icon(onPressed: _busy ? null : _correct, icon: const Icon(Icons.build_outlined), label: const Text('Correct…')),
        ]),
        const Divider(height: 28),
        Text('Equipment', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (d.equipmentAssignments.isEmpty) const Text('No equipment issued for this visit.', style: TextStyle(color: LsColors.muted)),
        ...d.equipmentAssignments.map((a) => Card(
              margin: const EdgeInsets.only(bottom: 6),
              child: ListTile(
                leading: const Icon(Icons.sports_hockey_outlined),
                title: Text('#${a.code}'),
                subtitle: Text(a.returnedAt != null ? 'Returned ${fmtHHMM(a.returnedAt)}' : 'Issued ${fmtHHMM(a.assignedAt)}'),
                trailing: (a.returnedAt == null && canReturnEq)
                    ? Row(mainAxisSize: MainAxisSize.min, children: [
                        TextButton(onPressed: _busy ? null : () => _returnEquipment(a, damaged: false), child: const Text('Return OK')),
                        TextButton(onPressed: _busy ? null : () => _returnEquipment(a, damaged: true), child: const Text('Damaged')),
                      ])
                    : null,
              ),
            )),
        if (canAssign && isLiveStatus) OutlinedButton.icon(onPressed: _busy ? null : _issueEquipment, icon: const Icon(Icons.add), label: const Text('Issue skates')),
        const Divider(height: 28),
        Text('Timeline', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        ...d.events.map((ev) => _TimelineRow(event: ev)),
      ],
    );
  }

  Widget _meta(String label, String value) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(color: LsColors.surface2, borderRadius: BorderRadius.circular(8)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(color: LsColors.muted, fontSize: 11)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
        ]),
      );
}

class _TimelineRow extends StatelessWidget {
  final SessionEvent event;
  const _TimelineRow({required this.event});
  @override
  Widget build(BuildContext context) {
    final label = sessionEventLabel[event.eventType] ?? titleCase(event.eventType);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Padding(padding: EdgeInsets.only(top: 4), child: Icon(Icons.circle, size: 8, color: LsColors.muted)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
            Text(
              '${fmtHHMM(event.occurredAt)}${event.actorName != null ? ' · ${event.actorName}' : ''}${event.deviceName != null ? ' · ${event.deviceName}' : ''}',
              style: const TextStyle(color: LsColors.muted, fontSize: 12),
            ),
          ]),
        ),
      ]),
    );
  }
}

extension _FirstOrNullP<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
