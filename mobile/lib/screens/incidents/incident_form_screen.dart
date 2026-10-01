import 'package:flutter/material.dart';
import '../../api/api_client.dart';
import '../../models/dashboard.dart';
import '../../models/incident.dart';
import '../../theme.dart';
import '../../format.dart';
import '../../widgets/camera_capture.dart';
import 'incidents_screen.dart' show incidentSeverityLevel;

/// Report-incident form, pushed from IncidentsScreen. Own Scaffold + AppBar.
class IncidentFormScreen extends StatefulWidget {
  const IncidentFormScreen({super.key});
  @override
  State<IncidentFormScreen> createState() => _IncidentFormScreenState();
}

class _IncidentFormScreenState extends State<IncidentFormScreen> {
  late ApiClient _api;
  bool _ready = false;

  String _type = incidentTypes.first;
  String _severity = incidentSeverities.first;
  List<LiveSession> _liveSessions = const [];
  LiveSession? _selectedSession;
  final _descriptionCtrl = TextEditingController();
  final _actionCtrl = TextEditingController();
  final _locationCtrl = TextEditingController(text: 'Main rink');
  bool _managerNotified = false;

  bool _submitting = false;
  String? _error;
  String? _createdId;
  String? _createdNumber;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    _api = await ApiClient.instance();
    try {
      final json = await _api.get('/sessions?group=live');
      if (json is Map<String, dynamic>) {
        final raw = (json['sessions'] as List?) ?? (json['items'] as List?) ?? (json['liveSessions'] as List?) ?? const [];
        _liveSessions = raw.whereType<Map<String, dynamic>>().map(LiveSession.fromJson).toList();
      }
    } catch (_) {
      // Non-fatal: "who was involved" is optional, the report can still be filed without it.
    }
    if (mounted) setState(() => _ready = true);
  }

  @override
  void dispose() {
    _descriptionCtrl.dispose();
    _actionCtrl.dispose();
    _locationCtrl.dispose();
    super.dispose();
  }

  bool get _descriptionValid => _descriptionCtrl.text.trim().length >= 3;

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final body = <String, dynamic>{
        'customerId': null,
        'sessionId': _selectedSession?.id,
        'location': _locationCtrl.text.trim().isEmpty ? null : _locationCtrl.text.trim(),
        'incidentType': _type,
        'severity': _severity,
        'description': _descriptionCtrl.text.trim(),
        'actionTaken': _actionCtrl.text.trim().isEmpty ? null : _actionCtrl.text.trim(),
        'managerNotified': _managerNotified,
      };
      final res = await _api.post('/incidents', body) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _createdId = res['id'] as String?;
        _createdNumber = res['incidentNumber'] as String?;
        _submitting = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _submitting = false;
      });
    }
  }

  Future<void> _addPhoto() async {
    final id = _createdId;
    if (id == null) return;
    final bytes = await captureCustomerPhoto(context, title: 'Incident photo');
    if (bytes == null) return;
    try {
      await _api.postRawImage('/incidents/$id/attachments', bytes);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Photo attached.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_createdId != null) return _buildConfirmation();
    return Scaffold(
      appBar: AppBar(title: const Text('Report incident')),
      body: !_ready
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text('Type', style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: incidentTypes
                      .map((t) => ChoiceChip(label: Text(titleCase(t)), selected: _type == t, onSelected: (_) => setState(() => _type = t)))
                      .toList(),
                ),
                const SizedBox(height: 18),
                const Text('Severity', style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: incidentSeverities.map((s) {
                    final (fg, bg) = levelColors(incidentSeverityLevel(s));
                    final selected = _severity == s;
                    return ChoiceChip(
                      label: Text(titleCase(s)),
                      selected: selected,
                      selectedColor: bg,
                      labelStyle: TextStyle(color: selected ? fg : null, fontWeight: selected ? FontWeight.w700 : null),
                      onSelected: (_) => setState(() => _severity = s),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 18),
                if (_liveSessions.isNotEmpty) ...[
                  const Text('Who was involved (optional)', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<LiveSession?>(
                    initialValue: _selectedSession,
                    decoration: const InputDecoration(hintText: 'Not linked to a session'),
                    items: [
                      const DropdownMenuItem<LiveSession?>(value: null, child: Text('Not linked to a session')),
                      ..._liveSessions.map((s) => DropdownMenuItem<LiveSession?>(value: s, child: Text(s.customerName))),
                    ],
                    onChanged: (v) => setState(() => _selectedSession = v),
                  ),
                  const SizedBox(height: 18),
                ],
                TextField(
                  controller: _locationCtrl,
                  decoration: const InputDecoration(labelText: 'Location'),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _descriptionCtrl,
                  autofocus: true,
                  minLines: 3,
                  maxLines: 6,
                  decoration: const InputDecoration(labelText: 'What happened? *', alignLabelWithHint: true),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _actionCtrl,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: 'Action taken (optional)', alignLabelWithHint: true),
                ),
                const SizedBox(height: 10),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _managerNotified,
                  onChanged: (v) => setState(() => _managerNotified = v ?? false),
                  title: const Text('Manager has been told'),
                  controlAffinity: ListTileControlAffinity.leading,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 10),
                  Text(_error!, style: const TextStyle(color: LsColors.red)),
                ],
                const SizedBox(height: 18),
                FilledButton(
                  onPressed: (_descriptionValid && !_submitting) ? _submit : null,
                  child: _submitting ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('Submit report'),
                ),
              ],
            ),
    );
  }

  Widget _buildConfirmation() {
    return Scaffold(
      appBar: AppBar(title: const Text('Incident reported')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.check_circle, color: LsColors.green, size: 56),
          const SizedBox(height: 16),
          Text('Incident #$_createdNumber recorded', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700), textAlign: TextAlign.center),
          const SizedBox(height: 24),
          OutlinedButton.icon(onPressed: _addPhoto, icon: const Icon(Icons.camera_alt_outlined), label: const Text('Add a photo')),
          const SizedBox(height: 12),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Done')),
        ]),
      ),
    );
  }
}
