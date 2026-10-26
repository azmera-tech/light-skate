import 'package:flutter/material.dart';
import '../../api/api_client.dart';
import '../../format.dart';
import '../../models/playstation.dart';
import '../../theme.dart';
import '../../widgets/ps_sheet.dart';

/// Opens a session on [console]. Play-first: nothing is paid here — the session starts the moment
/// the employee taps **Start Session**, and the bill is settled at checkout. Returns the new session id.
Future<String?> showNewGamingSessionSheet(BuildContext context, PsConsole console) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => _NewSessionLoader(console: console),
  );
}

class _NewSessionLoader extends StatefulWidget {
  final PsConsole console;
  const _NewSessionLoader({required this.console});
  @override
  State<_NewSessionLoader> createState() => _NewSessionLoaderState();
}

class _NewSessionLoaderState extends State<_NewSessionLoader> {
  List<PsPackage>? _packages;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final api = await ApiClient.instance();
      final p = await api.get('/playstation/packages') as Map<String, dynamic>;
      if (!mounted) return;
      setState(() => _packages = ((p['packages'] as List?) ?? const []).map((e) => PsPackage.fromJson(e as Map<String, dynamic>)).toList());
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<String> _create(Map<String, dynamic> body) async {
    final api = await ApiClient.instance();
    final res = await api.post('/playstation/sessions', body) as Map<String, dynamic>;
    return (res['session'] as Map<String, dynamic>)['id'] as String;
  }

  @override
  Widget build(BuildContext context) {
    if (_packages == null) {
      return SizedBox(
        height: 220,
        child: Center(child: _error != null ? Padding(padding: const EdgeInsets.all(20), child: Text(_error!, style: const TextStyle(color: LsColors.red))) : const CircularProgressIndicator()),
      );
    }
    return NewSessionForm(console: widget.console, packages: _packages!, onSubmit: _create, onLookup: (phone) async {
      final api = await ApiClient.instance();
      final r = await api.get('/playstation/customer-lookup?phone=${Uri.encodeQueryComponent(phone)}') as Map<String, dynamic>;
      return ((r['customers'] as List?) ?? const []).cast<Map<String, dynamic>>();
    });
  }
}

/// The form itself (network-free, so its layout can be tested): choose package, customer, optional starting quantity.
class NewSessionForm extends StatefulWidget {
  final PsConsole console;
  final List<PsPackage> packages;
  final Future<String> Function(Map<String, dynamic> body) onSubmit;
  final Future<List<Map<String, dynamic>>> Function(String phone) onLookup;
  const NewSessionForm({super.key, required this.console, required this.packages, required this.onSubmit, required this.onLookup});
  @override
  State<NewSessionForm> createState() => _NewSessionFormState();
}

class _NewSessionFormState extends State<NewSessionForm> {
  PsPackage? _pkg;
  int _qty = 0;
  bool _walkIn = true;
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _lookupPhone = TextEditingController();
  List<Map<String, dynamic>> _matches = [];
  Map<String, dynamic>? _customer;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.packages.length == 1) _choose(widget.packages.first);
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _lookupPhone.dispose();
    super.dispose();
  }

  void _choose(PsPackage p) {
    setState(() {
      _pkg = p;
      _qty = p.isTimed ? 1 : 0; // a timed package is sold by the block; per-game starts at zero and grows with each game
    });
  }

  bool get _valid => _pkg != null && (_walkIn ? _name.text.trim().isNotEmpty : _customer != null);

  Future<void> _lookup() async {
    setState(() => _error = null);
    try {
      final m = await widget.onLookup(_lookupPhone.text.trim());
      setState(() {
        _matches = m;
        _customer = m.length == 1 ? m.first : null;
        if (m.isEmpty) _error = 'No registered customer has that number. Use Walk-in instead.';
      });
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    }
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final id = await widget.onSubmit({
        'consoleId': widget.console.id,
        'packageId': _pkg!.id,
        'quantity': _qty,
        if (_walkIn) 'walkInName': _name.text.trim(),
        if (_walkIn && _phone.text.trim().isNotEmpty) 'walkInPhone': _phone.text.trim(),
        if (!_walkIn) 'customerId': _customer!['id'],
      });
      if (mounted) Navigator.of(context).pop(id);
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _pkg;
    final charge = (p?.priceMinor ?? 0) * _qty;
    return PsSheetScaffold(
      title: 'Start session · ${widget.console.code}',
      subtitle: widget.console.name,
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const _Label('Package'),
        if (widget.packages.isEmpty) const Text('No active packages yet. An admin needs to add them under Admin → PlayStation.', style: TextStyle(color: LsColors.red)),
        for (final k in widget.packages)
          _PackageTile(pkg: k, selected: p?.id == k.id, onTap: () => _choose(k)),
        if (p != null) ...[
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.isTimed ? 'How many ${p.durationMinutes}-minute blocks' : 'Games to start with', style: const TextStyle(fontWeight: FontWeight.w700)),
                Text(p.isTimed ? 'Total play time ${formatDuration((p.durationMinutes ?? 0) * 60 * _qty)}' : 'Leave at 0 and tap + Add Game as they play', style: const TextStyle(color: LsColors.muted, fontSize: 12.5)),
              ]),
            ),
            IconButton.outlined(tooltip: 'Fewer', onPressed: _qty > (p.isTimed ? 1 : 0) ? () => setState(() => _qty--) : null, icon: const Icon(Icons.remove)),
            SizedBox(width: 40, child: Text('$_qty', textAlign: TextAlign.center, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800))),
            IconButton.outlined(tooltip: 'More', onPressed: _qty < 50 ? () => setState(() => _qty++) : null, icon: const Icon(Icons.add)),
          ]),
        ],
        const SizedBox(height: 14),
        const _Label('Customer'),
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
          TextField(controller: _name, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Customer name'), onChanged: (_) => setState(() {})),
          const SizedBox(height: 8),
          TextField(controller: _phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone (optional)')),
        ] else ...[
          Row(children: [
            Expanded(child: TextField(controller: _lookupPhone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Customer phone number'), onSubmitted: (_) => _lookup())),
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
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: LsColors.brandSoft, borderRadius: BorderRadius.circular(10)),
          child: Row(children: [
            const Icon(Icons.info_outline, size: 18, color: LsColors.brandStrong),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                p == null ? 'Nothing is paid now. The bill is settled when the session ends.' : 'Charge so far ${formatMoney(charge, 'ETB')} · paid 0 ETB. Payment is taken at checkout.',
                style: const TextStyle(color: LsColors.brandStrong, fontSize: 12.5, fontWeight: FontWeight.w600),
              ),
            ),
          ]),
        ),
      ]),
      action: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (_error != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Semantics(liveRegion: true, child: Text(_error!, style: const TextStyle(color: LsColors.red, fontWeight: FontWeight.w700)))),
        SizedBox(
          height: 52,
          child: ElevatedButton.icon(
            onPressed: !_valid || _busy ? null : _submit,
            icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.play_arrow_rounded),
            label: Text(_busy ? 'Starting…' : 'Start Session'),
          ),
        ),
      ]),
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(text, style: const TextStyle(fontWeight: FontWeight.w800, color: LsColors.slate)));
}

class _PackageTile extends StatelessWidget {
  final PsPackage pkg;
  final bool selected;
  final VoidCallback onTap;
  const _PackageTile({required this.pkg, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Semantics(
        selected: selected,
        button: true,
        label: '${pkg.name}, ${pkg.unitLabel}, ${formatMoney(pkg.priceMinor, 'ETB')}${pkg.isTimed ? '' : ' per ${pkg.gameLabel ?? 'game'}'}',
        child: Material(
          color: selected ? LsColors.brandSoft : LsColors.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: selected ? LsColors.brand : LsColors.border, width: selected ? 2 : 1)),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(children: [
                Icon(pkg.isTimed ? Icons.timer_outlined : Icons.sports_esports_outlined, color: selected ? LsColors.brandStrong : LsColors.muted),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(pkg.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text(pkg.isTimed ? pkg.unitLabel : 'billed per ${pkg.gameLabel ?? 'game'}', style: const TextStyle(color: LsColors.muted, fontSize: 12.5)),
                  ]),
                ),
                Text(pkg.isTimed ? formatMoney(pkg.priceMinor, 'ETB') : '${formatMoney(pkg.priceMinor, 'ETB')} / ${pkg.gameLabel ?? 'game'}', style: const TextStyle(fontWeight: FontWeight.w800)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
