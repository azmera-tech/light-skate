import 'package:flutter/foundation.dart';

/// One server event (or a reconnect, as event 'RESYNC'). Screens refetch from REST when they see
/// a relevant one — the payload is a hint, never a source of truth.
class RealtimeSignal {
  final String event;
  final Map<String, dynamic> data;
  final int seq;
  const RealtimeSignal(this.event, this.data, this.seq);
}

/// App-wide fan-out of realtime events, so any open screen can react without owning a socket.
class RealtimeBus {
  RealtimeBus._();
  static final ValueNotifier<RealtimeSignal?> last = ValueNotifier(null);
  static int _seq = 0;
  static void publish(String event, [Map<String, dynamic> data = const {}]) {
    last.value = RealtimeSignal(event, data, ++_seq);
  }
}
