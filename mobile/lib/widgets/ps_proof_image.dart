import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../theme.dart';

/// A payment's evidence image, fetched through the authenticated API (never a public URL).
class PsProofImage extends StatefulWidget {
  final String paymentId;
  final double? height;
  final BoxFit fit;
  final bool tapToEnlarge;
  const PsProofImage({super.key, required this.paymentId, this.height = 150, this.fit = BoxFit.cover, this.tapToEnlarge = true});
  @override
  State<PsProofImage> createState() => _PsProofImageState();
}

class _PsProofImageState extends State<PsProofImage> {
  static final Map<String, Uint8List> _cache = {};
  Uint8List? _bytes;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant PsProofImage old) {
    super.didUpdateWidget(old);
    if (old.paymentId != widget.paymentId) {
      _bytes = null;
      _error = null;
      _load();
    }
  }

  Future<void> _load() async {
    final id = widget.paymentId;
    if (_cache.containsKey(id)) {
      setState(() => _bytes = _cache[id]);
      return;
    }
    try {
      final api = await ApiClient.instance();
      final b = Uint8List.fromList(await api.getBytes('/playstation/payments/$id/proof'));
      _cache[id] = b;
      if (mounted && widget.paymentId == id) setState(() => _bytes = b);
    } catch (e) {
      if (mounted && widget.paymentId == id) setState(() => _error = 'Evidence could not be loaded.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final img = _bytes;
    final child = img != null
        ? Image.memory(img, fit: widget.fit, width: double.infinity, height: widget.height)
        : Center(child: _error != null ? Text(_error!, style: const TextStyle(color: LsColors.red)) : const CircularProgressIndicator(strokeWidth: 2));
    return Semantics(
      label: 'Payment evidence image${widget.tapToEnlarge ? ', tap to enlarge' : ''}',
      button: widget.tapToEnlarge && img != null,
      child: GestureDetector(
        onTap: widget.tapToEnlarge && img != null ? () => showPsProofViewer(context, img) : null,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Container(height: widget.height, width: double.infinity, color: LsColors.surface2, child: child),
        ),
      ),
    );
  }
}

Future<void> showPsProofViewer(BuildContext context, Uint8List bytes) {
  return Navigator.of(context).push(MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, foregroundColor: Colors.white, title: const Text('Payment evidence')),
      body: SafeArea(child: Center(child: InteractiveViewer(minScale: 0.8, maxScale: 6, child: Image.memory(bytes)))),
    ),
  ));
}
