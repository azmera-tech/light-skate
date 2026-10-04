import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

/// This whole native-notification path is Android-only (the mobile build target) and a no-op
/// everywhere else, including the Flutter web build used for development/testing — checked via
/// `kIsWeb`/`defaultTargetPlatform` rather than `dart:io`'s `Platform`, which doesn't compile
/// for web at all.
bool get _isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

/// Schedules the native, backgrounded-reliable half of the session-expiry alarm.
///
/// A plain Dart `Timer` only fires while the app is in the foreground with the Dart VM
/// running — it is explicitly the wrong tool here (see the task's "do NOT implement this as
/// merely setInterval()" instruction). Instead, the exact session end time is handed to the
/// OS via `zonedSchedule` the moment a session starts/extends, so Android's own AlarmManager
/// fires it even if the app is backgrounded, the screen is locked, or the app process has been
/// killed — exactly the architecture an alarm-clock app uses. The backend's `scheduled_end_at`
/// stays authoritative throughout: this is only ever a locally-computed *reminder* of a time
/// the server already decided, and [ExpiryCoordinator] separately reconciles against the live
/// server state on every poll/resume, so a missed/late/duplicate local alarm can never by
/// itself mark anything expired.
class ExpiryAlarmService {
  ExpiryAlarmService._();
  static final ExpiryAlarmService instance = ExpiryAlarmService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;

  static const _channelId = 'session_expiry';
  static const _channelName = 'Session Expiry Alerts';
  static const _channelDesc = 'A skater\'s paid time has run out and needs staff attention.';

  Future<void> init({required void Function(String sessionId) onNotificationTapped}) async {
    if (_ready) return;
    tz_data.initializeTimeZones();
    try {
      tz.setLocalLocation(tz.getLocation(DateTime.now().timeZoneName));
    } catch (_) {
      // Fall back to UTC if the device's zone name isn't in the tz database under that name;
      // the alarm is still scheduled at the correct absolute instant either way.
    }
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(
      const InitializationSettings(android: androidInit),
      onDidReceiveNotificationResponse: (resp) {
        final sessionId = resp.payload;
        if (sessionId != null) onNotificationTapped(sessionId);
      },
    );
    if (_isAndroid) {
      final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await android?.requestNotificationsPermission();
      await android?.requestExactAlarmsPermission();
      await android?.createNotificationChannel(const AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: _channelDesc,
        importance: Importance.max,
        enableVibration: true,
        vibrationPattern: null,
        playSound: true,
      ));
    }
    // If the app was fully killed and got relaunched by the staff member tapping the
    // notification, the tap event above never fired — pick it up here instead.
    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (launch != null && launch.didNotificationLaunchApp) {
      final sessionId = launch.notificationResponse?.payload;
      if (sessionId != null) onNotificationTapped(sessionId);
    }
    _ready = true;
  }

  int _notificationId(String sessionId) => sessionId.hashCode & 0x7fffffff;

  /// Schedules (or re-schedules, cancelling any existing one for this session first) the
  /// native alert for the exact instant the session is due to end.
  Future<void> scheduleExpiry({required String sessionId, required String customerName, required DateTime scheduledEndAt}) async {
    if (!_ready || !_isAndroid) return;
    final id = _notificationId(sessionId);
    await _plugin.cancel(id);
    if (scheduledEndAt.isBefore(DateTime.now())) return; // already due — the foreground reconciler handles it directly
    try {
      await _plugin.zonedSchedule(
        id,
        'SESSION EXPIRED',
        "$customerName's session has run out of time.",
        tz.TZDateTime.from(scheduledEndAt, tz.local),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId, _channelName,
            channelDescription: _channelDesc,
            importance: Importance.max,
            priority: Priority.high,
            category: AndroidNotificationCategory.alarm,
            fullScreenIntent: true,
            ongoing: true,
            autoCancel: false,
            visibility: NotificationVisibility.public,
            icon: '@mipmap/ic_launcher',
          ),
        ),
        payload: sessionId,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      );
    } catch (_) {
      // Exact-alarm permission can be refused by the OS/user; the foreground reconciler
      // (polling + realtime refresh) still catches the expiry the next time the app is open.
    }
  }

  Future<void> cancelExpiry(String sessionId) async {
    if (!_isAndroid) return;
    await _plugin.cancel(_notificationId(sessionId));
  }

  /// Dismisses the delivered/standing notification once staff has actually seen the
  /// in-app alert — a lingering "ongoing" notification is the point while unacknowledged,
  /// but it must not stay forever once resolved.
  Future<void> clearDelivered(String sessionId) async {
    if (!_isAndroid) return;
    await _plugin.cancel(_notificationId(sessionId));
  }
}
