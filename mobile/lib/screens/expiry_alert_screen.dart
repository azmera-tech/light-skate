import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../alarm/expiry_queue.dart';
import '../format.dart';
import '../theme.dart';
import '../widgets/authed_photo.dart';
import '../widgets/shoe_photo.dart';
import 'session_detail_screen.dart';
import 'shoes/shoe_return_screen.dart';

/// The "very important" full-screen session-expiry alert (spec section 9). Shown immediately
/// when a session is found to be expired, whether that's because the app was already open and
/// polling, or because staff just tapped the native notification that fired while the app was
/// backgrounded/locked. Plays a short, repeating, bounded alert sound until dismissed — never
/// an open-ended loop (section 10).
class ExpiryAlertScreen extends StatefulWidget {
  const ExpiryAlertScreen({super.key});
  @override
  State<ExpiryAlertScreen> createState() => _ExpiryAlertScreenState();
}

class _ExpiryAlertScreenState extends State<ExpiryAlertScreen> {
  Timer? _soundTimer;
  int _soundTicks = 0;
  static const _maxSoundTicks = 20; // ~30s at the 1.5s interval below — a hard stop, never "uncontrolled"

  @override
  void initState() {
    super.initState();
    expiryQueue.addListener(_onQueueChanged);
    _startSound();
  }

  void _onQueueChanged() {
    if (expiryQueue.isEmpty && mounted) Navigator.of(context).pop();
    if (mounted) setState(() {});
  }

  void _startSound() {
    _playOnce();
    _soundTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      _soundTicks++;
      if (_soundTicks >= _maxSoundTicks) {
        _soundTimer?.cancel();
        return;
      }
      _playOnce();
    });
  }

  void _playOnce() {
    SystemSound.play(SystemSoundType.alert);
    HapticFeedback.heavyImpact();
  }

  void _stopSound() {
    _soundTimer?.cancel();
    _soundTimer = null;
  }

  @override
  void dispose() {
    _stopSound();
    expiryQueue.removeListener(_onQueueChanged);
    super.dispose();
  }

  void _dismiss() {
    _stopSound();
    // A direct pop(), not maybePop() — PopScope(canPop: false) below exists only to swallow the
    // system/predictive back gesture (staff must use the explicit buttons), and maybePop() goes
    // through that same "can this route pop" check, so it would silently no-op here too.
    Navigator.of(context).pop();
  }

  Future<void> _viewSession(String sessionId) async {
    _stopSound();
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => SessionDetailScreen(sessionId: sessionId)));
  }

  Future<void> _returnShoes(String claimId) async {
    _stopSound();
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ShoeReturnScreen(claimId: claimId)));
    if (mounted) _startSound();
  }

  @override
  Widget build(BuildContext context) {
    if (expiryQueue.isEmpty) return const SizedBox.shrink();
    final i = expiryQueue.currentIndex.clamp(0, expiryQueue.length - 1);
    final a = expiryQueue.items[i];
    final hasMultiple = expiryQueue.length > 1;

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(0xFF2A0A08),
        body: SafeArea(
          child: Column(children: [
            if (hasMultiple)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  IconButton(
                    color: Colors.white70,
                    onPressed: i > 0 ? () => expiryQueue.setIndex(i - 1) : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Text('${i + 1} of ${expiryQueue.length} expired', style: const TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
                  IconButton(
                    color: Colors.white70,
                    onPressed: i < expiryQueue.length - 1 ? () => expiryQueue.setIndex(i + 1) : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ]),
              ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 10, 24, 10),
                child: Column(children: [
                  const Icon(Icons.error, color: Colors.white, size: 72),
                  const SizedBox(height: 10),
                  const Text('SESSION EXPIRED', style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: 1)),
                  const SizedBox(height: 22),
                  AuthedPhoto(photoId: a.customerPhotoId, name: a.customerName, size: 110),
                  const SizedBox(height: 12),
                  Text(a.customerName, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800), textAlign: TextAlign.center),
                  Text(a.productName, style: const TextStyle(color: Colors.white70, fontSize: 15), textAlign: TextAlign.center),
                  const SizedBox(height: 4),
                  Text(
                    'Started ${fmtHHMM(a.startedAt)} · Ended ${fmtHHMM(a.scheduledEndAt)}',
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  if (a.equipment.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text('Equipment: ${a.equipment}', style: const TextStyle(color: Colors.white70, fontSize: 13))),
                  if (a.shoeClaimId != null) ...[
                    const SizedBox(height: 22),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(14)),
                      child: Column(children: [
                        const Text('👟 PERSONAL SHOES', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, letterSpacing: 0.6)),
                        const SizedBox(height: 10),
                        ShoePhoto(claimId: a.shoeClaimId!, size: 90, borderRadius: BorderRadius.circular(10)),
                        const SizedBox(height: 10),
                        Text('CLAIM #${a.shoeClaimNumber ?? ''}', style: const TextStyle(color: LsColors.yellowSoft, fontSize: 20, fontWeight: FontWeight.w800)),
                      ]),
                    ),
                  ],
                ]),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(children: [
                if (a.shoeClaimId != null)
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: const Color(0xFF2A0A08), minimumSize: const Size.fromHeight(52)),
                      onPressed: () => _returnShoes(a.shoeClaimId!),
                      icon: const Icon(Icons.checkroom_outlined),
                      label: const Text('Return Shoes', style: TextStyle(fontWeight: FontWeight.w800)),
                    ),
                  ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(foregroundColor: Colors.white, side: const BorderSide(color: Colors.white54), minimumSize: const Size.fromHeight(48)),
                    onPressed: () => _viewSession(a.sessionId),
                    child: const Text('View Session'),
                  ),
                ),
                const SizedBox(height: 10),
                TextButton(
                  onPressed: _dismiss,
                  child: const Text('Dismiss', style: TextStyle(color: Colors.white70)),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
