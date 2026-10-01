import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api/api_client.dart';
import '../../format.dart';
import '../../models/customer.dart';
import '../../models/me.dart';
import '../../theme.dart';
import '../../widgets/authed_photo.dart';
import '../../widgets/reason_dialog.dart';
import '../../widgets/status_badge.dart';
import '../checkin/checkin_flow.dart';

/// Full customer profile: header, status/waiver badges, KPIs, emergency contacts, notes,
/// visit history and permission-gated actions (check-in, edit, erase). Pushed via Navigator,
/// so it owns its own Scaffold/AppBar (unlike the tab-hosted search screen).
class CustomerProfileScreen extends StatefulWidget {
  final String customerId;
  const CustomerProfileScreen({super.key, required this.customerId});
  @override
  State<CustomerProfileScreen> createState() => _CustomerProfileScreenState();
}

class _CustomerProfileScreenState extends State<CustomerProfileScreen> {
  late ApiClient _api;
  Me? _me;
  CustomerProfile? _profile;
  List<CustomerHistoryEntry> _history = [];
  bool _loading = true;
  String? _error;

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

  Future<void> _load({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    try {
      final profileJson = await _api.get(
        '/customers/${widget.customerId}',
      ) as Map<String, dynamic>;
      final historyJson = await _api.get(
        '/customers/${widget.customerId}/history',
      ) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _profile = CustomerProfile.fromJson(profileJson);
        _history = (historyJson['history'] as List? ?? const [])
            .map(
              (e) => CustomerHistoryEntry.fromJson(e as Map<String, dynamic>),
            )
            .toList();
        _error = null;
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

  void _openCheckIn() {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => CheckInFlow(customerId: widget.customerId),
          ),
        )
        .then((_) => _load(silent: true));
  }

  Future<void> _editCustomer() async {
    final p = _profile;
    if (p == null) return;
    final nameController = TextEditingController(text: p.fullName);
    final phoneController = TextEditingController(text: p.phoneE164);
    final emailController = TextEditingController(text: p.email ?? '');
    final notesController = TextEditingController(text: p.notes ?? '');
    final canChangeStatus =
        _me?.can('session.correct') == true || _me?.can('staff.manage') == true;
    String status = p.status;

    final result = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          return Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 16,
              bottom: MediaQuery.of(context).viewInsets.bottom + 16,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Edit customer',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: nameController,
                    decoration: const InputDecoration(labelText: 'Full name'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: phoneController,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(labelText: 'Phone'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: emailController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(labelText: 'Email'),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: notesController,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(labelText: 'Notes'),
                  ),
                  if (canChangeStatus) ...[
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: status,
                      decoration: const InputDecoration(labelText: 'Status'),
                      items: const [
                        DropdownMenuItem(
                          value: 'ACTIVE',
                          child: Text('Active'),
                        ),
                        DropdownMenuItem(
                          value: 'BLOCKED',
                          child: Text('Blocked'),
                        ),
                        DropdownMenuItem(
                          value: 'ARCHIVED',
                          child: Text('Archived'),
                        ),
                      ],
                      onChanged: (v) =>
                          setSheetState(() => status = v ?? status),
                    ),
                  ],
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Save'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );

    if (result != true) return;
    final body = <String, dynamic>{
      'fullName': nameController.text.trim(),
      'phone': phoneController.text.trim(),
      'email': emailController.text.trim().isEmpty
          ? null
          : emailController.text.trim(),
      'notes': notesController.text.trim().isEmpty
          ? null
          : notesController.text.trim(),
    };
    if (canChangeStatus) body['status'] = status;

    try {
      await _api.patch('/customers/${widget.customerId}', body);
      await _load(silent: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Customer updated.')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _eraseCustomer() async {
    final confirmed = await showConfirmDialog(
      context,
      title: 'Erase personal data?',
      message:
          'This permanently removes this customer\'s personal details and photos. '
          'Payment and audit records are kept for accounting and compliance. This cannot be undone.',
      confirmLabel: 'Continue',
      danger: true,
    );
    if (!confirmed) return;
    if (!mounted) return;
    final reason = await showReasonDialog(
      context,
      title: 'Reason for erasing',
      label: 'Reason',
      minLength: 3,
      confirmLabel: 'Erase personal data',
      danger: true,
    );
    if (reason == null) return;

    try {
      await _api.post('/customers/${widget.customerId}/erase', {
        'reason': reason,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Personal data erased.')));
      await _load(silent: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _callContact(String phone) async {
    final uri = Uri.parse('tel:$phone');
    try {
      await launchUrl(uri);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the dialer.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _profile;
    return Scaffold(
      appBar: AppBar(title: Text(p?.fullName ?? 'Customer')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? _ErrorView(message: _error!, onRetry: () => _load())
          : p == null
          ? const SizedBox.shrink()
          : RefreshIndicator(
              onRefresh: () => _load(silent: true),
              child: ListView(
                padding: const EdgeInsets.all(14),
                children: [
                  _Header(profile: p),
                  const SizedBox(height: 12),
                  _BadgeRow(profile: p),
                  const SizedBox(height: 6),
                  Text(
                    'Registered ${fmtDate(p.registeredAt)}',
                    style: const TextStyle(
                      color: LsColors.muted,
                      fontSize: 12.5,
                    ),
                  ),
                  const SizedBox(height: 14),
                  _KpiRow(
                    profile: p,
                    canSeeMoney: _me?.can('payment.read') == true,
                  ),
                  if (p.notes != null && p.notes!.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    _NotesBanner(notes: p.notes!),
                  ],
                  if (p.emergencyContacts.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    Text(
                      'Emergency contacts',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    ...p.emergencyContacts.map(
                      (c) => _EmergencyContactTile(
                        contact: c,
                        onCall: () => _callContact(c.phone),
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  _ActionButtons(
                    profile: p,
                    me: _me,
                    onCheckIn: _openCheckIn,
                    onEdit: _editCustomer,
                    onErase: _eraseCustomer,
                  ),
                  const SizedBox(height: 22),
                  Text(
                    'Visit history',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  if (_history.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'No visits yet.',
                        style: TextStyle(color: LsColors.muted),
                      ),
                    )
                  else
                    ..._history.map(
                      (h) => _HistoryTile(entry: h, currency: 'ETB'),
                    ),
                ],
              ),
            ),
    );
  }
}

class _Header extends StatelessWidget {
  final CustomerProfile profile;
  const _Header({required this.profile});
  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AuthedPhoto(photoId: profile.photoId, name: profile.fullName, size: 84),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                profile.fullName,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                profile.customerCode,
                style: const TextStyle(
                  color: LsColors.muted,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                formatPhoneLocal(profile.phoneE164),
                style: const TextStyle(color: LsColors.text),
              ),
              if (profile.email != null && profile.email!.isNotEmpty)
                Text(
                  profile.email!,
                  style: const TextStyle(color: LsColors.muted, fontSize: 13),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _BadgeRow extends StatelessWidget {
  final CustomerProfile profile;
  const _BadgeRow({required this.profile});
  @override
  Widget build(BuildContext context) {
    final badges = <Widget>[];
    if (profile.status != 'ACTIVE') {
      badges.add(
        LsBadge(
          label: titleCase(profile.status),
          level: profile.status == 'BLOCKED' ? 'red' : 'gray',
          icon: profile.status == 'BLOCKED'
              ? Icons.block
              : Icons.archive_outlined,
        ),
      );
    }
    if (profile.isMinor) {
      badges.add(
        const LsBadge(label: 'Minor', level: 'yellow', icon: Icons.child_care),
      );
    }
    if (profile.waiver.accepted) {
      badges.add(
        LsBadge(
          label: 'Waiver v${profile.waiver.currentVersion ?? '?'} accepted',
          level: 'normal',
          icon: Icons.verified_outlined,
        ),
      );
    } else {
      badges.add(
        const LsBadge(
          label: 'Waiver needed',
          level: 'yellow',
          icon: Icons.warning_amber_rounded,
        ),
      );
    }
    if (profile.currentSession != null) {
      badges.add(
        const LsBadge(
          label: 'Skating now',
          level: 'normal',
          icon: Icons.play_circle_outline,
        ),
      );
    }
    return Wrap(spacing: 6, runSpacing: 6, children: badges);
  }
}

class _KpiRow extends StatelessWidget {
  final CustomerProfile profile;
  final bool canSeeMoney;
  const _KpiRow({required this.profile, required this.canSeeMoney});
  @override
  Widget build(BuildContext context) {
    final stats = profile.stats;
    final items = <(String, String)>[
      ('Total visits', '${stats.visitCount}'),
      (
        'Last visit',
        stats.lastVisitAt != null ? fmtDate(stats.lastVisitAt!) : '—',
      ),
      ('Skating time', formatDuration(stats.totalSkatingSeconds)),
      if (canSeeMoney)
        ('Total spending', formatMoney(stats.totalSpentMinor, 'ETB')),
    ];
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 2.4,
      children: items
          .map(
            (it) => Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      it.$1.toUpperCase(),
                      style: const TextStyle(
                        color: LsColors.muted,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      it.$2,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          )
          .toList(),
    );
  }
}

class _NotesBanner extends StatelessWidget {
  final String notes;
  const _NotesBanner({required this.notes});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: LsColors.yellowSoft,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.sticky_note_2_outlined,
            color: LsColors.yellow,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(notes, style: const TextStyle(color: LsColors.yellow)),
          ),
        ],
      ),
    );
  }
}

class _EmergencyContactTile extends StatelessWidget {
  final EmergencyContact contact;
  final VoidCallback onCall;
  const _EmergencyContactTile({required this.contact, required this.onCall});
  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        leading: const Icon(
          Icons.contact_phone_outlined,
          color: LsColors.brand,
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(contact.name, overflow: TextOverflow.ellipsis),
            ),
            if (contact.isGuardian) ...[
              const SizedBox(width: 6),
              const LsBadge(
                label: 'Guardian',
                level: 'info',
                icon: Icons.shield_outlined,
              ),
            ],
          ],
        ),
        subtitle: Text(
          [
            if (contact.relationship != null &&
                contact.relationship!.isNotEmpty)
              contact.relationship!,
            formatPhoneLocal(contact.phone),
          ].join(' · '),
        ),
        trailing: IconButton(
          icon: const Icon(Icons.call, color: LsColors.green),
          onPressed: onCall,
        ),
        onTap: onCall,
      ),
    );
  }
}

class _ActionButtons extends StatelessWidget {
  final CustomerProfile profile;
  final Me? me;
  final VoidCallback onCheckIn;
  final VoidCallback onEdit;
  final VoidCallback onErase;
  const _ActionButtons({
    required this.profile,
    required this.me,
    required this.onCheckIn,
    required this.onEdit,
    required this.onErase,
  });

  bool get _canCheckIn =>
      (me?.can('session.create') == true) &&
      profile.status == 'ACTIVE' &&
      profile.currentSession == null;
  bool get _canEdit => me?.can('customer.update') == true;
  bool get _erased => profile.fullName.isEmpty && profile.phoneE164.isEmpty;
  bool get _canErase => me?.can('customer.delete') == true && !_erased;

  @override
  Widget build(BuildContext context) {
    final buttons = <Widget>[];
    if (_canCheckIn) {
      buttons.add(
        FilledButton.icon(
          onPressed: onCheckIn,
          icon: const Icon(Icons.person_add_alt_1),
          label: const Text('New check-in'),
        ),
      );
    }
    if (_canEdit) {
      buttons.add(
        OutlinedButton.icon(
          onPressed: onEdit,
          icon: const Icon(Icons.edit_outlined),
          label: const Text('Edit'),
        ),
      );
    }
    if (_canErase) {
      buttons.add(
        OutlinedButton.icon(
          onPressed: onErase,
          style: OutlinedButton.styleFrom(
            foregroundColor: LsColors.red,
            side: const BorderSide(color: LsColors.red),
          ),
          icon: const Icon(Icons.delete_forever_outlined),
          label: const Text('Erase personal data…'),
        ),
      );
    }
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        for (final b in buttons)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SizedBox(width: double.infinity, child: b),
          ),
      ],
    );
  }
}

class _HistoryTile extends StatelessWidget {
  final CustomerHistoryEntry entry;
  final String currency;
  const _HistoryTile({required this.entry, required this.currency});
  @override
  Widget build(BuildContext context) {
    final timeRange = entry.startedAt != null
        ? '${fmtHHMM(entry.startedAt)}–${fmtHHMM(entry.actualEndAt ?? entry.scheduledEndAt)}'
        : '—';
    return Card(
      margin: const EdgeInsets.only(bottom: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        entry.localDate,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          entry.productName ?? '—',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    timeRange,
                    style: const TextStyle(
                      color: LsColors.muted,
                      fontSize: 12.5,
                    ),
                  ),
                  if (entry.equipment != null && entry.equipment!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        entry.equipment!,
                        style: const TextStyle(
                          color: LsColors.muted,
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (entry.paidMinor != null)
                  Text(
                    formatMoney(entry.paidMinor, currency),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                const SizedBox(height: 4),
                LsBadge.forStatus(
                  entry.visitStatus,
                  _levelForVisitStatus(entry.visitStatus),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _levelForVisitStatus(String status) {
    switch (status) {
      case 'COMPLETED':
        return 'normal';
      case 'ACTIVE':
        return 'info';
      case 'CANCELLED':
      case 'NO_SHOW':
        return 'gray';
      case 'EXPIRED':
        return 'expired';
      default:
        return 'gray';
    }
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: LsColors.red, size: 36),
            const SizedBox(height: 10),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 14),
            OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
