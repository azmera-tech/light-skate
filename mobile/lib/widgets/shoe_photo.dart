import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../theme.dart';

/// Shows a shoe claim's stored photo, fetched through the authenticated API (never a public
/// URL) — same privacy model as [AuthedPhoto], but for an arbitrary photo-serving path instead
/// of the shared customer-photos table. Falls back to a plain shoe icon while loading, on
/// error, or when the claim has no photo on file.
class ShoePhoto extends StatefulWidget {
  final String claimId;
  final double size;
  final BorderRadius? borderRadius;
  const ShoePhoto({super.key, required this.claimId, this.size = 56, this.borderRadius});

  @override
  State<ShoePhoto> createState() => _ShoePhotoState();
}

class _ShoePhotoState extends State<ShoePhoto> {
  static final Map<String, Uint8List> _cache = {};
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ShoePhoto old) {
    super.didUpdateWidget(old);
    if (old.claimId != widget.claimId) _load();
  }

  Future<void> _load() async {
    if (_cache.containsKey(widget.claimId)) {
      setState(() => _bytes = _cache[widget.claimId]);
      return;
    }
    try {
      final api = await ApiClient.instance();
      final bytes = Uint8List.fromList(await api.getBytes('/shoe-claims/${widget.claimId}/photo'));
      _cache[widget.claimId] = bytes;
      if (mounted) setState(() => _bytes = bytes);
    } catch (_) {
      // keep the icon fallback
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.borderRadius ?? BorderRadius.circular(widget.size * 0.2);
    return ClipRRect(
      borderRadius: r,
      child: Container(
        width: widget.size,
        height: widget.size,
        color: LsColors.surface2,
        alignment: Alignment.center,
        child: _bytes != null
            ? Image.memory(_bytes!, fit: BoxFit.cover, width: widget.size, height: widget.size)
            : Icon(Icons.checkroom_outlined, color: LsColors.muted, size: widget.size * 0.45),
      ),
    );
  }
}
