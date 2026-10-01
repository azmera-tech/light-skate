/// GET /reports/daily and /reports/range.
library;

class RevenueByMethod {
  final String method;
  final int chargesMinor;
  final int refundsMinor;
  final int count;
  RevenueByMethod({required this.method, required this.chargesMinor, required this.refundsMinor, required this.count});
  factory RevenueByMethod.fromJson(Map<String, dynamic> j) => RevenueByMethod(
        method: j['method'] as String,
        chargesMinor: (j['chargesMinor'] as int?) ?? 0,
        refundsMinor: (j['refundsMinor'] as int?) ?? 0,
        count: (j['count'] as int?) ?? 0,
      );
}

class HourlyStart {
  final int hour;
  final int sessions;
  HourlyStart({required this.hour, required this.sessions});
  factory HourlyStart.fromJson(Map<String, dynamic> j) => HourlyStart(hour: j['hour'] as int, sessions: (j['sessions'] as int?) ?? 0);
}

class DailyReport {
  final String date;
  final String currency;
  final int visitors;
  final int newCustomers;
  final int sessionsStarted;
  final int sessionsCompleted;
  final int earlyExits;
  final int active;
  final int cancelled;
  final int noShows;
  final int extensions;
  final int chargesMinor;
  final int refundsMinor;
  final int netMinor;
  final int discountsMinor;
  final List<RevenueByMethod> byMethod;
  final int equipmentIssues;
  final int distinctUnits;
  final int incidentsTotal;
  final int averageSessionSeconds;
  final double capacityUtilizationPercent;
  final int maxCapacity;
  final List<HourlyStart> hourlyStarts;

  DailyReport({
    required this.date, required this.currency, required this.visitors, required this.newCustomers,
    required this.sessionsStarted, required this.sessionsCompleted, required this.earlyExits, required this.active,
    required this.cancelled, required this.noShows, required this.extensions, required this.chargesMinor,
    required this.refundsMinor, required this.netMinor, required this.discountsMinor, required this.byMethod,
    required this.equipmentIssues, required this.distinctUnits, required this.incidentsTotal,
    required this.averageSessionSeconds, required this.capacityUtilizationPercent, required this.maxCapacity,
    required this.hourlyStarts,
  });

  factory DailyReport.fromJson(Map<String, dynamic> j) {
    final sessions = (j['sessions'] as Map<String, dynamic>?) ?? const {};
    final revenue = (j['revenue'] as Map<String, dynamic>?) ?? const {};
    final equipment = (j['equipment'] as Map<String, dynamic>?) ?? const {};
    final incidents = (j['incidents'] as Map<String, dynamic>?) ?? const {};
    return DailyReport(
      date: (j['date'] as String?) ?? '',
      currency: (j['currency'] as String?) ?? 'ETB',
      visitors: (j['visitors'] as int?) ?? 0,
      newCustomers: (j['newCustomers'] as int?) ?? 0,
      sessionsStarted: (sessions['started'] as int?) ?? 0,
      sessionsCompleted: (sessions['completed'] as int?) ?? 0,
      earlyExits: (sessions['earlyExits'] as int?) ?? 0,
      active: (sessions['active'] as int?) ?? 0,
      cancelled: (sessions['cancelled'] as int?) ?? 0,
      noShows: (sessions['noShows'] as int?) ?? 0,
      extensions: (sessions['extensions'] as int?) ?? 0,
      chargesMinor: (revenue['chargesMinor'] as int?) ?? 0,
      refundsMinor: (revenue['refundsMinor'] as int?) ?? 0,
      netMinor: (revenue['netMinor'] as int?) ?? 0,
      discountsMinor: (revenue['discountsMinor'] as int?) ?? 0,
      byMethod: ((revenue['byMethod'] as List?) ?? const []).map((e) => RevenueByMethod.fromJson(e as Map<String, dynamic>)).toList(),
      equipmentIssues: (equipment['issues'] as int?) ?? 0,
      distinctUnits: (equipment['distinctUnits'] as int?) ?? 0,
      incidentsTotal: (incidents['total'] as int?) ?? 0,
      averageSessionSeconds: (j['averageSessionSeconds'] as int?) ?? 0,
      capacityUtilizationPercent: ((j['capacityUtilizationPercent'] as num?) ?? 0).toDouble(),
      maxCapacity: (j['maxCapacity'] as int?) ?? 0,
      hourlyStarts: ((j['hourlyStarts'] as List?) ?? const []).map((e) => HourlyStart.fromJson(e as Map<String, dynamic>)).toList(),
    );
  }
}

class RangeRow {
  final String period;
  final int sessionsStarted;
  final int sessionsCompleted;
  final int uniqueCustomers;
  final int revenueMinor;
  final int refundsMinor;
  final int discountsMinor;
  final int averageSessionSeconds;
  RangeRow({
    required this.period, required this.sessionsStarted, required this.sessionsCompleted, required this.uniqueCustomers,
    required this.revenueMinor, required this.refundsMinor, required this.discountsMinor, required this.averageSessionSeconds,
  });
  factory RangeRow.fromJson(Map<String, dynamic> j) => RangeRow(
        period: j['period'] as String,
        sessionsStarted: (j['sessionsStarted'] as int?) ?? 0,
        sessionsCompleted: (j['sessionsCompleted'] as int?) ?? 0,
        uniqueCustomers: (j['uniqueCustomers'] as int?) ?? 0,
        revenueMinor: (j['revenueMinor'] as int?) ?? 0,
        refundsMinor: (j['refundsMinor'] as int?) ?? 0,
        discountsMinor: (j['discountsMinor'] as int?) ?? 0,
        averageSessionSeconds: (j['averageSessionSeconds'] as int?) ?? 0,
      );
}

class RangeReport {
  final String from;
  final String to;
  final String currency;
  final List<RangeRow> rows;
  final Map<String, dynamic> totals;
  RangeReport({required this.from, required this.to, required this.currency, required this.rows, required this.totals});
  factory RangeReport.fromJson(Map<String, dynamic> j) => RangeReport(
        from: j['from'] as String,
        to: j['to'] as String,
        currency: (j['currency'] as String?) ?? 'ETB',
        rows: ((j['rows'] as List?) ?? const []).map((e) => RangeRow.fromJson(e as Map<String, dynamic>)).toList(),
        totals: (j['totals'] as Map<String, dynamic>?) ?? const {},
      );
}
