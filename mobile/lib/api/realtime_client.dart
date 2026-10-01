import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'api_client.dart';

/// Mirrors web/src/realtime.ts's protocol and philosophy: realtime is a hint only, never a
/// source of truth. Every event (and every reconnect) just triggers [onEvent] so the caller
/// refetches the relevant REST endpoint — nobody tries to patch local state from the payload.
class RealtimeClient {
  final ApiClient api;
  final void Function() onEvent;
  final void Function(String status)? onStatus; // 'connecting' | 'live' | 'offline'

  WebSocketChannel? _channel;
  Timer? _pingTimer;
  Timer? _watchdog;
  Timer? _reconnectTimer;
  int _backoffMs = 1000;
  bool _closed = false;
  DateTime _lastMessageAt = DateTime.now();

  RealtimeClient({required this.api, required this.onEvent, this.onStatus});

  void connect() {
    _closed = false;
    _open();
  }

  void dispose() {
    _closed = true;
    _pingTimer?.cancel();
    _watchdog?.cancel();
    _reconnectTimer?.cancel();
    _channel?.sink.close();
  }

  void _open() {
    if (_closed) return;
    onStatus?.call('connecting');
    final wsUrl = '${api.baseUrl.replaceFirst('http', 'ws')}/api/v1/realtime';
    try {
      _channel = WebSocketChannel.connect(Uri.parse(wsUrl));
    } catch (_) {
      _scheduleReconnect();
      return;
    }
    _channel!.ready.then((_) {
      if (_closed) return;
      _channel!.sink.add(jsonEncode({'type': 'auth', 'token': api.authTokenForRealtime}));
    }).catchError((_) => _scheduleReconnect());

    _channel!.stream.listen(
      (raw) {
        _lastMessageAt = DateTime.now();
        Map<String, dynamic>? msg;
        try {
          msg = jsonDecode(raw as String) as Map<String, dynamic>;
        } catch (_) {
          return;
        }
        final type = msg['type'] as String?;
        if (type == 'ready') {
          _backoffMs = 1000;
          onStatus?.call('live');
          onEvent(); // resync once on (re)connect, same as the web client
          _startPing();
          _startWatchdog();
        } else if (type == 'event') {
          onEvent();
        }
        // 'pong' needs no handling beyond resetting _lastMessageAt above.
      },
      onDone: _scheduleReconnect,
      onError: (_) => _scheduleReconnect(),
      cancelOnError: true,
    );
  }

  void _startPing() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      try {
        _channel?.sink.add(jsonEncode({'type': 'ping'}));
      } catch (_) {
        // the watchdog below will notice and reconnect
      }
    });
  }

  void _startWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 5), (_) {
      if (DateTime.now().difference(_lastMessageAt) > const Duration(seconds: 20)) {
        onStatus?.call('offline');
        _channel?.sink.close();
      }
    });
  }

  void _scheduleReconnect() {
    if (_closed) return;
    onStatus?.call('offline');
    _pingTimer?.cancel();
    _watchdog?.cancel();
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(milliseconds: _backoffMs), _open);
    _backoffMs = (_backoffMs * 2).clamp(1000, 15000);
  }
}
