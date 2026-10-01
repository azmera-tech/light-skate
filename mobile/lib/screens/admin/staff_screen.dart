import 'package:flutter/material.dart';
import '../../api/api_client.dart';
import '../../format.dart';
import '../../theme.dart';

class _StaffMember {
  final String id;
  final String email;
  String fullName;
  String status; // ACTIVE | DISABLED
  final DateTime? lastLoginAt;
  String roleId;
  final String roleCode;
  String roleName;
  final String? phone;
  final String? employeeNo;
  _StaffMember({
    required this.id, required this.email, required this.fullName, required this.status, required this.lastLoginAt,
    required this.roleId, required this.roleCode, required this.roleName, required this.phone, required this.employeeNo,
  });
  factory _StaffMember.fromJson(Map<String, dynamic> j) => _StaffMember(
        id: j['id'] as String,
        email: j['email'] as String,
        fullName: j['fullName'] as String,
        status: j['status'] as String,
        lastLoginAt: j['lastLoginAt'] == null ? null : DateTime.tryParse(j['lastLoginAt'] as String),
        roleId: j['roleId'] as String,
        roleCode: (j['roleCode'] as String?) ?? '',
        roleName: (j['roleName'] as String?) ?? '',
        phone: j['phone'] as String?,
        employeeNo: j['employeeNo'] as String?,
      );
}

class _Role {
  final String id;
  final String code;
  final String name;
  final List<String> permissions;
  _Role({required this.id, required this.code, required this.name, required this.permissions});
  factory _Role.fromJson(Map<String, dynamic> j) => _Role(
        id: j['id'] as String,
        code: j['code'] as String,
        name: j['name'] as String,
        permissions: ((j['permissions'] as List?) ?? const []).map((e) => e as String).toList(),
      );
}

/// GET/POST/PATCH /staff + GET /roles (staff.manage). Role dropdown PATCHes immediately,
/// a status switch Disables/Enables immediately, and a reset-password action opens a dialog.
class StaffScreen extends StatefulWidget {
  const StaffScreen({super.key});
  @override
  State<StaffScreen> createState() => _StaffScreenState();
}

class _StaffScreenState extends State<StaffScreen> {
  late ApiClient _api;
  List<_StaffMember> _staff = [];
  List<_Role> _roles = [];
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
      final staffJson = await _api.get('/staff') as Map<String, dynamic>;
      final rolesJson = await _api.get('/roles') as Map<String, dynamic>;
      final staff = ((staffJson['staff'] as List?) ?? const []).map((e) => _StaffMember.fromJson(e as Map<String, dynamic>)).toList();
      final roles = ((rolesJson['roles'] as List?) ?? const []).map((e) => _Role.fromJson(e as Map<String, dynamic>)).toList();
      if (!mounted) return;
      setState(() {
        _staff = staff;
        _roles = roles;
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

  Future<void> _changeRole(_StaffMember s, String roleId) async {
    final previous = s.roleId;
    final role = _roles.firstWhere((r) => r.id == roleId);
    setState(() {
      s.roleId = roleId;
      s.roleName = role.name;
    });
    try {
      await _api.patch('/staff/${s.id}', {'roleId': roleId});
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => s.roleId = previous);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _toggleStatus(_StaffMember s) async {
    final next = s.status == 'ACTIVE' ? 'DISABLED' : 'ACTIVE';
    setState(() => s.status = next);
    try {
      await _api.patch('/staff/${s.id}', {'status': next});
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => s.status = next == 'ACTIVE' ? 'DISABLED' : 'ACTIVE');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _resetPassword(_StaffMember s) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(builder: (context, setDState) {
        final valid = ctrl.text.length >= 10;
        return AlertDialog(
          title: Text('Reset password — ${s.fullName}'),
          content: TextField(
            controller: ctrl,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'New password (min 10 characters)'),
            onChanged: (_) => setDState(() {}),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: valid ? () => Navigator.pop(context, true) : null, child: const Text('Reset')),
          ],
        );
      }),
    );
    if (ok != true) return;
    try {
      await _api.post('/staff/${s.id}/reset-password', {'password': ctrl.text});
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Password reset.')));
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _editName(_StaffMember s) async {
    final ctrl = TextEditingController(text: s.fullName);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit name'),
        content: TextField(controller: ctrl, decoration: const InputDecoration(labelText: 'Full name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true || ctrl.text.trim().isEmpty) return;
    final previous = s.fullName;
    setState(() => s.fullName = ctrl.text.trim());
    try {
      await _api.patch('/staff/${s.id}', {'fullName': s.fullName});
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => s.fullName = previous);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _addStaff() async {
    final emailCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    final passwordCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final empNoCtrl = TextEditingController();
    String? roleId = _roles.isNotEmpty ? _roles.first.id : null;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(builder: (context, setDState) {
        final valid = emailCtrl.text.contains('@') && nameCtrl.text.trim().isNotEmpty && passwordCtrl.text.length >= 10 && roleId != null;
        return AlertDialog(
          title: const Text('Add staff member'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Full name'), onChanged: (_) => setDState(() {})),
                const SizedBox(height: 10),
                TextField(controller: emailCtrl, decoration: const InputDecoration(labelText: 'Email'), onChanged: (_) => setDState(() {})),
                const SizedBox(height: 10),
                TextField(controller: passwordCtrl, obscureText: true, decoration: const InputDecoration(labelText: 'Temporary password (min 10 chars)'), onChanged: (_) => setDState(() {})),
                const SizedBox(height: 10),
                TextField(controller: phoneCtrl, decoration: const InputDecoration(labelText: 'Phone (optional)')),
                const SizedBox(height: 10),
                TextField(controller: empNoCtrl, decoration: const InputDecoration(labelText: 'Employee number (optional)')),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: roleId,
                  decoration: const InputDecoration(labelText: 'Role'),
                  items: _roles.map((r) => DropdownMenuItem(value: r.id, child: Text(r.name))).toList(),
                  onChanged: (v) => setDState(() => roleId = v),
                ),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(onPressed: valid ? () => Navigator.pop(context, true) : null, child: const Text('Add')),
          ],
        );
      }),
    );
    if (ok != true) return;
    try {
      await _api.post('/staff', {
        'email': emailCtrl.text.trim(),
        'fullName': nameCtrl.text.trim(),
        'password': passwordCtrl.text,
        'roleId': roleId,
        if (phoneCtrl.text.trim().isNotEmpty) 'phone': phoneCtrl.text.trim(),
        if (empNoCtrl.text.trim().isNotEmpty) 'employeeNo': empNoCtrl.text.trim(),
      });
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Staff')),
      floatingActionButton: FloatingActionButton.extended(onPressed: _addStaff, icon: const Icon(Icons.person_add_alt_1), label: const Text('Add staff')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorView(message: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(10, 10, 10, 80),
                    itemCount: _staff.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, i) => _staffCard(_staff[i]),
                  ),
                ),
    );
  }

  Widget _staffCard(_StaffMember s) {
    final disabled = s.status != 'ACTIVE';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(child: Text(s.fullName, style: TextStyle(fontWeight: FontWeight.w700, color: disabled ? LsColors.muted : LsColors.text))),
                  const SizedBox(width: 6),
                  IconButton(icon: const Icon(Icons.edit_outlined, size: 16), onPressed: () => _editName(s), visualDensity: VisualDensity.compact),
                ]),
                Text(s.email, style: const TextStyle(color: LsColors.muted, fontSize: 12)),
                if (s.phone != null) Text(formatPhoneLocal(s.phone), style: const TextStyle(color: LsColors.muted, fontSize: 12)),
                Text(
                  s.lastLoginAt == null ? 'Never logged in' : 'Last login: ${fmtDate(s.lastLoginAt!)} ${fmtHHMM(s.lastLoginAt)}',
                  style: const TextStyle(color: LsColors.muted, fontSize: 12),
                ),
              ]),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Switch(value: !disabled, onChanged: (_) => _toggleStatus(s)),
              Text(disabled ? 'Disabled' : 'Active', style: TextStyle(fontSize: 11, color: disabled ? LsColors.red : LsColors.green)),
            ]),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: _roles.any((r) => r.id == s.roleId) ? s.roleId : null,
                decoration: const InputDecoration(labelText: 'Role', isDense: true),
                items: _roles.map((r) => DropdownMenuItem(value: r.id, child: Text(r.name))).toList(),
                onChanged: (v) {
                  if (v != null) _changeRole(s, v);
                },
              ),
            ),
            const SizedBox(width: 8),
            TextButton(onPressed: () => _resetPassword(s), child: const Text('Reset password')),
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
