import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../../api/api_client.dart';
import '../../models/incident.dart';
import '../../models/me.dart';
import '../../theme.dart';
import '../../format.dart';
import '../../widgets/status_badge.dart';
import '../../widgets/reason_dialog.dart';
import 'incidents_screen.dart' show incidentSeverityLevel, incidentStatusLevel, incidentStatusIcon;

/// Fetches one incident attachment's raw bytes with the auth header, mirroring the pattern in
/// ApiClient.photoBytes() (that method is private/scoped to photos; this is the incidents
/// equivalent, kept local to this file rather than touching api_client.dart).
Future<Uint8List> _fetchAttachmentBytes(ApiClient api, String attachmentId) async {
  final headers = <String, String>{};
  final token = api.authTokenForRealtime;
  if (token != null) headers['authorization'] = 'Bearer $token';
  final res = await http.get(Uri.parse('${api.baseUrl}/api/v1/incident-attachments/$attachmentId/content'), headers: headers).timeout(const Duration(seconds: 20));
  if (res.statusCode != 200) throw ApiException(res.statusCode, 'ATTACHMENT', 'Photo unavailable.');
  return res.bodyBytes;
}

const _statusLabels = {
  'REPORTED': 'Reported',
  'ACKNOWLEDGED': 'Acknowledged',
  'ACTION_TAKEN': 'Action taken',
  'UNDER_REVIEW': 'Under review',
  'CLOSED': 'Closed',
};

/// Full incident detail, pushed from the incidents list. Own Scaffold + AppBar.
class IncidentDetailScreen extends StatefulWidget {
  final String incidentId;
  const IncidentDetailScreen({super.key, required this.incidentId});
  @override
  State<IncidentDetailScreen> createState() => _IncidentDetailScreenState();
}

class _IncidentDetailScreenState extends State<IncidentDetailScreen> {
  late ApiClient _api;
  Me? _me;
  IncidentDetail? _detail;
  bool _redacted = false;
  String? _error;
  bool _busy = false;
  final Map<String, Uint8List> _photoCache = {};

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    _api = await ApiClient.instance();
    _me = _api.me;
    await _load();
  }

  Future<void> _load() async {
    try {
      final json = await _api.get('/incidents/${widget.incidentId}') as Map<String, dynamic>;
      final redacted = (json['redacted'] as bool?) ?? false;
      final incidentJson = (json['incident'] as Map<String, dynamic>?) ?? json;
      final events = ((json['events'] as List?) ?? const []).map((e) => IncidentEvent.fromJson(e as Map<String, dynamic>)).toList();
      final attachments = ((json['attachments'] as List?) ?? const []).map((e) => IncidentAttachment.fromJson(e as Map<String, dynamic>)).toList();
      if (!mounted) return;
      setState(() {
        _detail = IncidentDetail(
          incident: IncidentRecord.fromJson(incidentJson, redacted: redacted),
          events: events,
          attachments: attachments,
        );
        _redacted = redacted;
        _error = null;
      });
      _prefetchPhotos(attachments);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  Future<void> _prefetchPhotos(List<IncidentAttachment> attachments) async {
    for (final a in attachments) {
      if (_photoCache.containsKey(a.id)) continue;
      try {
        final bytes = await _fetchAttachmentBytes(_api, a.id);
        _photoCache[a.id] = bytes;
        if (mounted) setState(() {});
      } catch (_) {
        // Leave this one out of the cache; the tile below just won't render it.
      }
    }
  }

  Future<void> _transition(String to) async {
    final severity = _detail!.incident.severity;
    final requiresNote = to == 'CLOSED' && (severity == 'SERIOUS' || severity == 'CRITICAL');
    final note = await showReasonDialog(
      context,
      title: to == 'CLOSED' ? 'Close incident' : 'Mark as ${titleCase(to)}',
      label: requiresNote ? 'Closing note (required for this severity)' : 'Note (optional)',
      minLength: requiresNote ? 3 : 0,
      confirmLabel: to == 'CLOSED' ? 'Close incident' : 'Confirm',
      danger: to == 'CLOSED',
    );
    if (note == null) return;
    setState(() => _busy = true);
    try {
      await _api.post('/incidents/${widget.incidentId}/transition', {'to': to, 'note': note.isEmpty ? null : note});
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
    final d = _detail;
    return Scaffold(
      appBar: AppBar(title: Text(d != null ? 'Incident #${d.incident.incidentNumber}' : 'Incident')),
      body: d == null
          ? Center(child: _error != null ? _ErrorBox(message: _error!, onRetry: _load) : const CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_redacted)
                    Container(
                      margin: const EdgeInsets.only(bottom: 14),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(color: LsColors.brandSoft, borderRadius: BorderRadius.circular(10)),
                      child: const Row(children: [
                        Icon(Icons.info_outline, color: LsColors.brandStrong, size: 20),
                        SizedBox(width: 10),
                        Expanded(child: Text('Limited view — personal details are hidden.', style: TextStyle(color: LsColors.brandStrong, fontWeight: FontWeight.w600))),
                      ]),
                    ),
                  _buildHeader(d.incident),
                  const SizedBox(height: 16),
                  _buildDescriptionCard(d.incident),
                  if (d.attachments.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text('Photos', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    _buildPhotos(d.attachments),
                  ],
                  if (_me != null && _me!.can('incident.manage') && d.incident.status != 'CLOSED') ...[
                    const SizedBox(height: 16),
                    Text('Update status', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    _buildTransitionButtons(d.incident.status),
                  ],
                  const SizedBox(height: 18),
                  Text('Event history', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  if (d.events.isEmpty)
                    const Text('No events recorded.', style: TextStyle(color: LsColors.muted))
                  else
                    ...([...d.events]..sort((a, b) => b.occurredAt.compareTo(a.occurredAt))).map((e) => _EventTile(event: e)),
                ],
              ),
            ),
    );
  }

  Widget _buildHeader(IncidentRecord inc) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(titleCase(inc.incidentType), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
            LsBadge(label: titleCase(inc.severity), level: incidentSeverityLevel(inc.severity), icon: Icons.priority_high),
            const SizedBox(width: 6),
            LsBadge(label: _statusLabels[inc.status] ?? inc.status, level: incidentStatusLevel(inc.status), icon: incidentStatusIcon(inc.status)),
          ]),
          const SizedBox(height: 8),
          Text('${fmtDate(inc.occurredAt)} ${fmtHHMM(inc.occurredAt)}${inc.location != null ? ' · ${inc.location}' : ''}', style: const TextStyle(color: LsColors.muted)),
          if (inc.customerName != null || inc.reportedByName != null) ...[
            const SizedBox(height: 8),
            if (inc.customerName != null) Text('Customer: ${inc.customerName}'),
            if (inc.reportedByName != null) Text('Reported by: ${inc.reportedByName}'),
          ],
        ]),
      ),
    );
  }

  Widget _buildDescriptionCard(IncidentRecord inc) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Description', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(inc.description ?? '—'),
          if (inc.actionTaken != null && inc.actionTaken!.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text('Action taken', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            Text(inc.actionTaken!),
          ],
        ]),
      ),
    );
  }

  Widget _buildPhotos(List<IncidentAttachment> attachments) {
    return SizedBox(
      height: 100,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: attachments.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final a = attachments[i];
          final bytes = _photoCache[a.id];
          return ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Container(
              width: 100,
              height: 100,
              color: LsColors.surface2,
              child: bytes != null
                  ? Image.memory(bytes, fit: BoxFit.cover, width: 100, height: 100)
                  : const Center(child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
            ),
          );
        },
      ),
    );
  }

  Widget _buildTransitionButtons(String status) {
    final options = incidentTransitions[status] ?? const [];
    if (options.isEmpty) return const Text('No further transitions available.', style: TextStyle(color: LsColors.muted));
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: options.map((to) {
        final isClose = to == 'CLOSED';
        final label = _statusLabels[to] ?? titleCase(to);
        return isClose
            ? FilledButton(onPressed: _busy ? null : () => _transition(to), child: Text(label))
            : OutlinedButton(onPressed: _busy ? null : () => _transition(to), child: Text(label));
      }).toList(),
    );
  }
}

class _EventTile extends StatelessWidget {
  final IncidentEvent event;
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
  final Future<void> Function() onRetry;
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
