import 'dart:async';
import 'package:flutter/material.dart';
import '../../api/api_client.dart';
import '../../format.dart';
import '../../models/cleaning.dart';
import '../../theme.dart';
import '../../widgets/cleaning_checklist_dialog.dart';
import '../../widgets/status_badge.dart';

/// "Cleaning Queue" — Needs Cleaning / Cleaning / Completed, matching the venue's standard
/// rule (clean after every customer use) plus the configurable scheduled-maintenance reminders.
class CleaningQueueScreen extends StatefulWidget {
  const CleaningQueueScreen({super.key});
  @override
  State<CleaningQueueScreen> createState() => _CleaningQueueScreenState();
}

class _CleaningQueueScreenState extends State<CleaningQueueScreen> {
  late ApiClient _api;
  CleaningQueue? _data;
  String? _error;
  bool _busy = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    _api = await ApiClient.instance();
    await _load();
    _poll = Timer.periodic(const Duration(seconds: 8), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    try {
      final json = await _api.get('/equipment/cleaning-queue') as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _data = CleaningQueue.fromJson(json);
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      if (!silent) setState(() => _error = e.toString());
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      await _load(silent: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startCleaning(CleaningItem item) => _run(() => _api.post('/equipment/${item.id}/cleaning/start'));

  Future<void> _markCleaned(CleaningItem item) async {
    final result = await showCleaningChecklistDialog(context, code: item.code);
    if (result == null) return;
    await _run(() => _api.post('/equipment/${item.id}/cleaning/complete', {'checklist': result.checklist, 'notes': result.notes}));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${item.code} cleaned and available again.')));
  }

  Future<void> _reportIssue(CleaningItem item) async {
    final issue = await showCleaningIssueDialog(context, code: item.code);
    if (issue == null) return;
    await _run(() => _api.post('/equipment/${item.id}/cleaning/issue', {'issue': issue}));
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Cleaning Queue'),
          bottom: TabBar(tabs: [
            Tab(text: 'Needs Cleaning${d != null ? ' (${d.needsCleaning.length})' : ''}'),
            Tab(text: 'Cleaning${d != null ? ' (${d.cleaning.length})' : ''}'),
            const Tab(text: 'Completed'),
          ]),
        ),
        body: d == null
            ? Center(
                child: _error != null
                    ? Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [Text(_error!, textAlign: TextAlign.center), const SizedBox(height: 10), OutlinedButton(onPressed: () => _load(), child: const Text('Retry'))]))
                    : const CircularProgressIndicator(),
              )
            : Stack(children: [
                TabBarView(children: [
                  _needsCleaningTab(d),
                  _cleaningTab(d),
                  _completedTab(d),
                ]),
                if (_busy) const LinearProgressIndicator(minHeight: 2),
              ]),
      ),
    );
  }

  Widget _needsCleaningTab(CleaningQueue d) {
    if (d.needsCleaning.isEmpty && d.overdueScheduled.isEmpty) return const _EmptyTab(text: 'Nothing needs cleaning right now.');
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        ...d.needsCleaning.map((item) => _CleaningCard(
              item: item,
              subtitle: item.returnedAt != null ? 'Returned ${_agoLabel(item.returnedAt!)}${item.lastCustomerName != null ? ' · ${item.lastCustomerName}' : ''}' : null,
              statusLabel: 'Needs cleaning',
              statusLevel: 'orange',
              actions: [
                FilledButton.tonal(onPressed: () => _startCleaning(item), child: const Text('Start cleaning')),
                OutlinedButton(onPressed: () => _reportIssue(item), child: const Text('Report issue')),
              ],
            )),
        if (d.overdueScheduled.isNotEmpty) ...[
          const Padding(padding: EdgeInsets.only(top: 8, bottom: 6), child: Text('Overdue for scheduled deep clean', style: TextStyle(fontWeight: FontWeight.w700, color: LsColors.red))),
          ...d.overdueScheduled.map((item) => _CleaningCard(
                item: item,
                subtitle: 'Overdue for deep inspection',
                statusLabel: 'Overdue',
                statusLevel: 'red',
                actions: const [],
              )),
        ],
      ],
    );
  }

  Widget _cleaningTab(CleaningQueue d) {
    if (d.cleaning.isEmpty) return const _EmptyTab(text: 'No skates currently being cleaned.');
    return ListView(
      padding: const EdgeInsets.all(14),
      children: d.cleaning
          .map((item) => _CleaningCard(
                item: item,
                subtitle: item.returnedAt != null ? 'Returned ${_agoLabel(item.returnedAt!)}' : null,
                statusLabel: 'Cleaning',
                statusLevel: 'info',
                actions: [
                  FilledButton.tonal(style: FilledButton.styleFrom(backgroundColor: LsColors.greenSoft, foregroundColor: LsColors.green), onPressed: () => _markCleaned(item), child: const Text('Mark Cleaned')),
                  OutlinedButton(onPressed: () => _reportIssue(item), child: const Text('Report issue')),
                ],
              ))
          .toList(),
    );
  }

  Widget _completedTab(CleaningQueue d) {
    if (d.completed.isEmpty) return const _EmptyTab(text: 'No cleaning history yet.');
    return ListView(
      padding: const EdgeInsets.all(14),
      children: d.completed
          .map((item) => _CleaningCard(
                item: item,
                subtitle: item.lastCleanedByName != null ? 'Cleaned by ${item.lastCleanedByName}' : null,
                statusLabel: 'Cleaned',
                statusLevel: 'normal',
                actions: const [],
              ))
          .toList(),
    );
  }

  String _agoLabel(DateTime t) {
    final mins = DateTime.now().difference(t).inMinutes;
    if (mins < 1) return 'just now';
    if (mins < 60) return '$mins minute${mins == 1 ? '' : 's'} ago';
    return '${fmtDate(t)} ${fmtHHMM(t)}';
  }
}

class _CleaningCard extends StatelessWidget {
  final CleaningItem item;
  final String? subtitle;
  final String statusLabel;
  final String statusLevel;
  final List<Widget> actions;
  const _CleaningCard({required this.item, required this.subtitle, required this.statusLabel, required this.statusLevel, required this.actions});
  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text('${item.code}${item.size != null ? ' — Size ${item.size}' : ''}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
            LsBadge(label: statusLabel, level: statusLevel, icon: Icons.cleaning_services_outlined),
          ]),
          if (subtitle != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(subtitle!, style: const TextStyle(color: LsColors.muted, fontSize: 13))),
          if (item.lastCleanedAt != null)
            Padding(padding: const EdgeInsets.only(top: 4), child: Text('Last cleaned ${fmtDate(item.lastCleanedAt!)} ${fmtHHMM(item.lastCleanedAt)}', style: const TextStyle(color: LsColors.muted, fontSize: 12))),
          if (actions.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 10), child: Wrap(spacing: 8, runSpacing: 6, children: actions)),
        ]),
      ),
    );
  }
}

class _EmptyTab extends StatelessWidget {
  final String text;
  const _EmptyTab({required this.text});
  @override
  Widget build(BuildContext context) => Center(child: Padding(padding: const EdgeInsets.all(32), child: Text(text, style: const TextStyle(color: LsColors.muted))));
}
