import 'dart:async';

import 'package:flutter/material.dart';

import '../../api/api_client.dart';
import '../../format.dart';
import '../../models/customer.dart';
import '../../theme.dart';
import '../../widgets/authed_photo.dart';
import '../../widgets/status_badge.dart';
import 'customer_profile_screen.dart';

/// Customer search tab. No Scaffold/AppBar of its own — hosted inside AppShell's "Customers"
/// tab body, same pattern as DashboardScreen: AppShell already supplies the outer Scaffold/AppBar.
class CustomerSearchScreen extends StatefulWidget {
  const CustomerSearchScreen({super.key});
  @override
  State<CustomerSearchScreen> createState() => _CustomerSearchScreenState();
}

class _CustomerSearchScreenState extends State<CustomerSearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  late ApiClient _api;
  bool _booted = false;

  List<CustomerSummary> _results = [];
  bool _loading = false;
  String? _error;
  String _lastQuery = '';

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    _api = await ApiClient.instance();
    if (mounted) setState(() => _booted = true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () => _search(q));
  }

  Future<void> _search(String q) async {
    final query = q.trim();
    if (query.length < 2) {
      setState(() {
        _results = [];
        _loading = false;
        _error = null;
        _lastQuery = query;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _lastQuery = query;
    });
    try {
      final res = await _api.get(
        '/customers?q=${Uri.encodeQueryComponent(query)}',
      ) as Map<String, dynamic>;
      if (!mounted || _lastQuery != query) return;
      final list = (res['customers'] as List? ?? const [])
          .map((e) => CustomerSummary.fromJson(e as Map<String, dynamic>))
          .toList();
      setState(() {
        _results = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || _lastQuery != query) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _openProfile(CustomerSummary c) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => CustomerProfileScreen(customerId: c.id),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_booted) return const Center(child: CircularProgressIndicator());

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
          child: TextField(
            controller: _controller,
            textInputAction: TextInputAction.search,
            onChanged: _onChanged,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: 'Search by name, phone, or customer code',
              suffixIcon: _controller.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _controller.clear();
                        _onChanged('');
                      },
                    )
                  : null,
            ),
          ),
        ),
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildBody() {
    if (_loading && _results.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: LsColors.red, size: 36),
              const SizedBox(height: 10),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 14),
              OutlinedButton(
                onPressed: () => _search(_lastQuery),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    if (_lastQuery.trim().length < 2) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Type at least 2 characters to search for a customer.',
            style: TextStyle(color: LsColors.muted),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (_results.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No customers found.',
            style: TextStyle(color: LsColors.muted),
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 14),
      itemCount: _results.length,
      separatorBuilder: (_, _) => const SizedBox(height: 6),
      itemBuilder: (context, i) => _CustomerRow(
        customer: _results[i],
        onTap: () => _openProfile(_results[i]),
      ),
    );
  }
}

class _CustomerRow extends StatelessWidget {
  final CustomerSummary customer;
  final VoidCallback onTap;
  const _CustomerRow({required this.customer, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              AuthedPhoto(
                photoId: customer.photoId,
                name: customer.fullName,
                size: 48,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      customer.fullName,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${formatPhoneLocal(customer.phoneE164)} · ${customer.customerCode}',
                      style: const TextStyle(
                        color: LsColors.muted,
                        fontSize: 12.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${customer.visitCount} visit${customer.visitCount == 1 ? '' : 's'}'
                      '${customer.lastVisitAt != null ? ' · last ${fmtDate(customer.lastVisitAt!)}' : ''}',
                      style: const TextStyle(
                        color: LsColors.muted,
                        fontSize: 12.5,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (customer.status != null && customer.status != 'ACTIVE')
                LsBadge(
                  label: titleCase(customer.status!),
                  level: customer.status == 'BLOCKED' ? 'red' : 'gray',
                  icon: customer.status == 'BLOCKED'
                      ? Icons.block
                      : Icons.archive_outlined,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
