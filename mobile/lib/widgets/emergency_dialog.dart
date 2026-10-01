import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../api/api_client.dart';
import '../theme.dart';

/// Always-available "Emergency" button content — tel: links for ambulance/police/fire/venue
/// contacts plus venue address and first-aid notes, sourced from venue settings (GET /emergency),
/// matching the web app's always-visible Emergency modal exactly.
Future<void> showEmergencyDialog(BuildContext context) async {
  final api = await ApiClient.instance();
  Map<String, dynamic>? emergency;
  String? error;
  try {
    emergency = await api.get('/emergency') as Map<String, dynamic>;
  } catch (e) {
    error = e.toString();
  }
  if (!context.mounted) return;

  final contacts = <(String, String?)>[
    ('Ambulance', emergency?['ambulance'] as String?),
    ('Police', emergency?['police'] as String?),
    ('Fire', emergency?['fire'] as String?),
    ('Venue contact', emergency?['venueContact'] as String?),
    ('Manager on duty', emergency?['manager'] as String?),
  ].where((c) => (c.$2 ?? '').isNotEmpty).toList();

  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Row(children: [Icon(Icons.emergency, color: LsColors.red), SizedBox(width: 8), Text('Emergency')]),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (error != null) Text('Could not load emergency contacts: $error', style: const TextStyle(color: LsColors.red)),
            const Text('Stay with the injured person. Call the ambulance first, then the manager. Record an incident afterwards.',
                style: TextStyle(color: LsColors.muted)),
            const SizedBox(height: 12),
            ...contacts.map((c) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.call, color: LsColors.red),
                  title: Text(c.$1),
                  subtitle: Text(c.$2!),
                  onTap: () => launchUrl(Uri.parse('tel:${c.$2}')),
                )),
            if ((emergency?['address'] as String?)?.isNotEmpty == true) ...[
              const Divider(),
              Text('Address: ${emergency!['address']}'),
            ],
            if ((emergency?['firstAid'] as String?)?.isNotEmpty == true) ...[
              const SizedBox(height: 8),
              Text(emergency!['firstAid'] as String, style: const TextStyle(color: LsColors.muted)),
            ],
          ]),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
    ),
  );
}
