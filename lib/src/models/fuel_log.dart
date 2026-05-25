class FuelLog {
  const FuelLog({
    required this.id,
    required this.fuelDate,
    required this.userCode,
    required this.driverName,
    required this.car,
    required this.docNo,
    required this.liters,
    required this.amount,
    required this.odometer,
    required this.station,
    required this.note,
    required this.hasImage,
    required this.createdAt,
  });

  final int id;
  final String fuelDate;
  final String userCode;
  final String driverName;
  final String car;
  final String docNo;
  final double liters;
  final double amount;
  final double? odometer;
  final String station;
  final String note;
  final bool hasImage;
  final String createdAt;

  static double _toDouble(Object? v) {
    if (v == null) return 0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0;
  }

  factory FuelLog.fromJson(Map<String, dynamic> json) {
    return FuelLog(
      id: (json['id'] is num) ? (json['id'] as num).toInt() : 0,
      fuelDate: (json['fuel_date'] ?? '').toString(),
      userCode: (json['user_code'] ?? '').toString(),
      driverName: (json['driver_name'] ?? '').toString(),
      car: (json['car'] ?? '').toString(),
      docNo: (json['doc_no'] ?? '').toString(),
      liters: _toDouble(json['liters']),
      amount: _toDouble(json['amount']),
      odometer: json['odometer'] == null ? null : _toDouble(json['odometer']),
      station: (json['station'] ?? '').toString(),
      note: (json['note'] ?? '').toString(),
      hasImage: json['has_image'] == true,
      createdAt: (json['created_at'] ?? '').toString(),
    );
  }
}

class FuelLogList {
  const FuelLogList({
    required this.rows,
    required this.totalLiters,
    required this.totalAmount,
    required this.count,
  });

  final List<FuelLog> rows;
  final double totalLiters;
  final double totalAmount;
  final int count;

  factory FuelLogList.fromJson(Map<String, dynamic> json) {
    final rawRows = (json['rows'] as List?) ?? const [];
    final rows = rawRows
        .whereType<Map>()
        .map((e) => FuelLog.fromJson(Map<String, dynamic>.from(e)))
        .toList();
    final summary = (json['summary'] as Map?) ?? const {};
    return FuelLogList(
      rows: rows,
      totalLiters: FuelLog._toDouble(summary['total_liters']),
      totalAmount: FuelLog._toDouble(summary['total_amount']),
      count: (summary['entry_count'] is num)
          ? (summary['entry_count'] as num).toInt()
          : rows.length,
    );
  }
}
