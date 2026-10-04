import 'package:flutter/foundation.dart';

/// Everything the full-screen expiry alert needs to show, snapshotted at the moment a session
/// was found to be expired — see spec section 9 (customer photo, name, session details, shoe
/// claim, equipment).
class ExpiryAlert {
  final String sessionId;
  final String customerName;
  final String? customerPhotoId;
  final String productName;
  final DateTime? startedAt;
  final DateTime? scheduledEndAt;
  final String equipment; // comma-joined codes, "" if none
  final String? shoeClaimId;
  final String? shoeClaimNumber;

  ExpiryAlert({
    required this.sessionId, required this.customerName, required this.customerPhotoId, required this.productName,
    required this.startedAt, required this.scheduledEndAt, required this.equipment,
    required this.shoeClaimId, required this.shoeClaimNumber,
  });
}

/// A small, app-wide queue of currently-unacknowledged expiry alerts — "3 Sessions Expired",
/// each tied to its own customer/session/claim/equipment, never overwriting one another.
/// Staff can step through them; dismissing one just moves to the next (or closes if none
/// remain) without losing the others, and reopening the queue later (via AppShell's chip)
/// finds exactly the sessions still genuinely unresolved on the server.
class ExpiryQueue extends ChangeNotifier {
  final List<ExpiryAlert> _items = [];
  int currentIndex = 0;

  List<ExpiryAlert> get items => List.unmodifiable(_items);
  bool get isEmpty => _items.isEmpty;
  int get length => _items.length;
  bool isShowing = false;

  bool contains(String sessionId) => _items.any((a) => a.sessionId == sessionId);

  void addIfNew(ExpiryAlert alert) {
    if (contains(alert.sessionId)) return;
    _items.add(alert);
    notifyListeners();
  }

  /// Removes a resolved session (returned/ended/extended back to active) from the queue —
  /// called by the reconciler, never by the alert screen itself (dismiss ≠ resolve).
  void removeBySessionId(String sessionId) {
    final before = _items.length;
    _items.removeWhere((a) => a.sessionId == sessionId);
    if (_items.length != before) {
      if (currentIndex >= _items.length) currentIndex = _items.isEmpty ? 0 : _items.length - 1;
      notifyListeners();
    }
  }

  void setIndex(int i) {
    if (i < 0 || i >= _items.length) return;
    currentIndex = i;
    notifyListeners();
  }
}

/// One instance for the whole app — a session's expiry alert must be visible and navigable
/// from anywhere (the notification tap, the dashboard, AppShell's persistent chip), not scoped
/// to whichever screen happened to be open when it was detected.
final expiryQueue = ExpiryQueue();
