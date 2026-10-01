/// GET /products — pricing rules the staff can choose from at check-in / extension time.
library;

class Product {
  final String id;
  final String kind; // SESSION | EXTENSION
  final String name;
  final int durationMinutes;
  final int priceMinor;
  final String currency;
  final String dayType;
  final String customerType;
  final bool active;

  Product({
    required this.id, required this.kind, required this.name, required this.durationMinutes,
    required this.priceMinor, required this.currency, required this.dayType, required this.customerType, required this.active,
  });

  factory Product.fromJson(Map<String, dynamic> j) => Product(
        id: j['id'] as String,
        kind: j['kind'] as String,
        name: j['name'] as String,
        durationMinutes: (j['durationMinutes'] as int?) ?? 0,
        priceMinor: (j['priceMinor'] as int?) ?? 0,
        currency: (j['currency'] as String?) ?? 'ETB',
        dayType: (j['dayType'] as String?) ?? 'ANY',
        customerType: (j['customerType'] as String?) ?? 'ANY',
        active: (j['active'] as bool?) ?? true,
      );
}

class ProductsResponse {
  final List<Product> sessions;
  final List<Product> extensions;
  ProductsResponse({required this.sessions, required this.extensions});
  factory ProductsResponse.fromJson(Map<String, dynamic> j) => ProductsResponse(
        sessions: ((j['sessions'] as List?) ?? const []).map((e) => Product.fromJson(e as Map<String, dynamic>)).toList(),
        extensions: ((j['extensions'] as List?) ?? const []).map((e) => Product.fromJson(e as Map<String, dynamic>)).toList(),
      );
}

class PaymentMethodOption {
  final String code;
  final String label;
  final bool requiresReference;
  final bool enabled;
  PaymentMethodOption({required this.code, required this.label, required this.requiresReference, required this.enabled});
  factory PaymentMethodOption.fromJson(Map<String, dynamic> j) => PaymentMethodOption(
        code: j['code'] as String,
        label: (j['label'] as String?) ?? j['code'] as String,
        requiresReference: (j['requiresReference'] as bool?) ?? false,
        enabled: (j['enabled'] as bool?) ?? true,
      );
}

/// Full /config response (superset of VenueConfig in dashboard.dart, which only reads the
/// subset the dashboard itself needs). Used by check-in, extend, settings screens.
class FullConfig {
  final DateTime serverTime;
  final String venueName;
  final String currency;
  final int maxCapacity;
  final List<PaymentMethodOption> paymentMethods;
  final int expiringMinutes;
  final bool pauseEnabled;
  final List<int> extensionOptionsMinutes;
  final bool waiverRequired;
  final int minorAgeYears;
  final String photoCapture; // NEW_CUSTOMER | EVERY_VISIT | NEVER
  final bool wristbandsEnabled;
  final List<String> wristbandColors;
  final bool equipmentRequiredForStart;
  final Map<String, dynamic> emergency;
  final List<({int minutes, String level})> warningThresholds;

  FullConfig({
    required this.serverTime, required this.venueName, required this.currency, required this.maxCapacity,
    required this.paymentMethods, required this.expiringMinutes, required this.pauseEnabled,
    required this.extensionOptionsMinutes, required this.waiverRequired, required this.minorAgeYears,
    required this.photoCapture, required this.wristbandsEnabled, required this.wristbandColors,
    required this.equipmentRequiredForStart, required this.emergency, required this.warningThresholds,
  });

  /// Same shape `levelFor()` (widgets/session_level.dart) expects — kept as a method so call
  /// sites read naturally (`cfg.warnings()`) without exposing the record type everywhere.
  List<({int minutes, String level})> warnings() => warningThresholds;

  factory FullConfig.fromJson(Map<String, dynamic> j) {
    final settings = j['settings'] as Map<String, dynamic>;
    final venue = j['venue'] as Map<String, dynamic>;
    final wrist = (settings['wristbands'] as Map<String, dynamic>?) ?? const {};
    final pause = (settings['pause'] as Map<String, dynamic>?) ?? const {};
    return FullConfig(
      serverTime: DateTime.tryParse((j['serverTime'] as String?) ?? '') ?? DateTime.now(),
      venueName: venue['name'] as String,
      currency: venue['currency'] as String,
      maxCapacity: (j['maxCapacity'] as int?) ?? 0,
      paymentMethods: ((settings['paymentMethods'] as List?) ?? const [])
          .map((e) => PaymentMethodOption.fromJson(e as Map<String, dynamic>))
          .where((m) => m.enabled)
          .toList(),
      expiringMinutes: (settings['expiringMinutes'] as int?) ?? 15,
      pauseEnabled: (pause['enabled'] as bool?) ?? true,
      extensionOptionsMinutes: ((settings['extensionOptionsMinutes'] as List?) ?? const [15, 30, 60]).map((e) => e as int).toList(),
      waiverRequired: (settings['waiverRequired'] as bool?) ?? true,
      minorAgeYears: (settings['minorAgeYears'] as int?) ?? 18,
      photoCapture: (settings['photoCapture'] as String?) ?? 'NEW_CUSTOMER',
      wristbandsEnabled: (wrist['enabled'] as bool?) ?? false,
      wristbandColors: ((wrist['colors'] as List?) ?? const []).map((e) => e as String).toList(),
      equipmentRequiredForStart: (settings['equipmentRequiredForStart'] as bool?) ?? false,
      emergency: (j['emergency'] as Map<String, dynamic>?) ?? const {},
      warningThresholds: ((settings['warnings'] as List?) ?? const [])
          .map((w) => (minutes: (w as Map<String, dynamic>)['minutes'] as int, level: w['level'] as String))
          .toList(),
    );
  }
}
