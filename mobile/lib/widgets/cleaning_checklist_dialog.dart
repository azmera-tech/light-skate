import 'package:flutter/material.dart';
import '../models/cleaning.dart';
import '../theme.dart';

/// "Mark Cleaned" checklist — every item must be checked before cleaning can be completed,
/// matching the backend's own CLEANING_CHECKLIST_ITEMS enforcement. Returns the checked
/// answers + optional notes, or null if cancelled.
Future<({Map<String, bool> checklist, String? notes})?> showCleaningChecklistDialog(BuildContext context, {required String code}) {
  final checked = <String, bool>{for (final k in cleaningChecklistItems.keys) k: false};
  final notesCtrl = TextEditingController();
  return showDialog<({Map<String, bool> checklist, String? notes})>(
    context: context,
    builder: (context) => StatefulBuilder(builder: (context, setLocal) {
      final allChecked = checked.values.every((v) => v);
      return AlertDialog(
        title: Text('Skate Cleaning Checklist — $code'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            ...cleaningChecklistItems.entries.map((e) => CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: checked[e.key],
                  onChanged: (v) => setLocal(() => checked[e.key] = v ?? false),
                  title: Text(e.value),
                )),
            const SizedBox(height: 8),
            TextField(controller: notesCtrl, decoration: const InputDecoration(labelText: 'Notes (optional)'), minLines: 1, maxLines: 3),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: LsColors.green),
            onPressed: allChecked ? () => Navigator.pop(context, (checklist: Map<String, bool>.from(checked), notes: notesCtrl.text.trim().isEmpty ? null : notesCtrl.text.trim())) : null,
            child: const Text('Complete Cleaning'),
          ),
        ],
      );
    }),
  );
}

/// "Report Issue" during cleaning — moves the skate straight to maintenance.
Future<String?> showCleaningIssueDialog(BuildContext context, {required String code}) {
  const examples = ['Broken strap', 'Wheel problem', 'Loose component', 'Damaged boot', 'Heavy wear', 'Other'];
  final ctrl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(builder: (context, setLocal) {
      final valid = ctrl.text.trim().length >= 3;
      return AlertDialog(
        title: Text('Report Issue — $code'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 6, runSpacing: 6, children: examples.map((e) => ActionChip(label: Text(e), onPressed: () => setLocal(() { ctrl.text = e; }))).toList()),
          const SizedBox(height: 10),
          TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(labelText: 'What is wrong with it?'), onChanged: (_) => setLocal(() {})),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: valid ? () => Navigator.pop(context, ctrl.text.trim()) : null,
            child: const Text('Report & move to maintenance'),
          ),
        ],
      );
    }),
  );
}
