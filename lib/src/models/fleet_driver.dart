/// One live fleet position from either a driver's phone or a vehicle GPS.
class FleetDriver {
  const FleetDriver({
    required this.unitKey,
    required this.source,
    required this.docNo,
    required this.driver,
    required this.car,
    required this.jobStatus,
    required this.lat,
    required this.lng,
    required this.recordedAt,
    required this.stationarySecs,
    required this.battery,
    required this.ageSeconds,
    required this.speed,
    required this.heading,
    required this.address,
  });

  final String unitKey;
  final String source;
  final String docNo;
  final String driver;
  final String car;
  final int jobStatus;
  final double? lat;
  final double? lng;
  final String recordedAt;
  final int stationarySecs;
  final String battery;

  /// Seconds since this driver's last GPS fix (server-computed).
  final int ageSeconds;
  final String speed;
  final String heading;
  final String address;

  /// Considered live when the last fix is recent (≤ 2 minutes).
  bool get isOnline => ageSeconds > 0 && ageSeconds <= 120;
  bool get isVehicleGps => source == 'vehicle';
  bool get isPhoneGps => !isVehicleGps;

  factory FleetDriver.fromJson(Map<String, dynamic> json) {
    double? parseLatLng(dynamic v) {
      final d = double.tryParse('${v ?? ''}'.trim());
      return d;
    }

    int parseInt(dynamic v) => int.tryParse('${v ?? ''}'.trim()) ?? 0;

    return FleetDriver(
      unitKey: (json['unit_key'] ?? json['doc_no'] ?? '').toString(),
      source: (json['source'] ?? 'phone').toString(),
      docNo: (json['doc_no'] ?? '').toString(),
      driver: (json['driver'] ?? '-').toString(),
      car: (json['car'] ?? '-').toString(),
      jobStatus: parseInt(json['job_status']),
      lat: parseLatLng(json['lat']),
      lng: parseLatLng(json['lng']),
      recordedAt: (json['recorded_at'] ?? '').toString(),
      stationarySecs: parseInt(json['stationary_secs']),
      battery: (json['battery'] ?? '').toString(),
      ageSeconds: parseInt(json['age_seconds']),
      speed: (json['speed'] ?? '').toString(),
      heading: (json['heading'] ?? '').toString(),
      address: (json['address'] ?? '').toString(),
    );
  }

  /// True when there's a usable (non-zero) coordinate to plot.
  bool get hasLocation {
    final la = lat, ln = lng;
    if (la == null || ln == null) return false;
    if (la == 0 && ln == 0) return false;
    return true;
  }
}
