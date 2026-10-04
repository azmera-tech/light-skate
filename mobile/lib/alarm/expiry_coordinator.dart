import '../api/api_client.dart';
import '../models/dashboard.dart';
import '../models/session_detail.dart';
import 'expiry_alarm_service.dart';
import 'expiry_queue.dart';

/// Reconciles the live session list (always the server's own authoritative truth — see
/// sessions.ts's `scheduled_end_at` / `processSessionTimers`) against what's currently
/// scheduled/alerted on this device. Called every time fresh dashboard data arrives: on the
/// dashboard's own poll, on a realtime event, and on app resume — never on a bare local timer,
/// so a session is never marked expired just because the app was closed, offline, or asleep;
/// only the server's own status is ever trusted.
class ExpiryCoordinator {
  ExpiryCoordinator._();
  static final ExpiryCoordinator instance = ExpiryCoordinator._();

  final Map<String, DateTime> _scheduledEndAt = {};
  final Set<String> _alerted = {};

  Future<void> reconcile(Dashboard d, ApiClient api) async {
    final liveIds = <String>{};
    for (final s in d.liveSessions) {
      liveIds.add(s.id);

      if (s.scheduledEndAt != null && (s.status == 'ACTIVE' || s.status == 'EXPIRING' || s.status == 'PAUSED')) {
        final prev = _scheduledEndAt[s.id];
        if (prev == null || prev != s.scheduledEndAt) {
          // Covers both "newly scheduled" and "extended" (test D): the stale native alarm for
          // the old end time is cancelled inside scheduleExpiry before the new one is set, so
          // there is never a spurious alarm at the original time.
          _scheduledEndAt[s.id] = s.scheduledEndAt!;
          await ExpiryAlarmService.instance.scheduleExpiry(sessionId: s.id, customerName: s.customerName, scheduledEndAt: s.scheduledEndAt!);
        }
      }

      if (s.status == 'EXPIRED') {
        if (!_alerted.contains(s.id)) {
          _alerted.add(s.id);
          await _surface(s, api);
        }
      } else if (_alerted.remove(s.id)) {
        // Extended back out of EXPIRED, or otherwise no longer expired — resolved.
        expiryQueue.removeBySessionId(s.id);
        await ExpiryAlarmService.instance.cancelExpiry(s.id);
        _scheduledEndAt.remove(s.id);
      }
    }

    // Sessions that vanished from the live list entirely (ended, cancelled, shoes returned and
    // visit completed) are fully resolved — clear every trace of them.
    final resolved = _scheduledEndAt.keys.where((id) => !liveIds.contains(id)).toList();
    for (final id in resolved) {
      _scheduledEndAt.remove(id);
    }
    final resolvedAlerts = _alerted.where((id) => !liveIds.contains(id)).toList();
    for (final id in resolvedAlerts) {
      _alerted.remove(id);
      expiryQueue.removeBySessionId(id);
      await ExpiryAlarmService.instance.cancelExpiry(id);
    }
  }

  Future<void> _surface(LiveSession s, ApiClient api) async {
    String? shoeClaimId, shoeClaimNumber;
    try {
      final json = await api.get('/sessions/${s.id}') as Map<String, dynamic>;
      final detail = SessionDetail.fromJson(json);
      shoeClaimId = detail.shoeClaimId;
      shoeClaimNumber = detail.shoeClaimNumber;
    } catch (_) {
      // Shoe-claim lookup is a nice-to-have on the alert; the alert itself must not be blocked by it.
    }
    expiryQueue.addIfNew(ExpiryAlert(
      sessionId: s.id, customerName: s.customerName, customerPhotoId: s.photoId, productName: s.productName,
      startedAt: s.startedAt, scheduledEndAt: s.scheduledEndAt, equipment: s.equipment,
      shoeClaimId: shoeClaimId, shoeClaimNumber: shoeClaimNumber,
    ));
  }

  /// The notification-tap / cold-launch-from-notification path: only a sessionId is known, and
  /// the queue may be empty (app process was killed). Re-verifies against the server before
  /// showing anything — a stale/duplicate tap for an already-resolved session shows nothing.
  Future<void> surfaceById(String sessionId, ApiClient api) async {
    if (expiryQueue.contains(sessionId)) return;
    try {
      final json = await api.get('/sessions/$sessionId') as Map<String, dynamic>;
      final detail = SessionDetail.fromJson(json);
      if (detail.status != 'EXPIRED') return;
      _alerted.add(sessionId);
      expiryQueue.addIfNew(ExpiryAlert(
        sessionId: sessionId, customerName: detail.session.customerName, customerPhotoId: detail.session.photoId,
        productName: detail.session.productName, startedAt: detail.session.startedAt, scheduledEndAt: detail.session.scheduledEndAt,
        equipment: detail.session.equipment, shoeClaimId: detail.shoeClaimId, shoeClaimNumber: detail.shoeClaimNumber,
      ));
    } catch (_) {
      // Server unreachable — nothing to show yet; the next successful reconcile will catch up.
    }
  }
}
