import 'package:flutter/material.dart';
import '../../api/api_client.dart';
import '../../format.dart';
import '../../models/shoe_claim.dart';
import '../../theme.dart';
import '../../widgets/authed_photo.dart';
import '../../widgets/shoe_photo.dart';
import '../../widgets/status_badge.dart';

/// "Shoe Return" — find a claim (by id, from the list, or by number, from Search Claim),
/// confirm the shoes were returned, or raise an operational "Report Mismatch" alert.
/// Never auto-accuses: a mismatch/missing report just opens an ordinary incident.
class ShoeReturnScreen extends StatefulWidget {
  final String? claimId;
  final String? claimNumber;
  const ShoeReturnScreen({super.key, this.claimId, this.claimNumber}) : assert(claimId != null || claimNumber != null);

  @override
  State<ShoeReturnScreen> createState() => _ShoeReturnScreenState();
}

class _ShoeReturnScreenState extends State<ShoeReturnScreen> {
  late ApiClient _api;
  ShoeClaim? _claim;
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
      final json = widget.claimId != null
          ? await _api.get('/shoe-claims/${widget.claimId}') as Map<String, dynamic>
          : await _api.get('/shoe-claims/search?number=${Uri.encodeQueryComponent(widget.claimNumber!)}') as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _claim = ShoeClaim.fromJson(json['claim'] as Map<String, dynamic>);
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  Future<void> _confirmReturned() async {
    final c = _claim!;
    setState(() => _busy = true);
    try {
      await _api.post('/shoe-claims/${c.id}/return', {}, _api.newIdempotencyKey());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Shoes returned — claim #${c.claimNumber} closed.')));
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _reportMismatch() async {
    final c = _claim!;
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (context) => _ReportMismatchDialog(claimNumber: c.claimNumber),
    );
    if (result == null) return;
    setState(() => _busy = true);
    try {
      final res = await _api.post('/shoe-claims/${c.id}/report', {'type': result.$1, 'description': result.$2}) as Map<String, dynamic>;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Reported — incident ${res['incidentNumber']} opened. A manager will review it.')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _claim;
    return Scaffold(
      appBar: AppBar(title: const Text('Shoe Return')),
      body: c == null
          ? Center(
              child: _error != null
                  ? Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [Text(_error!, textAlign: TextAlign.center), const SizedBox(height: 10), OutlinedButton(onPressed: _load, child: const Text('Retry'))]))
                  : const CircularProgressIndicator(),
            )
          : ListView(
              padding: const EdgeInsets.all(18),
              children: [
                Center(child: ShoePhoto(claimId: c.id, size: 180, borderRadius: BorderRadius.circular(14))),
                const SizedBox(height: 16),
                Center(child: Text('#${c.claimNumber}', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: LsColors.brand))),
                const SizedBox(height: 14),
                Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        AuthedPhoto(photoId: c.customerPhotoId, name: c.customerName ?? '?', size: 48),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(c.customerName ?? '—', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                            if (c.sessionStatus != null) LsBadge(label: 'Session ${titleCase(c.sessionStatus!)}', level: c.sessionStatus == 'EXPIRED' ? 'expired' : 'normal', icon: Icons.circle),
                          ]),
                        ),
                      ]),
                      const Divider(height: 24),
                      _row('Stored', '${fmtDate(c.createdAt)} ${fmtHHMM(c.createdAt)}'),
                      if (c.equipment.isNotEmpty) _row('Equipment', c.equipment),
                      _row('Status', titleCase(c.status)),
                      if (c.returnedAt != null) _row('Returned', '${fmtDate(c.returnedAt!)} ${fmtHHMM(c.returnedAt)}'),
                    ]),
                  ),
                ),
                const SizedBox(height: 20),
                if (c.status != 'RETURNED') ...[
                  FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: LsColors.green, minimumSize: const Size.fromHeight(52)),
                    onPressed: _busy ? null : _confirmReturned,
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text('Confirm Shoes Returned', style: TextStyle(fontWeight: FontWeight.w800)),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(foregroundColor: LsColors.red, minimumSize: const Size.fromHeight(48)),
                    onPressed: _busy ? null : _reportMismatch,
                    icon: const Icon(Icons.warning_amber_rounded),
                    label: const Text('Report Mismatch'),
                  ),
                ] else
                  const Padding(padding: EdgeInsets.all(8), child: Center(child: Text('These shoes have already been returned.', style: TextStyle(color: LsColors.muted)))),
              ],
            ),
    );
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          SizedBox(width: 90, child: Text(label, style: const TextStyle(color: LsColors.muted))),
          Expanded(child: Text(value, style: const TextStyle(fontWeight: FontWeight.w600))),
        ]),
      );
}

class _ReportMismatchDialog extends StatefulWidget {
  final String claimNumber;
  const _ReportMismatchDialog({required this.claimNumber});
  @override
  State<_ReportMismatchDialog> createState() => _ReportMismatchDialogState();
}

class _ReportMismatchDialogState extends State<_ReportMismatchDialog> {
  String _type = 'SHOE_MISMATCH';
  final _descCtrl = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final valid = _descCtrl.text.trim().length >= 3;
    return StatefulBuilder(builder: (context, setLocal) {
      return AlertDialog(
        title: Text('Report issue — #${widget.claimNumber}'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('This opens an operational incident for a manager to review — it is not an accusation.', style: TextStyle(color: LsColors.muted, fontSize: 12)),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _type,
              decoration: const InputDecoration(labelText: 'Issue type'),
              items: shoeIssueTypes.map((t) => DropdownMenuItem(value: t, child: Text(shoeIssueLabels[t]!))).toList(),
              onChanged: (v) => setLocal(() => _type = v ?? _type),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _descCtrl,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'What did staff notice?'),
              onChanged: (_) => setLocal(() {}),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: valid ? () => Navigator.pop(context, (_type, _descCtrl.text.trim())) : null,
            child: const Text('Report'),
          ),
        ],
      );
    });
  }
}
