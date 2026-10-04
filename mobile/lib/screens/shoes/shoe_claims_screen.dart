import 'dart:async';
import 'package:flutter/material.dart';
import '../../api/api_client.dart';
import '../../format.dart';
import '../../models/shoe_claim.dart';
import '../../theme.dart';
import '../../widgets/authed_photo.dart';
import '../../widgets/shoe_photo.dart';
import '../../widgets/status_badge.dart';
import 'shoe_return_screen.dart';

const _sessionLevel = <String, String>{
  'ACTIVE': 'normal', 'EXPIRING': 'yellow', 'PAUSED': 'paused', 'EXPIRED': 'expired',
  'COMPLETED': 'gray', 'EARLY_EXIT': 'gray',
};

/// "👟 Shoes on Shelf" — the active personal-shoe claims. There is only one shared shelf, so
/// this is deliberately a flat list, not a storage-location picker.
class ShoeClaimsScreen extends StatefulWidget {
  const ShoeClaimsScreen({super.key});
  @override
  State<ShoeClaimsScreen> createState() => _ShoeClaimsScreenState();
}

class _ShoeClaimsScreenState extends State<ShoeClaimsScreen> {
  late ApiClient _api;
  ShoeClaimListResponse? _data;
  String? _error;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    _api = await ApiClient.instance();
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
      final json = await _api.get('/shoe-claims') as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _data = ShoeClaimListResponse.fromJson(json);
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      if (!silent) setState(() => _error = e.toString());
    }
  }

  Future<void> _searchClaim() async {
    final number = await showDialog<String>(
      context: context,
      builder: (context) {
        final ctrl = TextEditingController();
        return AlertDialog(
          title: const Text('Search claim'),
          content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(labelText: 'Claim number', hintText: 'LS-4827'), textCapitalization: TextCapitalization.characters),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, ctrl.text.trim()), child: const Text('Find')),
          ],
        );
      },
    );
    if (number == null || number.isEmpty) return;
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ShoeReturnScreen(claimNumber: number)));
    _load(silent: true);
  }

  Future<void> _openClaim(ShoeClaim c) async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ShoeReturnScreen(claimId: c.id)));
    _load(silent: true);
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    return Scaffold(
      appBar: AppBar(title: const Text('Shoes on Shelf'), actions: [
        IconButton(onPressed: _searchClaim, icon: const Icon(Icons.search), tooltip: 'Search claim'),
      ]),
      body: RefreshIndicator(
        onRefresh: () => _load(),
        child: d == null
            ? (_error != null
                ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [Text(_error!, textAlign: TextAlign.center), const SizedBox(height: 10), OutlinedButton(onPressed: () => _load(), child: const Text('Retry'))])))
                : const Center(child: CircularProgressIndicator()))
            : d.items.isEmpty
                ? ListView(children: const [Padding(padding: EdgeInsets.all(32), child: Center(child: Text('No shoes on the shelf right now.', style: TextStyle(color: LsColors.muted))))])
                : ListView.separated(
                    padding: const EdgeInsets.all(14),
                    itemCount: d.items.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final c = d.items[i];
                      return _ClaimTile(key: ValueKey(c.id), claim: c, onTap: () => _openClaim(c));
                    },
                  ),
      ),
    );
  }
}

class _ClaimTile extends StatelessWidget {
  final ShoeClaim claim;
  final VoidCallback onTap;
  const _ClaimTile({super.key, required this.claim, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final level = claim.sessionStatus != null ? (_sessionLevel[claim.sessionStatus] ?? 'gray') : 'gray';
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            ShoePhoto(claimId: claim.id, size: 52),
            const SizedBox(width: 10),
            AuthedPhoto(photoId: claim.customerPhotoId, name: claim.customerName ?? '?', size: 44),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('#${claim.claimNumber}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: LsColors.brand)),
                Text(claim.customerName ?? '—', style: const TextStyle(fontWeight: FontWeight.w600)),
                Text('Stored ${fmtHHMM(claim.createdAt)}', style: const TextStyle(color: LsColors.muted, fontSize: 12)),
              ]),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              if (claim.sessionStatus != null) LsBadge(label: titleCase(claim.sessionStatus!), level: level, icon: Icons.circle),
              if (claim.returnPending) const Padding(padding: EdgeInsets.only(top: 4), child: Text('Return pending', style: TextStyle(color: LsColors.orange, fontSize: 11, fontWeight: FontWeight.w700))),
            ]),
          ]),
        ),
      ),
    );
  }
}
