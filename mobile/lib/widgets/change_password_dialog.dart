import 'package:flutter/material.dart';
import '../api/api_client.dart';
import '../theme.dart';

/// Lets the signed-in staff member change their own password. The server checks the current
/// password, enforces the minimum length, and signs out their other devices.
Future<void> showChangePasswordDialog(BuildContext context) async {
  final current = TextEditingController();
  final next = TextEditingController();
  final confirm = TextEditingController();
  String? error;
  bool busy = false;
  bool hide = true;

  final done = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setD) {
      Future<void> submit() async {
        if (next.text.length < 10) {
          setD(() => error = 'The new password must be at least 10 characters.');
          return;
        }
        if (next.text != confirm.text) {
          setD(() => error = 'The new passwords do not match.');
          return;
        }
        setD(() {
          busy = true;
          error = null;
        });
        try {
          final api = await ApiClient.instance();
          await api.post('/auth/change-password', {'currentPassword': current.text, 'newPassword': next.text});
          if (ctx.mounted) Navigator.of(ctx).pop(true);
        } catch (e) {
          setD(() {
            busy = false;
            error = e.toString();
          });
        }
      }

      return AlertDialog(
        title: const Text('Change my password'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: current, obscureText: hide, decoration: const InputDecoration(labelText: 'Current password')),
            const SizedBox(height: 10),
            TextField(controller: next, obscureText: hide, decoration: const InputDecoration(labelText: 'New password (min 10 characters)')),
            const SizedBox(height: 10),
            TextField(controller: confirm, obscureText: hide, decoration: const InputDecoration(labelText: 'Repeat new password'), onSubmitted: (_) => busy ? null : submit()),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setD(() => hide = !hide),
                icon: Icon(hide ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 18),
                label: Text(hide ? 'Show passwords' : 'Hide passwords'),
              ),
            ),
            if (error != null) Text(error!, style: const TextStyle(color: LsColors.red)),
            const SizedBox(height: 4),
            const Text('Your other signed-in devices will be signed out.', style: TextStyle(color: LsColors.muted, fontSize: 12.5)),
          ]),
        ),
        actions: [
          TextButton(onPressed: busy ? null : () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: busy ? null : submit, child: Text(busy ? 'Saving…' : 'Change password')),
        ],
      );
    }),
  );
  if (done == true && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Password changed.')));
  }
}
