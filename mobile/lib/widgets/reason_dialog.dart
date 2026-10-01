import 'package:flutter/material.dart';

/// Replaces the web app's native browser `prompt()` dialogs (damage notes, cancellation/refund
/// reasons, out-of-service reasons, correction reasons) with a proper Material text-input dialog.
/// Returns the trimmed text, or null if the user cancelled.
Future<String?> showReasonDialog(
  BuildContext context, {
  required String title,
  String label = 'Reason',
  String? hint,
  int minLength = 3,
  String confirmLabel = 'Confirm',
  bool danger = false,
  String? initialValue,
}) {
  final controller = TextEditingController(text: initialValue ?? '');
  return showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(builder: (context, setState) {
      final valid = controller.text.trim().length >= minLength;
      return AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 1,
          maxLines: 4,
          decoration: InputDecoration(labelText: label, hintText: hint),
          onChanged: (_) => setState(() {}),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            style: danger ? FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error) : null,
            onPressed: valid ? () => Navigator.pop(context, controller.text.trim()) : null,
            child: Text(confirmLabel),
          ),
        ],
      );
    }),
  );
}

/// Simple yes/no confirmation, used for destructive or consequential one-tap actions.
Future<bool> showConfirmDialog(
  BuildContext context, {
  required String title,
  String? message,
  String confirmLabel = 'Confirm',
  String cancelLabel = 'Cancel',
  bool danger = false,
}) async {
  final res = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: message != null ? Text(message) : null,
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(cancelLabel)),
        FilledButton(
          style: danger ? FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error) : null,
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return res ?? false;
}
