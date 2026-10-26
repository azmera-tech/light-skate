import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../api/api_client.dart';
import '../../format.dart';
import '../../models/playstation.dart';
import '../../models/product.dart';
import '../../theme.dart';
import '../../widgets/ps_sheet.dart';

/// Session checkout: the bill, what has been received, and the payment form. Returns true if a payment
/// was recorded. Closing without paying ("Pay later") leaves the balance outstanding — it is never lost.
Future<bool?> showPsCheckoutSheet(BuildContext context, String sessionId) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    isDismissible: true,
    builder: (_) => _CheckoutLoader(sessionId: sessionId),
  );
}

class _CheckoutLoader extends StatefulWidget {
  final String sessionId;
  const _CheckoutLoader({required this.sessionId});
  @override
  State<_CheckoutLoader> createState() => _CheckoutLoaderState();
}

class _CheckoutLoaderState extends State<_CheckoutLoader> {
  PsSessionDetail? _d;
  List<PaymentMethodOption> _methods = [];
  Set<String> _proofRequired = {};
  bool _verifyNonCash = true;
  String? _error;
  bool _paidSomething = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final api = await ApiClient.instance();
      final j = await api.get(
        '/playstation/sessions/${widget.sessionId}',
      ) as Map<String, dynamic>;
      final st = await api.get('/playstation/settings') as Map<String, dynamic>;
      final s = (st['settings'] as Map).cast<String, dynamic>();
      if (!mounted) return;
      setState(() {
        _d = PsSessionDetail.fromJson(j);
        _methods = ((st['paymentMethods'] as List?) ?? const [])
            .map((e) => PaymentMethodOption.fromJson(e as Map<String, dynamic>))
            .toList();
        _proofRequired = ((s['proofRequiredMethods'] as List?) ?? const [])
            .map((e) => e as String)
            .toSet();
        _verifyNonCash = s['verifyNonCash'] != false;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    if (d == null) {
      return SizedBox(
        height: 220,
        child: Center(
          child: _error != null
              ? Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: LsColors.red),
                  ),
                )
              : const CircularProgressIndicator(),
        ),
      );
    }
    return PsCheckoutForm(
      detail: d,
      methods: _methods,
      proofRequiredMethods: _proofRequired,
      verifyNonCash: _verifyNonCash,
      onPaid: () async {
        _paidSomething = true;
        await _load();
      },
      onClose: () => Navigator.of(context).pop(_paidSomething),
    );
  }
}

String _referenceLabel(String code, bool required) => switch (code) {
  'TELEBIRR' => 'Telebirr transaction ID',
  'BANK_TRANSFER' => 'Bank transaction reference',
  'CARD' => 'Card receipt / approval number',
  _ => required ? 'Reference' : 'Reference (optional)',
};

String _sniffMime(Uint8List b) {
  if (b.length > 3 && b[0] == 0x89 && b[1] == 0x50) return 'image/png';
  if (b.length > 11 && b[0] == 0x52 && b[1] == 0x49 && b[8] == 0x57) {
    return 'image/webp';
  }
  return 'image/jpeg';
}

class PsCheckoutForm extends StatefulWidget {
  final PsSessionDetail detail;
  final List<PaymentMethodOption> methods;
  final Set<String> proofRequiredMethods;
  final bool verifyNonCash;
  final Future<void> Function() onPaid;
  final VoidCallback onClose;
  const PsCheckoutForm({
    super.key,
    required this.detail,
    required this.methods,
    required this.proofRequiredMethods,
    required this.verifyNonCash,
    required this.onPaid,
    required this.onClose,
  });
  @override
  State<PsCheckoutForm> createState() => _PsCheckoutFormState();
}

class _PsCheckoutFormState extends State<PsCheckoutForm> {
  String? _method;
  final _amount = TextEditingController();
  final _tendered = TextEditingController();
  final _reference = TextEditingController();
  Uint8List? _proof;
  bool _busy = false;
  String? _error;

  PsSessionDetail get d => widget.detail;

  @override
  void initState() {
    super.initState();
    _method =
        widget.methods.where((m) => m.code == 'CASH').firstOrNull?.code ??
        widget.methods.firstOrNull?.code;
    _resetAmount();
  }

  @override
  void didUpdateWidget(covariant PsCheckoutForm old) {
    super.didUpdateWidget(old);
    if (old.detail.toCollectMinor != d.toCollectMinor) {
      _resetAmount();
      _tendered.clear();
      _reference.clear();
      _proof = null;
    }
  }

  void _resetAmount() => _amount.text = _plain(d.toCollectMinor);

  static String _plain(int minor) =>
      minor % 100 == 0 ? '${minor ~/ 100}' : (minor / 100).toStringAsFixed(2);
  int? _minor(String s) {
    final v = double.tryParse(s.trim().replaceAll(',', ''));
    return v == null ? null : (v * 100).round();
  }

  bool get _isCash => _method == 'CASH';
  PaymentMethodOption? get _m =>
      widget.methods.where((x) => x.code == _method).firstOrNull;
  bool get _proofRequired =>
      !_isCash && widget.proofRequiredMethods.contains(_method);
  int? get _amountMinor => _minor(_amount.text);
  int? get _tenderedMinor =>
      _tendered.text.trim().isEmpty ? null : _minor(_tendered.text);

  String? get _problem {
    final a = _amountMinor;
    if (_method == null) return 'Choose how the customer paid.';
    if (a == null || a <= 0) return 'Enter the amount being paid.';
    if (a > d.toCollectMinor) {
      return 'That is more than the ${formatMoney(d.toCollectMinor, 'ETB')} still to collect.';
    }
    if (_isCash && _tenderedMinor != null && _tenderedMinor! < a) {
      return 'The cash received is less than the amount being paid.';
    }
    if (!_isCash &&
        (_m?.requiresReference ?? false) &&
        _reference.text.trim().isEmpty) {
      return '${_referenceLabel(_method!, true)} is required.';
    }
    if (_proofRequired && _proof == null) {
      return 'Add a photo or screenshot of the payment.';
    }
    return null;
  }

  Future<void> _pick(ImageSource src) async {
    try {
      final f = await ImagePicker().pickImage(
        source: src,
        maxWidth: 1800,
        maxHeight: 1800,
        imageQuality: 88,
      );
      if (f == null) return;
      final b = await f.readAsBytes();
      if (!mounted) return;
      setState(() {
        _proof = b;
        _error = null;
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = src == ImageSource.camera
              ? 'The camera could not be opened. Choose from the gallery instead.'
              : 'The photo could not be loaded. Try another one.',
        );
      }
    }
  }

  Future<void> _submit() async {
    final a = _amountMinor!;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = await ApiClient.instance();
      final ref = _reference.text.trim();
      final tendered = _isCash ? _tenderedMinor : null;
      Map<String, dynamic> res;
      if (_proof != null && !_isCash) {
        final q = <String, String>{
          'amountMinor': '$a',
          'method': _method!,
          if (ref.isNotEmpty) 'reference': ref,
        };
        res = await api.postRawImage(
          '/playstation/sessions/${d.id}/payments/with-proof?${Uri(queryParameters: q).query}',
          _proof!,
          contentType: _sniffMime(_proof!),
        );
      } else {
        res = await api.post('/playstation/sessions/${d.id}/payments', {
          'amountMinor': a,
          'method': _method,
          if (ref.isNotEmpty && !_isCash) 'reference': ref,
          'tenderedMinor': ?tendered,
        }) as Map<String, dynamic>;
      }
      if (!mounted) return;
      final change = (res['changeMinor'] as num?)?.toInt();
      final pending = ((res['payment'] as Map?)?['status']) == 'PENDING';
      final after = PsSessionDetail.fromJson(res);
      if (change != null && change > 0) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            icon: const Icon(
              Icons.payments_outlined,
              size: 40,
              color: LsColors.green,
            ),
            title: Text('Give ${formatMoney(change, 'ETB')} change'),
            content: Text(
              'Received ${formatMoney(_tenderedMinor ?? 0, 'ETB')} for ${formatMoney(a, 'ETB')}.',
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Done'),
              ),
            ],
          ),
        );
      }
      await widget.onPaid();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            pending
                ? 'Submitted for verification. The balance stays outstanding until an admin verifies it.'
                : after.balanceMinor > 0
                ? 'Payment recorded. ${formatMoney(after.balanceMinor, 'ETB')} still to pay.'
                : 'Paid in full.',
          ),
        ),
      );
      if (after.balanceMinor == 0 || (pending && after.toCollectMinor == 0)) {
        widget.onClose();
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _row(String label, String value, {bool bold = false, Color? color}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: LsColors.muted,
                  fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
            Text(
              value,
              style: TextStyle(
                fontWeight: bold ? FontWeight.w900 : FontWeight.w700,
                fontSize: bold ? 18 : 14.5,
                color: color,
              ),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final d = this.d;
    final change =
        _isCash &&
            _tenderedMinor != null &&
            _amountMinor != null &&
            _tenderedMinor! > _amountMinor!
        ? _tenderedMinor! - _amountMinor!
        : null;
    final quantityLabel = d.pricingType == 'PER_GAME'
        ? '${d.quantity} ${d.quantity == 1 ? 'game' : 'games'}'
        : '${formatDuration(d.purchasedSeconds)} of play';
    final settled = d.toCollectMinor == 0;
    return PsSheetScaffold(
      title: '${d.consoleCode} — Session Checkout',
      subtitle: '${d.sessionNumber}${d.isPlaying ? ' · still playing' : ''}',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: LsColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: LsColors.border),
            ),
            child: Column(
              children: [
                _row('Customer', d.playerName ?? '—'),
                _row('Package', d.packageName),
                _row(
                  d.pricingType == 'PER_GAME'
                      ? 'Games played'
                      : 'Time purchased',
                  quantityLabel,
                ),
                if (d.pricingType == 'PER_GAME')
                  _row('Price per game', formatMoney(d.unitPriceMinor, 'ETB')),
                const Divider(height: 14),
                _row('Total due', formatMoney(d.totalMinor, 'ETB'), bold: true),
                _row('Previously paid', formatMoney(d.settledMinor, 'ETB')),
                if (d.pendingMinor > 0)
                  _row(
                    'Awaiting verification',
                    formatMoney(d.pendingMinor, 'ETB'),
                    color: LsColors.orange,
                  ),
                _row(
                  'Balance remaining',
                  formatMoney(d.balanceMinor, 'ETB'),
                  bold: true,
                  color: d.balanceMinor > 0 ? LsColors.red : LsColors.green,
                ),
              ],
            ),
          ),
          if (settled)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text(
                d.balanceMinor == 0 ? 'Nothing left to pay.' : 'The remaining balance is already covered by payments awaiting verification.',
                style: const TextStyle(color: LsColors.muted),
              ),
            )
          else ...[
            const SizedBox(height: 14),
            const Text(
              'Payment method',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: LsColors.slate,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final m in widget.methods)
                  ChoiceChip(
                    label: Text(m.label),
                    selected: _method == m.code,
                    showCheckmark: true,
                    labelStyle: TextStyle(
                      fontWeight: _method == m.code
                          ? FontWeight.w800
                          : FontWeight.w500,
                    ),
                    onSelected: (_) => setState(() {
                      _method = m.code;
                      _error = null;
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: 'Amount being paid (ETB)',
                helperText: d.toCollectMinor > (_amountMinor ?? 0)
                    ? 'Less than the balance is a partial payment'
                    : null,
              ),
              onChanged: (_) => setState(() {}),
            ),
            if (_isCash) ...[
              const SizedBox(height: 10),
              TextField(
                controller: _tendered,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: 'Cash received (ETB, optional)',
                  helperText: change != null
                      ? 'Change to give back: ${formatMoney(change, 'ETB')}'
                      : 'Fill in to work out the change',
                ),
                onChanged: (_) => setState(() {}),
              ),
            ] else ...[
              const SizedBox(height: 10),
              TextField(
                controller: _reference,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  labelText: _referenceLabel(
                    _method ?? '',
                    _m?.requiresReference ?? false,
                  ),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Payment proof',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: LsColors.slate,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: _proofRequired
                          ? LsColors.orangeSoft
                          : LsColors.graySoft,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _proofRequired ? 'Required' : 'Optional',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: _proofRequired ? LsColors.orange : LsColors.gray,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              if (_proof == null)
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy
                            ? null
                            : () => _pick(ImageSource.camera),
                        icon: const Icon(Icons.photo_camera_outlined),
                        label: const Text('Take photo'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy
                            ? null
                            : () => _pick(ImageSource.gallery),
                        icon: const Icon(Icons.photo_library_outlined),
                        label: const Text('Upload screenshot'),
                      ),
                    ),
                  ],
                )
              else ...[
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    height: 170,
                    color: LsColors.surface2,
                    child: Image.memory(
                      _proof!,
                      fit: BoxFit.contain,
                      width: double.infinity,
                    ),
                  ),
                ),
                Row(
                  children: [
                    TextButton.icon(
                      onPressed: _busy
                          ? null
                          : () => _pick(ImageSource.gallery),
                      icon: const Icon(Icons.swap_horiz),
                      label: const Text('Replace'),
                    ),
                    TextButton.icon(
                      onPressed: _busy ? null : () => _pick(ImageSource.camera),
                      icon: const Icon(Icons.photo_camera_outlined),
                      label: const Text('Retake'),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: _busy
                          ? null
                          : () => setState(() => _proof = null),
                      icon: const Icon(
                        Icons.delete_outline,
                        color: LsColors.red,
                      ),
                      label: const Text(
                        'Remove',
                        style: TextStyle(color: LsColors.red),
                      ),
                    ),
                  ],
                ),
              ],
              if (widget.verifyNonCash)
                Container(
                  margin: const EdgeInsets.only(top: 6),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: LsColors.brandSoft,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.verified_user_outlined,
                        size: 18,
                        color: LsColors.brandStrong,
                      ),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'An administrator checks this payment before it counts. Until then the balance stays outstanding.',
                          style: TextStyle(
                            color: LsColors.brandStrong,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ],
      ),
      action: settled
          ? SizedBox(
              height: 52,
              child: ElevatedButton(
                onPressed: widget.onClose,
                child: const Text('Done'),
              ),
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // The error sits beside the button, not in the scrolling body, so it is never out of sight.
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        _error!,
                        style: const TextStyle(
                          color: LsColors.red,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                SizedBox(
                  height: 52,
                  child: ElevatedButton.icon(
                    onPressed: _problem != null || _busy ? null : _submit,
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.check_circle_outline),
                    label: Text(
                      _busy
                          ? (_proof != null ? 'Uploading proof…' : 'Saving…')
                          : _isCash
                          ? 'Record ${formatMoney(_amountMinor ?? 0, 'ETB')} cash received'
                          : 'Submit ${formatMoney(_amountMinor ?? 0, 'ETB')} payment',
                    ),
                  ),
                ),
              ],
            ),
      secondaryAction: settled
          ? null
          : TextButton(
              onPressed: _busy ? null : widget.onClose,
              child: Text(
                _problem != null && _amountMinor != null
                    ? 'Pay later — balance stays outstanding'
                    : 'Pay later',
              ),
            ),
    );
  }
}
