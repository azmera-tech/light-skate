import 'package:flutter/material.dart';
import '../../api/api_client.dart';
import '../../format.dart';
import '../../theme.dart';

const _deviceTypes = ['FRONT_DESK', 'RENTAL_DESK', 'MANAGER', 'KIOSK', 'OTHER'];

class _Device {
  final String id;
  String name;
  final String deviceType;
  String status; // ACTIVE | DISABLED
  final DateTime? lastSeenAt;
  final DateTime? registeredAt;
  _Device({required this.id, required this.name, required this.deviceType, required this.status, required this.lastSeenAt, required this.registeredAt});
  factory _Device.fromJson(Map<String, dynamic> j) => _Device(
        id: j['id'] as String,
        name: j['name'] as String,
        deviceType: (j['deviceType'] as String?) ?? 'OTHER',
        status: (j['status'] as String?) ?? 'ACTIVE',
        lastSeenAt: j['lastSeenAt'] == null ? null : DateTime.tryParse(j['lastSeenAt'] as String),
        registeredAt: j['registeredAt'] == null ? null : DateTime.tryParse(j['registeredAt'] as String),
      );
}

/// GET/POST/PATCH /devices (device.manage). A register form + a table with enable/disable
/// per row.
class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});
  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  late ApiClient _api;
  List<_Device> _devices = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _api = await ApiClient.instance();
      final json = await _api.get('/devices') as Map<String, dynamic>;
      final devices = ((json['devices'] as List?) ?? const []).map((e) => _Device.fromJson(e as Map<String, dynamic>)).toList();
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _toggleStatus(_Device d) async {
    final next = d.status == 'ACTIVE' ? 'DISABLED' : 'ACTIVE';
    final previous = d.status;
    setState(() => d.status = next);
    try {
      await _api.patch('/devices/${d.id}', {'status': next});
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => d.status = previous);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _rename(_Device d) async {
    final ctrl = TextEditingController(text: d.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename device'),
        content: TextField(controller: ctrl, decoration: const InputDecoration(labelText: 'Name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true || ctrl.text.trim().isEmpty) return;
    final previous = d.name;
    setState(() => d.name = ctrl.text.trim());
    try {
      await _api.patch('/devices/${d.id}', {'name': d.name});
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => d.name = previous);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _register() async {
    final nameCtrl = TextEditingController();
    String type = _deviceTypes.first;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(builder: (context, setDState) {
        return AlertDialog(
          title: const Text('Register device'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Device name')),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: type,
              decoration: const InputDecoration(labelText: 'Type'),
              items: _deviceTypes.map((t) => DropdownMenuItem(value: t, child: Text(titleCase(t)))).toList(),
              onChanged: (v) => setDState(() => type = v ?? type),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: nameCtrl.text.trim().isEmpty ? null : () => Navigator.pop(context, true), child: const Text('Register')),
          ],
        );
      }),
    );
    if (ok != true || nameCtrl.text.trim().isEmpty) return;
    try {
      await _api.post('/devices', {'name': nameCtrl.text.trim(), 'deviceType': type});
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Devices')),
      floatingActionButton: FloatingActionButton.extended(onPressed: _register, icon: const Icon(Icons.add), label: const Text('Register device')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorView(message: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: _devices.isEmpty
                      ? ListView(children: const [Padding(padding: EdgeInsets.all(24), child: Center(child: Text('No devices registered.', style: TextStyle(color: LsColors.muted))))])
                      : ListView.separated(
                          padding: const EdgeInsets.fromLTRB(10, 10, 10, 80),
                          itemCount: _devices.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (context, i) => _deviceCard(_devices[i]),
                        ),
                ),
    );
  }

  Widget _deviceCard(_Device d) {
    final disabled = d.status != 'ACTIVE';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: Text(d.name, style: TextStyle(fontWeight: FontWeight.w700, color: disabled ? LsColors.muted : LsColors.text))),
                const SizedBox(width: 6),
                IconButton(icon: const Icon(Icons.edit_outlined, size: 16), onPressed: () => _rename(d), visualDensity: VisualDensity.compact),
              ]),
              Text(titleCase(d.deviceType), style: const TextStyle(color: LsColors.muted, fontSize: 12)),
              Text(
                d.lastSeenAt == null ? 'Never seen' : 'Last seen: ${fmtDate(d.lastSeenAt!)} ${fmtHHMM(d.lastSeenAt)}',
                style: const TextStyle(color: LsColors.muted, fontSize: 12),
              ),
              if (d.registeredAt != null) Text('Registered: ${fmtDate(d.registeredAt!)}', style: const TextStyle(color: LsColors.muted, fontSize: 12)),
            ]),
          ),
          Column(children: [
            Switch(value: !disabled, onChanged: (_) => _toggleStatus(d)),
            Text(disabled ? 'Disabled' : 'Active', style: TextStyle(fontSize: 11, color: disabled ? LsColors.red : LsColors.green)),
          ]),
        ]),
      ),
    );
  }
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
