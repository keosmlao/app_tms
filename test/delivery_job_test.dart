import 'package:flutter_test/flutter_test.dart';
import 'package:odgtms/src/models/delivery_job.dart';

void main() {
  group('DeliveryJob.fromJson', () {
    test('parses all fields with defaults for missing values', () {
      final job = DeliveryJob.fromJson(const {});
      expect(job.docNo, '');
      expect(job.car, '-');
      expect(job.itemBill, 0);
      expect(job.approveStatus, 0);
    });

    test('coerces numeric fields safely from string input', () {
      final job = DeliveryJob.fromJson(const {
        'doc_no': 'D1',
        'item_bill': '5',
        'approve_status': '1',
        'job_status': '2',
        'waiting_bill_count': '0',
        'inprogress_bill_count': '1',
      });
      expect(job.docNo, 'D1');
      expect(job.itemBill, 5);
      expect(job.approveStatus, 1);
      expect(job.jobStatus, 2);
    });
  });

  group('DeliveryJob status guards', () {
    DeliveryJob make({
      int approveStatus = 1,
      int jobStatus = 0,
      int waiting = 0,
      int inProgress = 0,
    }) {
      return DeliveryJob.fromJson({
        'approve_status': approveStatus,
        'job_status': jobStatus,
        'waiting_bill_count': waiting,
        'inprogress_bill_count': inProgress,
      });
    }

    test('canReceive only when approved and not yet started', () {
      expect(make(approveStatus: 1, jobStatus: 0).canReceive, true);
      expect(make(approveStatus: 0, jobStatus: 0).canReceive, false);
      expect(make(approveStatus: 1, jobStatus: 1).canReceive, false);
    });

    test('canStartDispatch only when approved and received', () {
      expect(make(jobStatus: 1).canStartDispatch, true);
      expect(make(jobStatus: 0).canStartDispatch, false);
    });

    test('canCompleteJob requires all bills resolved', () {
      expect(make(jobStatus: 2, waiting: 0, inProgress: 0).canCompleteJob, true);
      expect(make(jobStatus: 2, waiting: 1).canCompleteJob, false);
      expect(make(jobStatus: 2, inProgress: 1).canCompleteJob, false);
      expect(make(jobStatus: 3).canCompleteJob, false);
    });

    test('driverClosed when jobStatus >= 3', () {
      expect(make(jobStatus: 2).driverClosed, false);
      expect(make(jobStatus: 3).driverClosed, true);
      expect(make(jobStatus: 9).driverClosed, true);
    });
  });
}
