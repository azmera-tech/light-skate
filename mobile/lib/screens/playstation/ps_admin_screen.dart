import 'package:flutter/material.dart';
import '../../api/api_client.dart';
import '../../format.dart';
import '../../models/playstation.dart';
import '../../theme.dart';
import 'ps_dashboard_screen.dart';
import 'ps_history_screen.dart';

/// Admin → PlayStation: the management module. Each tab is gated by its own permission; the server
/// enforces the same rules on every request.
class PsAdminScreen extends StatelessWidget {
  const PsAdminScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ApiClient>(
      future: ApiClient.instance(),
      builder: (context, snap) {
        final me = snap.data?.me;
        if (me == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
        final tabs = <(String, Widget)>[
          ('Overview', const _OverviewTab()),
          if (me.can('playstation.operate')) ('Live sessions', const PsDashboardScreen(showHistoryButton: false)),
          if (me.can('playstation.manage')) ('Pricing & packages', const _PackagesTab()),
          if (me.can('playstation.manage')) ('Consoles', const _ConsolesTab()),
          ('Session history', const PsHistoryScreen()),
          if (me.can('playstation.reports')) ('Reports', const _ReportsTab()),
          if (me.can('playstation.manage')) ('Settings', const _SettingsTab()),
        ];
        return DefaultTabController(
          length: tabs.length,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('PlayStation management'),
              bottom: TabBar(isScrollable: true, tabAlignment: TabAlignment.start, tabs: [for (final t in tabs) Tab(text: t.$1)]),
            ),
            body: TabBarView(children: [for (final t in tabs) t.$2]),
          ),
        );
      },
    );
  }
}

// ============================================================================================ overview

class _OverviewTab extends StatefulWidget {
  const _OverviewTab();
  @override
  State<_OverviewTab> createState() => _OverviewTabState();
}

class _OverviewTabState extends State<_OverviewTab> {
  Map<String, dynamic>? _ov;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final api = await ApiClient.instance();
      final j = await api.get('/playstation/overview') as Map<String, dynamic>;
      if (mounted) setState(() => _ov = j);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final ov = _ov;
    if (ov == null) return Center(child: _error != null ? Text(_error!) : const CircularProgressIndicator());
    final cs = (ov['consoles'] as Map).cast<String, dynamic>();
    final ss = (ov['sessions'] as Map).cast<String, dynamic>();
    final rev = (ov['revenueToday'] as Map).cast<String, dynamic>();
    final out = (ov['outstanding'] as Map).cast<String, dynamic>();
    final pop = ((ov['popularPackages'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final recent = ((ov['recentActivity'] as List?) ?? const []).cast<Map<String, dynamic>>();
    Widget kpi(String l, String v, Color c) => SizedBox(
          width: 160,
          child: Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(v, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: c)),
            Text(l, style: const TextStyle(color: LsColors.muted, fontSize: 12)),
          ]))),
        );
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(12), children: [
        Text('Today (${ov['date']})', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        Wrap(spacing: 4, runSpacing: 4, children: [
          kpi('Total consoles', '${cs['total']}', LsColors.slate),
          kpi('Available', '${cs['available']}', LsColors.green),
          kpi('Occupied', '${cs['inUse']}', LsColors.brand),
          kpi('Maintenance', '${cs['maintenance']}', LsColors.orange),
          kpi('Active sessions', '${ss['active']}', LsColors.brand),
          kpi('Completed today', '${ss['completedToday']}', LsColors.slate),
          kpi('Revenue today (net)', formatMoney((rev['netMinor'] as num).toInt(), 'ETB'), LsColors.green),
          kpi('Refunded today', formatMoney((rev['refundedMinor'] as num).toInt(), 'ETB'), LsColors.red),
          kpi('Unpaid sessions', '${out['sessions']} · ${formatMoney((out['minor'] as num).toInt(), 'ETB')}', LsColors.red),
        ]),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 6),
          child: Text('Revenue = payments actually received today minus refunds issued today. Unpaid sessions are not counted.', style: TextStyle(color: LsColors.muted, fontSize: 12)),
        ),
        const SizedBox(height: 8),
        Text('Popular packages (last 7 days)', style: Theme.of(context).textTheme.titleMedium),
        if (pop.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('No sales yet.', style: TextStyle(color: LsColors.muted))),
        for (final p in pop)
          ListTile(dense: true, contentPadding: EdgeInsets.zero, title: Text(p['packageName'] as String), subtitle: Text('${p['sold']} sold'), trailing: Text(formatMoney((p['valueMinor'] as num).toInt(), 'ETB'))),
        const SizedBox(height: 8),
        Text('Recent session activity', style: Theme.of(context).textTheme.titleMedium),
        for (final r in recent)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text('${r['consoleCode']} · ${r['sessionNumber']} · ${psEventLabel[r['eventType']] ?? r['eventType']}'),
            subtitle: Text('${fmtHHMM(DateTime.tryParse(r['occurredAt'] as String? ?? '')?.toLocal())}${r['actorName'] != null ? ' · ${r['actorName']}' : ' · system'}'),
          ),
      ]),
    );
  }
}

// ============================================================================================ packages

class _PackagesTab extends StatefulWidget {
  const _PackagesTab();
  @override
  State<_PackagesTab> createState() => _PackagesTabState();
}

class _PackagesTabState extends State<_PackagesTab> {
  late ApiClient _api;
  List<PsPackage>? _list;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _api = await ApiClient.instance();
    final j = await _api.get('/playstation/packages?all=true') as Map<String, dynamic>;
    if (mounted) setState(() => _list = ((j['packages'] as List?) ?? const []).map((e) => PsPackage.fromJson(e as Map<String, dynamic>)).toList());
  }

  Future<void> _call(Future<dynamic> Function() f, String ok) async {
    try {
      await f();
      await _load();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok)));
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _edit([PsPackage? p]) async {
    final name = TextEditingController(text: p?.name ?? '');
    final desc = TextEditingController(text: p?.description ?? '');
    final price = TextEditingController(text: p == null ? '' : (p.priceMinor / 100).toStringAsFixed(p.priceMinor % 100 == 0 ? 0 : 2));
    final minutes = TextEditingController(text: p?.durationMinutes?.toString() ?? '');
    final games = TextEditingController(text: p?.gamesPerUnit?.toString() ?? '1');
    final label = TextEditingController(text: p?.gameLabel ?? 'game');
    String type = p?.pricingType ?? 'DURATION';
    bool active = p?.active ?? true;
    String? err;
    final body = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
            title: Text(p == null ? 'New package' : 'Edit package'),
            content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                SegmentedButton<String>(
                  segments: const [ButtonSegment(value: 'DURATION', label: Text('By time')), ButtonSegment(value: 'PER_GAME', label: Text('Per game'))],
                  selected: {type},
                  onSelectionChanged: p != null && p.timesSold > 0 ? null : (v) => setD(() => type = v.first),
                ),
                if (p != null && p.timesSold > 0) const Padding(padding: EdgeInsets.only(top: 4), child: Text('Already sold — the pricing type is locked.', style: TextStyle(fontSize: 12, color: LsColors.muted))),
                const SizedBox(height: 10),
                TextField(controller: name, decoration: const InputDecoration(labelText: 'Package name')),
                const SizedBox(height: 8),
                TextField(controller: price, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Price (ETB)')),
                const SizedBox(height: 8),
                if (type == 'DURATION')
                  TextField(controller: minutes, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Duration (minutes)'))
                else ...[
                  TextField(controller: games, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Games included')),
                  const SizedBox(height: 8),
                  TextField(controller: label, decoration: const InputDecoration(labelText: 'What one game means, e.g. "FIFA match"')),
                ],
                const SizedBox(height: 8),
                TextField(controller: desc, decoration: const InputDecoration(labelText: 'Description (optional)')),
                SwitchListTile(contentPadding: EdgeInsets.zero, value: active, onChanged: (v) => setD(() => active = v), title: const Text('Active (can be sold)')),
                if (err != null) Text(err!, style: const TextStyle(color: LsColors.red)),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              FilledButton(
                onPressed: () {
                  final pr = double.tryParse(price.text.trim());
                  final mins = int.tryParse(minutes.text.trim());
                  final gm = int.tryParse(games.text.trim());
                  if (name.text.trim().isEmpty) return setD(() => err = 'Enter a name.');
                  if (pr == null || pr <= 0) return setD(() => err = 'Enter a price above 0.');
                  if (type == 'DURATION' && (mins == null || mins <= 0)) return setD(() => err = 'Enter a duration in minutes.');
                  if (type == 'PER_GAME' && (gm == null || gm <= 0)) return setD(() => err = 'Enter how many games it includes.');
                  Navigator.pop(ctx, {
                    'name': name.text.trim(), 'description': desc.text.trim().isEmpty ? null : desc.text.trim(), 'pricingType': type,
                    'priceMinor': (pr * 100).round(), 'active': active,
                    if (type == 'DURATION') 'durationMinutes': mins,
                    if (type == 'PER_GAME') 'gamesPerUnit': gm,
                    if (type == 'PER_GAME') 'gameLabel': label.text.trim(),
                  });
                },
                child: const Text('Save'),
              ),
            ],
          )),
    );
    if (body == null) return;
    if (p == null) {
      await _call(() => _api.post('/playstation/packages', body), 'Package created.');
    } else {
      await _call(() => _api.patch('/playstation/packages/${p.id}', body), 'Package updated. Existing sessions keep their original price.');
    }
  }

  Future<void> _delete(PsPackage p) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${p.name}"?'),
        content: Text(p.timesSold > 0 ? 'It has been sold ${p.timesSold} time(s), so it will be archived: hidden from sale, with its history kept.' : 'It has never been sold and will be removed.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: LsColors.red), onPressed: () => Navigator.pop(ctx, true), child: Text(p.timesSold > 0 ? 'Archive' : 'Delete')),
        ],
      ),
    );
    if (ok == true) await _call(() => _api.delete('/playstation/packages/${p.id}'), p.timesSold > 0 ? 'Package archived.' : 'Package deleted.');
  }

  @override
  Widget build(BuildContext context) {
    final l = _list;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(onPressed: () => _edit(), icon: const Icon(Icons.add), label: const Text('Package')),
      body: l == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 90), children: [
                if (l.isEmpty) const Padding(padding: EdgeInsets.all(20), child: Text('No packages yet. Add your time and per-game prices.', textAlign: TextAlign.center)),
                for (final p in l)
                  Card(
                    child: ListTile(
                      leading: Icon(p.isTimed ? Icons.timer_outlined : Icons.sports_esports_outlined, color: p.active ? LsColors.brand : LsColors.gray),
                      title: Text(p.name, style: TextStyle(fontWeight: FontWeight.w700, color: p.active ? LsColors.text : LsColors.muted)),
                      subtitle: Text('${p.isTimed ? 'By time' : 'Per game'} · ${p.unitLabel} · ${p.active ? 'Active' : 'Inactive'} · sold ${p.timesSold}×${p.description != null ? '\n${p.description}' : ''}'),
                      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                        Text(formatMoney(p.priceMinor, 'ETB'), style: const TextStyle(fontWeight: FontWeight.w800)),
                        PopupMenuButton<String>(
                          onSelected: (v) {
                            if (v == 'edit') _edit(p);
                            if (v == 'toggle') _call(() => _api.patch('/playstation/packages/${p.id}', {'active': !p.active}), p.active ? 'Package deactivated.' : 'Package activated.');
                            if (v == 'delete') _delete(p);
                          },
                          itemBuilder: (_) => [
                            const PopupMenuItem(value: 'edit', child: Text('Edit')),
                            PopupMenuItem(value: 'toggle', child: Text(p.active ? 'Deactivate' : 'Activate')),
                            const PopupMenuItem(value: 'delete', child: Text('Delete / archive')),
                          ],
                        ),
                      ]),
                    ),
                  ),
              ]),
            ),
    );
  }
}

// ============================================================================================ consoles

class _ConsolesTab extends StatefulWidget {
  const _ConsolesTab();
  @override
  State<_ConsolesTab> createState() => _ConsolesTabState();
}

class _ConsolesTabState extends State<_ConsolesTab> {
  late ApiClient _api;
  List<PsConsole>? _list;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    _api = await ApiClient.instance();
    final j = await _api.get('/playstation/consoles') as Map<String, dynamic>;
    if (mounted) setState(() => _list = ((j['consoles'] as List?) ?? const []).map((e) => PsConsole.fromJson(e as Map<String, dynamic>)).toList());
  }

  Future<void> _call(Future<dynamic> Function() f, String ok) async {
    try {
      await f();
      await _load();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ok)));
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _edit([PsConsole? c]) async {
    final code = TextEditingController(text: c?.code ?? 'PS-${((_list?.length ?? 0) + 1).toString().padLeft(2, '0')}');
    final name = TextEditingController(text: c?.name ?? '');
    final model = TextEditingController(text: c?.model ?? 'PlayStation 5');
    final loc = TextEditingController(text: c?.location ?? '');
    final notes = TextEditingController(text: c?.notes ?? '');
    String status = c?.status ?? 'ACTIVE';
    final body = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setD) => AlertDialog(
            title: Text(c == null ? 'Add console' : 'Edit ${c.code}'),
            content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(controller: code, decoration: const InputDecoration(labelText: 'Console number, e.g. PS-01')),
                const SizedBox(height: 8),
                TextField(controller: name, decoration: const InputDecoration(labelText: 'Display name, e.g. Station 1')),
                const SizedBox(height: 8),
                TextField(controller: model, decoration: const InputDecoration(labelText: 'Model')),
                const SizedBox(height: 8),
                TextField(controller: loc, decoration: const InputDecoration(labelText: 'Location / station (optional)')),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: status,
                  decoration: const InputDecoration(labelText: 'Status'),
                  items: const [
                    DropdownMenuItem(value: 'ACTIVE', child: Text('Active')),
                    DropdownMenuItem(value: 'MAINTENANCE', child: Text('Maintenance')),
                    DropdownMenuItem(value: 'INACTIVE', child: Text('Inactive')),
                  ],
                  onChanged: (v) => setD(() => status = v ?? 'ACTIVE'),
                ),
                const SizedBox(height: 8),
                TextField(controller: notes, minLines: 1, maxLines: 3, decoration: const InputDecoration(labelText: 'Maintenance notes (optional)')),
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              FilledButton(
                onPressed: () => code.text.trim().isEmpty || name.text.trim().isEmpty
                    ? null
                    : Navigator.pop(ctx, {
                        'code': code.text.trim(), 'name': name.text.trim(), 'model': model.text.trim().isEmpty ? null : model.text.trim(),
                        'location': loc.text.trim().isEmpty ? null : loc.text.trim(), 'notes': notes.text.trim().isEmpty ? null : notes.text.trim(), 'status': status,
                      }),
                child: const Text('Save'),
              ),
            ],
          )),
    );
    if (body == null) return;
    if (c == null) {
      await _call(() => _api.post('/playstation/consoles', body), 'Console added.');
    } else {
      await _call(() => _api.patch('/playstation/consoles/${c.id}', body), 'Console updated.');
    }
  }

  Future<void> _archive(PsConsole c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${c.code}?'),
        content: const Text('The console is archived: it disappears from the board, and all of its session history is kept.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: LsColors.red), onPressed: () => Navigator.pop(ctx, true), child: const Text('Archive')),
        ],
      ),
    );
    if (ok == true) await _call(() => _api.patch('/playstation/consoles/${c.id}', {'archived': true}), 'Console archived.');
  }

  @override
  Widget build(BuildContext context) {
    final l = _list;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(onPressed: () => _edit(), icon: const Icon(Icons.add), label: const Text('Console')),
      body: l == null
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 90), children: [
                if (l.isEmpty) const Padding(padding: EdgeInsets.all(20), child: Text('No consoles yet. Add each PlayStation you rent out.', textAlign: TextAlign.center)),
                for (final c in l)
                  Card(
                    child: ListTile(
                      leading: Icon(Icons.sports_esports, color: switch (c.state) { 'AVAILABLE' => LsColors.green, 'IN_USE' => LsColors.brand, 'MAINTENANCE' => LsColors.orange, _ => LsColors.gray }),
                      title: Text('${c.code} · ${c.name}', style: const TextStyle(fontWeight: FontWeight.w700)),
                      subtitle: Text('${titleCase(c.state)}${c.model != null ? ' · ${c.model}' : ''}${c.location != null ? ' · ${c.location}' : ''}${c.notes != null ? '\n${c.notes}' : ''}'),
                      trailing: PopupMenuButton<String>(
                        onSelected: (v) {
                          if (v == 'edit') _edit(c);
                          if (v == 'maint') _call(() => _api.patch('/playstation/consoles/${c.id}', {'status': 'MAINTENANCE'}), '${c.code} is under maintenance.');
                          if (v == 'active') _call(() => _api.patch('/playstation/consoles/${c.id}', {'status': 'ACTIVE'}), '${c.code} is back in service.');
                          if (v == 'inactive') _call(() => _api.patch('/playstation/consoles/${c.id}', {'status': 'INACTIVE'}), '${c.code} deactivated.');
                          if (v == 'archive') _archive(c);
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(value: 'edit', child: Text('Edit')),
                          if (c.status != 'MAINTENANCE') const PopupMenuItem(value: 'maint', child: Text('Put under maintenance')),
                          if (c.status != 'ACTIVE') const PopupMenuItem(value: 'active', child: Text('Return to service')),
                          if (c.status != 'INACTIVE') const PopupMenuItem(value: 'inactive', child: Text('Deactivate')),
                          const PopupMenuItem(value: 'archive', child: Text('Remove (archive)')),
                        ],
                      ),
                    ),
                  ),
              ]),
            ),
    );
  }
}

// ============================================================================================ reports

class _ReportsTab extends StatefulWidget {
  const _ReportsTab();
  @override
  State<_ReportsTab> createState() => _ReportsTabState();
}

class _ReportsTabState extends State<_ReportsTab> {
  late DateTimeRange _range;
  Map<String, dynamic>? _r;
  String? _error;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _range = DateTimeRange(start: DateTime(now.year, now.month, now.day).subtract(const Duration(days: 6)), end: DateTime(now.year, now.month, now.day));
    _load();
  }

  Future<void> _load() async {
    try {
      final api = await ApiClient.instance();
      final j = await api.get('/playstation/reports?from=${fmtDate(_range.start)}&to=${fmtDate(_range.end)}') as Map<String, dynamic>;
      if (mounted) {
        setState(() {
          _r = j;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _r;
    int n(dynamic v) => (v as num?)?.toInt() ?? 0;
    final totals = (r?['totals'] as Map?)?.cast<String, dynamic>() ?? const {};
    List<Map<String, dynamic>> rows(String k) => ((r?[k] as List?) ?? const []).cast<Map<String, dynamic>>();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(12), children: [
        OutlinedButton.icon(
          onPressed: () async {
            final now = DateTime.now();
            final p = await showDateRangePicker(context: context, firstDate: DateTime(now.year - 2), lastDate: now, initialDateRange: _range);
            if (p != null) {
              setState(() => _range = p);
              _load();
            }
          },
          icon: const Icon(Icons.date_range),
          label: Text('${fmtDate(_range.start)} → ${fmtDate(_range.end)}'),
        ),
        if (_error != null) Text(_error!, style: const TextStyle(color: LsColors.red)),
        if (r == null) const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator())),
        if (r != null) ...[
          const SizedBox(height: 10),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Net revenue ${formatMoney(n(totals['netMinor']), 'ETB')}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: LsColors.green)),
                Text('Collected ${formatMoney(n(totals['collectedMinor']), 'ETB')} · Refunded ${formatMoney(n(totals['refundedMinor']), 'ETB')} · ${n(totals['sessionsCompleted'])} sessions completed'),
              ]),
            ),
          ),
          _section('By day', [for (final d in rows('byDay')) _row(d['day'] as String, '${n(d['sessionsCompleted'])} sessions', formatMoney(n(d['collectedMinor']) - n(d['refundedMinor']), 'ETB'))]),
          _section('By package', [for (final p in rows('byPackage')) _row(p['packageName'] as String, '${n(p['timesSold'])} sales · ${n(p['units'])} units', formatMoney(n(p['soldMinor']), 'ETB'))]),
          _section('By console', [for (final c in rows('byConsole')) _row('${c['code']} · ${c['name']}', '${n(c['sessions'])} sessions', formatDuration(n(c['playedSeconds'])))]),
          _section('By employee', [for (final e in rows('byEmployee')) _row('${e['fullName']}', '${e['roleName']} · ${n(e['sessionsOpened'])} opened · ${n(e['actions'])} actions', formatMoney(n(e['collectedMinor']), 'ETB'))]),
        ],
      ]),
    );
  }

  Widget _section(String title, List<Widget> children) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          if (children.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('Nothing in this period.', style: TextStyle(color: LsColors.muted))),
          ...children,
        ]),
      );

  Widget _row(String a, String b, String c) => ListTile(dense: true, contentPadding: EdgeInsets.zero, title: Text(a), subtitle: Text(b), trailing: Text(c, style: const TextStyle(fontWeight: FontWeight.w700)));
}

// ============================================================================================ settings

class _SettingsTab extends StatefulWidget {
  const _SettingsTab();
  @override
  State<_SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<_SettingsTab> {
  int _warn = 5;
  bool _requirePay = true;
  bool _pause = true;
  bool _loaded = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = await ApiClient.instance();
    final j = await api.get('/playstation/settings') as Map<String, dynamic>;
    final s = (j['settings'] as Map).cast<String, dynamic>();
    if (mounted) {
      setState(() {
        _warn = (s['warningMinutes'] as num).toInt();
        _requirePay = s['requirePaymentBeforeStart'] == true;
        _pause = s['pauseEnabled'] == true;
        _loaded = true;
      });
    }
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final api = await ApiClient.instance();
      await api.put('/playstation/settings', {'warningMinutes': _warn, 'requirePaymentBeforeStart': _requirePay, 'pauseEnabled': _pause});
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PlayStation settings saved.')));
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const Center(child: CircularProgressIndicator());
    return ListView(padding: const EdgeInsets.all(12), children: [
      ListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Warn the operator before a timed session ends'),
        subtitle: Text('$_warn minutes before'),
        trailing: SizedBox(
          width: 150,
          child: Slider(value: _warn.toDouble(), min: 1, max: 30, divisions: 29, label: '$_warn min', onChanged: (v) => setState(() => _warn = v.round())),
        ),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _requirePay,
        onChanged: (v) => setState(() => _requirePay = v),
        title: const Text('Require full payment before a session starts'),
        subtitle: const Text('When off, operators can start first and take payment later (outstanding amounts show as unpaid).'),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _pause,
        onChanged: (v) => setState(() => _pause = v),
        title: const Text('Allow pausing sessions'),
        subtitle: const Text('Paused time is not charged: the countdown freezes and the end time moves out by the pause length.'),
      ),
      const SizedBox(height: 12),
      ElevatedButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'Saving…' : 'Save settings')),
      const SizedBox(height: 16),
      const Text('PlayStation Manager accounts are created and revoked in Admin → Staff: give the account the "PlayStation Manager" role.', style: TextStyle(color: LsColors.muted)),
    ]);
  }
}

