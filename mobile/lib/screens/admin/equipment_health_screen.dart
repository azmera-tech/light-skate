import 'package:flutter/material.dart';
import '../../api/api_client.dart';
import '../../models/cleaning.dart';
import '../../theme.dart';
import '../equipment/cleaning_queue_screen.dart';

/// Admin "Equipment Health" — the operational picture a manager needs at a glance: fleet
/// status breakdown plus cleaning compliance, matching the venue-wide numbers the dashboard
/// summarises for front-line staff but with full detail and no permission trimming.
class EquipmentHealthScreen extends StatefulWidget {
  const EquipmentHealthScreen({super.key});
  @override
  State<EquipmentHealthScreen> createState() => _EquipmentHealthScreenState();
}

class _EquipmentHealthScreenState extends State<EquipmentHealthScreen> {
  late ApiClient _api;
  EquipmentHealth? _data;
  String? _error;

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
      final json = await _api.get('/equipment/health') as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _data = EquipmentHealth.fromJson(json);
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return Scaffold(
      appBar: AppBar(title: const Text('Equipment Health')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: d == null
            ? Center(
                child: _error != null
                    ? Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [Text(_error!, textAlign: TextAlign.center), const SizedBox(height: 10), OutlinedButton(onPressed: _load, child: const Text('Retry'))]))
                    : const CircularProgressIndicator(),
              )
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text('Fleet', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  _StatGrid(items: [
                    ('Total skates', '${d.total}', null),
                    ('Available', '${d.available}', null),
                    ('In use', '${d.inUse}', null),
                    ('Needs cleaning', '${d.needsCleaning}', d.needsCleaning > 0 ? LsColors.orange : null),
                    ('Overdue', '${d.overdue}', d.overdue > 0 ? LsColors.red : null),
                    ('Maintenance', '${d.maintenance}', d.maintenance > 0 ? LsColors.orange : null),
                    ('Out of service', '${d.outOfService}', d.outOfService > 0 ? LsColors.red : null),
                  ]),
                  const SizedBox(height: 20),
                  Row(children: [
                    Expanded(child: Text('Cleaning', style: Theme.of(context).textTheme.titleMedium)),
                    TextButton(onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CleaningQueueScreen())).then((_) => _load()), child: const Text('Open queue')),
                  ]),
                  const SizedBox(height: 8),
                  _StatGrid(items: [
                    ('Cleaned today', '${d.cleanedToday}', LsColors.green),
                    ('Pending cleaning', '${d.pendingCleaning}', d.pendingCleaning > 0 ? LsColors.orange : null),
                    ('Overdue', '${d.overdue}', d.overdue > 0 ? LsColors.red : null),
                    ('Compliance', '${d.cleaningCompliancePct}%', d.cleaningCompliancePct >= 90 ? LsColors.green : LsColors.orange),
                  ]),
                ],
              ),
      ),
    );
  }
}

class _StatGrid extends StatelessWidget {
  final List<(String, String, Color?)> items;
  const _StatGrid({required this.items});
  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 1.9,
      children: items
          .map((it) => Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text(it.$1.toUpperCase(), style: const TextStyle(color: LsColors.muted, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.4)),
                    const SizedBox(height: 4),
                    Text(it.$2, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: it.$3 ?? LsColors.text)),
                  ]),
                ),
              ))
          .toList(),
    );
  }
}
