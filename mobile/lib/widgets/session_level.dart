/// Ports the exact same severity rule the backend's warning worker and the web app both use
/// (backend/src/modules/sessions.ts, web/src/components/ui.tsx levelFor()) — one rule, enforced
/// identically on every client, driven by the venue's own configured thresholds, not hard-coded.
String levelFor(int? remainingSeconds, String status, List<({int minutes, String level})> warnings) {
  if (status == 'PAUSED') return 'paused';
  if (status == 'EXPIRED' || (remainingSeconds != null && remainingSeconds <= 0 && (status == 'ACTIVE' || status == 'EXPIRING'))) {
    return 'expired';
  }
  if (remainingSeconds == null) return 'gray';
  final sorted = [...warnings]..sort((a, b) => a.minutes.compareTo(b.minutes));
  for (final w in sorted) {
    if (remainingSeconds <= w.minutes * 60) return w.level.toLowerCase();
  }
  return 'normal';
}

const Map<String, String> statusLabel = {
  'ACTIVE': 'Active',
  'PAUSED': 'Paused',
  'EXPIRING': 'Ending soon',
  'EXPIRED': 'Time up',
  'COMPLETED': 'Completed',
  'EARLY_EXIT': 'Left early',
  'CANCELLED': 'Cancelled',
  'NO_SHOW': 'No-show',
  'READY': 'Ready to start',
  'CHECKED_IN': 'Checked in',
  'PAYMENT_PENDING': 'Awaiting payment',
  'CREATED': 'Created',
};

String fmtClock(int totalSeconds) {
  final neg = totalSeconds < 0;
  final s = totalSeconds.abs();
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  final mm = m.toString().padLeft(2, '0'), ss = sec.toString().padLeft(2, '0');
  final head = h > 0 ? '$h:$mm' : '$m';
  return '${neg ? '+' : ''}$head:$ss';
}
