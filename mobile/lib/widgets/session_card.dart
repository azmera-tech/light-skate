import 'dart:async';
import 'package:flutter/material.dart';
import '../models/dashboard.dart';
import '../theme.dart';
import 'authed_photo.dart';
import 'status_badge.dart';
import 'session_level.dart';

String _hhmm(DateTime? t) => t == null ? '—' : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// One skater on the live rink. Countdown is display-only, recomputed every second from the
/// authoritative scheduled_end_at timestamp carried on the session — never a locally
/// decremented counter, so it is correct after a reconnect, a restart, or on a second device.
class SessionCard extends StatefulWidget {
  final LiveSession session;
  final List<({int minutes, String level})> warnings;
  final DateTime Function() now;
  final VoidCallback? onTap;
  const SessionCard({super.key, required this.session, required this.warnings, required this.now, this.onTap});

  @override
  State<SessionCard> createState() => _SessionCardState();
}

class _SessionCardState extends State<SessionCard> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    final remaining = s.remainingSeconds(widget.now());
    final level = levelFor(remaining, s.status, widget.warnings);
    final (fg, _) = levelColors(level);

    return Card(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: LsColors.border),
      ),
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border(left: BorderSide(color: fg, width: 6)),
          ),
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              AuthedPhoto(photoId: s.photoId, name: s.customerName, size: 56),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text(s.customerName, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16), overflow: TextOverflow.ellipsis)),
                    LsBadge.forStatus(s.status, level),
                  ]),
                  const SizedBox(height: 2),
                  Text(
                    '${s.productName}${s.wristband != null ? ' · ${s.wristband} band' : ''}',
                    style: const TextStyle(color: LsColors.muted, fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ]),
              ),
            ]),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                remaining == null ? '—' : fmtClock(remaining),
                semanticsLabel: remaining == null ? null : (remaining < 0 ? 'Over time by ${fmtClock(remaining)}' : '${fmtClock(remaining)} remaining'),
                style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: 30, fontFeatures: const [FontFeature.tabularFigures()]),
              ),
            ),
            const Divider(height: 20),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              _meta('Started', _hhmm(s.startedAt)),
              _meta('Ends', _hhmm(s.scheduledEndAt)),
              _meta('Skates', s.equipment.isEmpty ? '—' : s.equipment),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _meta(String label, String value) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: const TextStyle(color: LsColors.muted, fontSize: 12)),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()])),
      ]);
}
