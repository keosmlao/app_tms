class DeliveryJob {
  const DeliveryJob({
    required this.docDate,
    required this.docNo,
    required this.dateLogistic,
    required this.carCode,
    required this.car,
    required this.driver,
    required this.itemBill,
    required this.userCreated,
    required this.approveStatus,
    required this.jobStatus,
    required this.waitingBillCount,
    required this.inprogressBillCount,
    required this.completedBillCount,
    required this.cancelledBillCount,
    required this.receivedAt,
    required this.dispatchStartedAt,
    required this.milesStart,
    required this.imgStart,
    required this.milesEnd,
    required this.imgEnd,
    required this.statusText,
  });

  final String docDate;
  final String docNo;
  final String dateLogistic;
  final String carCode;
  final String car;
  final String driver;
  final int itemBill;
  final String userCreated;
  final int approveStatus;
  final int jobStatus;
  final int waitingBillCount;
  final int inprogressBillCount;
  final int completedBillCount;
  final int cancelledBillCount;
  final String receivedAt;
  final String dispatchStartedAt;
  final String milesStart;
  final String imgStart;
  final String milesEnd;
  final String imgEnd;
  final String statusText;

  factory DeliveryJob.fromJson(Map<String, dynamic> json) {
    int parseInt(dynamic value) => int.tryParse('$value') ?? 0;

    return DeliveryJob(
      docDate: (json['doc_date'] ?? '-').toString(),
      docNo: (json['doc_no'] ?? '').toString(),
      dateLogistic: (json['date_logistic'] ?? '-').toString(),
      carCode: (json['car_code'] ?? '').toString(),
      car: (json['car'] ?? '-').toString(),
      driver: (json['driver'] ?? '-').toString(),
      itemBill: parseInt(json['item_bill']),
      userCreated: (json['user_created'] ?? '-').toString(),
      approveStatus: parseInt(json['approve_status']),
      jobStatus: parseInt(json['job_status']),
      waitingBillCount: parseInt(json['waiting_bill_count']),
      inprogressBillCount: parseInt(json['inprogress_bill_count']),
      completedBillCount: parseInt(json['completed_bill_count']),
      cancelledBillCount: parseInt(json['cancelled_bill_count']),
      receivedAt: (json['received_at'] ?? '-').toString(),
      dispatchStartedAt: (json['dispatch_started_at'] ?? '-').toString(),
      milesStart: (json['miles_start'] ?? '').toString(),
      imgStart: (json['img_start'] ?? '').toString(),
      milesEnd: (json['miles_end'] ?? '').toString(),
      imgEnd: (json['img_end'] ?? '').toString(),
      statusText: (json['status'] ?? '-').toString(),
    );
  }

  bool get isApproved => approveStatus == 1;
  bool get pendingApproval => approveStatus == 0;

  bool get canReceive => isApproved && jobStatus == 0;

  bool get canStartDispatch => isApproved && jobStatus == 1;

  bool get canCompleteJob =>
      isApproved &&
      jobStatus < 3 &&
      waitingBillCount == 0 &&
      inprogressBillCount == 0;

  bool get driverClosed => jobStatus >= 3;
}
