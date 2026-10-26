import 'package:flutter/material.dart';
import '../theme.dart';

/// Layout for modal bottom sheets whose primary button must always be reachable:
///  * the form scrolls, the action bar does not — so a long form on a short phone never hides the button;
///  * the action bar sits inside a bottom [SafeArea], so Android's gesture bar / three-button navigation
///    (which the app draws behind, edge-to-edge) never covers it;
///  * the sheet lifts by the keyboard height, so the focused field and the button stay in view.
/// Use with `showModalBottomSheet(isScrollControlled: true, useSafeArea: true)`.
class PsSheetScaffold extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget body;
  final Widget action;
  final Widget? secondaryAction;
  const PsSheetScaffold({super.key, required this.title, this.subtitle, required this.body, required this.action, this.secondaryAction});

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 120),
      padding: EdgeInsets.only(bottom: keyboard),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            if (subtitle != null) Text(subtitle!, style: const TextStyle(color: LsColors.muted)),
          ]),
        ),
        Flexible(
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: body,
          ),
        ),
        Material(
          color: LsColors.surface,
          elevation: 10,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                action,
                if (secondaryAction != null) Padding(padding: const EdgeInsets.only(top: 4), child: secondaryAction),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

/// Bottom padding for full-screen scrolling lists that have no bottom bar of their own, so their last
/// item can be scrolled clear of the Android navigation area.
EdgeInsets scrollPadding(BuildContext context, {double h = 14, double top = 14, double bottom = 24}) =>
    EdgeInsets.fromLTRB(h, top, h, bottom + MediaQuery.viewPaddingOf(context).bottom);
