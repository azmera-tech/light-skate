import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../api/api_client.dart';
import '../../format.dart';
import '../../models/customer.dart';
import '../../models/product.dart';
import '../../models/waiver.dart';
import '../../models/equipment.dart';
import '../../models/session_detail.dart';
import '../../theme.dart';
import '../../widgets/authed_photo.dart';
import '../../widgets/camera_capture.dart';
import '../../widgets/signature_pad.dart';
import '../../widgets/status_badge.dart';

enum _Step { customer, details, photo, shoes, waiver, session, payment, start }

const _stepLabels = <_Step, String>{
  _Step.customer: 'Customer',
  _Step.details: 'Customer',
  _Step.photo: 'Photo',
  _Step.shoes: 'Shoes',
  _Step.waiver: 'Waiver',
  _Step.session: 'Session',
  _Step.payment: 'Payment',
  _Step.start: 'Start',
};
const _progressSteps = [_Step.customer, _Step.photo, _Step.shoes, _Step.waiver, _Step.session, _Step.payment, _Step.start];

/// The full check-in wizard: customer (search/register) -> photo -> waiver -> session (package
/// choice) -> payment -> start (equipment + confirm). Matches the web app's step wizard exactly
/// (same steps, same skip rules) but as a single-screen native flow instead of browser routes.
///
/// Pass [customerId] to skip straight past the customer step (e.g. from a profile's
/// "New check-in" button) — everything else proceeds the same way.
class CheckInFlow extends StatefulWidget {
  final String? customerId;
  const CheckInFlow({super.key, this.customerId});
  @override
  State<CheckInFlow> createState() => _CheckInFlowState();
}

class _CheckInFlowState extends State<CheckInFlow> {
  late ApiClient _api;
  FullConfig? _cfg;
  bool _bootDone = false;
  String? _bootError;

  _Step _step = _Step.customer;
  bool _busy = false;
  String? _error;

  // customer
  String? _customerId;
  CustomerProfile? _profile;
  String _normalizedPhone = '';

  // visit
  String? _visitId;

  // photo
  Uint8List? _capturedPhoto;

  // personal shoes
  Uint8List? _shoeBytes;
  String? _shoeClaimId;
  String? _shoeClaimNumber;

  // waiver
  CurrentWaiver? _waiver;

  // session
  Product? _selectedProduct;
  String? _wristband;
  bool _applyDiscount = false;
  final _discountAmountCtrl = TextEditingController();
  final _discountReasonCtrl = TextEditingController();

  // session/payment state (kept in sync via _refreshSession)
  String? _sessionId;
  SessionDetail? _session;

  // start
  List<EquipmentItem> _availableEquipment = [];
  final Set<String> _selectedEquipmentIds = {};
  String? _equipmentSizeFilter;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      _api = await ApiClient.instance();
      final cfgJson = await _api.get('/config') as Map<String, dynamic>;
      _cfg = FullConfig.fromJson(cfgJson);
      if (widget.customerId != null) {
        await _loadProfile(widget.customerId!);
        await _afterCustomerResolved();
      }
    } catch (e) {
      _bootError = e.toString();
    } finally {
      if (mounted) setState(() => _bootDone = true);
    }
  }

  Future<void> _loadProfile(String id) async {
    final json = await _api.get('/customers/$id') as Map<String, dynamic>;
    _profile = CustomerProfile.fromJson(json);
    _customerId = id;
  }

  // ---- step transitions -----------------------------------------------------------------

  Future<void> _afterCustomerResolved() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final visitRes = await _api.post('/visits', {'customerId': _customerId}) as Map<String, dynamic>;
      _visitId = visitRes['id'] as String;
      if (_needsPhoto()) {
        setState(() => _step = _Step.photo);
      } else {
        await _afterPhotoResolved();
      }
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _needsPhoto() {
    if (!(_api.me?.can('customer.update') ?? false)) return false;
    final capture = _cfg!.photoCapture;
    if (capture == 'NEVER') return false;
    if (capture == 'EVERY_VISIT') return true;
    return _profile!.photoId == null; // NEW_CUSTOMER
  }

  Future<void> _afterPhotoResolved() async {
    setState(() => _step = _Step.shoes);
  }

  Future<void> _afterShoesResolved() async {
    if (_profile!.waiver.accepted) {
      setState(() => _step = _Step.session);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final json = await _api.get('/waivers/current') as Map<String, dynamic>?;
      if (json == null || json['waiver'] == null) {
        // No waiver published yet — nothing to accept, proceed (matches backend: NO_WAIVER only
        // blocks acceptance submission, not the whole flow when waiverRequired is effectively moot).
        setState(() => _step = _Step.session);
        return;
      }
      _waiver = CurrentWaiver.fromJson(json['waiver'] as Map<String, dynamic>);
      setState(() => _step = _Step.waiver);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _afterWaiverResolved() async {
    setState(() => _step = _Step.session);
  }

  Future<void> _refreshSession() async {
    final json = await _api.get('/sessions/$_sessionId') as Map<String, dynamic>;
    _session = SessionDetail.fromJson(json);
  }

  // ---- step 1: customer search -----------------------------------------------------------

  Widget _buildCustomerStep() => _CustomerSearchStep(
        api: _api,
        onPicked: (id) async {
          setState(() => _busy = true);
          try {
            await _loadProfile(id);
            await _afterCustomerResolved();
          } on ApiException catch (e) {
            setState(() => _error = e.message);
          } finally {
            if (mounted) setState(() => _busy = false);
          }
        },
        onRegisterNew: (normalizedPhone) {
          setState(() {
            _normalizedPhone = normalizedPhone;
            _step = _Step.details;
          });
        },
      );

  // ---- step 2: new customer details ------------------------------------------------------

  Widget _buildDetailsStep() => _CustomerDetailsStep(
        api: _api,
        initialPhone: _normalizedPhone,
        minorAgeYears: _cfg!.minorAgeYears,
        busy: _busy,
        error: _error,
        onBack: () => setState(() {
          _step = _Step.customer;
          _error = null;
        }),
        onSubmit: (body) async {
          setState(() {
            _busy = true;
            _error = null;
          });
          try {
            final res = await _api.post('/customers', body) as Map<String, dynamic>;
            await _loadProfile(res['id'] as String);
            await _afterCustomerResolved();
          } on ApiException catch (e) {
            if (e.code == 'POSSIBLE_DUPLICATE') {
              final candidates = ((e.details as Map<String, dynamic>?)?['candidates'] as List? ?? const [])
                  .map((c) => CustomerSummary.fromJson(c as Map<String, dynamic>))
                  .toList();
              if (!mounted) return;
              final result = await _showDuplicateDialog(candidates);
              if (result == null) {
                setState(() => _busy = false);
                return;
              }
              if (result is CustomerSummary) {
                await _loadProfile(result.id);
                await _afterCustomerResolved();
              } else {
                // 'different' — resubmit forcing a new, distinct customer record.
                try {
                  final res2 = await _api.post('/customers', {...body, 'confirmDistinct': true}) as Map<String, dynamic>;
                  await _loadProfile(res2['id'] as String);
                  await _afterCustomerResolved();
                } on ApiException catch (e2) {
                  setState(() => _error = e2.message);
                }
              }
            } else {
              setState(() => _error = e.message);
            }
          } finally {
            if (mounted) setState(() => _busy = false);
          }
        },
      );

  Future<dynamic> _showDuplicateDialog(List<CustomerSummary> candidates) {
    return showDialog<dynamic>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Possible existing customer found'),
        content: SizedBox(
          width: 360,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text(
                'Parents often register several children with one number. Is this the same person? '
                'If this is a different person, register them as a new customer.',
                style: TextStyle(color: LsColors.muted),
              ),
              const SizedBox(height: 10),
              ...candidates.map((c) => Card(
                    margin: const EdgeInsets.only(bottom: 6),
                    child: ListTile(
                      leading: AuthedPhoto(photoId: c.photoId, name: c.fullName, size: 40),
                      title: Text(c.fullName),
                      subtitle: Text('${formatPhoneLocal(c.phoneE164)} · ${c.customerCode}'),
                      trailing: FilledButton.tonal(onPressed: () => Navigator.pop(context, c), child: const Text('Same person')),
                    ),
                  )),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, null), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, 'different'), child: const Text('Different person — create new')),
        ],
      ),
    );
  }

  // ---- step 3: photo -----------------------------------------------------------------------

  Widget _buildPhotoStep() {
    final isReturning = _profile!.photoId != null;
    return _StepScaffold(
      title: isReturning ? 'Confirm identity' : 'Take a photo of the customer',
      subtitle: 'The photo helps staff recognise people on the rink. It is stored privately and deleted according to the venue\'s retention policy.',
      busy: _busy,
      error: _error,
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (isReturning) ...[
          Center(child: AuthedPhoto(photoId: _profile!.photoId, name: _profile!.fullName, size: 120)),
          const SizedBox(height: 8),
          Center(child: Text(_profile!.fullName, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
          Center(child: Text(formatPhoneLocal(_profile!.phoneE164), style: const TextStyle(color: LsColors.muted))),
          const SizedBox(height: 16),
        ],
        PhotoPreviewTile(bytes: _capturedPhoto, onTap: _pickPhoto),
      ]),
      actions: [
        if (isReturning)
          OutlinedButton(onPressed: _busy ? null : () => _finishPhotoStep(skip: true), child: const Text('Yes, it is them — keep current photo')),
        TextButton(onPressed: _busy ? null : () => _finishPhotoStep(skip: true), child: const Text('Skip photo')),
        FilledButton(
          onPressed: _busy || _capturedPhoto == null ? null : () => _finishPhotoStep(skip: false),
          child: const Text('Continue'),
        ),
      ],
    );
  }

  Future<void> _pickPhoto() async {
    final bytes = await captureCustomerPhoto(context);
    if (bytes != null) setState(() => _capturedPhoto = bytes);
  }

  Future<void> _finishPhotoStep({required bool skip}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!skip && _capturedPhoto != null) {
        await _api.postRawImage('/customers/$_customerId/photos?purpose=VISIT&visitId=$_visitId', _capturedPhoto!);
        await _loadProfile(_customerId!); // pick up the new photoId
      }
      await _afterPhotoResolved();
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- step 3b: personal shoes --------------------------------------------------------------

  Widget _buildShoesStep() {
    return _StepScaffold(
      title: 'Store personal shoes',
      subtitle: 'Photograph both shoes together, then place them on the shelf. A short claim '
          'number is generated so they can be found again later — keep it until the shoes are returned.',
      busy: _busy,
      error: _error,
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PhotoPreviewTile(bytes: _shoeBytes, onTap: _pickShoePhoto),
      ]),
      actions: [
        TextButton(onPressed: _busy ? null : () => _finishShoesStep(skip: true), child: const Text('No shoes to store')),
        FilledButton.icon(
          onPressed: _busy || _shoeBytes == null ? null : () => _finishShoesStep(skip: false),
          icon: const Icon(Icons.checkroom_outlined),
          label: const Text('Store Personal Shoes'),
        ),
      ],
    );
  }

  Future<void> _pickShoePhoto() async {
    final bytes = await captureCustomerPhoto(context, title: "Photo of customer's shoes");
    if (bytes != null) setState(() => _shoeBytes = bytes);
  }

  Future<void> _finishShoesStep({required bool skip}) async {
    if (skip) {
      await _afterShoesResolved();
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await _api.postRawImage('/shoe-claims?customerId=$_customerId&visitId=$_visitId', _shoeBytes!);
      _shoeClaimId = res['id'] as String?;
      _shoeClaimNumber = res['claimNumber'] as String?;
      if (!mounted) return;
      await _showShoeClaimConfirmation();
      await _afterShoesResolved();
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showShoeClaimConfirmation() {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Personal Shoes Stored'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          ClipRRect(borderRadius: BorderRadius.circular(10), child: Image.memory(_shoeBytes!, height: 120, fit: BoxFit.cover)),
          const SizedBox(height: 16),
          const Text('CLAIM NUMBER', style: TextStyle(color: LsColors.muted, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.5)),
          const SizedBox(height: 4),
          Text('#${_shoeClaimNumber ?? ''}', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: LsColors.brand)),
          const SizedBox(height: 10),
          Text(_profile!.fullName, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: LsColors.yellowSoft, borderRadius: BorderRadius.circular(8)),
            child: const Text('Keep this claim number until your shoes are returned.', textAlign: TextAlign.center, style: TextStyle(color: LsColors.yellow)),
          ),
        ]),
        actions: [
          FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
        ],
      ),
    );
  }

  // ---- step 4: waiver -----------------------------------------------------------------------

  final _guardianNameCtrl = TextEditingController();
  final _guardianPhoneCtrl = TextEditingController();
  bool _waiverChecked = false;
  final _signatureKey = GlobalKey<SignaturePadState>();

  Widget _buildWaiverStep() {
    final isMinor = _profile!.isMinor;
    return StatefulBuilder(builder: (context, setLocal) {
      final valid = _waiverChecked && (!isMinor || (_guardianNameCtrl.text.trim().isNotEmpty && _guardianPhoneCtrl.text.trim().isNotEmpty));
      return _StepScaffold(
        title: _waiver?.title ?? 'Waiver',
        subtitle: _waiver != null ? 'Version ${_waiver!.version}' : null,
        busy: _busy,
        error: _error,
        body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            constraints: const BoxConstraints(maxHeight: 220),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: LsColors.surface2, borderRadius: BorderRadius.circular(10), border: Border.all(color: LsColors.border)),
            child: SingleChildScrollView(child: Text(_waiver?.body ?? '')),
          ),
          if (isMinor) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: LsColors.yellowSoft, borderRadius: BorderRadius.circular(8)),
              child: Text('${_profile!.fullName} is a minor — a parent or guardian must accept.', style: const TextStyle(color: LsColors.yellow)),
            ),
            const SizedBox(height: 10),
            TextField(controller: _guardianNameCtrl, decoration: const InputDecoration(labelText: 'Guardian full name'), onChanged: (_) => setLocal(() {})),
            const SizedBox(height: 10),
            TextField(controller: _guardianPhoneCtrl, decoration: const InputDecoration(labelText: 'Guardian phone'), keyboardType: TextInputType.phone, onChanged: (_) => setLocal(() {})),
          ],
          const SizedBox(height: 12),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _waiverChecked,
            onChanged: (v) => setLocal(() => _waiverChecked = v ?? false),
            title: Text('The ${isMinor ? 'guardian' : 'customer'} has read and accepts the skating rules, assumption of risk and personal-data notice.'),
          ),
          const SizedBox(height: 10),
          const Text('Signature (optional)', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          SignaturePad(key: _signatureKey),
        ]),
        actions: [
          FilledButton(onPressed: !valid || _busy ? null : _submitWaiver, child: const Text('Accept & continue')),
        ],
      );
    });
  }

  Future<void> _submitWaiver() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final sig = await _signatureKey.currentState?.exportPng();
      final body = <String, dynamic>{
        if (_waiver != null) 'waiverVersionId': _waiver!.id,
        if (_visitId != null) 'visitId': _visitId,
        if (sig != null) 'signatureData': 'data:image/png;base64,${base64Encode(sig)}',
        if (_profile!.isMinor) 'guardianName': _guardianNameCtrl.text.trim(),
        if (_profile!.isMinor) 'guardianPhone': _guardianPhoneCtrl.text.trim(),
      };
      await _api.post('/customers/$_customerId/waiver-acceptance', body);
      await _loadProfile(_customerId!);
      await _afterWaiverResolved();
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- step 5: session/package selection -----------------------------------------------------

  List<Product> _products = [];
  bool _productsLoaded = false;

  Future<void> _loadProducts() async {
    if (_productsLoaded) return;
    setState(() => _busy = true);
    try {
      final json = await _api.get('/products?customerId=$_customerId') as Map<String, dynamic>;
      _products = ProductsResponse.fromJson(json).sessions;
      _productsLoaded = true;
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _buildSessionStep() {
    if (!_productsLoaded) {
      _loadProducts();
      return const Center(child: CircularProgressIndicator());
    }
    final canDiscount = _api.me?.can('payment.discount') ?? false;
    return StatefulBuilder(builder: (context, setLocal) {
      final discountValid = !_applyDiscount || (int.tryParse(_discountAmountCtrl.text) != null && _discountReasonCtrl.text.trim().length >= 3);
      return _StepScaffold(
        title: 'Choose session',
        busy: _busy,
        error: _error,
        body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.3,
            children: _products.map((p) {
              final selected = _selectedProduct?.id == p.id;
              return InkWell(
                onTap: () => setLocal(() => _selectedProduct = p),
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  decoration: BoxDecoration(
                    color: selected ? LsColors.brandSoft : LsColors.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: selected ? LsColors.brand : LsColors.border, width: selected ? 2 : 1),
                  ),
                  padding: const EdgeInsets.all(12),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text('${p.durationMinutes} min', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 20)),
                    Text(p.name, style: const TextStyle(color: LsColors.muted)),
                    const SizedBox(height: 4),
                    Text(formatMoney(p.priceMinor, p.currency), style: const TextStyle(fontWeight: FontWeight.w700)),
                  ]),
                ),
              );
            }).toList(),
          ),
          if (_cfg!.wristbandsEnabled) ...[
            const SizedBox(height: 14),
            const Text('Wristband colour', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Wrap(spacing: 8, children: _cfg!.wristbandColors.map((c) {
              final sel = _wristband == c;
              return ChoiceChip(label: Text(c), selected: sel, onSelected: (_) => setLocal(() => _wristband = sel ? null : c));
            }).toList()),
          ],
          if (canDiscount) ...[
            const SizedBox(height: 14),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _applyDiscount,
              onChanged: (v) => setLocal(() => _applyDiscount = v ?? false),
              title: const Text('Apply discount / complimentary'),
            ),
            if (_applyDiscount) ...[
              TextField(
                controller: _discountAmountCtrl,
                decoration: const InputDecoration(labelText: 'Discount amount (minor units, e.g. 2000 = 20.00)'),
                keyboardType: TextInputType.number,
                onChanged: (_) => setLocal(() {}),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _discountReasonCtrl,
                decoration: const InputDecoration(labelText: 'Reason (required)'),
                onChanged: (_) => setLocal(() {}),
              ),
            ],
          ],
        ]),
        actions: [
          FilledButton(
            onPressed: (_selectedProduct == null || !discountValid || _busy) ? null : _submitSession,
            child: Text(_selectedProduct == null
                ? 'Continue'
                : 'Continue — ${formatMoney(_selectedProduct!.priceMinor - (_applyDiscount ? (int.tryParse(_discountAmountCtrl.text) ?? 0) : 0), _selectedProduct!.currency)}'),
          ),
        ],
      );
    });
  }

  Future<void> _submitSession() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final body = <String, dynamic>{
        'visitId': _visitId,
        'pricingRuleId': _selectedProduct!.id,
        if (_applyDiscount) 'discountMinor': int.tryParse(_discountAmountCtrl.text) ?? 0,
        if (_applyDiscount) 'discountReason': _discountReasonCtrl.text.trim(),
        if (_wristband != null) 'wristband': _wristband,
      };
      final res = await _api.post('/sessions', body) as Map<String, dynamic>;
      _sessionId = res['id'] as String;
      if (_shoeClaimId != null) {
        // Best-effort link: the shoe photo is usually taken before the session exists, so the
        // claim is backfilled with the session id once it's created. Not fatal if it fails —
        // the claim is still fully usable by its claim number alone.
        unawaited(_api.post('/shoe-claims/$_shoeClaimId/link-session', {'sessionId': _sessionId}).catchError((_) => null));
      }
      await _refreshSession();
      if (_session!.status == 'READY') {
        await _loadEquipment();
        setState(() => _step = _Step.start);
      } else {
        setState(() => _step = _Step.payment);
      }
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- step 6: payment -----------------------------------------------------------------------

  String? _paymentMethod;
  final _referenceCtrl = TextEditingController();
  final _cashTenderedCtrl = TextEditingController();
  bool _unconfirmed = false;

  Widget _buildPaymentStep() {
    final s = _session!;
    final due = s.dueMinor;
    return StatefulBuilder(builder: (context, setLocal) {
      final method = _cfg!.paymentMethods.where((m) => m.code == _paymentMethod).firstOrNull;
      final tendered = int.tryParse(_cashTenderedCtrl.text.replaceAll(RegExp(r'[^0-9]'), ''));
      final change = (_paymentMethod == 'CASH' && tendered != null && tendered >= due) ? tendered - due : null;
      final needsRef = method?.requiresReference ?? false;
      final valid = _paymentMethod != null && (!needsRef || _referenceCtrl.text.trim().isNotEmpty || _unconfirmed);

      return _StepScaffold(
        title: 'Payment',
        busy: _busy,
        error: _error,
        body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Card(
            color: LsColors.brandSoft,
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                const Text('Amount due', style: TextStyle(fontWeight: FontWeight.w600)),
                Text(formatMoney(due, s.session.wristband != null ? _cfg!.currency : _cfg!.currency), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
              ]),
            ),
          ),
          if (due <= 0)
            const Padding(
              padding: EdgeInsets.only(top: 14),
              child: Text('A payment is already awaiting confirmation for the full amount.', style: TextStyle(color: LsColors.muted)),
            )
          else ...[
            const SizedBox(height: 14),
            const Text('Payment method', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              children: _cfg!.paymentMethods.map((m) {
                final sel = _paymentMethod == m.code;
                return ChoiceChip(label: Text(m.label), selected: sel, onSelected: (_) => setLocal(() => _paymentMethod = m.code));
              }).toList(),
            ),
            if (needsRef) ...[
              const SizedBox(height: 10),
              TextField(
                controller: _referenceCtrl,
                decoration: InputDecoration(labelText: '${method?.label ?? 'Payment'} reference / receipt number'),
                onChanged: (_) => setLocal(() {}),
              ),
              const SizedBox(height: 6),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _unconfirmed,
                onChanged: (v) => setLocal(() => _unconfirmed = v ?? false),
                title: const Text('Not yet confirmed (awaiting transfer). The session will stay on "awaiting payment".'),
              ),
            ],
            if (_paymentMethod == 'CASH') ...[
              const SizedBox(height: 10),
              TextField(
                controller: _cashTenderedCtrl,
                decoration: const InputDecoration(labelText: 'Cash received (minor units, optional)'),
                keyboardType: TextInputType.number,
                onChanged: (_) => setLocal(() {}),
              ),
              if (change != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text('Change to give: ${formatMoney(change, _cfg!.currency)}')),
            ],
          ],
        ]),
        actions: [
          if (due <= 0)
            FilledButton(onPressed: _busy ? null : () => _pollPaymentThenAdvance(), child: const Text('Continue'))
          else
            FilledButton(
              onPressed: (!valid || _busy) ? null : _submitPayment,
              child: Text(_unconfirmed ? 'Record pending payment' : 'Record ${formatMoney(due, _cfg!.currency)} received'),
            ),
        ],
      );
    });
  }

  Future<void> _pollPaymentThenAdvance() async {
    setState(() => _busy = true);
    try {
      await _refreshSession();
      if (_session!.status == 'READY') {
        await _loadEquipment();
        setState(() => _step = _Step.start);
      }
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submitPayment() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final body = <String, dynamic>{
        'sessionId': _sessionId,
        'amountMinor': _session!.dueMinor,
        'method': _paymentMethod,
        if (_referenceCtrl.text.trim().isNotEmpty) 'reference': _referenceCtrl.text.trim(),
        'confirmed': !_unconfirmed,
      };
      await _api.post('/payments', body);
      await _refreshSession();
      if (_session!.status == 'READY') {
        await _loadEquipment();
        setState(() => _step = _Step.start);
      }
      // else: still due (partial payment) — stay on Payment, UI refreshes with the new due amount.
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- step 7: start (equipment + confirm) ---------------------------------------------------

  Future<void> _loadEquipment() async {
    if (!(_api.me?.can('equipment.assign') ?? false)) return;
    try {
      final json = await _api.get('/equipment?status=AVAILABLE') as Map<String, dynamic>;
      _availableEquipment = EquipmentListResponse.fromJson(json).items;
    } catch (_) {
      // equipment is optional at check-in; a failed fetch just means the picker stays empty
    }
  }

  Widget _buildStartStep() {
    final s = _session!;
    return StatefulBuilder(builder: (context, setLocal) {
      final sizes = _availableEquipment.map((e) => e.size).whereType<String>().toSet().toList()..sort();
      final filtered = _equipmentSizeFilter == null ? _availableEquipment : _availableEquipment.where((e) => e.size == _equipmentSizeFilter).toList();
      final requireEquipment = _cfg!.equipmentRequiredForStart && _selectedEquipmentIds.isEmpty;

      return _StepScaffold(
        title: 'Ready to start',
        busy: _busy,
        error: _error,
        body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Center(child: AuthedPhoto(photoId: _profile!.photoId, name: _profile!.fullName, size: 96)),
          const SizedBox(height: 8),
          Center(child: Text(_profile!.fullName, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17))),
          Center(child: Text('${s.session.productName} · ${_selectedProduct?.durationMinutes ?? ''} min', style: const TextStyle(color: LsColors.muted))),
          const SizedBox(height: 10),
          Center(
            child: LsBadge(label: 'Paid ${formatMoney(s.paidMinor, _cfg!.currency)}', level: 'normal', icon: Icons.check_circle_outline),
          ),
          if (_availableEquipment.isNotEmpty) ...[
            const SizedBox(height: 18),
            const Text('Issue rental skates (optional)', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            if (sizes.length > 1)
              Wrap(spacing: 6, children: [
                ChoiceChip(label: const Text('All sizes'), selected: _equipmentSizeFilter == null, onSelected: (_) => setLocal(() => _equipmentSizeFilter = null)),
                ...sizes.map((sz) => ChoiceChip(label: Text(sz), selected: _equipmentSizeFilter == sz, onSelected: (_) => setLocal(() => _equipmentSizeFilter = sz))),
              ]),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: filtered.map((e) {
                final sel = _selectedEquipmentIds.contains(e.id);
                return FilterChip(
                  label: Text('#${e.code}${e.size != null ? ' (${e.size})' : ''}'),
                  selected: sel,
                  onSelected: (v) => setLocal(() => v ? _selectedEquipmentIds.add(e.id) : _selectedEquipmentIds.remove(e.id)),
                );
              }).toList(),
            ),
            if (_selectedEquipmentIds.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('Selected: ${_selectedEquipmentIds.map((id) => _availableEquipment.firstWhere((e) => e.id == id).code).join(', ')}', style: const TextStyle(color: LsColors.muted)),
              ),
            if (requireEquipment)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('This venue requires skates to be issued before starting.', style: TextStyle(color: LsColors.orange)),
              ),
          ],
        ]),
        actions: [
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: LsColors.green, minimumSize: const Size.fromHeight(52)),
            onPressed: (requireEquipment || _busy) ? null : _submitStart,
            icon: const Icon(Icons.play_arrow),
            label: const Text('START SKATING', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 0.5)),
          ),
        ],
      );
    });
  }

  Future<void> _submitStart({String? overrideCapacityReason}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final body = <String, dynamic>{
        if (_selectedEquipmentIds.isNotEmpty) 'equipmentIds': _selectedEquipmentIds.toList(),
        if (_wristband != null) 'wristband': _wristband,
        // The null-aware `?key:` marker checks the KEY's nullability, not the value's, so it
        // doesn't apply to this conditional-value case.
        // ignore: use_null_aware_elements
        if (overrideCapacityReason != null) 'overrideCapacityReason': overrideCapacityReason,
      };
      await _api.post('/sessions/$_sessionId/start', body);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${_profile!.fullName} is skating.')));
      Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (e.code == 'VENUE_FULL') {
        final details = e.details as Map<String, dynamic>?;
        final canOverride = (details?['canOverride'] as bool?) ?? false;
        if (canOverride) {
          if (!mounted) return;
          final reason = await showDialog<String>(
            context: context,
            builder: (context) {
              final ctrl = TextEditingController();
              return AlertDialog(
                title: const Text('Venue full — override capacity?'),
                content: TextField(controller: ctrl, decoration: const InputDecoration(labelText: 'Reason (required)'), autofocus: true),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                  FilledButton(onPressed: () => Navigator.pop(context, ctrl.text.trim()), child: const Text('Override & start')),
                ],
              );
            },
          );
          if (reason != null && reason.length >= 3) {
            await _submitStart(overrideCapacityReason: reason);
            return;
          }
        }
        setState(() => _error = e.message);
      } else {
        setState(() => _error = e.message);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---- shell ----------------------------------------------------------------------------------

  @override
  void dispose() {
    _discountAmountCtrl.dispose();
    _discountReasonCtrl.dispose();
    _guardianNameCtrl.dispose();
    _guardianPhoneCtrl.dispose();
    _referenceCtrl.dispose();
    _cashTenderedCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_bootDone) {
      return Scaffold(appBar: AppBar(title: const Text('Check-in')), body: const Center(child: CircularProgressIndicator()));
    }
    if (_bootError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Check-in')),
        body: Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_bootError!, textAlign: TextAlign.center))),
      );
    }

    Widget body;
    switch (_step) {
      case _Step.customer:
        body = _buildCustomerStep();
        break;
      case _Step.details:
        body = _buildDetailsStep();
        break;
      case _Step.photo:
        body = _buildPhotoStep();
        break;
      case _Step.shoes:
        body = _buildShoesStep();
        break;
      case _Step.waiver:
        body = _buildWaiverStep();
        break;
      case _Step.session:
        body = _buildSessionStep();
        break;
      case _Step.payment:
        body = _buildPaymentStep();
        break;
      case _Step.start:
        body = _buildStartStep();
        break;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Check-in'),
        actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel', style: TextStyle(color: LsColors.red)))],
      ),
      body: Column(children: [
        _ProgressHeader(current: _step),
        Expanded(child: body),
      ]),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

class _ProgressHeader extends StatelessWidget {
  final _Step current;
  const _ProgressHeader({required this.current});
  @override
  Widget build(BuildContext context) {
    final currentIndex = _progressSteps.indexOf(current == _Step.details ? _Step.customer : current);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: _progressSteps.asMap().entries.map((e) {
          final done = e.key < currentIndex;
          final active = e.key == currentIndex;
          return Expanded(
            child: Column(children: [
              CircleAvatar(
                radius: 11,
                backgroundColor: done ? LsColors.green : (active ? LsColors.brand : LsColors.graySoft),
                child: done
                    ? const Icon(Icons.check, size: 13, color: Colors.white)
                    : Text('${e.key + 1}', style: TextStyle(fontSize: 11, color: active ? Colors.white : LsColors.muted)),
              ),
              const SizedBox(height: 3),
              Text(_stepLabels[e.value]!, style: TextStyle(fontSize: 10, color: active ? LsColors.brand : LsColors.muted, fontWeight: active ? FontWeight.w700 : FontWeight.w400)),
            ]),
          );
        }).toList(),
      ),
    );
  }
}

/// Shared layout for every step after customer search: title/subtitle, scrollable body, error
/// banner, and a bottom action bar — mirrors the web wizard's consistent step chrome.
class _StepScaffold extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget body;
  final List<Widget> actions;
  final bool busy;
  final String? error;
  const _StepScaffold({required this.title, this.subtitle, required this.body, required this.actions, required this.busy, this.error});

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(title, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
            if (subtitle != null) Padding(padding: const EdgeInsets.only(top: 2), child: Text(subtitle!, style: const TextStyle(color: LsColors.muted, fontSize: 12))),
            const SizedBox(height: 14),
            if (error != null)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: LsColors.redSoft, borderRadius: BorderRadius.circular(8)),
                child: Text(error!, style: const TextStyle(color: LsColors.red)),
              ),
            body,
          ]),
        ),
      ),
      if (busy) const LinearProgressIndicator(minHeight: 2),
      SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(mainAxisAlignment: MainAxisAlignment.end, children: actions.map((a) => Padding(padding: const EdgeInsets.only(left: 8), child: a)).toList()),
        ),
      ),
    ]);
  }
}

// ---- customer search + registration step widgets --------------------------------------------

class _CustomerSearchStep extends StatefulWidget {
  final ApiClient api;
  final void Function(String customerId) onPicked;
  final void Function(String normalizedPhone) onRegisterNew;
  const _CustomerSearchStep({required this.api, required this.onPicked, required this.onRegisterNew});
  @override
  State<_CustomerSearchStep> createState() => _CustomerSearchStepState();
}

class _CustomerSearchStepState extends State<_CustomerSearchStep> {
  final _phoneCtrl = TextEditingController();
  List<CustomerSummary> _results = [];
  String? _normalizedPhone;
  bool _loading = false;
  bool _searched = false;

  Future<void> _search(String raw) async {
    final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length < 4) {
      setState(() {
        _results = [];
        _searched = false;
        _normalizedPhone = null;
      });
      return;
    }
    setState(() => _loading = true);
    try {
      final json = await widget.api.get('/customers?q=${Uri.encodeQueryComponent(raw)}&limit=8') as Map<String, dynamic>;
      setState(() {
        _results = (json['customers'] as List? ?? const []).map((e) => CustomerSummary.fromJson(e as Map<String, dynamic>)).toList();
        _normalizedPhone = json['normalizedPhone'] as String?;
        _searched = true;
      });
    } catch (_) {
      // a transient search failure shouldn't block typing; just show no results
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canRegister = widget.api.me?.can('customer.create') ?? false;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: TextField(
          controller: _phoneCtrl,
          autofocus: true,
          keyboardType: TextInputType.phone,
          decoration: InputDecoration(
            labelText: 'Customer phone number',
            hintText: 'Any format works: 0912345678, +251912345678',
            prefixIcon: const Icon(Icons.phone),
            suffixIcon: _loading ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))) : null,
          ),
          onChanged: _search,
        ),
      ),
      Expanded(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            ..._results.map((c) => Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: ListTile(
                    leading: AuthedPhoto(photoId: c.photoId, name: c.fullName, size: 44),
                    title: Text(c.fullName, style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text('${formatPhoneLocal(c.phoneE164)} · ${c.customerCode} · ${c.visitCount} visits'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => widget.onPicked(c.id),
                  ),
                )),
            if (_searched && _results.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('No existing customer with this number.', style: TextStyle(color: LsColors.muted)),
              ),
            if (canRegister) ...[
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: _normalizedPhone == null ? null : () => widget.onRegisterNew(_normalizedPhone!),
                icon: const Icon(Icons.person_add_alt_1),
                label: Text(_normalizedPhone == null ? 'Register new customer' : 'Register new customer ($_normalizedPhone)'),
              ),
            ],
          ],
        ),
      ),
    ]);
  }
}

class _CustomerDetailsStep extends StatefulWidget {
  final ApiClient api;
  final String initialPhone;
  final int minorAgeYears;
  final bool busy;
  final String? error;
  final VoidCallback onBack;
  final void Function(Map<String, dynamic> body) onSubmit;
  const _CustomerDetailsStep({
    required this.api, required this.initialPhone, required this.minorAgeYears, required this.busy,
    required this.error, required this.onBack, required this.onSubmit,
  });
  @override
  State<_CustomerDetailsStep> createState() => _CustomerDetailsStepState();
}

class _CustomerDetailsStepState extends State<_CustomerDetailsStep> {
  late final _nameCtrl = TextEditingController();
  late final _phoneCtrl = TextEditingController(text: widget.initialPhone);
  final _emailCtrl = TextEditingController();
  final _guardianNameCtrl = TextEditingController();
  final _guardianPhoneCtrl = TextEditingController();
  DateTime? _dob;

  bool get _looksMinor => _dob != null && DateTime.now().difference(_dob!).inDays < widget.minorAgeYears * 365;

  @override
  Widget build(BuildContext context) {
    return StatefulBuilder(builder: (context, setLocal) {
      final valid = _nameCtrl.text.trim().length >= 2;
      return _StepScaffold(
        title: 'New customer',
        busy: widget.busy,
        error: widget.error,
        body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(controller: _nameCtrl, autofocus: true, decoration: const InputDecoration(labelText: 'Full name'), onChanged: (_) => setLocal(() {})),
          const SizedBox(height: 10),
          TextField(controller: _phoneCtrl, decoration: const InputDecoration(labelText: 'Phone'), keyboardType: TextInputType.phone),
          const SizedBox(height: 10),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(_dob == null ? 'Date of birth (optional)' : fmtDate(_dob!)),
            subtitle: const Text('Used for child pricing and the guardian workflow', style: TextStyle(color: LsColors.muted)),
            trailing: const Icon(Icons.calendar_today, size: 18),
            onTap: () async {
              final picked = await showDatePicker(context: context, initialDate: DateTime(2010), firstDate: DateTime(1920), lastDate: DateTime.now());
              if (picked != null) setLocal(() => _dob = picked);
            },
          ),
          TextField(controller: _emailCtrl, decoration: const InputDecoration(labelText: 'Email (optional)'), keyboardType: TextInputType.emailAddress),
          if (_looksMinor) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: LsColors.yellowSoft, borderRadius: BorderRadius.circular(8)),
              child: const Text('This customer is a minor. A guardian must accept the waiver. Add the guardian below.', style: TextStyle(color: LsColors.yellow)),
            ),
          ],
          const SizedBox(height: 10),
          TextField(controller: _guardianNameCtrl, decoration: InputDecoration(labelText: _looksMinor ? 'Guardian name' : 'Emergency contact name (optional)')),
          const SizedBox(height: 10),
          TextField(controller: _guardianPhoneCtrl, decoration: InputDecoration(labelText: _looksMinor ? 'Guardian phone' : 'Emergency contact phone (optional)'), keyboardType: TextInputType.phone),
        ]),
        actions: [
          OutlinedButton(onPressed: widget.busy ? null : widget.onBack, child: const Text('Back')),
          FilledButton(
            onPressed: (!valid || widget.busy)
                ? null
                : () => widget.onSubmit({
                      'fullName': _nameCtrl.text.trim(),
                      'phone': _phoneCtrl.text.trim(),
                      if (_dob != null) 'dateOfBirth': fmtDate(_dob!),
                      if (_emailCtrl.text.trim().isNotEmpty) 'email': _emailCtrl.text.trim(),
                      if (_guardianNameCtrl.text.trim().isNotEmpty || _guardianPhoneCtrl.text.trim().isNotEmpty)
                        'emergencyContact': {
                          'name': _guardianNameCtrl.text.trim(),
                          'phone': _guardianPhoneCtrl.text.trim(),
                          'isGuardian': _looksMinor,
                        },
                    }),
            child: const Text('Save & continue'),
          ),
        ],
      );
    });
  }
}
