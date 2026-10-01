import 'package:flutter/material.dart';

import '../../api/api_client.dart';
import '../../format.dart';
import '../../models/me.dart';
import '../../models/visit.dart';
import '../../theme.dart';
import '../../widgets/authed_photo.dart';
import '../../widgets/status_badge.dart';
import '../customers/customer_profile_screen.dart';

/// Looks up a value under the first matching key — the single-visit payload isn't modeled
/// (only the /visits list row and the timeline/payment shapes are), so header fields are read
/// defensively across the plausible key names rather than assumed to match the list row exactly.
T? _pick<T>(Map<String, dynamic> j, List<String> keys) {
  for (final k in keys) {
    final v = j[k];
    if (v != null && v is T) return v;
  }
  return null;
}

/// Full detail for one visit: customer header, payments (if permitted), and the complete
/// event timeline. Pushed via Navigator, so it owns its own Scaffold/AppBar.
class VisitDetailScreen extends StatefulWidget {
  final String visitId;
  const VisitDetailScreen({super.key, required this.visitId});
  @override
  State<VisitDetailScreen> createState() => _VisitDetailScreenState();
}

class _VisitDetailScreenState extends State<VisitDetailScreen> {
  late ApiClient _api;
  Me? _me;
  bool _loading = true;
  String? _error;

  Map<String, dynamic> _visit = {};
  List<Map<String, dynamic>> _paymentsRaw = [];
  List<TimelineEntry> _timeline = [];

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
    setState(() => _loading = true);
    try {
      final res =
          await _api.get('/visits/${widget.visitId}') as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _visit = (res['visit'] as Map?)?.cast<String, dynamic>() ?? const {};
        _paymentsRaw = (res['payments'] as List? ?? const [])
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();
        _timeline = (res['timeline'] as List? ?? const [])
            .map((e) => TimelineEntry.fromJson(e as Map<String, dynamic>))
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

  String? get _customerId => _pick<String>(_visit, ['customerId']);
  String get _customerName =>
      _pick<String>(_visit, ['fullName', 'customerName']) ?? 'Customer';
  String? get _customerPhone => _pick<String>(_visit, [
    'phoneE164',
    'customerPhoneE164',
    'customerPhone',
  ]);
  String? get _customerCode => _pick<String>(_visit, ['customerCode']);
  String? get _photoId => _pick<String>(_visit, ['photoId', 'customerPhotoId']);
  String? get _visitStatus => _pick<String>(_visit, ['visitStatus', 'status']);
  int? get _visitNumber => _pick<int>(_visit, ['visitNumber']);

  void _openProfile() {
    final id = _customerId;
    if (id == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => CustomerProfileScreen(customerId: id)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _visitNumber != null ? 'Visit #$_visitNumber' : 'Visit detail',
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? _ErrorView(message: _error!, onRetry: _load)
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(14),
                children: [
                  _buildHeader(),
                  const SizedBox(height: 18),
                  if (_me?.can('payment.read') == true) ...[
                    Text(
                      'Payments',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    if (_paymentsRaw.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: Text(
                          'No payments recorded.',
                          style: TextStyle(color: LsColors.muted),
                        ),
                      )
                    else
                      ..._paymentsRaw.map(
                        (p) => _PaymentTile(
                          payment: PaymentLike.fromJson(p),
                          reference: _pick<String>(p, [
                            'reference',
                            'referenceCode',
                            'last4',
                          ]),
                        ),
                      ),
                    const SizedBox(height: 18),
                  ],
                  Text(
                    'Timeline',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  if (_timeline.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Text(
                        'No events recorded for this visit.',
                        style: TextStyle(color: LsColors.muted),
                      ),
                    )
                  else
                    _Timeline(entries: _timeline),
                ],
              ),
            ),
    );
  }

  Widget _buildHeader() {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            AuthedPhoto(photoId: _photoId, name: _customerName, size: 64),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _customerName,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  if (_customerCode != null)
                    Text(
                      _customerCode!,
                      style: const TextStyle(
                        color: LsColors.muted,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  if (_customerPhone != null)
                    Text(
                      formatPhoneLocal(_customerPhone),
                      style: const TextStyle(color: LsColors.text),
                    ),
                  if (_visitStatus != null) ...[
                    const SizedBox(height: 6),
                    LsBadge.forStatus(_visitStatus!, _levelFor(_visitStatus!)),
                  ],
                ],
              ),
            ),
            if (_me?.can('customer.read') == true && _customerId != null)
              IconButton(
                onPressed: _openProfile,
                icon: const Icon(Icons.open_in_new),
                tooltip: 'Open profile',
              ),
          ],
        ),
      ),
    );
  }

  String _levelFor(String status) {
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

class _PaymentTile extends StatelessWidget {
  final PaymentLike payment;
  final String? reference;
  const _PaymentTile({required this.payment, required this.reference});

  String get _level {
    switch (payment.status.toUpperCase()) {
      case 'SUCCEEDED':
      case 'PAID':
      case 'COMPLETED':
        return 'normal';
      case 'REFUNDED':
      case 'PARTIALLY_REFUNDED':
        return 'yellow';
      case 'FAILED':
      case 'VOID':
      case 'CANCELLED':
        return 'red';
      default:
        return 'gray';
    }
  }

  @override
  Widget build(BuildContext context) {
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
                  Text(
                    [
                      titleCase(payment.method),
                      if (payment.purpose != null &&
                          payment.purpose!.isNotEmpty)
                        titleCase(payment.purpose!),
                    ].join(' · '),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  if (reference != null && reference!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        'Ref: $reference',
                        style: const TextStyle(
                          color: LsColors.muted,
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                  if (payment.refundedMinor > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        'Refunded ${formatMoney(payment.refundedMinor, 'ETB')}',
                        style: const TextStyle(
                          color: LsColors.orange,
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
                Text(
                  formatMoney(payment.amountMinor, 'ETB'),
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 4),
                LsBadge(
                  label: titleCase(payment.status),
                  level: _level,
                  icon: Icons.payments_outlined,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Timeline extends StatelessWidget {
  final List<TimelineEntry> entries;
  const _Timeline({required this.entries});

  IconData _iconFor(String eventType) {
    final t = eventType.toLowerCase();
    if (t.contains('checkin') || t.contains('check_in')) return Icons.login;
    if (t.contains('start')) return Icons.play_circle_outline;
    if (t.contains('pause')) return Icons.pause_circle_outline;
    if (t.contains('resume')) return Icons.play_arrow;
    if (t.contains('end') || t.contains('complete') || t.contains('checkout')) {
      return Icons.logout;
    }
    if (t.contains('cancel')) return Icons.cancel_outlined;
    if (t.contains('expire')) return Icons.timer_off_outlined;
    if (t.contains('payment') || t.contains('refund')) {
      return Icons.payments_outlined;
    }
    if (t.contains('equipment')) return Icons.sports_hockey_outlined;
    if (t.contains('incident')) return Icons.report_problem_outlined;
    if (t.contains('correct') || t.contains('edit') || t.contains('update')) {
      return Icons.edit_outlined;
    }
    if (t.contains('waiver')) return Icons.description_outlined;
    return Icons.circle_outlined;
  }

  String _labelFor(TimelineEntry e) {
    final label = e.metadata['label'];
    if (label is String && label.isNotEmpty) return label;
    return titleCase(e.eventType);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < entries.length; i++)
          _TimelineRow(
            entry: entries[i],
            icon: _iconFor(entries[i].eventType),
            label: _labelFor(entries[i]),
            isLast: i == entries.length - 1,
          ),
      ],
    );
  }
}

class _TimelineRow extends StatelessWidget {
  final TimelineEntry entry;
  final IconData icon;
  final String label;
  final bool isLast;
  const _TimelineRow({
    required this.entry,
    required this.icon,
    required this.label,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: const BoxDecoration(
                  color: LsColors.brandSoft,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, size: 16, color: LsColors.brandStrong),
              ),
              if (!isLast)
                Expanded(child: Container(width: 2, color: LsColors.border)),
            ],
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${fmtDate(entry.occurredAt)} ${fmtHHMM(entry.occurredAt)}'
                    '${entry.actorName != null ? ' · ${entry.actorName}' : ''}'
                    '${entry.deviceName != null ? ' · ${entry.deviceName}' : ''}',
                    style: const TextStyle(
                      color: LsColors.muted,
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
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
