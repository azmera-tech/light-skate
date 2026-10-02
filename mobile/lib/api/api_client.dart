import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../demo/demo_mode.dart';
import '../demo/mock_backend.dart';
import '../models/me.dart';

/// Thrown for any non-2xx response. Carries the server's own readable message —
/// the backend writes messages for staff to read, not for developers, so we show it as-is.
class ApiException implements Exception {
  final int status;
  final String code;
  final String message;
  /// The error envelope's `details` field, when present (e.g. duplicate-customer candidates,
  /// venue-full occupancy/canOverride). Most callers only need `message`; this is for the
  /// handful of flows that branch on structured error data.
  final dynamic details;
  ApiException(this.status, this.code, this.message, [this.details]);
  @override
  String toString() => message;
}

/// Thin REST client for the Light Skate API. Mirrors web/src/api.ts:
///  - bearer token + registered device id on every request
///  - an Idempotency-Key on every state-changing call (reused on retry, so a dropped
///    response after a timeout can never duplicate a payment, a session start, etc.)
///  - tracks the server clock offset so countdowns are computed from authoritative
///    time, not the phone's own clock
class ApiClient {
  ApiClient._(this.baseUrl);

  /// Compile-time override: flutter build web --dart-define=API_BASE_URL=https://your-venue.example.com
  static const String _compiledBaseUrl = String.fromEnvironment('API_BASE_URL', defaultValue: 'http://localhost:8090');

  final String baseUrl;
  String? _token;
  String? _deviceId;
  Me? _me;
  Duration _clockOffset = Duration.zero;
  final _rng = Random.secure();

  static ApiClient? _instance;
  static Future<ApiClient> instance() async {
    if (_instance != null) return _instance!;
    final c = ApiClient._(_compiledBaseUrl);
    final prefs = await SharedPreferences.getInstance();
    c._token = prefs.getString('ls.token');
    c._deviceId = prefs.getString('ls.device');
    final meJson = prefs.getString('ls.me');
    if (meJson != null) {
      try {
        c._me = Me.fromJson(jsonDecode(meJson) as Map<String, dynamic>);
      } catch (_) {
        // ignore a corrupted cache entry; /auth/me will be refetched on next login
      }
    }
    _instance = c;
    return c;
  }

  bool get isAuthenticated => _token != null && _me != null;
  Me? get me => _me;
  String? get authTokenForRealtime => _token;

  Future<void> setToken(String? token) async {
    _token = token;
    final prefs = await SharedPreferences.getInstance();
    if (token == null) {
      await prefs.remove('ls.token');
    } else {
      await prefs.setString('ls.token', token);
    }
  }

  /// POST /auth/login then GET /auth/me, so the permissions array driving every UI gate is
  /// available immediately — never derived from the role name alone.
  Future<Me> login(String email, String password) async {
    final res = await post('/auth/login', {'email': email, 'password': password});
    await setToken(res['token'] as String);
    final meJson = await get('/auth/me') as Map<String, dynamic>;
    _me = Me.fromJson(meJson);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ls.me', jsonEncode(_me!.toJson()));
    return _me!;
  }

  /// Demo-mode login: accepts anything, makes no network call, grants every permission so the
  /// whole app is reachable. See lib/demo/demo_mode.dart — flip `kDemoMode` to false and this
  /// path is simply never called; `login()` above (real backend) is unaffected either way.
  Future<Me> loginDemo(String email) async {
    await setToken('demo-token');
    _me = Me(
      id: 'demo-user',
      email: email.isEmpty ? 'demo@lightskate.demo' : email,
      fullName: 'Demo Staff',
      role: 'OWNER',
      permissions: MockBackend.allPermissionCodes.toSet(),
      venueId: 'venue-demo',
      deviceId: null,
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ls.me', jsonEncode(_me!.toJson()));
    return _me!;
  }

  Future<void> logout() async {
    try {
      await post('/auth/logout');
    } catch (_) {
      // sign out locally regardless of whether the server call succeeded
    }
    _me = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('ls.me');
    await setToken(null);
  }

  DateTime serverNow() => DateTime.now().add(_clockOffset);

  void _syncClock(String? serverTimeIso) {
    if (serverTimeIso == null) return;
    final t = DateTime.tryParse(serverTimeIso);
    if (t != null) _clockOffset = t.difference(DateTime.now());
  }

  String newIdempotencyKey() {
    final bytes = List<int>.generate(16, (_) => _rng.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  Future<dynamic> get(String path) => _send('GET', path);
  Future<dynamic> post(String path, [Map<String, dynamic>? body, String? idempotencyKey]) =>
      _send('POST', path, body: body, idempotencyKey: idempotencyKey ?? newIdempotencyKey());
  Future<dynamic> patch(String path, [Map<String, dynamic>? body]) => _send('PATCH', path, body: body);
  Future<dynamic> put(String path, [Map<String, dynamic>? body, String? idempotencyKey]) =>
      _send('PUT', path, body: body, idempotencyKey: idempotencyKey);
  Future<dynamic> delete(String path) => _send('DELETE', path);

  Future<dynamic> _send(String method, String path, {Map<String, dynamic>? body, String? idempotencyKey}) async {
    if (kDemoMode) {
      // Tiny artificial delay so loading states/spinners are visible, same as a real request.
      await Future.delayed(const Duration(milliseconds: 150));
      final json = MockBackend.instance.handle(method, path, body) as Map<String, dynamic>?;
      if (json != null && json['serverTime'] is String) _syncClock(json['serverTime'] as String);
      return json;
    }
    final headers = <String, String>{'content-type': 'application/json'};
    if (_token != null) headers['authorization'] = 'Bearer $_token';
    if (_deviceId != null) headers['x-device-id'] = _deviceId!;
    if (idempotencyKey != null) headers['idempotency-key'] = idempotencyKey;

    final uri = Uri.parse('$baseUrl/api/v1$path');
    final encodedBody = body == null ? null : jsonEncode(body);
    http.Response res;
    try {
      switch (method) {
        case 'GET':
          res = await http.get(uri, headers: headers).timeout(const Duration(seconds: 20));
          break;
        case 'PATCH':
          res = await http.patch(uri, headers: headers, body: encodedBody).timeout(const Duration(seconds: 20));
          break;
        case 'PUT':
          res = await http.put(uri, headers: headers, body: encodedBody).timeout(const Duration(seconds: 20));
          break;
        case 'DELETE':
          res = await http.delete(uri, headers: headers).timeout(const Duration(seconds: 20));
          break;
        default:
          res = await http.post(uri, headers: headers, body: encodedBody).timeout(const Duration(seconds: 20));
      }
    } on TimeoutException {
      throw ApiException(0, 'NETWORK', 'The server did not respond in time. Check the connection.');
    } catch (_) {
      throw ApiException(0, 'NETWORK', 'Cannot reach the server. Check the connection.');
    }

    Map<String, dynamic>? json;
    if (res.body.isNotEmpty) {
      try {
        json = jsonDecode(res.body) as Map<String, dynamic>;
      } catch (_) {
        // non-JSON body; leave json null
      }
    }
    if (json != null && json['serverTime'] is String) _syncClock(json['serverTime'] as String);

    if (res.statusCode >= 200 && res.statusCode < 300) return json;
    final err = (json?['error'] as Map<String, dynamic>?) ?? {};
    throw ApiException(res.statusCode, (err['code'] as String?) ?? 'ERROR', (err['message'] as String?) ?? 'Request failed (${res.statusCode}).', err['details']);
  }

  /// Fetches a protected photo's bytes with the auth header — never a public URL.
  Future<List<int>> photoBytes(String photoId) async {
    if (kDemoMode) throw ApiException(404, 'NOT_FOUND', 'No photo in demo mode.');
    final headers = <String, String>{if (_token != null) 'authorization': 'Bearer $_token'};
    final res = await http.get(Uri.parse('$baseUrl/api/v1/photos/$photoId/content'), headers: headers).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw ApiException(res.statusCode, 'PHOTO', 'Photo unavailable.');
    return res.bodyBytes;
  }

  /// Uploads raw image bytes (not JSON/multipart — the backend reads the request body directly
  /// as the file). Used for customer photos, equipment maintenance photos, incident attachments.
  Future<Map<String, dynamic>> postRawImage(String path, List<int> bytes, {String contentType = 'image/jpeg'}) async {
    if (kDemoMode) {
      await Future.delayed(const Duration(milliseconds: 150));
      return (MockBackend.instance.handle('POST', path, const {}) as Map<String, dynamic>?) ?? {};
    }
    final headers = <String, String>{'content-type': contentType, 'idempotency-key': newIdempotencyKey()};
    if (_token != null) headers['authorization'] = 'Bearer $_token';
    if (_deviceId != null) headers['x-device-id'] = _deviceId!;
    http.Response res;
    try {
      res = await http.post(Uri.parse('$baseUrl/api/v1$path'), headers: headers, body: bytes).timeout(const Duration(seconds: 30));
    } on TimeoutException {
      throw ApiException(0, 'NETWORK', 'The server did not respond in time. Check the connection.');
    } catch (_) {
      throw ApiException(0, 'NETWORK', 'Cannot reach the server. Check the connection.');
    }
    Map<String, dynamic>? json;
    if (res.body.isNotEmpty) {
      try {
        json = jsonDecode(res.body) as Map<String, dynamic>;
      } catch (_) {
        // non-JSON body; leave json null
      }
    }
    if (res.statusCode >= 200 && res.statusCode < 300) return json ?? {};
    final err = (json?['error'] as Map<String, dynamic>?) ?? {};
    throw ApiException(res.statusCode, (err['code'] as String?) ?? 'ERROR', (err['message'] as String?) ?? 'Upload failed (${res.statusCode}).');
  }
}
