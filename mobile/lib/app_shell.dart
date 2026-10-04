import 'package:flutter/material.dart';
import 'alarm/expiry_alarm_service.dart';
import 'alarm/expiry_coordinator.dart';
import 'alarm/expiry_queue.dart';
import 'api/api_client.dart';
import 'api/realtime_client.dart';
import 'demo/demo_mode.dart';
import 'models/me.dart';
import 'screens/dashboard_screen.dart';
import 'screens/customers/customer_search_screen.dart';
import 'screens/equipment_screen.dart';
import 'screens/incidents/incidents_screen.dart';
import 'screens/history_screen.dart';
import 'screens/admin/admin_home.dart';
import 'screens/checkin/checkin_flow.dart';
import 'screens/expiry_alert_screen.dart';
import 'screens/login_screen.dart';
import 'widgets/emergency_dialog.dart';
import 'theme.dart';

/// The permission-driven app shell: a bottom nav of tabs the signed-in staff member is allowed
/// to see (mirrors web/src/App.tsx's staffTabs filtering — one permission check per tab, no
/// hardcoded role switch), a shared app bar with realtime status / admin / emergency / sign-out,
/// and a live WebSocket that refreshes whichever tab is open on every server event.
class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _NavTab {
  final String label;
  final IconData icon;
  final Widget Function(GlobalKey<DashboardScreenState> dashKey) build;
  final bool Function(Me me) visible;
  final bool isAction; // true = tapping it pushes a route instead of switching tabs
  const _NavTab(this.label, this.icon, this.build, this.visible, {this.isAction = false});
}

final _allTabs = <_NavTab>[
  _NavTab('Live', Icons.dashboard_outlined, (k) => DashboardScreen(key: k), (me) => true),
  _NavTab('Check-in', Icons.person_add_alt_1_outlined, (_) => const CheckInFlow(), (me) => me.can('session.create'), isAction: true),
  _NavTab('Customers', Icons.people_outline, (_) => const CustomerSearchScreen(), (me) => me.canAny(['customer.read', 'customer.create'])),
  _NavTab('History', Icons.history, (_) => const HistoryScreen(), (me) => me.can('visit.read')),
  _NavTab('Equipment', Icons.sports_hockey_outlined, (_) => const EquipmentScreen(), (me) => me.can('equipment.read')),
  _NavTab('Incidents', Icons.report_problem_outlined, (_) => const IncidentsScreen(), (me) => me.canAny(['incident.create', 'incident.read'])),
];

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  late ApiClient _api;
  Me? _me;
  int _index = 0;
  RealtimeClient? _rt;
  String _rtStatus = 'connecting';
  final _dashboardKey = GlobalKey<DashboardScreenState>();
  late List<_NavTab> _tabs;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    expiryQueue.addListener(_onExpiryQueueChanged);
    _boot();
  }

  Future<void> _boot() async {
    _api = await ApiClient.instance();
    final me = _api.me;
    if (me == null) return; // _Bootstrap in main.dart only routes here when authenticated
    _me = me;
    _tabs = _allTabs.where((t) => t.visible(me)).toList();
    if (kDemoMode) {
      // No real server to hold a WebSocket open to; the dashboard's own poll timer is the
      // only refresh mechanism in demo mode. Show the status dot as permanently "live" rather
      // than a misleading "offline".
      _rtStatus = 'live';
    } else {
      _rt = RealtimeClient(
        api: _api,
        onEvent: () => _dashboardKey.currentState?.refreshNow(),
        onStatus: (s) {
          if (mounted) setState(() => _rtStatus = s);
        },
      );
      _rt!.connect();
    }
    // The native half of the session-expiry alarm: fires even with the app backgrounded or the
    // screen locked (see lib/alarm/expiry_alarm_service.dart). Independent of demo mode — it's
    // pure on-device scheduling, nothing to do with where session data comes from.
    await ExpiryAlarmService.instance.init(onNotificationTapped: (sessionId) async {
      await ExpiryCoordinator.instance.surfaceById(sessionId, _api);
    });
    if (mounted) setState(() {});
  }

  void _onExpiryQueueChanged() {
    if (!mounted) return;
    setState(() {}); // keeps the app-bar "N expired" chip in sync
    if (!expiryQueue.isEmpty && !expiryQueue.isShowing) _showExpiryAlert();
  }

  void _showExpiryAlert() {
    if (expiryQueue.isEmpty || expiryQueue.isShowing) return;
    expiryQueue.isShowing = true;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ExpiryAlertScreen(), fullscreenDialog: true)).then((_) {
      expiryQueue.isShowing = false;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Reconcile against the server the moment the app comes back to the foreground — a session
    // can have expired (or been extended) while backgrounded, and polling itself is paused
    // while backgrounded, so this is the catch-up point rather than a bare timer.
    if (state == AppLifecycleState.resumed) _dashboardKey.currentState?.refreshNow();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    expiryQueue.removeListener(_onExpiryQueueChanged);
    _rt?.dispose();
    super.dispose();
  }

  Future<void> _signOut() async {
    _rt?.dispose();
    await _api.logout();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const LoginScreen()), (_) => false);
  }

  void _onSelect(int i) {
    final tab = _tabs[i];
    if (tab.isAction) {
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => tab.build(_dashboardKey)));
      return;
    }
    setState(() => _index = i);
  }

  void _openAdmin() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AdminHomeScreen()));
  }

  Color get _rtColor => switch (_rtStatus) {
        'live' => LsColors.green,
        'connecting' => LsColors.yellow,
        _ => LsColors.red,
      };

  @override
  Widget build(BuildContext context) {
    final me = _me;
    if (me == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));

    final showAdmin = me.canAny(managementPerms);
    // Body tabs only (skip the "Check-in" entry, which is an action, not a persistent page).
    final bodyTabs = _tabs.where((t) => !t.isAction).toList();
    final selectedBodyIndex = bodyTabs.indexOf(_tabs[_index.clamp(0, _tabs.length - 1)]).clamp(0, bodyTabs.length - 1);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Light Skate'),
        actions: [
          if (!expiryQueue.isEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: ActionChip(
                avatar: const Icon(Icons.error, color: Colors.white, size: 16),
                label: Text('${expiryQueue.length} Expired', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12)),
                backgroundColor: LsColors.red,
                onPressed: _showExpiryAlert,
              ),
            ),
          Tooltip(
            message: switch (_rtStatus) { 'live' => 'Live updates connected', 'connecting' => 'Connecting…', _ => 'Offline — showing last known data' },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Icon(Icons.circle, size: 11, color: _rtColor),
            ),
          ),
          if (showAdmin) IconButton(onPressed: _openAdmin, icon: const Icon(Icons.admin_panel_settings_outlined), tooltip: 'Admin'),
          IconButton(onPressed: () => showEmergencyDialog(context), icon: const Icon(Icons.emergency, color: LsColors.red), tooltip: 'Emergency'),
          IconButton(onPressed: _signOut, icon: const Icon(Icons.logout), tooltip: 'Sign out'),
        ],
      ),
      body: IndexedStack(
        index: selectedBodyIndex,
        children: bodyTabs.map((t) => t.build(_dashboardKey)).toList(),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index.clamp(0, _tabs.length - 1),
        onDestinationSelected: _onSelect,
        destinations: _tabs.map((t) => NavigationDestination(icon: Icon(t.icon), label: t.label)).toList(),
      ),
    );
  }
}
