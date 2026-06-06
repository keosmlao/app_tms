class DeliveryBill {
  const DeliveryBill({
    required this.billNo,
    required this.billDate,
    required this.custCode,
    required this.custName,
    required this.telephone,
    required this.destination,
    required this.pickupTransportCode,
    required this.pickupTransportName,
    required this.forwardTransportCode,
    required this.forwardTransportName,
    required this.parentBillNo,
    required this.dateLogistic,
    required this.lat,
    required this.lng,
    required this.latEnd,
    required this.lngEnd,
    required this.plannedLat,
    required this.plannedLng,
    required this.countItem,
    required this.status,
    required this.reciptJob,
    required this.sentStart,
    required this.sentEnd,
    required this.urlImage,
    required this.signatureImage,
    required this.remark,
    required this.deliveredItemCount,
    required this.remainingItemCount,
    required this.deliveredQtyTotal,
    required this.remainingQtyTotal,
    required this.phase,
    required this.statusText,
    this.hasReciptImg = false,
    this.hasReciptSignImg = false,
    this.codAmount = 0,
    this.collectedAmount,
    this.paymentMethod = '',
    this.cancelReasonCode = '',
    this.rescheduleDate = '',
  });

  final String billNo;
  final String billDate;
  final String custCode;
  final String custName;
  final String telephone;
  final String destination;
  final String pickupTransportCode;
  final String pickupTransportName;
  final String forwardTransportCode;
  final String forwardTransportName;
  // Empty string when the bill is standalone (no parent sale). Non-empty
  // means this bill is a sub-bill of a larger customer order that was split
  // across multiple warehouses or branches.
  final String parentBillNo;
  final String dateLogistic;
  final String lat;
  final String lng;
  final String latEnd;
  final String lngEnd;
  // Dispatcher-set pickup pin from the bills-pending dashboard. Empty when
  // the dispatcher hasn't marked one — fall back to lat/lng for navigation.
  final String plannedLat;
  final String plannedLng;
  final int countItem;
  final int status;
  final String reciptJob;
  final String sentStart;
  final String sentEnd;
  final String urlImage;
  final String signatureImage;
  final String remark;
  final int deliveredItemCount;
  final int remainingItemCount;
  final double deliveredQtyTotal;
  final double remainingQtyTotal;
  final String phase;
  final String statusText;
  // True when the driver captured a pickup photo / customer signature at the
  // customer's yard ('__CUSTOMER__' receive). The bytes are excluded from the
  // list payload — these flags only signal "proof on file".
  final bool hasReciptImg;
  final bool hasReciptSignImg;
  // COD (Module B): cod_amount = expected to collect; collectedAmount = taken.
  final double codAmount;
  final double? collectedAmount;
  final String paymentMethod; // cash | transfer | none | ''
  // Module D: standardized cancel reason + reschedule date (display string).
  final String cancelReasonCode;
  final String rescheduleDate;

  factory DeliveryBill.fromJson(Map<String, dynamic> json) {
    int parseInt(dynamic value) => int.tryParse('$value') ?? 0;
    double parseDouble(dynamic value) => double.tryParse('$value') ?? 0;

    return DeliveryBill(
      billNo: (json['bill_no'] ?? '').toString(),
      billDate: (json['bill_date'] ?? '-').toString(),
      custCode: (json['cust_code'] ?? '').toString(),
      custName: (json['cust_name'] ?? '-').toString(),
      telephone: (json['telephone'] ?? '').toString(),
      destination: (json['destination'] ?? '').toString(),
      pickupTransportCode: (json['pickup_transport_code'] ?? '').toString(),
      pickupTransportName: (json['pickup_transport_name'] ?? '').toString(),
      forwardTransportCode: (json['forward_transport_code'] ?? '').toString(),
      forwardTransportName: (json['forward_transport_name'] ?? '').toString(),
      parentBillNo: (json['parent_bill_no'] ?? '').toString(),
      dateLogistic: (json['date_logistic'] ?? '-').toString(),
      lat: (json['lat'] ?? '').toString(),
      lng: (json['lng'] ?? '').toString(),
      latEnd: (json['lat_end'] ?? '').toString(),
      lngEnd: (json['lng_end'] ?? '').toString(),
      plannedLat: (json['planned_lat'] ?? '').toString(),
      plannedLng: (json['planned_lng'] ?? '').toString(),
      countItem: parseInt(json['count_item']),
      status: parseInt(json['status']),
      reciptJob: (json['recipt_job'] ?? '-').toString(),
      sentStart: (json['sent_start'] ?? '-').toString(),
      sentEnd: (json['sent_end'] ?? '-').toString(),
      urlImage: (json['url_img'] ?? '').toString(),
      signatureImage: (json['sight_img'] ?? '').toString(),
      remark: (json['remark'] ?? '').toString(),
      deliveredItemCount: parseInt(json['delivered_item_count']),
      remainingItemCount: parseInt(json['remaining_item_count']),
      deliveredQtyTotal: parseDouble(json['delivered_qty_total']),
      remainingQtyTotal: parseDouble(json['remaining_qty_total']),
      phase: (json['phase'] ?? 'waiting').toString(),
      statusText: (json['status_text'] ?? '-').toString(),
      hasReciptImg: json['has_recipt_img'] == true ||
          json['has_recipt_img']?.toString() == 'true',
      hasReciptSignImg: json['has_recipt_sign_img'] == true ||
          json['has_recipt_sign_img']?.toString() == 'true',
      codAmount: parseDouble(json['cod_amount']),
      collectedAmount: json['collected_amount'] == null
          ? null
          : parseDouble(json['collected_amount']),
      paymentMethod: (json['payment_method'] ?? '').toString(),
      cancelReasonCode: (json['cancel_reason_code'] ?? '').toString(),
      rescheduleDate: (json['reschedule_date'] ?? '').toString(),
    );
  }

  // Returns a new bill with selected fields overridden. Used for optimistic
  // updates after a successful action — the UI flips to the predicted phase
  // immediately so a flaky post-action reload that falls back to the cached
  // (pre-action) state doesn't make the button reappear.
  DeliveryBill copyWith({
    String? phase,
    int? status,
    String? statusText,
  }) {
    return DeliveryBill(
      billNo: billNo,
      billDate: billDate,
      custCode: custCode,
      custName: custName,
      telephone: telephone,
      destination: destination,
      pickupTransportCode: pickupTransportCode,
      pickupTransportName: pickupTransportName,
      forwardTransportCode: forwardTransportCode,
      forwardTransportName: forwardTransportName,
      parentBillNo: parentBillNo,
      dateLogistic: dateLogistic,
      lat: lat,
      lng: lng,
      latEnd: latEnd,
      lngEnd: lngEnd,
      plannedLat: plannedLat,
      plannedLng: plannedLng,
      countItem: countItem,
      status: status ?? this.status,
      reciptJob: reciptJob,
      sentStart: sentStart,
      sentEnd: sentEnd,
      urlImage: urlImage,
      signatureImage: signatureImage,
      remark: remark,
      deliveredItemCount: deliveredItemCount,
      remainingItemCount: remainingItemCount,
      deliveredQtyTotal: deliveredQtyTotal,
      remainingQtyTotal: remainingQtyTotal,
      phase: phase ?? this.phase,
      statusText: statusText ?? this.statusText,
      hasReciptImg: hasReciptImg,
      hasReciptSignImg: hasReciptSignImg,
      codAmount: codAmount,
      collectedAmount: collectedAmount,
      paymentMethod: paymentMethod,
      cancelReasonCode: cancelReasonCode,
      rescheduleDate: rescheduleDate,
    );
  }

  bool get isPickedUp => phase == 'pickup' || phase == 'inprogress';

  bool get canPickup => phase == 'waiting';

  bool get canCheckIn => phase == 'pickup';

  bool get canComplete => phase == 'inprogress';

  bool get canCancel =>
      phase == 'waiting' || phase == 'pickup' || phase == 'inprogress';

  // Driver can roll back a completed delivery while the trip is still open
  // (job_status < 3). The trip-closed check is enforced in the screen since
  // the bill model doesn't know its parent job's status.
  bool get canRevertComplete => phase == 'done';

  // Same trip-open window as canRevertComplete — edit lets the driver change
  // photos / quantity / remark / signature without resetting the delivery.
  bool get canEdit => phase == 'done';

  bool get isFinished => phase == 'done' || phase == 'cancel';
}
