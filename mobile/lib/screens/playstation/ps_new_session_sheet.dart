import 'package:flutter/material.dart';
import '../../api/api_client.dart';
import '../../format.dart';
import '../../models/playstation.dart';
import '../../models/product.dart';
import '../../theme.dart';

/// Opens a gaming session on [console]: pick an admin-configured package (the price comes from
/// the server — staff cannot type one), the player (walk-in or registered customer by phone),
/// and record the payment. Returns the new session id.
Future<String?> showNewGamingSessionSheet(BuildContext context, PsConsole console) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _NewSessionSheet(console: console),
  );
}

class _NewSessionSheet extends StatefulWidget {
  final PsConsole console;
  const _NewSessionSheet({required this.console});
  @override
  State<_NewSessionSheet> createState() => _NewSessionSheetState();
}

class _NewSessionSheetState extends State<_NewSessionSheet> {
  late ApiClient _api;
  List<PsPackage> _packages = [];
  List<PaymentMethodOption> _methods = [];
  bool _requirePayment = true;
  PsPackage? _pkg;
  int _qty = 1;
  bool _walkIn = true;
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _lookupPhone = TextEditingController();
  List<Map<String, dynamic>> _matches = [];
  Map<String, dynamic>? _customer;
  bool _payNow = true;
  String? _method;
  final _ref = TextEditingController();
  bool _unconfirmed = false;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    _api = await ApiClient.instance();
    try {
      final p = await _api.get('/playstation/packages') as Map<String, dynamic>;
      final st = await _api.get('/playstation/settings') as Map<String, dynamic>;
      setState(() {
        _packages = ((p['packages'] as List?) ?? const []).map((e) => PsPackage.fromJson(e as Map<String, dynamic>)).toList();
        _methods = ((st['paymentMethods'] as List?) ?? const []).map((e) => PaymentMethodOption.fromJson(e as Map<String, dynamic>)).toList();
        _requirePayment = (st['settings'] as Map?)?['requirePaymentBeforeStart'] != false;
        _method = _methods.where((m) => m.code == 'CASH').firstOrNull?.code ?? _methods.firstOrNull?.code;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _lookup() async {
    setState(() => _error = null);
    try {
      final r = await _api.get('/playstation/customer-lookup?phone=${Uri.encodeQueryComponent(_lookupPhone.text.trim())}') as Map<String, dynamic>;
      setState(() {
        _matches = ((r['customers'] as List?) ?? const []).cast<Map<String, dynamic>>();
        _customer = _matches.length == 1 ? _matches.first : null;
        if (_matches.isEmpty) _error = 'No registered customer has that phone number. Use walk-in instead.';
      });
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    }
  }

  PaymentMethodOption? get _selectedMethod => _methods.where((m) => m.code == _method).firstOrNull;

  bool get _valid {
    if (_pkg == null) return false;
    if (_walkIn ? _name.text.trim().isEmpty : _customer == null) return false;
    if (_payNow) {
      if (_method == null) return false;
      if ((_selectedMethod?.requiresReference ?? false) && !_unconfirmed && _ref.text.trim().isEmpty) return false;
    }
    return true;
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final body = <String, dynamic>{
        'consoleId': widget.console.id,
        'packageId': _pkg!.id,
        'quantity': _qty,
        if (_walkIn) 'walkInName': _name.text.trim(),
        if (_walkIn && _phone.text.trim().isNotEmpty) 'walkInPhone': _phone.text.trim(),
        if (!_walkIn) 'customerId': _customer!['id'],
        if (_payNow)
          'payment': {
            'method': _method,
            if (_ref.text.trim().isNotEmpty) 'reference': _ref.text.trim(),
            'confirmed': !_unconfirmed,
          },
      };
      final res = await _api.post('/playstation/sessions', body) as Map<String, dynamic>;
      final d = PsSessionDetail.fromJson(res);
      if (!mounted) return;
      if (d.status == 'READY' || (!_requirePayment && d.status == 'PENDING_PAYMENT')) {
        final start = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text('Start ${widget.console.code} now?'),
            content: Text(d.isTimed ? 'The ${formatDuration(d.purchasedSeconds)} countdown starts when you tap Start.' : '${d.gamesPurchased} game(s) purchased.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Later')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Start')),
            ],
          ),
        );
        if (start == true) await _api.post('/playstation/sessions/${d.id}/start');
      }
      if (mounted) Navigator.of(context).pop(d.id);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = (_pkg?.priceMinor ?? 0) * _qty;
    final needsRef = _selectedMethod?.requiresReference ?? false;
    return Padding(
      padding: EdgeInsets.only(left: 16, right: 16, bottom: MediaQuery.of(context).viewInsets.bottom + 16),
      child: _loading
          ? const SizedBox(height: 200, child: Center(child: CircularProgressIndicator()))
          : SingleChildScrollView(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                Text('New session on ${widget.console.code} · ${widget.console.name}', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 12),
                const Text('Package', style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                if (_packages.isEmpty) const Text('No active packages. An admin needs to add packages first.', style: TextStyle(color: LsColors.red)),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final p in _packages)
                    ChoiceChip(
                      label: Text('${p.name} · ${p.unitLabel} · ${formatMoney(p.priceMinor, 'ETB')}'),
                      selected: _pkg?.id == p.id,
                      onSelected: (_) => setState(() => _pkg = p),
                    ),
                ]),
                if (_pkg != null) ...[
                  const SizedBox(height: 10),
                  Row(children: [
                    const Text('Quantity', style: TextStyle(fontWeight: FontWeight.w700)),
                    const Spacer(),
                    IconButton.outlined(onPressed: _qty > 1 ? () => setState(() => _qty--) : null, icon: const Icon(Icons.remove)),
                    Padding(padding: const EdgeInsets.symmetric(horizontal: 14), child: Text('$_qty', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
                    IconButton.outlined(onPressed: _qty < 50 ? () => setState(() => _qty++) : null, icon: const Icon(Icons.add)),
                  ]),
                  Text(_pkg!.isTimed ? 'Total play time: ${formatDuration((_pkg!.durationMinutes ?? 0) * 60 * _qty)}' : 'Games: ${(_pkg!.gamesPerUnit ?? 1) * _qty}',
                      style: const TextStyle(color: LsColors.muted)),
                ],
                const Divider(height: 26),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('Walk-in'), icon: Icon(Icons.directions_walk)),
                    ButtonSegment(value: false, label: Text('Registered'), icon: Icon(Icons.badge_outlined)),
                  ],
                  selected: {_walkIn},
                  onSelectionChanged: (v) => setState(() => _walkIn = v.first),
                ),
                const SizedBox(height: 10),
                if (_walkIn) ...[
                  TextField(controller: _name, decoration: const InputDecoration(labelText: 'Customer name'), onChanged: (_) => setState(() {})),
                  const SizedBox(height: 8),
                  TextField(controller: _phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone (optional)')),
                ] else ...[
                  Row(children: [
                    Expanded(child: TextField(controller: _lookupPhone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Customer phone number'))),
                    const SizedBox(width: 8),
                    FilledButton.tonal(onPressed: _lookup, child: const Text('Find')),
                  ]),
                  for (final c in _matches)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(_customer?['id'] == c['id'] ? Icons.check_circle : Icons.circle_outlined, color: LsColors.brand),
                      onTap: () => setState(() => _customer = c),
                      title: Text(c['fullName'] as String),
                      subtitle: Text(c['customerCode'] as String),
                    ),
                ],
                const Divider(height: 26),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _payNow,
                  onChanged: (v) => setState(() => _payNow = v),
                  title: const Text('Record payment now'),
                  subtitle: Text(_requirePayment ? 'Sessions can only start once fully paid.' : 'This venue allows starting before payment.'),
                ),
                if (_payNow) ...[
                  Wrap(spacing: 8, children: [
                    for (final m in _methods) ChoiceChip(label: Text(m.label), selected: _method == m.code, onSelected: (_) => setState(() => _method = m.code)),
                  ]),
                  if (needsRef) ...[
                    const SizedBox(height: 8),
                    TextField(controller: _ref, decoration: InputDecoration(labelText: '${_selectedMethod?.label} reference / receipt number'), onChanged: (_) => setState(() {})),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: _unconfirmed,
                      onChanged: (v) => setState(() => _unconfirmed = v ?? false),
                      title: const Text('Not confirmed yet — record as pending'),
                    ),
                  ],
                ],
                if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_error!, style: const TextStyle(color: LsColors.red))),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: !_valid || _busy ? null : _submit,
                  child: Text(_busy ? 'Saving…' : _pkg == null ? 'Choose a package' : _payNow ? 'Open session · ${formatMoney(total, 'ETB')} ${_unconfirmed ? 'pending' : 'received'}' : 'Open session · ${formatMoney(total, 'ETB')} due'),
                ),
              ]),
            ),
    );
  }
}
