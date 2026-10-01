/// Payment ledger models (POST/GET /payments*).
library;

class PaymentRecord {
  final String id;
  final String? sessionId;
  final int amountMinor;
  final int refundedMinor;
  final String currency;
  final String method;
  final String status; // PAID | PENDING | FAILED
  final String? providerReference;
  final String? note;
  final DateTime createdAt;
  final String? customerName;
  final String? staffName;
  final bool canRefund;

  PaymentRecord({
    required this.id, required this.sessionId, required this.amountMinor, required this.refundedMinor,
    required this.currency, required this.method, required this.status, required this.providerReference,
    required this.note, required this.createdAt, required this.customerName, required this.staffName, this.canRefund = false,
  });

  factory PaymentRecord.fromJson(Map<String, dynamic> j) => PaymentRecord(
        id: j['id'] as String,
        sessionId: j['sessionId'] as String?,
        amountMinor: (j['amountMinor'] as int?) ?? 0,
        refundedMinor: (j['refundedMinor'] as int?) ?? 0,
        currency: (j['currency'] as String?) ?? 'ETB',
        method: (j['method'] as String?) ?? 'CASH',
        status: (j['status'] as String?) ?? 'PAID',
        providerReference: j['providerReference'] as String?,
        note: j['note'] as String?,
        createdAt: DateTime.tryParse((j['createdAt'] as String?) ?? '') ?? DateTime.now(),
        customerName: j['customerName'] as String?,
        staffName: j['staffName'] as String?,
        canRefund: (j['canRefund'] as bool?) ?? false,
      );
}
