import 'package:flutter/material.dart';
import '../models/loyalty.dart';

/// Where the 10 stamp circles and the "Name:" line sit on each tier's card artwork (pixels in the
/// original image). Positions run left→right, top row (1-5) then bottom row (6-10), as printed.
class TierArt {
  final String asset;
  final double width;
  final double height;
  final List<double> xs;
  final List<double> ys;
  final double radius;
  final Offset nameAt;
  final double nameRight;
  final Color stamp;
  final Color stampInk;
  final Color nameColor;
  const TierArt({
    required this.asset, required this.width, required this.height, required this.xs, required this.ys, required this.radius,
    required this.nameAt, required this.nameRight, required this.stamp, required this.stampInk, required this.nameColor,
  });

  Offset slot(int position) => Offset(xs[(position - 1) % 5], ys[(position - 1) ~/ 5]);

  static const standard = TierArt(
    asset: 'assets/loyalty/standard.jpg', width: 1004, height: 648, xs: [167, 330, 495, 660, 830], ys: [330, 455], radius: 58,
    nameAt: Offset(192, 238), nameRight: 925, stamp: Color(0xFF1F3C9E), stampInk: Colors.white, nameColor: Colors.white,
  );
  static const golden = TierArt(
    asset: 'assets/loyalty/golden.jpg', width: 1004, height: 649, xs: [145, 307, 470, 643, 822], ys: [326, 449], radius: 60,
    nameAt: Offset(184, 234), nameRight: 925, stamp: Color(0xFF151515), stampInk: Color(0xFFFFD21F), nameColor: Color(0xFFFFD21F),
  );
  static const diamond = TierArt(
    asset: 'assets/loyalty/diamond.jpg', width: 1004, height: 650, xs: [167, 332, 497, 662, 830], ys: [330, 458], radius: 58,
    nameAt: Offset(192, 239), nameRight: 930, stamp: Color(0xFF173C86), stampInk: Color(0xFFBFEAFF), nameColor: Colors.white,
  );
  static const light = TierArt(
    asset: 'assets/loyalty/light.jpg', width: 1004, height: 649, xs: [167, 330, 495, 660, 830], ys: [330, 456], radius: 58,
    nameAt: Offset(184, 238), nameRight: 925, stamp: Color(0xFFD01F26), stampInk: Colors.white, nameColor: Colors.white,
  );

  static TierArt of(String tier) => switch (tier) {
        'GOLDEN' => golden,
        'DIAMOND' => diamond,
        'LIGHT' => light,
        _ => standard,
      };
}

/// Accent color per tier for chips, progress bars and headers around the card.
Color tierColor(String tier) => switch (tier) {
      'GOLDEN' => const Color(0xFFB98900),
      'DIAMOND' => const Color(0xFF1C8FC4),
      'LIGHT' => const Color(0xFFC4161C),
      _ => const Color(0xFF2747B0),
    };

/// The customer's physical loyalty card, digitally: the real tier artwork with each earned
/// position stamped. Reward positions keep the printed badge; once earned they get a stamp
/// ring plus an EARNED (still to use) or USED marker — earning is never shown as redeemed.
class LoyaltyCardView extends StatelessWidget {
  final String tier;
  final List<LoyaltyPosition> positions;
  final String? name;
  final bool completedVip;
  const LoyaltyCardView({super.key, required this.tier, required this.positions, this.name, this.completedVip = false});

  @override
  Widget build(BuildContext context) {
    final art = TierArt.of(tier);
    final nextPos = positions.where((p) => !p.earned).map((p) => p.position).fold<int?>(null, (a, b) => a ?? b);
    return AspectRatio(
      aspectRatio: art.width / art.height,
      child: LayoutBuilder(builder: (context, box) {
        final k = box.maxWidth / art.width;
        final r = art.radius * k;
        return ClipRRect(
          borderRadius: BorderRadius.circular(14 * k + 4),
          child: Stack(children: [
            Positioned.fill(child: Image.asset(art.asset, fit: BoxFit.fill, filterQuality: FilterQuality.medium)),
            if (name != null && name!.isNotEmpty)
              Positioned(
                left: art.nameAt.dx * k,
                width: (art.nameRight - art.nameAt.dx) * k,
                top: (art.nameAt.dy - 24) * k,
                height: 40 * k,
                child: FittedBox(
                  alignment: Alignment.centerLeft,
                  fit: BoxFit.scaleDown,
                  child: Text(name!, style: TextStyle(color: art.nameColor, fontWeight: FontWeight.w800, fontSize: 30, letterSpacing: 0.5, fontStyle: FontStyle.italic)),
                ),
              ),
            for (final p in positions)
              Positioned(
                left: art.slot(p.position).dx * k - r,
                top: art.slot(p.position).dy * k - r,
                width: r * 2,
                height: r * 2,
                child: _Slot(p: p, art: art, scale: k, isNext: p.position == nextPos && !completedVip),
              ),
            if (completedVip)
              Positioned(
                right: 10 * k,
                top: 10 * k,
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 14 * k, vertical: 6 * k),
                  decoration: BoxDecoration(color: const Color(0xFFD4A21A), borderRadius: BorderRadius.circular(20 * k), boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 4)]),
                  child: Text('VIP · COMPLETE', style: TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: 20 * k, letterSpacing: 1)),
                ),
              ),
          ]),
        );
      }),
    );
  }
}

class _Slot extends StatelessWidget {
  final LoyaltyPosition p;
  final TierArt art;
  final double scale;
  final bool isNext;
  const _Slot({required this.p, required this.art, required this.scale, required this.isNext});

  @override
  Widget build(BuildContext context) {
    final label = p.isReward
        ? '${p.label ?? 'Reward'} at stamp ${p.position}: ${p.earned ? (p.rewardStatus == 'REDEEMED' ? 'earned and used' : 'earned, not used yet') : 'not yet earned'}'
        : 'Stamp ${p.position}: ${p.earned ? 'earned' : 'not yet earned'}';
    Widget child;
    if (!p.earned) {
      child = isNext
          ? DecoratedBox(decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: art.stamp.withValues(alpha: 0.85), width: 4 * scale + 1.5)))
          : const SizedBox.shrink();
    } else if (!p.isReward) {
      child = Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: art.stamp.withValues(alpha: 0.92),
          border: Border.all(color: art.stampInk.withValues(alpha: 0.9), width: 5 * scale + 1),
          boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 3, offset: Offset(0, 1))],
        ),
        alignment: Alignment.center,
        child: FractionallySizedBox(
          widthFactor: 0.7,
          heightFactor: 0.7,
          child: FittedBox(child: Icon(Icons.check_rounded, color: art.stampInk)),
        ),
      );
    } else {
      final used = p.rewardStatus == 'REDEEMED';
      child = Stack(clipBehavior: Clip.none, children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: used ? Colors.black.withValues(alpha: 0.35) : Colors.transparent,
              border: Border.all(color: used ? Colors.grey.shade600 : const Color(0xFF12A150), width: 7 * scale + 1.5),
            ),
          ),
        ),
        // A small ribbon along the bottom edge so the printed reward badge stays readable.
        Positioned(
          left: -8 * scale,
          right: -8 * scale,
          bottom: -12 * scale,
          height: 26 * scale + 8,
          child: Center(
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 10 * scale + 3, vertical: 2),
              decoration: BoxDecoration(color: used ? Colors.grey.shade700 : const Color(0xFF12A150), borderRadius: BorderRadius.circular(10)),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(used ? 'USED' : 'EARNED', maxLines: 1, softWrap: false, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 13, letterSpacing: 0.5)),
              ),
            ),
          ),
        ),
      ]);
    }
    return Semantics(label: label, child: child);
  }
}

/// "2 of 3 cards completed" as a row of small card pips plus a bar for the current card.
class TierProgressIndicator extends StatelessWidget {
  final String tier;
  final int completed;
  final int required;
  final int stampsOnCard;
  final bool maxCompleted;
  const TierProgressIndicator({super.key, required this.tier, required this.completed, required this.required, required this.stampsOnCard, this.maxCompleted = false});

  @override
  Widget build(BuildContext context) {
    final c = tierColor(tier);
    return Row(children: [
      for (var i = 0; i < required; i++)
        Padding(
          padding: const EdgeInsets.only(right: 6),
          child: Container(
            width: 34,
            height: 22,
            decoration: BoxDecoration(
              color: i < completed || maxCompleted ? c : c.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: c, width: 1.5),
            ),
            alignment: Alignment.center,
            child: i < completed || maxCompleted
                ? const Icon(Icons.check, size: 15, color: Colors.white)
                : i == completed
                    ? Text('$stampsOnCard/10', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: c))
                    : null,
          ),
        ),
      const SizedBox(width: 4),
      Expanded(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: maxCompleted ? 1 : (completed * 10 + stampsOnCard) / (required * 10),
            minHeight: 8,
            color: c,
            backgroundColor: c.withValues(alpha: 0.12),
          ),
        ),
      ),
    ]);
  }
}
