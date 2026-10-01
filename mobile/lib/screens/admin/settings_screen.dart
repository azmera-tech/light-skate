import 'dart:convert';
import 'package:flutter/material.dart';
import '../../api/api_client.dart';
import '../../models/me.dart';
import '../../models/waiver.dart';
import '../../theme.dart';
import '../../widgets/reason_dialog.dart';

class _WarningRow {
  final TextEditingController minutes;
  String level;
  _WarningRow(int minutes, this.level) : minutes = TextEditingController(text: '$minutes');
}

class _PaymentMethodRow {
  final String code;
  final TextEditingController label;
  bool requiresReference;
  bool enabled;
  _PaymentMethodRow({required this.code, required String label, required this.requiresReference, required this.enabled})
      : label = TextEditingController(text: label);
}

/// GET/PUT /settings (settings.manage) + PUT /capacity (capacity.manage, separate permission) +
/// GET /waivers/current + POST /waivers/versions (waiver.manage). A user with only
/// capacity.manage can't call GET /settings at all, so for them this screen loads just
/// /dashboard (for maxCapacity/occupancy) and renders the capacity card alone.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late ApiClient _api;
  late Me _me;
  bool _loading = true;
  String? _error;

  Map<String, dynamic>? _rawSettings; // last-saved server copy, for diffing
  bool get _canFull => _me.can('settings.manage');
  bool get _canCapacity => _me.can('capacity.manage');
  bool get _canWaiver => _me.can('waiver.manage');

  // Capacity
  final _capacityCtrl = TextEditingController();
  int? _occupancy;
  bool _savingCapacity = false;

  // Timers & warnings
  final _expiringCtrl = TextEditingController();
  List<_WarningRow> _warnings = [];

  // Pausing & extensions
  bool _pauseEnabled = false;
  bool _pauseCounts = false;
  final _extensionOptionsCtrl = TextEditingController();
  final _earlyExitGraceCtrl = TextEditingController();
  final _noShowMinutesCtrl = TextEditingController();

  // Check-in
  bool _waiverRequired = false;
  final _minorAgeCtrl = TextEditingController();
  String _photoCapture = 'NEW_CUSTOMER';
  bool _wristbandsEnabled = false;
  final _wristbandColorsCtrl = TextEditingController();
  bool _equipmentRequiredForStart = false;
  bool _inspectOnReturn = false;
  bool _enforceOperatingHours = false;
  final _operatingHoursCtrl = TextEditingController();
  final _weekendDaysCtrl = TextEditingController();
  final _holidaysCtrl = TextEditingController();

  // Payment methods
  List<_PaymentMethodRow> _paymentMethods = [];

  // Retention
  final _retProfilePhotoCtrl = TextEditingController();
  final _retVisitPhotoCtrl = TextEditingController();
  final _retIncidentCtrl = TextEditingController();

  // Emergency
  final _ambulanceCtrl = TextEditingController();
  final _policeCtrl = TextEditingController();
  final _fireCtrl = TextEditingController();
  final _venueContactCtrl = TextEditingController();
  final _managerCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _firstAidCtrl = TextEditingController();

  bool _saving = false;
  bool _dirty = false;

  // Waiver
  CurrentWaiver? _waiver;
  bool _loadingWaiver = false;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _capacityCtrl.dispose();
    _expiringCtrl.dispose();
    _extensionOptionsCtrl.dispose();
    _earlyExitGraceCtrl.dispose();
    _noShowMinutesCtrl.dispose();
    _minorAgeCtrl.dispose();
    _wristbandColorsCtrl.dispose();
    _operatingHoursCtrl.dispose();
    _weekendDaysCtrl.dispose();
    _holidaysCtrl.dispose();
    _retProfilePhotoCtrl.dispose();
    _retVisitPhotoCtrl.dispose();
    _retIncidentCtrl.dispose();
    _ambulanceCtrl.dispose();
    _policeCtrl.dispose();
    _fireCtrl.dispose();
    _venueContactCtrl.dispose();
    _managerCtrl.dispose();
    _addressCtrl.dispose();
    _firstAidCtrl.dispose();
    for (final w in _warnings) {
      w.minutes.dispose();
    }
    for (final p in _paymentMethods) {
      p.label.dispose();
    }
    super.dispose();
  }

  Future<void> _boot() async {
    _api = await ApiClient.instance();
    _me = _api.me!;
    await _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (_canFull) {
        final json = await _api.get('/settings') as Map<String, dynamic>;
        final settings = (json['settings'] as Map<String, dynamic>?) ?? const {};
        _applySettings(settings);
        _capacityCtrl.text = '${json['maxCapacity'] ?? ''}';
        _loadWaiver();
      } else if (_canCapacity) {
        final dash = await _api.get('/dashboard') as Map<String, dynamic>;
        final cap = dash['capacity'] as Map<String, dynamic>? ?? const {};
        _capacityCtrl.text = '${cap['max'] ?? ''}';
        _occupancy = cap['occupancy'] as int?;
      }
      if (!mounted) return;
      setState(() {
        _loading = false;
        _dirty = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _loadWaiver() async {
    setState(() => _loadingWaiver = true);
    try {
      final json = await _api.get('/waivers/current') as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _waiver = CurrentWaiver.fromJson(json);
        _loadingWaiver = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingWaiver = false);
    }
  }

  void _applySettings(Map<String, dynamic> s) {
    _rawSettings = jsonDecode(jsonEncode(s)) as Map<String, dynamic>; // deep copy for diffing

    for (final w in _warnings) {
      w.minutes.dispose();
    }
    for (final p in _paymentMethods) {
      p.label.dispose();
    }

    _expiringCtrl.text = '${s['expiringMinutes'] ?? 0}';
    _warnings = ((s['warnings'] as List?) ?? const [])
        .map((w) => _WarningRow((w['minutes'] as num?)?.toInt() ?? 0, (w['level'] as String?) ?? 'YELLOW'))
        .toList();

    final pause = (s['pause'] as Map<String, dynamic>?) ?? const {};
    _pauseEnabled = (pause['enabled'] as bool?) ?? false;
    _pauseCounts = (pause['countsTowardTime'] as bool?) ?? false;
    _extensionOptionsCtrl.text = ((s['extensionOptionsMinutes'] as List?) ?? const []).join(', ');
    _earlyExitGraceCtrl.text = '${s['earlyExitGraceSeconds'] ?? 0}';
    _noShowMinutesCtrl.text = '${s['noShowMinutes'] ?? 0}';

    _waiverRequired = (s['waiverRequired'] as bool?) ?? false;
    _minorAgeCtrl.text = '${s['minorAgeYears'] ?? 0}';
    _photoCapture = (s['photoCapture'] as String?) ?? 'NEW_CUSTOMER';
    final wristbands = (s['wristbands'] as Map<String, dynamic>?) ?? const {};
    _wristbandsEnabled = (wristbands['enabled'] as bool?) ?? false;
    _wristbandColorsCtrl.text = ((wristbands['colors'] as List?) ?? const []).join(', ');
    _equipmentRequiredForStart = (s['equipmentRequiredForStart'] as bool?) ?? false;
    _inspectOnReturn = (s['inspectOnReturn'] as bool?) ?? false;
    _enforceOperatingHours = (s['enforceOperatingHours'] as bool?) ?? false;
    _operatingHoursCtrl.text = const JsonEncoder.withIndent('  ').convert(s['operatingHours'] ?? {});
    _weekendDaysCtrl.text = ((s['weekendDays'] as List?) ?? const []).join(', ');
    _holidaysCtrl.text = const JsonEncoder.withIndent('  ').convert(s['holidays'] ?? []);

    _paymentMethods = ((s['paymentMethods'] as List?) ?? const [])
        .map((m) => _PaymentMethodRow(
              code: (m['code'] as String?) ?? '',
              label: (m['label'] as String?) ?? '',
              requiresReference: (m['requiresReference'] as bool?) ?? false,
              enabled: (m['enabled'] as bool?) ?? true,
            ))
        .toList();

    final retention = (s['retention'] as Map<String, dynamic>?) ?? const {};
    _retProfilePhotoCtrl.text = '${retention['profilePhotoDays'] ?? 0}';
    _retVisitPhotoCtrl.text = '${retention['visitPhotoDays'] ?? 0}';
    _retIncidentCtrl.text = '${retention['incidentAttachmentDays'] ?? 0}';

    final emergency = (s['emergency'] as Map<String, dynamic>?) ?? const {};
    _ambulanceCtrl.text = (emergency['ambulance'] as String?) ?? '';
    _policeCtrl.text = (emergency['police'] as String?) ?? '';
    _fireCtrl.text = (emergency['fire'] as String?) ?? '';
    _venueContactCtrl.text = (emergency['venueContact'] as String?) ?? '';
    _managerCtrl.text = (emergency['manager'] as String?) ?? '';
    _addressCtrl.text = (emergency['address'] as String?) ?? '';
    _firstAidCtrl.text = (emergency['firstAid'] as String?) ?? '';
  }

  List<int> _parseIntList(String s) =>
      s.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).map((e) => int.tryParse(e) ?? 0).toList();

  List<String> _parseStrList(String s) => s.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  /// Reconstructs the full settings.manage-controlled payload from current form state.
  Map<String, dynamic> _buildFullPayload() {
    dynamic operatingHours;
    try {
      operatingHours = jsonDecode(_operatingHoursCtrl.text);
    } catch (_) {
      operatingHours = _rawSettings?['operatingHours'] ?? {};
    }
    dynamic holidays;
    try {
      holidays = jsonDecode(_holidaysCtrl.text);
    } catch (_) {
      holidays = _rawSettings?['holidays'] ?? [];
    }
    return {
      'expiringMinutes': int.tryParse(_expiringCtrl.text) ?? 0,
      'warnings': _warnings.map((w) => {'minutes': int.tryParse(w.minutes.text) ?? 0, 'level': w.level}).toList(),
      'pause': {'enabled': _pauseEnabled, 'countsTowardTime': _pauseCounts},
      'extensionOptionsMinutes': _parseIntList(_extensionOptionsCtrl.text),
      'earlyExitGraceSeconds': int.tryParse(_earlyExitGraceCtrl.text) ?? 0,
      'noShowMinutes': int.tryParse(_noShowMinutesCtrl.text) ?? 0,
      'waiverRequired': _waiverRequired,
      'minorAgeYears': int.tryParse(_minorAgeCtrl.text) ?? 0,
      'photoCapture': _photoCapture,
      'wristbands': {'enabled': _wristbandsEnabled, 'colors': _parseStrList(_wristbandColorsCtrl.text)},
      'equipmentRequiredForStart': _equipmentRequiredForStart,
      'inspectOnReturn': _inspectOnReturn,
      'enforceOperatingHours': _enforceOperatingHours,
      'operatingHours': operatingHours,
      'weekendDays': _parseIntList(_weekendDaysCtrl.text),
      'holidays': holidays,
      'paymentMethods': _paymentMethods
          .map((p) => {'code': p.code, 'label': p.label.text, 'requiresReference': p.requiresReference, 'enabled': p.enabled})
          .toList(),
      'retention': {
        'profilePhotoDays': int.tryParse(_retProfilePhotoCtrl.text) ?? 0,
        'visitPhotoDays': int.tryParse(_retVisitPhotoCtrl.text) ?? 0,
        'incidentAttachmentDays': int.tryParse(_retIncidentCtrl.text) ?? 0,
      },
      'emergency': {
        'ambulance': _ambulanceCtrl.text,
        'police': _policeCtrl.text,
        'fire': _fireCtrl.text,
        'venueContact': _venueContactCtrl.text,
        'manager': _managerCtrl.text,
        'address': _addressCtrl.text,
        'firstAid': _firstAidCtrl.text,
      },
    };
  }

  Map<String, dynamic> _diff() {
    final full = _buildFullPayload();
    final raw = _rawSettings ?? const {};
    final out = <String, dynamic>{};
    for (final entry in full.entries) {
      if (jsonEncode(entry.value) != jsonEncode(raw[entry.key])) out[entry.key] = entry.value;
    }
    return out;
  }

  void _markDirty() => setState(() => _dirty = _diff().isNotEmpty);

  Future<void> _save() async {
    final body = _diff();
    if (body.isEmpty) return;
    setState(() => _saving = true);
    try {
      await _api.put('/settings', body);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Settings saved.')));
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveCapacity() async {
    final value = int.tryParse(_capacityCtrl.text);
    if (value == null || value < 1) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a valid capacity.')));
      return;
    }
    final reason = await showReasonDialog(context, title: 'Change max capacity', label: 'Reason', minLength: 3);
    if (reason == null) return;
    setState(() => _savingCapacity = true);
    try {
      final res = await _api.put('/capacity', {'maxCapacity': value, 'reason': reason});
      if (!mounted) return;
      setState(() {
        _occupancy = (res as Map<String, dynamic>)['occupancy'] as int?;
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Capacity updated.')));
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _savingCapacity = false);
    }
  }

  Future<void> _publishWaiver() async {
    final titleCtrl = TextEditingController();
    final bodyCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(builder: (context, setDState) {
        final valid = titleCtrl.text.trim().length >= 3 && bodyCtrl.text.trim().length >= 20;
        return AlertDialog(
          title: const Text('Publish new waiver version'),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: titleCtrl, decoration: const InputDecoration(labelText: 'Title'), onChanged: (_) => setDState(() {})),
              const SizedBox(height: 10),
              TextField(
                controller: bodyCtrl,
                decoration: const InputDecoration(labelText: 'Body (min 20 characters)'),
                maxLines: 8,
                onChanged: (_) => setDState(() {}),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: valid ? () => Navigator.pop(context, true) : null, child: const Text('Publish')),
          ],
        );
      }),
    );
    if (ok != true) return;
    try {
      await _api.post('/waivers/versions', {'title': titleCtrl.text.trim(), 'body': bodyCtrl.text.trim(), 'language': 'en'});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('New waiver version published.')));
      await _loadWaiver();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          if (_canFull)
            TextButton(
              onPressed: (_dirty && !_saving) ? _save : null,
              child: _saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save changes'),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorView(message: _error!, onRetry: _load)
              : !_canFull && !_canCapacity
                  ? const Center(child: Text('No settings access.'))
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(
                        padding: const EdgeInsets.all(14),
                        children: [
                          _capacityCard(),
                          if (_canFull) ...[
                            const SizedBox(height: 14),
                            _section('Timers & warnings', [
                              _numberField('Session expiring warning threshold (minutes)', _expiringCtrl),
                              const SizedBox(height: 10),
                              const Text('Warning levels', style: TextStyle(fontWeight: FontWeight.w600)),
                              ..._warnings.asMap().entries.map((e) => _warningRow(e.key, e.value)),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: TextButton.icon(
                                  onPressed: () => setState(() {
                                    _warnings.add(_WarningRow(10, 'YELLOW'));
                                    _markDirty();
                                  }),
                                  icon: const Icon(Icons.add),
                                  label: const Text('Add warning level'),
                                ),
                              ),
                            ]),
                            _section('Pausing & extensions', [
                              SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('Allow pausing sessions'),
                                value: _pauseEnabled,
                                onChanged: (v) => setState(() {
                                  _pauseEnabled = v;
                                  _markDirty();
                                }),
                              ),
                              SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('Pause counts toward session time'),
                                value: _pauseCounts,
                                onChanged: (v) => setState(() {
                                  _pauseCounts = v;
                                  _markDirty();
                                }),
                              ),
                              _textField('Extension options (minutes, comma-separated)', _extensionOptionsCtrl),
                              const SizedBox(height: 10),
                              _numberField('Early exit grace period (seconds)', _earlyExitGraceCtrl),
                              const SizedBox(height: 10),
                              _numberField('No-show threshold (minutes)', _noShowMinutesCtrl),
                            ]),
                            _section('Check-in', [
                              SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('Waiver required'),
                                value: _waiverRequired,
                                onChanged: (v) => setState(() {
                                  _waiverRequired = v;
                                  _markDirty();
                                }),
                              ),
                              _numberField('Minor age threshold (years)', _minorAgeCtrl),
                              const SizedBox(height: 10),
                              DropdownButtonFormField<String>(
                                initialValue: _photoCapture,
                                decoration: const InputDecoration(labelText: 'Photo capture'),
                                items: const [
                                  DropdownMenuItem(value: 'NEW_CUSTOMER', child: Text('New customer only')),
                                  DropdownMenuItem(value: 'EVERY_VISIT', child: Text('Every visit')),
                                  DropdownMenuItem(value: 'NEVER', child: Text('Never')),
                                ],
                                onChanged: (v) => setState(() {
                                  _photoCapture = v ?? 'NEW_CUSTOMER';
                                  _markDirty();
                                }),
                              ),
                              const SizedBox(height: 10),
                              SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('Wristbands enabled'),
                                value: _wristbandsEnabled,
                                onChanged: (v) => setState(() {
                                  _wristbandsEnabled = v;
                                  _markDirty();
                                }),
                              ),
                              _textField('Wristband colors (comma-separated)', _wristbandColorsCtrl),
                              const SizedBox(height: 10),
                              SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('Equipment required to start a session'),
                                value: _equipmentRequiredForStart,
                                onChanged: (v) => setState(() {
                                  _equipmentRequiredForStart = v;
                                  _markDirty();
                                }),
                              ),
                              SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('Inspect equipment on return'),
                                value: _inspectOnReturn,
                                onChanged: (v) => setState(() {
                                  _inspectOnReturn = v;
                                  _markDirty();
                                }),
                              ),
                              SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: const Text('Enforce operating hours'),
                                value: _enforceOperatingHours,
                                onChanged: (v) => setState(() {
                                  _enforceOperatingHours = v;
                                  _markDirty();
                                }),
                              ),
                              _textField('Weekend days (0=Sun .. 6=Sat, comma-separated)', _weekendDaysCtrl),
                              const SizedBox(height: 10),
                              _jsonField('Operating hours (JSON)', _operatingHoursCtrl),
                              const SizedBox(height: 10),
                              _jsonField('Holidays (JSON array)', _holidaysCtrl),
                            ]),
                            _section('Payment methods', [
                              ..._paymentMethods.map(_paymentMethodRow),
                            ]),
                            _section('Data retention (days)', [
                              _numberField('Profile photos', _retProfilePhotoCtrl),
                              const SizedBox(height: 10),
                              _numberField('Visit photos', _retVisitPhotoCtrl),
                              const SizedBox(height: 10),
                              _numberField('Incident attachments', _retIncidentCtrl),
                            ]),
                            _section('Emergency info', [
                              _textField('Ambulance', _ambulanceCtrl),
                              const SizedBox(height: 10),
                              _textField('Police', _policeCtrl),
                              const SizedBox(height: 10),
                              _textField('Fire', _fireCtrl),
                              const SizedBox(height: 10),
                              _textField('Venue contact', _venueContactCtrl),
                              const SizedBox(height: 10),
                              _textField('Manager', _managerCtrl),
                              const SizedBox(height: 10),
                              _textField('Address', _addressCtrl),
                              const SizedBox(height: 10),
                              _textField('First aid notes', _firstAidCtrl),
                            ]),
                            _waiverSection(),
                          ],
                          const SizedBox(height: 24),
                        ],
                      ),
                    ),
    );
  }

  Widget _capacityCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Capacity', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 10),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: TextField(
                controller: _capacityCtrl,
                enabled: _canCapacity,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Max capacity'),
              ),
            ),
            const SizedBox(width: 12),
            if (_occupancy != null)
              Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Text('Occupancy: $_occupancy', style: const TextStyle(color: LsColors.muted)),
              ),
          ]),
          if (_canCapacity) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: _savingCapacity ? null : _saveCapacity,
                child: _savingCapacity ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Update capacity'),
              ),
            ),
          ] else
            const Padding(padding: EdgeInsets.only(top: 6), child: Text('Read-only — you lack permission to change capacity.', style: TextStyle(color: LsColors.muted, fontSize: 12))),
        ]),
      ),
    );
  }

  Widget _waiverSection() {
    if (!_canWaiver && _waiver == null && !_loadingWaiver) return const SizedBox.shrink();
    return _section('Waiver', [
      if (_loadingWaiver)
        const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()))
      else if (_waiver != null) ...[
        Text('Current version: v${_waiver!.version} — ${_waiver!.title}', style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        TextButton(
          onPressed: () => showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(_waiver!.title),
              content: SizedBox(width: 400, child: SingleChildScrollView(child: Text(_waiver!.body))),
              actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
            ),
          ),
          child: const Text('View full text'),
        ),
      ] else
        const Text('No waiver on file.', style: TextStyle(color: LsColors.muted)),
      if (_canWaiver) ...[
        const SizedBox(height: 8),
        Align(alignment: Alignment.centerLeft, child: OutlinedButton.icon(onPressed: _publishWaiver, icon: const Icon(Icons.add), label: const Text('Publish new version'))),
      ],
    ]);
  }

  Widget _warningRow(int index, _WarningRow w) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(children: [
        Expanded(
          child: TextField(
            controller: w.minutes,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Minutes before end'),
            onChanged: (_) => _markDirty(),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue: w.level,
            decoration: const InputDecoration(labelText: 'Level'),
            items: const [
              DropdownMenuItem(value: 'YELLOW', child: Text('Yellow')),
              DropdownMenuItem(value: 'ORANGE', child: Text('Orange')),
              DropdownMenuItem(value: 'RED', child: Text('Red')),
            ],
            onChanged: (v) => setState(() {
              w.level = v ?? 'YELLOW';
              _markDirty();
            }),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline, color: LsColors.red),
          onPressed: () => setState(() {
            _warnings.removeAt(index);
            _markDirty();
          }),
        ),
      ]),
    );
  }

  Widget _paymentMethodRow(_PaymentMethodRow p) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        SizedBox(width: 90, child: Text(p.code, style: const TextStyle(fontWeight: FontWeight.w600))),
        Expanded(child: TextField(controller: p.label, decoration: const InputDecoration(labelText: 'Label'), onChanged: (_) => _markDirty())),
        const SizedBox(width: 8),
        Column(children: [
          const Text('Ref. req.', style: TextStyle(fontSize: 10, color: LsColors.muted)),
          Checkbox(
            value: p.requiresReference,
            onChanged: (v) => setState(() {
              p.requiresReference = v ?? false;
              _markDirty();
            }),
          ),
        ]),
        Column(children: [
          const Text('Enabled', style: TextStyle(fontSize: 10, color: LsColors.muted)),
          Checkbox(
            value: p.enabled,
            onChanged: (v) => setState(() {
              p.enabled = v ?? false;
              _markDirty();
            }),
          ),
        ]),
      ]),
    );
  }

  Widget _section(String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 10),
            ...children,
          ]),
        ),
      ),
    );
  }

  Widget _textField(String label, TextEditingController ctrl) =>
      TextField(controller: ctrl, decoration: InputDecoration(labelText: label), onChanged: (_) => _markDirty());

  Widget _numberField(String label, TextEditingController ctrl) => TextField(
        controller: ctrl,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: label),
        onChanged: (_) => _markDirty(),
      );

  Widget _jsonField(String label, TextEditingController ctrl) => TextField(
        controller: ctrl,
        maxLines: 5,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        decoration: InputDecoration(labelText: label),
        onChanged: (_) => _markDirty(),
      );
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorView({required this.message, required this.onRetry});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.error_outline, color: LsColors.red, size: 36),
          const SizedBox(height: 10),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 14),
          OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
        ]),
      ),
    );
  }
}
