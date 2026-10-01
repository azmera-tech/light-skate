import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../theme.dart';

/// Loads a customer photo through the authenticated API endpoint (never a public URL),
/// same privacy model as the web app. Falls back to a plain initials avatar while loading,
/// on error, or when no photo is on file.
class AuthedPhoto extends StatefulWidget {
  final String? photoId;
  final String name;
  final double size;
  const AuthedPhoto({super.key, required this.photoId, required this.name, this.size = 56});

  @override
  State<AuthedPhoto> createState() => _AuthedPhotoState();
}

class _AuthedPhotoState extends State<AuthedPhoto> {
  static final Map<String, Uint8List> _cache = {};
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant AuthedPhoto old) {
    super.didUpdateWidget(old);
    if (old.photoId != widget.photoId) _load();
  }

  Future<void> _load() async {
    final id = widget.photoId;
    if (id == null) {
      setState(() => _bytes = null);
      return;
    }
    if (_cache.containsKey(id)) {
      setState(() => _bytes = _cache[id]);
      return;
    }
    try {
      final api = await ApiClient.instance();
      final bytes = Uint8List.fromList(await api.photoBytes(id));
      _cache[id] = bytes;
      if (mounted) setState(() => _bytes = bytes);
    } catch (_) {
      // keep the initials fallback
    }
  }

  String get _initials {
    final parts = widget.name.replaceFirst('Demo ', '').trim().split(RegExp(r'\s+'));
    final letters = parts.where((p) => p.isNotEmpty).take(2).map((p) => p[0].toUpperCase()).join();
    return letters.isEmpty ? '?' : letters;
  }

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(widget.size * 0.2);
    return ClipRRect(
      borderRadius: r,
      child: Container(
        width: widget.size,
        height: widget.size,
        color: LsColors.surface2,
        alignment: Alignment.center,
        child: _bytes != null
            ? Image.memory(_bytes!, fit: BoxFit.cover, width: widget.size, height: widget.size)
            : Text(_initials, style: TextStyle(color: LsColors.muted, fontWeight: FontWeight.w700, fontSize: widget.size * 0.32)),
      ),
    );
  }
}
