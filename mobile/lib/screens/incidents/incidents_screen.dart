import 'dart:async';
import 'package:flutter/material.dart';
import '../../api/api_client.dart';
import '../../models/incident.dart';
import '../../models/me.dart';
import '../../theme.dart';
import '../../widgets/status_badge.dart';
import '../../format.dart';
import 'incident_form_screen.dart';
import 'incident_detail_screen.dart';

const _incidentStatusLabels = {
  'REPORTED': 'Reported',
  'ACKNOWLEDGED': 'Acknowledged',
  'ACTION_TAKEN': 'Action taken',
  'UNDER_REVIEW': 'Under review',
  'CLOSED': 'Closed',
};

String incidentStatusLevel(String status) => switch (status) {
      'REPORTED' => 'yellow',
      'ACKNOWLEDGED' => 'info',
      'ACTION_TAKEN' => 'orange',
      'UNDER_REVIEW' => 'paused',
      'CLOSED' => 'normal',
      _ => 'gray',
    };

IconData incidentStatusIcon(String status) => switch (status) {
      'REPORTED' => Icons.fiber_new_outlined,
      'ACKNOWLEDGED' => Icons.visibility_outlined,
      'ACTION_TAKEN' => Icons.build_outlined,
      'UNDER_REVIEW' => Icons.rate_review_outlined,
      'CLOSED' => Icons.check_circle_outline,
      _ => Icons.circle,
    };

String incidentSeverityLevel(String severity) => switch (severity) {
      'MINOR' => 'gray',
      'MODERATE' => 'yellow',
      'SERIOUS' => 'orange',
      'CRITICAL' => 'red',
      _ => 'gray',
    };

/// Incidents tab — bare body widget hosted inside AppShell's IndexedStack (no own Scaffold/AppBar),
/// same convention as DashboardScreen.
class IncidentsScreen extends StatefulWidget {
  const IncidentsScreen({super.key});
  @override
  State<IncidentsScreen> createState() => _IncidentsScreenState();
}

class _IncidentsScreenState extends State<IncidentsScreen> {
  late ApiClient _api;
  Me? _me;
  List<IncidentRecord>? _incidents;
  bool _redacted = false;
  String? _error;
  bool _openOnly = true;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    _api = await ApiClient.instance();
    _me = _api.me;
    await _load();
    _poll = Timer.periodic(const Duration(seconds: 10), (_) => _load(silent: true));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    try {
      final path = _openOnly ? '/incidents?open=true' : '/incidents';
      final json = await _api.get(path) as Map<String, dynamic>;
      final redacted = (json['redacted'] as bool?) ?? false;
      final rows = (json['incidents'] as List? ?? const []).map((e) => IncidentRecord.fromJson(e as Map<String, dynamic>, redacted: redacted)).toList();
      if (!mounted) return;
      setState(() {
        _incidents = rows;
        _redacted = redacted;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      if (!silent) setState(() => _error = e.toString());
    }
  }

  void _openForm() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const IncidentFormScreen())).then((_) => _load(silent: true));
  }

  void _openDetail(String id) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => IncidentDetailScreen(incidentId: id))).then((_) => _load(silent: true));
  }

  @override
  Widget build(BuildContext context) {
    final me = _me;
    if (me == null) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: () => _load(),
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          Row(children: [
            Expanded(child: Text('Incidents', style: Theme.of(context).textTheme.headlineSmall)),
            if (me.can('incident.create')) FilledButton.icon(onPressed: _openForm, icon: const Icon(Icons.add), label: const Text('Report incident')),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Checkbox(
              value: _openOnly,
              onChanged: (v) {
                setState(() => _openOnly = v ?? true);
                _load(silent: true);
              },
            ),
            const Text('Open only'),
          ]),
          if (_redacted)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(color: LsColors.brandSoft, borderRadius: BorderRadius.circular(10)),
              child: const Row(children: [
                Icon(Icons.info_outline, color: LsColors.brandStrong, size: 20),
                SizedBox(width: 10),
                Expanded(child: Text('You can see only the incidents you reported, without personal details.', style: TextStyle(color: LsColors.brandStrong, fontWeight: FontWeight.w600))),
              ]),
            ),
          const SizedBox(height: 4),
          if (_error != null && _incidents == null)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(children: [
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 10),
                OutlinedButton(onPressed: () => _load(), child: const Text('Retry')),
              ]),
            )
          else if (_incidents == null)
            const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
          else if (_incidents!.isEmpty)
            const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('No incidents to show.', style: TextStyle(color: LsColors.muted))))
          else
            ..._incidents!.map((inc) => _IncidentTile(incident: inc, onTap: () => _openDetail(inc.id))),
        ],
      ),
    );
  }
}

class _IncidentTile extends StatelessWidget {
  final IncidentRecord incident;
  final VoidCallback onTap;
  const _IncidentTile({required this.incident, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text('#${incident.incidentNumber}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
              LsBadge(label: titleCase(incident.severity), level: incidentSeverityLevel(incident.severity), icon: Icons.priority_high),
              const SizedBox(width: 6),
              LsBadge(label: _incidentStatusLabels[incident.status] ?? incident.status, level: incidentStatusLevel(incident.status), icon: incidentStatusIcon(incident.status)),
            ]),
            const SizedBox(height: 6),
            Text('${titleCase(incident.incidentType)} · ${fmtDate(incident.occurredAt)} ${fmtHHMM(incident.occurredAt)}${incident.location != null ? ' · ${incident.location}' : ''}', style: const TextStyle(color: LsColors.muted, fontSize: 13)),
            if (incident.customerName != null || incident.reportedByName != null) ...[
              const SizedBox(height: 4),
              Text(
                [
                  if (incident.customerName != null) 'Customer: ${incident.customerName}',
                  if (incident.reportedByName != null) 'Reported by: ${incident.reportedByName}',
                ].join(' · '),
                style: const TextStyle(fontSize: 12.5),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}
