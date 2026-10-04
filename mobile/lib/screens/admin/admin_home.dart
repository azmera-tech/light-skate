import 'package:flutter/material.dart';
import '../../api/api_client.dart';
import '../../models/me.dart';
import '../../theme.dart';
import 'overview_screen.dart';
import 'reports_screen.dart';
import 'settings_screen.dart';
import 'pricing_screen.dart';
import 'staff_screen.dart';
import 'devices_screen.dart';
import 'audit_screen.dart';
import 'close_day_screen.dart';
import 'equipment_health_screen.dart';

class _AdminPage {
  final String title;
  final String subtitle;
  final IconData icon;
  final bool Function(Me me) visible;
  final WidgetBuilder builder;
  const _AdminPage({required this.title, required this.subtitle, required this.icon, required this.visible, required this.builder});
}

/// Admin landing page — a permission-gated list of admin sections, each pushed as its own
/// screen. Reached from AppShell's app-bar admin icon (shown when the signed-in staff member
/// has any of `managementPerms`); each entry below is gated by its own specific permission so a
/// user only sees the sections they can actually act in, not every admin page.
class AdminHomeScreen extends StatelessWidget {
  const AdminHomeScreen({super.key});

  static final _pages = <_AdminPage>[
    _AdminPage(
      title: 'Overview',
      subtitle: 'Today at a glance',
      icon: Icons.insights_outlined,
      // Landing/summary page — show it if the user can see any other admin page at all.
      visible: (me) => me.canAny(const [
            'reports.read', 'staff.manage', 'settings.manage', 'pricing.manage',
            'capacity.manage', 'audit.read', 'device.manage', 'dayclose.manage',
            'equipment.manage', 'payment.read', 'incident.read',
          ]),
      builder: (_) => const AdminOverviewScreen(),
    ),
    _AdminPage(
      title: 'Reports',
      subtitle: 'Daily and range reports',
      icon: Icons.bar_chart_outlined,
      visible: (me) => me.can('reports.read'),
      builder: (_) => const ReportsScreen(),
    ),
    _AdminPage(
      title: 'Settings',
      subtitle: 'Venue configuration & capacity',
      icon: Icons.settings_outlined,
      visible: (me) => me.canAny(const ['settings.manage', 'capacity.manage']),
      builder: (_) => const SettingsScreen(),
    ),
    _AdminPage(
      title: 'Equipment Health',
      subtitle: 'Fleet status & cleaning compliance',
      icon: Icons.health_and_safety_outlined,
      visible: (me) => me.canAny(const ['equipment.manage', 'equipment.cleaning', 'equipment.maintenance']),
      builder: (_) => const EquipmentHealthScreen(),
    ),
    _AdminPage(
      title: 'Pricing',
      subtitle: 'Session & extension prices',
      icon: Icons.sell_outlined,
      visible: (me) => me.can('pricing.manage'),
      builder: (_) => const PricingScreen(),
    ),
    _AdminPage(
      title: 'Staff',
      subtitle: 'Accounts, roles & access',
      icon: Icons.badge_outlined,
      visible: (me) => me.can('staff.manage'),
      builder: (_) => const StaffScreen(),
    ),
    _AdminPage(
      title: 'Devices',
      subtitle: 'Registered terminals',
      icon: Icons.tablet_mac_outlined,
      visible: (me) => me.can('device.manage'),
      builder: (_) => const DevicesScreen(),
    ),
    _AdminPage(
      title: 'Audit log',
      subtitle: 'Who changed what, and when',
      icon: Icons.fact_check_outlined,
      visible: (me) => me.can('audit.read'),
      builder: (_) => const AuditScreen(),
    ),
    _AdminPage(
      title: 'Close day',
      subtitle: 'End-of-day reconciliation',
      icon: Icons.nightlight_outlined,
      visible: (me) => me.can('dayclose.manage'),
      builder: (_) => const CloseDayScreen(),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Admin')),
      body: FutureBuilder<ApiClient>(
        future: ApiClient.instance(),
        builder: (context, snap) {
          final api = snap.data;
          if (api == null) return const Center(child: CircularProgressIndicator());
          final me = api.me;
          if (me == null) return const Center(child: Text('Not signed in.'));
          final visible = _pages.where((p) => p.visible(me)).toList();
          if (visible.isEmpty) {
            return const Center(child: Padding(padding: EdgeInsets.all(24), child: Text("You don't have access to any admin pages.")));
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: visible.length,
            separatorBuilder: (_, _) => const Divider(height: 1, color: LsColors.border),
            itemBuilder: (context, i) {
              final p = visible[i];
              return ListTile(
                leading: CircleAvatar(backgroundColor: LsColors.brandSoft, foregroundColor: LsColors.brandStrong, child: Icon(p.icon)),
                title: Text(p.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(p.subtitle, style: const TextStyle(color: LsColors.muted)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: p.builder)),
              );
            },
          );
        },
      ),
    );
  }
}
