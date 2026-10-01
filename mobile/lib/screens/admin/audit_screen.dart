import 'dart:convert';
import 'package:flutter/material.dart';
import '../../api/api_client.dart';
import '../../format.dart';
import '../../theme.dart';

class _AuditEntry {
  final String id;
  final String action;
  final String entityType;
  final String? entityId;
  final Map<String, dynamic>? beforeData;
  final Map<String, dynamic>? afterData;
  final String? reason;
  final DateTime createdAt;
  final String? actorName;
  final String? deviceName;
  _AuditEntry({
    required this.id, required this.action, required this.entityType, required this.entityId, required this.beforeData,
    required this.afterData, required this.reason, required this.createdAt, required this.actorName, required this.deviceName,
  });
  factory _AuditEntry.fromJson(Map<String, dynamic> j) => _AuditEntry(
        id: j['id'] as String,
        action: j['action'] as String,
        entityType: (j['entityType'] as String?) ?? '',
        entityId: j['entityId'] as String?,
        beforeData: j['beforeData'] as Map<String, dynamic>?,
        afterData: j['afterData'] as Map<String, dynamic>?,
        reason: j['reason'] as String?,
        createdAt: DateTime.parse(j['createdAt'] as String),
        actorName: j['actorName'] as String?,
        deviceName: j['deviceName'] as String?,
      );
}

/// GET /audit (audit.read). A simple action-prefix text filter plus infinite-scroll "load more"
/// using the `before` cursor (an entry's own id).
class AuditScreen extends StatefulWidget {
  const AuditScreen({super.key});
  @override
  State<AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends State<AuditScreen> {
  late ApiClient _api;
  final _filterCtrl = TextEditingController();
  List<_AuditEntry> _entries = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;
  final _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    _filterCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollCtrl.position.pixels > _scrollCtrl.position.maxScrollExtent - 200) {
      _loadMore();
    }
  }

  String get _query {
    final action = _filterCtrl.text.trim();
    return action.isEmpty ? '' : '&action=${Uri.encodeQueryComponent(action)}';
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _hasMore = true;
    });
    try {
      _api = await ApiClient.instance();
      final json = await _api.get('/audit?limit=100$_query') as Map<String, dynamic>;
      final entries = ((json['entries'] as List?) ?? const []).map((e) => _AuditEntry.fromJson(e as Map<String, dynamic>)).toList();
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _loading = false;
        _hasMore = entries.length >= 100;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _entries.isEmpty) return;
    setState(() => _loadingMore = true);
    try {
      final before = _entries.last.id;
      final json = await _api.get('/audit?limit=100&before=$before$_query') as Map<String, dynamic>;
      final more = ((json['entries'] as List?) ?? const []).map((e) => _AuditEntry.fromJson(e as Map<String, dynamic>)).toList();
      if (!mounted) return;
      setState(() {
        _entries = [..._entries, ...more];
        _hasMore = more.length >= 100;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  void _showDetail(_AuditEntry e) {
    const encoder = JsonEncoder.withIndent('  ');
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(e.action),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${fmtDate(e.createdAt)} ${fmtHHMM(e.createdAt)} · ${e.actorName ?? 'system'}${e.deviceName != null ? ' · ${e.deviceName}' : ''}'),
              const SizedBox(height: 8),
              Text('Entity: ${e.entityType}${e.entityId != null ? ' (${e.entityId})' : ''}'),
              if (e.reason != null) ...[const SizedBox(height: 8), Text('Reason: ${e.reason}')],
              if (e.beforeData != null) ...[
                const SizedBox(height: 10),
                const Text('Before', style: TextStyle(fontWeight: FontWeight.w700)),
                Text(encoder.convert(e.beforeData), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              ],
              if (e.afterData != null) ...[
                const SizedBox(height: 10),
                const Text('After', style: TextStyle(fontWeight: FontWeight.w700)),
                Text(encoder.convert(e.afterData), style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              ],
            ]),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Audit log')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _filterCtrl,
            decoration: InputDecoration(
              labelText: 'Filter by action prefix (e.g. "session.")',
              prefixIcon: const Icon(Icons.filter_alt_outlined),
              suffixIcon: _filterCtrl.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _filterCtrl.clear();
                        _load();
                      },
                    ),
            ),
            onSubmitted: (_) => _load(),
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? _ErrorView(message: _error!, onRetry: _load)
                  : _entries.isEmpty
                      ? const Center(child: Text('No audit entries.', style: TextStyle(color: LsColors.muted)))
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView.separated(
                            controller: _scrollCtrl,
                            padding: const EdgeInsets.fromLTRB(10, 0, 10, 20),
                            itemCount: _entries.length + (_hasMore ? 1 : 0),
                            separatorBuilder: (_, __) => const Divider(height: 1, color: LsColors.border),
                            itemBuilder: (context, i) {
                              if (i >= _entries.length) {
                                return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
                              }
                              final e = _entries[i];
                              return ListTile(
                                dense: true,
                                title: Text(e.action, style: const TextStyle(fontWeight: FontWeight.w600)),
                                subtitle: Text(
                                  '${e.entityType}${e.entityId != null ? ' #${e.entityId}' : ''} · ${e.actorName ?? 'system'}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: Text('${fmtDate(e.createdAt)}\n${fmtHHMM(e.createdAt)}', textAlign: TextAlign.right, style: const TextStyle(fontSize: 11, color: LsColors.muted)),
                                onTap: () => _showDetail(e),
                              );
                            },
                          ),
                        ),
        ),
      ]),
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
