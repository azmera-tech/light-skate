/// Shared formatting helpers — money is always integer minor units end-to-end (never a double),
/// exactly like the backend and the web app (web/src/format.ts).
library;

String formatMoney(int? minor, String currency) {
  if (minor == null) return '—';
  final neg = minor < 0;
  final abs = minor.abs();
  final whole = (abs ~/ 100).toString();
  final grouped = whole.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');
  final frac = abs % 100;
  return '${neg ? '-' : ''}$grouped${frac == 0 ? '' : '.${frac.toString().padLeft(2, '0')}'} $currency';
}

String formatDuration(int totalSeconds) {
  final s = totalSeconds.abs();
  final h = s ~/ 3600, m = (s % 3600) ~/ 60;
  if (h > 0) return '${h}h ${m}m';
  return '${m}m';
}

String fmtHHMM(DateTime? t) => t == null ? '—' : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

String fmtDate(DateTime t) => '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

/// Local display format for an Ethiopian E.164 number: +251912345678 -> 0912 345 678.
String formatPhoneLocal(String? e164) {
  if (e164 == null || e164.isEmpty) return '—';
  var digits = e164.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.startsWith('251')) digits = '0${digits.substring(3)}';
  if (digits.length == 10) return '${digits.substring(0, 4)} ${digits.substring(4, 7)} ${digits.substring(7)}';
  return e164;
}

String titleCase(String s) => s
    .split('_')
    .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}')
    .join(' ');
