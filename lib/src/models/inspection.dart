int _parseInt(dynamic v) =>
    v == null ? 0 : v is num ? v.toInt() : int.tryParse(v.toString()) ?? 0;

class DriverCar {
  const DriverCar({
    required this.code,
    required this.name,
    required this.plateNo,
  });

  final String code;
  final String name;
  final String plateNo;

  String get displayLabel => plateNo.isNotEmpty ? '$code — $plateNo' : code;

  factory DriverCar.fromJson(Map<String, dynamic> json) => DriverCar(
        code: (json['code'] ?? '').toString(),
        name: (json['name'] ?? '').toString(),
        plateNo: (json['plate_no'] ?? '').toString(),
      );
}

double? _parseDouble(dynamic v) =>
    v == null ? null : v is num ? v.toDouble() : double.tryParse(v.toString());

class InspectCheckItem {
  const InspectCheckItem({
    required this.itemCode,
    required this.itemName,
    required this.sortOrder,
  });

  final String itemCode;
  final String itemName;
  final int sortOrder;

  factory InspectCheckItem.fromJson(Map<String, dynamic> json) =>
      InspectCheckItem(
        itemCode: (json['item_code'] ?? '').toString(),
        itemName: (json['item_name'] ?? '').toString(),
        sortOrder: _parseInt(json['sort_order']),
      );
}

class InspectStatusOption {
  const InspectStatusOption({
    required this.statusCode,
    required this.statusName,
  });

  final int statusCode;
  final String statusName;

  factory InspectStatusOption.fromJson(Map<String, dynamic> json) =>
      InspectStatusOption(
        statusCode: _parseInt(json['status_code']),
        statusName: (json['status_name'] ?? '').toString(),
      );
}

class InspectMeta {
  const InspectMeta({required this.items, required this.statuses});

  final List<InspectCheckItem> items;
  final List<InspectStatusOption> statuses;

  factory InspectMeta.fromJson(Map<String, dynamic> json) => InspectMeta(
        items: (json['items'] as List? ?? [])
            .whereType<Map>()
            .map((e) => InspectCheckItem.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
        statuses: (json['statuses'] as List? ?? [])
            .whereType<Map>()
            .map((e) =>
                InspectStatusOption.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );
}

class InspectionDetail {
  const InspectionDetail({
    required this.itemCode,
    required this.itemName,
    required this.statusCode,
    required this.statusName,
  });

  final String itemCode;
  final String itemName;
  final int statusCode;
  final String statusName;

  factory InspectionDetail.fromJson(Map<String, dynamic> json) =>
      InspectionDetail(
        itemCode: (json['item_code'] ?? '').toString(),
        itemName: (json['item_name'] ?? '').toString(),
        statusCode: _parseInt(json['status_code']),
        statusName: (json['status_name'] ?? '').toString(),
      );
}

class InspectionRecord {
  const InspectionRecord({
    required this.inspectCode,
    required this.vehicleCode,
    required this.vehicleName,
    required this.inspectDate,
    this.inspectTime,
    this.driverCode,
    this.driverName = '',
    required this.employeeCode,
    required this.employeeName,
    this.odometer,
    this.note,
    required this.approvalStatus,
    this.approvedBy,
    this.approvedByName,
    this.approvedAt,
    this.approvalNote,
    this.detailCount = 0,
    this.details = const [],
  });

  final String inspectCode;
  final String vehicleCode;
  final String vehicleName;
  final String inspectDate;
  final String? inspectTime;
  final String? driverCode;
  final String driverName;
  final String employeeCode;
  final String employeeName;
  final double? odometer;
  final String? note;
  final String approvalStatus;
  final String? approvedBy;
  final String? approvedByName;
  final String? approvedAt;
  final String? approvalNote;
  final int detailCount;
  final List<InspectionDetail> details;

  bool get isPending => approvalStatus == 'pending';
  bool get isApproved => approvalStatus == 'approved';
  bool get isRejected => approvalStatus == 'rejected';

  factory InspectionRecord.fromJson(Map<String, dynamic> json) =>
      InspectionRecord(
        inspectCode: (json['inspect_code'] ?? '').toString(),
        vehicleCode: (json['vehicle_code'] ?? '').toString(),
        vehicleName: (json['vehicle_name'] ?? '').toString(),
        inspectDate: (json['inspect_date'] ?? '').toString(),
        inspectTime: json['inspect_time']?.toString(),
        driverCode: json['driver_code']?.toString(),
        driverName: (json['driver_name'] ?? '').toString(),
        employeeCode: (json['employee_code'] ?? '').toString(),
        employeeName: (json['employee_name'] ?? '').toString(),
        odometer: _parseDouble(json['odometer']),
        note: json['note']?.toString(),
        approvalStatus: (json['approval_status'] ?? 'pending').toString(),
        approvedBy: json['approved_by']?.toString(),
        approvedByName: json['approved_by_name']?.toString(),
        approvedAt: json['approved_at']?.toString(),
        approvalNote: json['approval_note']?.toString(),
        detailCount: _parseInt(json['detail_count']),
        details: (json['details'] as List? ?? [])
            .whereType<Map>()
            .map((e) =>
                InspectionDetail.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );
}
