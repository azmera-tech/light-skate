import 'package:flutter/material.dart';
import '../theme.dart';
import 'session_level.dart';

/// Same principle as the web app's badges: colour is never the only signal — every badge
/// carries a text label and an icon too, so it reads correctly for colour-blind staff.
class LsBadge extends StatelessWidget {
  final String label;
  final String level;
  final IconData icon;
  const LsBadge({super.key, required this.label, required this.level, this.icon = Icons.circle});

  factory LsBadge.forStatus(String status, String level) {
    String label = statusLabel[status] ?? status;
    IconData icon = Icons.check_circle;
    if (status == 'ACTIVE' && level != 'normal') {
      label = level == 'red' ? 'Last minute' : level == 'orange' ? 'Finishing' : 'Ending soon';
      icon = Icons.warning_amber_rounded;
    } else if (status == 'EXPIRING') {
      icon = Icons.warning_amber_rounded;
    } else if (status == 'PAUSED') {
      icon = Icons.pause_circle_outline;
    } else if (status == 'EXPIRED') {
      icon = Icons.stop_circle_outlined;
    } else if (status == 'ACTIVE') {
      icon = Icons.play_circle_outline;
    }
    return LsBadge(label: label, level: level, icon: icon);
  }

  @override
  Widget build(BuildContext context) {
    final (fg, bg) = levelColors(level);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 13, color: fg),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w700)),
      ]),
    );
  }
}
