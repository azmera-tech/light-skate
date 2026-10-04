/// Personal shoe check-in claims (POST/GET /shoe-claims*).
library;

class ShoeClaim {
  final String id;
  final String claimNumber;
  final String customerId;
  final String? customerName;
  final String? customerPhotoId;
  final String visitId;
  final String? sessionId;
  final String? sessionStatus; // live status of the linked session, if any
  final String equipment; // comma-joined equipment codes for that session, for the expiry alert
  final String status; // STORED | RETURN_PENDING | RETURNED | MISSING | DISPUTED
  final DateTime createdAt;
  final DateTime? returnedAt;

  ShoeClaim({
    required this.id, required this.claimNumber, required this.customerId, required this.customerName, required this.customerPhotoId,
    required this.visitId, required this.sessionId, required this.sessionStatus, required this.equipment,
    required this.status, required this.createdAt, required this.returnedAt,
  });

  factory ShoeClaim.fromJson(Map<String, dynamic> j) => ShoeClaim(
        id: j['id'] as String,
        claimNumber: (j['claimNumber'] as String?) ?? '',
        customerId: (j['customerId'] as String?) ?? '',
        customerName: j['customerName'] as String?,
        customerPhotoId: j['customerPhotoId'] as String?,
        visitId: (j['visitId'] as String?) ?? '',
        sessionId: j['sessionId'] as String?,
        sessionStatus: j['sessionStatus'] as String?,
        equipment: (j['equipment'] as String?) ?? '',
        status: (j['status'] as String?) ?? 'STORED',
        createdAt: DateTime.tryParse((j['createdAt'] as String?) ?? '') ?? DateTime.now(),
        returnedAt: j['returnedAt'] == null ? null : DateTime.tryParse(j['returnedAt'] as String),
      );

  /// "Session expired, shoes not yet returned" — computed the same way the dashboard/alert
  /// screens decide whether a claim still needs attention; not a stored status of its own.
  bool get returnPending => status != 'RETURNED' && (sessionStatus == 'EXPIRED' || sessionStatus == 'COMPLETED' || sessionStatus == 'EARLY_EXIT');
}

class ShoeClaimListResponse {
  final List<ShoeClaim> items;
  final int onShelf;
  ShoeClaimListResponse({required this.items, required this.onShelf});
  factory ShoeClaimListResponse.fromJson(Map<String, dynamic> j) => ShoeClaimListResponse(
        items: ((j['items'] as List?) ?? const []).map((e) => ShoeClaim.fromJson(e as Map<String, dynamic>)).toList(),
        onShelf: (j['onShelf'] as int?) ?? 0,
      );
}

const shoeIssueTypes = ['SHOE_MISMATCH', 'SHOE_MISSING', 'SHOE_DAMAGED', 'OTHER'];
const shoeIssueLabels = <String, String>{
  'SHOE_MISMATCH': 'Shoe mismatch',
  'SHOE_MISSING': 'Missing shoes',
  'SHOE_DAMAGED': 'Damaged shoes',
  'OTHER': 'Other',
};
