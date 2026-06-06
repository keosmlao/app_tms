import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show HapticFeedback, SystemUiOverlayStyle;
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:signature/signature.dart';
import 'package:url_launcher/url_launcher.dart';

import 'checkin_map_screen.dart';
import 'qr_find_screen.dart';
import 'route_screen.dart';

import '../app_controller.dart';
import '../core/app_theme.dart';
import '../models/delivery_bill.dart';
import '../models/delivery_item.dart';
import '../models/delivery_job.dart';
import '../services/api_client.dart';
import '../services/location_tracking_service.dart';
import '../services/local_cache.dart';
import '../services/offline_outbox.dart';
import '../widgets/gps_tracking_banner.dart';

class JobDetailScreen extends StatefulWidget {
  final AppController controller;
  final DeliveryJob initialJob;
  final bool readOnly;
  const JobDetailScreen({
    super.key,
    required this.controller,
    required this.initialJob,
    this.readOnly = false,
  });
  @override
  State<JobDetailScreen> createState() => _JobDetailScreenState();
}

class _JobDetailScreenState extends State<JobDetailScreen> {
  late DeliveryJob _job;
  bool _loading = true;
  bool _busy = false;
  List<DeliveryBill> _bills = const [];
  String? _expandedBillNo;
  List<DeliveryItem> _expandedItems = const [];
  bool _loadingItems = false;
  bool _lastLoadUsedCache = false;
  DateTime? _jobsCacheAt;
  DateTime? _billsCacheAt;

  @override
  void initState() {
    super.initState();
    _job = widget.initialJob;
    _loadData();
  }

  // GPS-bound location resolver — actions that need lat/lng (start_dispatch,
  // checkin_bill, complete_bill, cancel_bill) call this. Throws on missing
  // permission or disabled service so _runAction surfaces a clear message
  // instead of silently submitting empty coordinates.
  Future<Map<String, String>> _getLocation() async {
    final serviceOn = await Geolocator.isLocationServiceEnabled();
    if (!serviceOn) {
      await Geolocator.openLocationSettings();
      throw Exception('ກະລຸນາເປີດ GPS ກ່ອນດຳເນີນການ');
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.deniedForever) {
      await Geolocator.openAppSettings();
      throw Exception('ກະລຸນາອະນຸຍາດການເຂົ້າເຖິງ GPS ໃນຕັ້ງຄ່າແອັບ');
    }
    if (perm == LocationPermission.denied) {
      throw Exception('ກະລຸນາອະນຸຍາດການເຂົ້າເຖິງ GPS');
    }
    final pos =
        await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
          ),
        ).timeout(
          const Duration(seconds: 15),
          onTimeout: () =>
              throw Exception('ບໍ່ສາມາດອ່ານ GPS ໄດ້ — ກະລຸນາລອງໃໝ່'),
        );
    return {'lat': pos.latitude.toString(), 'lng': pos.longitude.toString()};
  }

  Future<void> _loadData({bool silent = false}) async {
    // `silent` skips the centered "ກຳລັງໂຫຼດ..." spinner so post-action
    // refreshes don't double up with the busy overlay already on screen.
    if (!silent) setState(() => _loading = true);
    try {
      final api = widget.controller.api;
      final jobsRequest = widget.controller.user?.isOperationsUser == true
          ? api.getSupervisorJobs()
          : api.getJobs(driverId: widget.controller.user!.driverId);
      final results = await Future.wait([
        jobsRequest,
        api.getBills(docNo: _job.docNo),
        LocalCache.instance.jobsSavedAt(widget.controller.user!.driverId),
        LocalCache.instance.billsSavedAt(_job.docNo),
      ]);
      final jobs = results[0] as List<DeliveryJob>;
      final bills = results[1] as List<DeliveryBill>;
      final jobsCacheAt = results[2] as DateTime?;
      final billsCacheAt = results[3] as DateTime?;
      final updated = jobs.where((j) => j.docNo == _job.docNo).firstOrNull;
      setState(() {
        if (updated != null) _job = updated;
        _bills = bills;
        _lastLoadUsedCache = api.lastFetchUsedCache;
        _jobsCacheAt = jobsCacheAt;
        _billsCacheAt = billsCacheAt;
        if (!silent) _loading = false;
      });
      // Start/stop continuous GPS tracking immediately when this trip's dispatch
      // state changes (e.g. right after "ເລີ່ມຈັດສົ່ງ" or "ປິດງານ").
      LocationTrackingService.instance.sync(
        jobs: jobs,
        baseUrl: widget.controller.baseUrl,
        authToken: widget.controller.user!.token,
        driverId: widget.controller.user!.driverId,
      );
    } catch (e) {
      if (!silent) setState(() => _loading = false);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  // Apply an optimistic local change to a single bill in `_bills`. Used after
  // a state-changing action returns success: we know the server's new state,
  // so flip the bill in memory immediately. This prevents the "ປຸ່ມສຳເລັດກັບມາ"
  // bug where a flaky post-action getBills falls back to cached pre-action
  // data and stamps the old phase back onto the UI.
  void _applyLocalBillUpdate(
    String billNo,
    DeliveryBill Function(DeliveryBill) update,
  ) {
    setState(() {
      _bills = [
        for (final bill in _bills)
          if (bill.billNo == billNo) update(bill) else bill,
      ];
    });
  }

  Future<void> _toggleItems(String billNo) async {
    if (_expandedBillNo == billNo) {
      setState(() => _expandedBillNo = null);
      return;
    }
    setState(() {
      _expandedBillNo = billNo;
      _loadingItems = true;
    });
    try {
      final items = await widget.controller.api.getBillItems(billNo: billNo);
      setState(() {
        _expandedItems = items;
        _loadingItems = false;
      });
    } catch (e) {
      setState(() => _loadingItems = false);
    }
  }

  Future<void> _runAction(
    Future<void> Function() action,
    String successMsg, {
    // Optimistic local change to apply once `action` returns success — runs
    // BEFORE the reload so the UI flips immediately, and is RE-APPLIED after
    // the reload if the reload fell back to cached (pre-action) data.
    void Function()? optimisticUpdate,
  }) async {
    setState(() => _busy = true);
    // Snapshot offline-queue size so we can detect whether `action` actually
    // committed to the server or fell back to OfflineOutbox.enqueue — the
    // _postQueueable wrapper swallows network failures silently, so without
    // this check the UI would show a "ສຳເລັດ" snackbar for work that hasn't
    // really been sent yet.
    final outboxBefore = OfflineOutbox.instance.pendingCount;
    try {
      await action();
      final wasQueued = OfflineOutbox.instance.pendingCount > outboxBefore;

      // Apply optimistic state for actions that committed straight to the
      // server. Queued actions haven't actually run yet, so faking "done"
      // would lie to the driver.
      if (!wasQueued && optimisticUpdate != null) {
        optimisticUpdate();
      }

      await _loadData(silent: true);
      final usedCache = _lastLoadUsedCache;

      // _loadData overwrote _bills with whatever getBills returned. If that
      // was the stale pre-action cache, the optimistic flip just got undone —
      // re-apply it so the driver doesn't see the button reappear.
      if (usedCache && !wasQueued && optimisticUpdate != null) {
        optimisticUpdate();
      }

      if (mounted) {
        final String msg;
        Color? bg;
        if (wasQueued) {
          msg = 'ບໍ່ມີເນັດ — ບັນທຶກໄວ້, ຈະສົ່ງເມື່ອມີສັນຍານ';
          bg = AppTheme.warning;
        } else if (usedCache) {
          msg = '$successMsg — ໂຫຼດຂໍ້ມູນໃໝ່ບໍ່ໄດ້, ດຶງລົງເພື່ອອັບເດດ';
          bg = AppTheme.warning;
        } else {
          msg = successMsg;
        }
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(msg), backgroundColor: bg));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _approveAsSupervisor() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.controller.api.approveJob(_job.docNo);
      await _loadData(silent: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('ອະນຸມັດ ${_job.docNo} ແລ້ວ'),
          backgroundColor: AppTheme.success,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('ອະນຸມັດບໍ່ໄດ້: ${e is ApiException ? e.message : e}'),
          backgroundColor: AppTheme.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _receiveJob() async {
    await _runAction(
      () => widget.controller.api.receiveJob(_job.docNo),
      'ຮັບຖ້ຽວແລ້ວ',
    );
  }

  Future<void> _startDispatch() async {
    final r = await showModalBottomSheet<_StartDispatchResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _StartDispatchSheet(),
    );
    if (r == null) return;
    await _runAction(() async {
      final l = await _getLocation();
      await widget.controller.api.startDispatch(
        docNo: _job.docNo,
        milesStart: r.miles,
        imageDataUri: r.img,
        lat: l['lat'],
        lng: l['lng'],
      );
    }, 'ເລີ່ມຈັດສົ່ງແລ້ວ');

    // Once dispatch starts the driver is leaving the depot — pull every bill's
    // item list into the local cache now so check-in and complete still work
    // in areas with no signal. Items are otherwise only fetched lazily when
    // the complete page opens, which fails offline if the bill was never
    // viewed online.
    if (mounted && _bills.isNotEmpty) {
      await _prefetchBillItemsForOffline();
    }
  }

  Future<void> _prefetchBillItemsForOffline() async {
    final bills = List<DeliveryBill>.from(_bills);
    if (bills.isEmpty) return;

    final progress = ValueNotifier<int>(0);
    int failed = 0;

    final dialogFuture = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('ກຳລັງໂຫຼດຂໍ້ມູນສຳລັບ offline'),
        content: ValueListenableBuilder<int>(
          valueListenable: progress,
          builder: (_, done, _) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LinearProgressIndicator(
                  value: bills.isEmpty ? 0 : done / bills.length,
                ),
                const SizedBox(height: 12),
                Text('$done / ${bills.length} ບິນ'),
              ],
            );
          },
        ),
      ),
    );

    for (final bill in bills) {
      if (!mounted) break;
      try {
        await widget.controller.api.getBillItems(billNo: bill.billNo);
      } catch (_) {
        failed++;
      }
      progress.value++;
    }

    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    await dialogFuture;
    progress.dispose();

    if (!mounted) return;
    final ok = bills.length - failed;
    final msg = failed == 0
        ? 'ໂຫຼດຂໍ້ມູນ $ok ບິນ ສຳເລັດ — ສຳເລັດໄດ້ offline'
        : 'ໂຫຼດໄດ້ $ok/${bills.length} ບິນ — $failed ບິນລົ້ມເຫລວ, ກວດເບິ່ງເນັດກ່ອນອອກຈາກ warehouse';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: failed == 0 ? null : AppTheme.warning,
        duration: Duration(seconds: failed == 0 ? 3 : 6),
      ),
    );
  }

  bool _hasLocation(DeliveryBill b) {
    final lat = double.tryParse(b.lat.trim());
    final lng = double.tryParse(b.lng.trim());
    if (lat == null || lng == null) return false;
    if (lat == 0 && lng == 0) return false;
    return true;
  }

  Future<void> _openMap(DeliveryBill b) async {
    HapticFeedback.selectionClick();
    // Prefer the dispatcher's planned pin (set on the bills-pending dashboard)
    // — it's verified by a human and won't drift like the customer's lat/lng
    // from ar_customer_detail. Fall back to the bill's lat/lng otherwise.
    final plannedLat = b.plannedLat.trim();
    final plannedLng = b.plannedLng.trim();
    final hasPlanned = plannedLat.isNotEmpty && plannedLng.isNotEmpty;
    final lat = hasPlanned ? plannedLat : b.lat.trim();
    final lng = hasPlanned ? plannedLng : b.lng.trim();
    final label = Uri.encodeComponent(
      b.custName.isNotEmpty ? b.custName : 'ຈຸດສົ່ງ',
    );
    // Universal link — Google Maps app on Android/iOS, browser fallback.
    final uri = Uri.parse(
      'https://www.google.com/maps/search/?api=1&query=$lat,$lng&query_place_id=$label',
    );
    await _launchOrSnack(uri, 'ບໍ່ສາມາດເປີດແຜນທີ່ໄດ້');
  }

  bool _hasPhone(DeliveryBill b) => _normalizePhone(b.telephone) != null;

  /// Returns a phone number in international format (e.g. 8562012345678) or
  /// null when the input has fewer than 8 digits.
  String? _normalizePhone(String raw) {
    var digits = raw.replaceAll(RegExp(r'[^0-9+]'), '');
    if (digits.startsWith('+')) digits = digits.substring(1);
    // Default country code = Laos (856) when number starts with 0 or has no
    // country prefix.
    if (digits.startsWith('00')) digits = digits.substring(2);
    if (digits.startsWith('0')) digits = '856${digits.substring(1)}';
    if (digits.length < 8) return null;
    return digits;
  }

  Future<void> _callPhone(DeliveryBill b) async {
    HapticFeedback.selectionClick();
    final number = _normalizePhone('856${b.telephone}');
    if (number == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('ບໍ່ມີເບີໂທ')));
      return;
    }
    await _launchOrSnack(Uri.parse('tel:+$number'), 'ບໍ່ສາມາດໂທໄດ້');
  }

  Future<void> _openWhatsApp(DeliveryBill b) async {
    HapticFeedback.selectionClick();
    final number = _normalizePhone('856${b.telephone}');
    if (number == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('ບໍ່ມີເບີໂທ')));
      return;
    }
    final greeting = b.custName.isNotEmpty
        ? 'ສະບາຍດີ ${b.custName} 🚚 ຈະນຳສິນຄ້າມາສົ່ງ ບິນ ${b.billNo}'
        : 'ສະບາຍດີ 🚚 ຈະນຳສິນຄ້າມາສົ່ງ ບິນ ${b.billNo}';
    final text = Uri.encodeComponent(greeting);
    final uri = Uri.parse('https://wa.me/$number?text=$text');
    await _launchOrSnack(uri, 'ບໍ່ສາມາດເປີດ WhatsApp ໄດ້');
  }

  Future<void> _launchOrSnack(Uri uri, String fallbackMessage) async {
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(fallbackMessage)));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$fallbackMessage: $e')));
    }
  }

  Future<void> _pickupBill(DeliveryBill b) async {
    await _runAction(
      () => widget.controller.api.pickupBill(billNo: b.billNo),
      'ເບີກບິນແລ້ວ',
    );
  }

  Future<void> _pickupBills(List<DeliveryBill> pending, String label) async {
    if (pending.isEmpty) return;
    setState(() => _busy = true);
    try {
      for (final b in pending) {
        await widget.controller.api.pickupBill(billNo: b.billNo);
      }
      await _loadData(silent: true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('ເບີກ$label ແລ້ວ (${pending.length} ບິນ)')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      setState(() => _busy = false);
    }
  }

  // Receive goods at the customer's home/shop for a '__CUSTOMER__' pickup bill.
  // Two captures before sending: (1) GPS confirmation on the map, then (2) a
  // proof photo + the customer's signature. On success the bill moves to the
  // "pickup" phase — the driver then does the normal Check in + ສຳເລັດ at the
  // delivery destination (a separate, second leg).
  Future<void> _receiveFromCustomer(DeliveryBill b) async {
    // CheckinMapScreen pops a geolocator Position (untyped here, mirroring
    // _checkInBill — the screen returns null on cancel).
    final pos = await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => CheckinMapScreen(bill: b)));
    if (pos == null || !mounted) return; // GPS step cancelled

    final r = await Navigator.of(context).push<_ReceivePickupResult>(
      MaterialPageRoute(builder: (_) => _ReceivePickupPage(bill: b)),
    );
    if (r == null) return; // photo/signature step cancelled

    final lat = pos.latitude.toString();
    final lng = pos.longitude.toString();

    // Other customer-pickup bills still waiting at the SAME customer — offer to
    // receive them all with this one photo + signature + GPS so the driver
    // doesn't repeat the capture per bill.
    final siblings = _bills
        .where(
          (x) =>
              x.billNo != b.billNo &&
              x.pickupTransportCode == '__CUSTOMER__' &&
              x.custCode == b.custCode &&
              x.canPickup,
        )
        .toList();
    bool applyToSiblings = false;
    if (siblings.isNotEmpty && mounted) {
      applyToSiblings = await _askApplyReceiveToSiblings(b, siblings) ?? false;
    }

    DeliveryBill toPickup(DeliveryBill bill) =>
        bill.copyWith(phase: 'pickup', status: 0, statusText: 'ເບີກເຄື່ອງແລ້ວ');

    await _runAction(
      () async {
        await widget.controller.api.receiveCustomerPickup(
          billNo: b.billNo,
          lat: lat,
          lng: lng,
          photo: r.photo,
          signature: r.signature,
        );
        if (applyToSiblings) {
          for (final sib in siblings) {
            try {
              await widget.controller.api.receiveCustomerPickup(
                billNo: sib.billNo,
                lat: lat,
                lng: lng,
                photo: r.photo,
                signature: r.signature,
              );
            } catch (_) {
              // Don't fail the batch if one sibling errors — the main bill is
              // received and the driver can retry the sibling individually.
            }
          }
        }
      },
      applyToSiblings
          ? 'ຮັບສິນຄ້າຈາກລານລູກຄ້າ ${1 + siblings.length} ບິນແລ້ວ'
          : 'ຮັບສິນຄ້າຈາກລານລູກຄ້າແລ້ວ',
      // recipt_job set, sent_start left NULL → bill lands in the "pickup" phase.
      optimisticUpdate: () {
        _applyLocalBillUpdate(b.billNo, toPickup);
        if (applyToSiblings) {
          for (final sib in siblings) {
            _applyLocalBillUpdate(sib.billNo, toPickup);
          }
        }
      },
    );
  }

  Future<bool?> _askApplyReceiveToSiblings(
    DeliveryBill main,
    List<DeliveryBill> siblings,
  ) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgDark,
        title: const Text(
          'ຮັບຫຼາຍບິນພ້ອມກັນ',
          style: TextStyle(color: AppTheme.textBright),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'ມີອີກ ${siblings.length} ບິນ ທີ່ຕ້ອງຮັບຈາກລານ ${main.custName} ຄືກັນ:',
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 8),
            for (final sib in siblings)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  '• ${sib.billNo}',
                  style: const TextStyle(
                    color: AppTheme.textBright,
                    fontSize: 12,
                  ),
                ),
              ),
            const SizedBox(height: 12),
            const Text(
              'ໃຊ້ ຮູບ + ລາຍເຊັນ ນີ້ກັບທຸກບິນບໍ?',
              style: TextStyle(color: AppTheme.textBright, fontSize: 13),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('ບໍ່ — ຮັບແຕ່ບິນນີ້'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.success),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('ໃຊ້ກັບ ${1 + siblings.length} ບິນ'),
          ),
        ],
      ),
    );
  }

  // Open the nearest-neighbour route over the trip's remaining stops.
  Future<void> _openRoute() async {
    HapticFeedback.selectionClick();
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            RouteScreen(bills: _bills.where((b) => !b.isFinished).toList()),
      ),
    );
  }

  // Open a full-screen viewer for the proof captured at the customer's yard.
  // Bytes are fetched on demand (the list only carries has_recipt_img flags).
  Future<void> _viewPickupProof(DeliveryBill b) async {
    HapticFeedback.selectionClick();
    await Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _PickupProofViewer(api: widget.controller.api, bill: b),
      ),
    );
  }

  // Group bills by pickup point (warehouse name or "ບ້ານ/ຮ້ານລູກຄ້າ"). Bills
  // without a pickup_transport_name fall under "ບໍ່ໄດ້ກຳນົດ" so they're still
  // visible. Insertion order is preserved by LinkedHashMap (Dart default).
  Map<String, List<DeliveryBill>> _billsByPickup() {
    final groups = <String, List<DeliveryBill>>{};
    for (final b in _bills) {
      final key = b.pickupTransportName.isNotEmpty
          ? b.pickupTransportName
          : 'ບໍ່ໄດ້ກຳນົດຈຸດຮັບ';
      (groups[key] ??= []).add(b);
    }
    return groups;
  }

  Widget _buildPickupSectionHeader(
    String pickupName,
    List<DeliveryBill> bills,
  ) {
    final pendingPickup = bills.where((b) => b.canPickup).toList();
    final isCustomerPickup =
        pickupName.contains('ບ້ານ') || pickupName.contains('ຮ້ານ');
    return Container(
      margin: const EdgeInsets.only(top: 10, bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.18)),
      ),
      child: Row(
        children: [
          Icon(
            isCustomerPickup ? Icons.home_outlined : Icons.warehouse_outlined,
            size: 14,
            color: AppTheme.primary,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '$pickupName · ${bills.length} ບິນ',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: AppTheme.textBright,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (pendingPickup.isNotEmpty && !isCustomerPickup)
            TextButton.icon(
              onPressed: _busy
                  ? null
                  : () {
                      HapticFeedback.mediumImpact();
                      _pickupBills(pendingPickup, pickupName);
                    },
              icon: const Icon(Icons.inventory_2_outlined, size: 12),
              label: Text(
                'ເບີກ ${pendingPickup.length}',
                style: const TextStyle(fontSize: 10),
              ),
              style: TextButton.styleFrom(
                foregroundColor: AppTheme.primary,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
        ],
      ),
    );
  }

  // One tap: silently capture the current GPS (check-in) and go straight to the
  // complete form — no separate map-confirm step or second "ສຳເລັດ" press.
  Future<void> _checkInBill(DeliveryBill b) async {
    setState(() => _busy = true);
    try {
      final loc = await _getLocation();
      await widget.controller.api.checkInBill(
        billNo: b.billNo,
        lat: loc['lat']!,
        lng: loc['lng']!,
      );
      await _loadData(silent: true);
      if (!mounted) return;
      final updatedBill =
          _bills.where((bill) => bill.billNo == b.billNo).firstOrNull ?? b;
      setState(() => _busy = false);
      await _completeBill(updatedBill);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _completeBill(DeliveryBill b) async {
    final r = await Navigator.of(context).push<_CompResult>(
      MaterialPageRoute(
        builder: (_) => _CompPage(api: widget.controller.api, bill: b),
      ),
    );
    if (r == null) return;

    if (r.isCancelled) {
      await _runAction(
        () async {
          final l = await _getLocation();
          await widget.controller.api.cancelBill(
            billNo: b.billNo,
            comment: r.comment,
            deliveryImage: r.images.isNotEmpty ? r.images.first : null,
            lat: l['lat'],
            lng: l['lng'],
            latEnd: l['lat'],
            lngEnd: l['lng'],
          );
        },
        'ຍົກເລີກການຈັດສົ່ງແລ້ວ',
        optimisticUpdate: () => _applyLocalBillUpdate(
          b.billNo,
          (bill) => bill.copyWith(
            phase: 'cancel',
            status: 2,
            statusText: 'ຍົກເລີກຈັດສົ່ງ',
          ),
        ),
      );
      return;
    }

    // If this bill is part of a parent sale (same customer, split across
    // warehouses) and there are sibling sub-bills also ready to complete at
    // this customer, offer to apply the same images + signature to all of
    // them so the driver doesn't have to re-sign + re-photograph for each.
    final siblings = b.parentBillNo.isEmpty
        ? const <DeliveryBill>[]
        : _bills
              .where(
                (x) =>
                    x.billNo != b.billNo &&
                    x.parentBillNo == b.parentBillNo &&
                    x.custCode == b.custCode &&
                    (x.phase == 'pickup' || x.phase == 'inprogress'),
              )
              .toList();
    bool applyToSiblings = false;
    if (siblings.isNotEmpty && mounted) {
      applyToSiblings = await _askApplyToSiblings(b, siblings) ?? false;
    }

    await _runAction(
      () async {
        final l = await _getLocation();
        await widget.controller.api.completeBill(
          billNo: b.billNo,
          items: r.items,
          deliveryImages: r.images,
          signatureImage: r.sig,
          comment: r.comment,
          lat: l['lat'],
          lng: l['lng'],
          latEnd: l['lat'],
          lngEnd: l['lng'],
          collectedAmount: r.collectedAmount,
          paymentMethod: r.paymentMethod,
        );
        if (applyToSiblings) {
          for (final sib in siblings) {
            try {
              await widget.controller.api.completeBill(
                billNo: sib.billNo,
                // Empty items → backend defaults to delivering the remaining
                // qty for each item on the sibling bill.
                items: const [],
                deliveryImages: r.images,
                signatureImage: r.sig,
                comment: r.comment,
                lat: l['lat'],
                lng: l['lng'],
                latEnd: l['lat'],
                lngEnd: l['lng'],
              );
            } catch (_) {
              // Don't fail the whole batch if one sibling errors — main bill
              // already completed and the driver can retry the sibling
              // individually. Errors will surface on the next reload.
            }
          }
        }
      },
      applyToSiblings
          ? 'ບັນທຶກການຈັດສົ່ງ ${1 + siblings.length} ບິນແລ້ວ'
          : 'ບັນທຶກການຈັດສົ່ງແລ້ວ',
      optimisticUpdate: () {
        _applyLocalBillUpdate(
          b.billNo,
          (bill) => bill.copyWith(
            phase: 'done',
            status: 1,
            statusText: 'ຈັດສົ່ງສຳເລັດ',
          ),
        );
        if (applyToSiblings) {
          for (final sib in siblings) {
            _applyLocalBillUpdate(
              sib.billNo,
              (bill) => bill.copyWith(
                phase: 'done',
                status: 1,
                statusText: 'ຈັດສົ່ງສຳເລັດ',
              ),
            );
          }
        }
      },
    );
  }

  Future<bool?> _askApplyToSiblings(
    DeliveryBill main,
    List<DeliveryBill> siblings,
  ) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.bgDark,
        title: const Text(
          'ບິນຂາຍດຽວກັນ',
          style: TextStyle(color: AppTheme.textBright),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'ບິນ ${main.billNo} ມີ ${siblings.length} ບິນອື່ນຂອງບິນຂາຍ ${main.parentBillNo} '
              'ທີ່ກຳລັງສົ່ງໃຫ້ ${main.custName} ຄືກັນ:',
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 8),
            for (final sib in siblings)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  '• ${sib.billNo}'
                  '${sib.pickupTransportName.isNotEmpty ? " (${sib.pickupTransportName})" : ""}',
                  style: const TextStyle(
                    color: AppTheme.textBright,
                    fontSize: 12,
                  ),
                ),
              ),
            const SizedBox(height: 12),
            const Text(
              'ໃຊ້ ຮູບ + ລາຍເຊັນ + ໝາຍເຫດ ນີ້ກັບທຸກບິນບໍ?',
              style: TextStyle(color: AppTheme.textBright, fontSize: 13),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('ບໍ່ — ສຳເລັດແຕ່ບິນນີ້'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.success),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text('ໃຊ້ກັບ ${1 + siblings.length} ບິນ'),
          ),
        ],
      ),
    );
  }

  Future<void> _cancelBill(DeliveryBill b) async {
    final r = await showDialog<_CancelResult>(
      context: context,
      builder: (_) => _CancelDialog(billNo: b.billNo),
    );
    if (r == null || r.comment.isEmpty) return;
    await _runAction(
      () async {
        final l = await _getLocation();
        await widget.controller.api.cancelBill(
          billNo: b.billNo,
          comment: r.comment,
          reasonCode: r.reasonCode,
          rescheduleDate: r.rescheduleDate,
          lat: l['lat'],
          lng: l['lng'],
          latEnd: l['lat'],
          lngEnd: l['lng'],
        );
      },
      r.rescheduleDate != null ? 'ນັດສົ່ງໃໝ່ແລ້ວ' : 'ຍົກເລີກບິນແລ້ວ',
      optimisticUpdate: () => _applyLocalBillUpdate(
        b.billNo,
        (bill) => bill.copyWith(
          phase: 'cancel',
          status: 2,
          statusText: 'ຍົກເລີກຈັດສົ່ງ',
        ),
      ),
    );
  }

  // Floating "Scan ສຳເລັດ": scan any delivery-point QR, find the matching bill
  // in this trip, verify the driver is within 50 m of the point, then run the
  // same complete flow as method 1 (check-in + ສຳເລັດ).
  Future<void> _scanCompleteAnyBill() async {
    HapticFeedback.selectionClick();
    final r = await Navigator.of(context).push<QrFindResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const QrFindScreen(),
      ),
    );
    if (r == null || !mounted) return;
    void snack(String m) => ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(m)));

    final pos = r.pos;
    if (pos == null) {
      snack(r.gpsError ?? 'ບໍ່ສາມາດອ່ານ GPS — ລອງໃໝ່');
      return;
    }
    final dist = Geolocator.distanceBetween(
      pos.latitude,
      pos.longitude,
      r.lat,
      r.lng,
    );
    if (dist > 50) {
      snack('ໄກຈຸດສົ່ງ ${dist.round()}m (ເກີນ 50m) — ບໍ່ສາມາດສຳເລັດ');
      return;
    }
    final target = r.billNo.isEmpty
        ? null
        : _bills.where((b) => b.billNo == r.billNo).firstOrNull;
    if (target == null) {
      snack(
        r.billNo.isEmpty
            ? 'QR ບໍ່ມີເລກບິນ'
            : 'ບໍ່ພົບບິນ ${r.billNo} ໃນຖ້ຽວນີ້',
      );
      return;
    }
    if (target.isFinished || !(target.canComplete || target.phase == 'pickup')) {
      snack('ບິນ ${target.billNo} ສຳເລັດແລ້ວ ຫຼື ຍັງບໍ່ພ້ອມ');
      return;
    }
    snack('✓ ${target.billNo} ໃກ້ຈຸດ ${dist.round()}m — ກຳລັງສຳເລັດ');
    await _checkInBill(target);
  }

  Future<void> _editBill(DeliveryBill b) async {
    final result = await Navigator.of(context).push<_EditResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _EditBillPage(api: widget.controller.api, bill: b),
      ),
    );
    if (result == null) return;
    await _runAction(
      () => widget.controller.api.editCompleteBill(
        billNo: b.billNo,
        items: result.items,
        deliveryImages: result.newImages,
        signatureImage: result.newSignature,
        comment: result.newComment,
      ),
      'ບັນທຶກການແກ້ໄຂແລ້ວ',
    );
  }

  Future<void> _revertCompleteBill(DeliveryBill b) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ຍົກເລີກສຳເລັດ'),
        content: Text(
          'ຍົກເລີກການຈັດສົ່ງສຳເລັດຂອງບິນ ${b.billNo}?\n'
          'ຮູບ, ລາຍເຊັນ, ແລະ ຈຳນວນສົ່ງຈະຖືກລຶບ — ຫຼັງຈາກນັ້ນ ກົດ "ສຳເລັດ" ໃໝ່ ເພື່ອບັນທຶກຮູບ ແລະ location ໃໝ່.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('ຍ້ອນກັບ'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('ຢືນຢັນ'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await _runAction(
      () => widget.controller.api.revertCompleteBill(billNo: b.billNo),
      'ຍົກເລີກສຳເລັດແລ້ວ — ກົດ "ສຳເລັດ" ເພື່ອບັນທຶກໃໝ່',
      optimisticUpdate: () => _applyLocalBillUpdate(
        b.billNo,
        // Server clears sent_end + images and resets status=0 while keeping
        // sent_start, so the bill drops back to phase=inprogress (the driver
        // is still mid-delivery, just needs to re-capture).
        (bill) => bill.copyWith(
          phase: 'inprogress',
          status: 0,
          statusText: 'ກຳລັງຈັດສົ່ງ',
        ),
      ),
    );
  }

  Future<void> _closeJob() async {
    final r = await showModalBottomSheet<_CloseJobResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _CloseJobSheet(),
    );
    if (r == null) return;
    setState(() => _busy = true);
    final outboxBefore = OfflineOutbox.instance.pendingCount;
    try {
      final l = await _getLocation();
      await widget.controller.api.completeJob(
        docNo: _job.docNo,
        carCode: _job.carCode,
        milesEnd: r.miles,
        imageDataUri: r.img,
        lat: l['lat'],
        lng: l['lng'],
      );
      if (!mounted) return;
      final wasQueued = OfflineOutbox.instance.pendingCount > outboxBefore;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            wasQueued ? 'ປິດງານໄວ້ — ຈະສົ່ງເມື່ອມີເນັດ' : 'ປິດງານແລ້ວ',
          ),
          backgroundColor: wasQueued ? AppTheme.warning : null,
        ),
      );
      Navigator.of(context).popUntil((route) => route.isFirst);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Color _phaseColor(String phase) => switch (phase) {
    'done' => AppTheme.success,
    'cancel' => AppTheme.error,
    'inprogress' => AppTheme.info,
    'pickup' => AppTheme.info,
    'waiting' => AppTheme.warning,
    _ => AppTheme.warning,
  };

  IconData _phaseIcon(String phase) => switch (phase) {
    'done' => Icons.check_circle_rounded,
    'cancel' => Icons.cancel_rounded,
    'inprogress' => Icons.local_shipping_rounded,
    'pickup' => Icons.inventory_2_rounded,
    'waiting' => Icons.schedule_rounded,
    _ => Icons.circle_rounded,
  };

  Color get _statusColor => switch (_job.jobStatus) {
    0 => AppTheme.warning,
    1 => AppTheme.primary,
    2 => AppTheme.info,
    3 => AppTheme.success,
    _ => AppTheme.textMuted,
  };

  IconData get _statusIcon => switch (_job.jobStatus) {
    0 => Icons.schedule_send_rounded,
    1 => Icons.inventory_2_rounded,
    2 => Icons.local_shipping_rounded,
    >= 3 => Icons.verified_rounded,
    _ => Icons.circle_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final sc = _statusColor;

    return Stack(
      children: [
        _buildScaffold(sc),
        if (_busy) const Positioned.fill(child: _BusyOverlay()),
      ],
    );
  }

  Widget _buildScaffold(Color sc) {
    return Scaffold(
      backgroundColor: AppTheme.bgDark,
      // Floating "Scan ສຳເລັດ": scan a delivery-point QR to find + complete the
      // matching bill (within 50 m) without opening each bill. Shown while the
      // trip is being delivered and there is still a deliverable bill.
      floatingActionButton:
          (!widget.readOnly &&
              widget.controller.settings.qrScanVerifyEnabled &&
              _job.jobStatus >= 1 &&
              _job.jobStatus < 3 &&
              _bills.any((b) => b.canComplete || b.phase == 'pickup'))
          ? FloatingActionButton.extended(
              onPressed: _busy ? null : _scanCompleteAnyBill,
              backgroundColor: AppTheme.primary,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.qr_code_scanner_rounded),
              label: const Text('Scan ສຳເລັດ'),
            )
          : null,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(56),
        child: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          systemOverlayStyle: SystemUiOverlayStyle.light,
          leading: Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 0, 6),
            child: Material(
              color: AppTheme.bgSurface.withValues(alpha: 0.85),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: AppTheme.surfaceBorder),
              ),
              child: InkWell(
                onTap: () => Navigator.pop(context),
                borderRadius: BorderRadius.circular(12),
                child: const Icon(
                  Icons.arrow_back_rounded,
                  size: 20,
                  color: AppTheme.textBright,
                ),
              ),
            ),
          ),
          title: const Text(
            'ລາຍລະອຽດຖ້ຽວ',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w900,
              color: AppTheme.textBright,
            ),
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 6, 12, 6),
              child: Material(
                color: AppTheme.bgSurface.withValues(alpha: 0.85),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: AppTheme.surfaceBorder),
                ),
                child: InkWell(
                  onTap: _loading ? null : _loadData,
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    width: 40,
                    height: 40,
                    child: _loading
                        ? const Center(
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppTheme.primary,
                              ),
                            ),
                          )
                        : const Icon(
                            Icons.refresh_rounded,
                            size: 20,
                            color: AppTheme.textBright,
                          ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primary),
            )
          : Column(
              children: [
                const GpsTrackingBanner(),
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _loadData,
                    color: AppTheme.primary,
                    backgroundColor: AppTheme.bgCard,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(12, 2, 12, 18),
                      children: [
                        // ── Hero header (gradient with status color) ──
                        _HeroJobHeader(job: _job, color: sc, icon: _statusIcon),
                        const SizedBox(height: 10),
                        if (_lastLoadUsedCache) ...[
                          _cacheBanner(),
                          const SizedBox(height: 10),
                        ],
                        _tripTimelineCard(),
                        const SizedBox(height: 10),

                        // ── Progress Steps ──
                        _card(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'ຄວາມຄືບໜ້າ',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.textBright,
                                ),
                              ),
                              const SizedBox(height: 10),
                              _buildSteps(),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),

                        // ── Bills Header ──
                        Row(
                          children: [
                            const Text(
                              'ລາຍການບິນ',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: AppTheme.textBright,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: AppTheme.primary.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                '${_bills.length}',
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.primary,
                                ),
                              ),
                            ),
                            const Spacer(),
                            // Route view — only useful once dispatching and with
                            // ≥1 unfinished bill that has a coordinate.
                            if (_job.jobStatus == 2 &&
                                _bills.any(
                                  (b) => !b.isFinished && _hasLocation(b),
                                ))
                              TextButton.icon(
                                onPressed: _openRoute,
                                icon: const Icon(Icons.route_rounded, size: 16),
                                label: const Text(
                                  'ເສັ້ນທາງ',
                                  style: TextStyle(fontSize: 12),
                                ),
                                style: TextButton.styleFrom(
                                  foregroundColor: AppTheme.primary,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                  ),
                                  minimumSize: const Size(0, 32),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),

                        // ── Bills List (grouped by pickup point) ──
                        for (final entry in _billsByPickup().entries) ...[
                          _buildPickupSectionHeader(entry.key, entry.value),
                          for (final bill in entry.value) _buildBillCard(bill),
                        ],
                      ],
                    ),
                  ),
                ),

                // ── Bottom Action ──
                if (!widget.readOnly)
                  _buildBottom()
                else if (_job.pendingApproval &&
                    widget.controller.user?.canApproveJobs == true)
                  _buildSupervisorApprovalBottom(),
              ],
            ),
    );
  }

  // ── Glass Card wrapper ──
  Widget _card({required Widget child}) => Container(
    padding: const EdgeInsets.all(10),
    decoration: BoxDecoration(
      color: AppTheme.bgSurface,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: AppTheme.surfaceBorder),
      boxShadow: AppTheme.shadowSm,
    ),
    child: child,
  );

  String _cleanText(String value) {
    final text = value.trim();
    if (text.isEmpty || text == '-') return '';
    return text;
  }

  String _formatCacheTime(DateTime? value) {
    if (value == null) return 'ບໍ່ຮູ້ເວລາ';
    final local = value.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.day)}/${two(local.month)}/${local.year} ${two(local.hour)}:${two(local.minute)}';
  }

  Widget _cacheBanner() {
    final jobsAt = _formatCacheTime(_jobsCacheAt);
    final billsAt = _formatCacheTime(_billsCacheAt);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppTheme.warning.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.cloud_off_rounded,
            color: AppTheme.warning,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'ກຳລັງສະແດງຂໍ້ມູນຈາກ cache',
                  style: TextStyle(
                    color: AppTheme.textBright,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  'Jobs: $jobsAt · Bills: $billsAt',
                  style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: _loading ? null : _loadData,
            style: TextButton.styleFrom(
              foregroundColor: AppTheme.warning,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 30),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('ອັບເດດ'),
          ),
        ],
      ),
    );
  }

  List<({String label, String detail, String time, IconData icon, Color color})>
  _timelineRows() {
    final waiting = _bills.where((b) => b.phase == 'waiting').length;
    final pickup = _bills.where((b) => b.phase == 'pickup').length;
    final inprogress = _bills.where((b) => b.phase == 'inprogress').length;
    final done = _bills.where((b) => b.phase == 'done').length;
    final cancel = _bills.where((b) => b.phase == 'cancel').length;
    final rows =
        <
          ({
            String label,
            String detail,
            String time,
            IconData icon,
            Color color,
          })
        >[
          (
            label: _job.pendingApproval ? 'ລໍຖ້າອະນຸມັດ' : 'ຖ້ຽວຖືກອະນຸມັດ',
            detail: '${_job.itemBill} ບິນ · ${_job.car}',
            time: _cleanText(_job.dateLogistic).isNotEmpty
                ? _cleanText(_job.dateLogistic)
                : _cleanText(_job.docDate),
            icon: _job.pendingApproval
                ? Icons.pending_actions_rounded
                : Icons.verified_user_rounded,
            color: _job.pendingApproval ? AppTheme.warning : AppTheme.success,
          ),
        ];

    if (_job.jobStatus >= 1) {
      rows.add((
        label: 'ຮັບຖ້ຽວແລ້ວ',
        detail: _job.driver,
        time: _cleanText(_job.receivedAt),
        icon: Icons.inventory_2_rounded,
        color: AppTheme.primary,
      ));
    }
    if (_job.jobStatus >= 2) {
      rows.add((
        label: 'ເລີ່ມຈັດສົ່ງ',
        detail: _cleanText(_job.milesStart).isNotEmpty
            ? 'Mile ${_cleanText(_job.milesStart)}'
            : 'ກຳລັງອອກສົ່ງ',
        time: _cleanText(_job.dispatchStartedAt),
        icon: Icons.local_shipping_rounded,
        color: AppTheme.info,
      ));
    }

    rows.add((
      label: 'ສະຖານະບິນ',
      detail:
          'ລໍ $waiting · ເບີກ $pickup · ກຳລັງ $inprogress · ສຳເລັດ $done · ຍົກເລີກ $cancel',
      time: '',
      icon: Icons.receipt_long_rounded,
      color: AppTheme.textMuted,
    ));

    if (_job.jobStatus >= 3) {
      rows.add((
        label: 'ປິດຖ້ຽວ',
        detail: _cleanText(_job.milesEnd).isNotEmpty
            ? 'Mile ${_cleanText(_job.milesEnd)}'
            : _job.statusText,
        time: '',
        icon: Icons.flag_circle_rounded,
        color: AppTheme.success,
      ));
    }
    return rows;
  }

  Widget _tripTimelineCard() {
    final rows = _timelineRows();
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.timeline_rounded, color: AppTheme.primary, size: 16),
              SizedBox(width: 7),
              Text(
                'Timeline ຖ້ຽວ',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.textBright,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (final row in rows.indexed)
            _TimelineRow(
              label: row.$2.label,
              detail: row.$2.detail,
              time: row.$2.time,
              icon: row.$2.icon,
              color: row.$2.color,
              isLast: row.$1 == rows.length - 1,
            ),
        ],
      ),
    );
  }

  // ── Steps ──
  Widget _buildSteps() {
    const data = [
      (label: 'ລໍຖ້າ', icon: Icons.schedule_rounded, status: 0),
      (label: 'ຮັບຖ້ຽວ', icon: Icons.check_circle_rounded, status: 1),
      (label: 'ກຳລັງສົ່ງ', icon: Icons.local_shipping_rounded, status: 2),
      (label: 'ປິດງານ', icon: Icons.verified_rounded, status: 3),
    ];

    return Row(
      children: data.indexed.expand((e) {
        final (i, s) = e;
        final active = _job.jobStatus >= s.status;
        final current = _job.jobStatus == s.status;
        final c = active
            ? (current ? AppTheme.primary : AppTheme.success)
            : AppTheme.surfaceBorder;

        final step = Expanded(
          child: Column(
            children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: active
                      ? c.withValues(alpha: 0.15)
                      : AppTheme.bgSurface.withValues(alpha: 0.3),
                  shape: BoxShape.circle,
                  border: Border.all(color: c, width: current ? 2.5 : 1),
                ),
                child: Icon(
                  s.icon,
                  size: 14,
                  color: active ? c : AppTheme.textMuted,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                s.label,
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: current ? FontWeight.w700 : FontWeight.w500,
                  color: active ? AppTheme.textBright : AppTheme.textMuted,
                ),
              ),
            ],
          ),
        );

        if (i < data.length - 1) {
          final lineActive = _job.jobStatus > s.status;
          return [
            step,
            Expanded(
              child: Container(
                height: 2,
                margin: const EdgeInsets.only(bottom: 17),
                color: lineActive ? AppTheme.success : AppTheme.surfaceBorder,
              ),
            ),
          ];
        }
        return [step];
      }).toList(),
    );
  }

  // ── Bill Card ──
  // True when another bill in this job is already checked in (sent_start set,
  // not yet completed/cancelled). The backend enforces "one active checkin
  // per job" — mirroring the rule here lets us grey out the Check-in button
  // immediately, before the user wastes a tap on a guaranteed error.
  bool _hasOtherActiveCheckin(DeliveryBill current) {
    return _bills.any(
      (b) => b.billNo != current.billNo && b.phase == 'inprogress',
    );
  }

  // Prominent "ຮັບຂອງ → ປາຍທາງ" strip inside each bill card. Replaces the old
  // small grey "ຮັບ:" / "ສົ່ງ:" lines so the driver sees where to collect and
  // where to deliver at a glance — the two facts they most need per bill.
  Widget _routeStrip(DeliveryBill bill) {
    final pickup = bill.pickupTransportName.trim();
    final isCustomerPickup = bill.pickupTransportCode == '__CUSTOMER__';
    // Fall back to the customer name when no explicit destination text — that's
    // still "where it's going" for the driver.
    final dest = bill.destination.trim().isNotEmpty
        ? bill.destination.trim()
        : bill.custName.trim();
    if (pickup.isEmpty && dest.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(top: 7),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.20)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (pickup.isNotEmpty)
            _routeEndpoint(
              icon: isCustomerPickup
                  ? Icons.home_rounded
                  : Icons.warehouse_rounded,
              label: 'ຮັບຂອງ',
              value: pickup,
              color: AppTheme.info,
            ),
          if (pickup.isNotEmpty && dest.isNotEmpty)
            const Padding(
              padding: EdgeInsets.only(left: 5, top: 1, bottom: 1),
              child: Icon(
                Icons.south_rounded,
                size: 13,
                color: AppTheme.textMuted,
              ),
            ),
          if (dest.isNotEmpty)
            _routeEndpoint(
              icon: Icons.location_on_rounded,
              label: 'ປາຍທາງ',
              value: dest,
              color: AppTheme.success,
            ),
        ],
      ),
    );
  }

  Widget _routeEndpoint({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 19,
          height: 19,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(icon, size: 12, color: color),
        ),
        const SizedBox(width: 6),
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Text(
            '$label: ',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                color: AppTheme.textBright,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBillCard(DeliveryBill bill) {
    final isWaiting = _job.jobStatus == 0;
    final phase = isWaiting ? 'waiting' : bill.phase;
    final statusText = isWaiting ? 'ລໍຖ້າຈັດສົ່ງ' : bill.statusText;
    final c = _phaseColor(phase);
    final ic = _phaseIcon(phase);
    final open = _expandedBillNo == bill.billNo;
    final hasMap = _hasLocation(bill);
    final blockedByActive = _hasOtherActiveCheckin(bill);
    final hasPhone = _hasPhone(bill);
    final isCustomerPickupBill = bill.pickupTransportCode == '__CUSTOMER__';
    final hasContactActions = hasMap || hasPhone;
    final hasWorkflowActions =
        !widget.readOnly &&
        ((bill.canPickup && _job.jobStatus == 1) ||
            // Customer-pickup "ຮັບສິນຄ້າ" entry point — available whenever the bill
            // is still waiting and the trip is open (driver collects en route).
            (bill.canPickup && _job.jobStatus < 3 && isCustomerPickupBill) ||
            (_job.jobStatus >= 2 &&
                bill.phase == 'pickup' &&
                !bill.isFinished) ||
            bill.canComplete ||
            bill.canCancel);
    final hasActions = hasContactActions || hasWorkflowActions;

    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.bgSurface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: open ? c.withValues(alpha: 0.3) : AppTheme.surfaceBorder,
          ),
        ),
        child: Column(
          children: [
            InkWell(
              onTap: () => _toggleItems(bill.billNo),
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
                child: Row(
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: c.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Icon(ic, size: 15, color: c),
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  bill.billNo,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    color: AppTheme.textBright,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (bill.parentBillNo.isNotEmpty) ...[
                                const SizedBox(width: 6),
                                _ParentBillChip(
                                  parentBillNo: bill.parentBillNo,
                                  siblingCount: _bills
                                      .where(
                                        (x) =>
                                            x.parentBillNo == bill.parentBillNo,
                                      )
                                      .length,
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            bill.custName,
                            style: const TextStyle(
                              fontSize: 10,
                              color: AppTheme.textMuted,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          // Prominent ຮັບຂອງ → ປາຍທາງ strip (replaces the old
                          // small grey "ຮັບ:" / "ສົ່ງ:" lines).
                          _routeStrip(bill),
                          // Delivery type pill: forwardTransportCode empty
                          // means delivered to the customer; otherwise the
                          // bill is being forwarded to a sister branch.
                          const SizedBox(height: 4),
                          _DeliveryTypePill(
                            forwardCode: bill.forwardTransportCode,
                            forwardName: bill.forwardTransportName,
                          ),
                          // Proof-of-pickup captured at the customer's yard —
                          // tap to re-view the photo + signature.
                          if (bill.hasReciptImg || bill.hasReciptSignImg) ...[
                            const SizedBox(height: 4),
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => _viewPickupProof(bill),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.inventory_2_rounded,
                                    size: 11,
                                    color: AppTheme.success,
                                  ),
                                  const SizedBox(width: 3),
                                  Flexible(
                                    child: Text(
                                      bill.hasReciptImg && bill.hasReciptSignImg
                                          ? 'ຮັບເຄື່ອງຈາກລານ: ຮູບ + ລາຍເຊັນ'
                                          : bill.hasReciptImg
                                          ? 'ຮັບເຄື່ອງຈາກລານ: ຮູບ'
                                          : 'ຮັບເຄື່ອງຈາກລານ: ລາຍເຊັນ',
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: AppTheme.success,
                                        fontWeight: FontWeight.w600,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  const Icon(
                                    Icons.visibility_rounded,
                                    size: 12,
                                    color: AppTheme.success,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: c.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: c.withValues(alpha: 0.15)),
                      ),
                      child: Text(
                        statusText,
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          color: c,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    AnimatedRotation(
                      turns: open ? 0.5 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: const Icon(
                        Icons.expand_more_rounded,
                        size: 18,
                        color: AppTheme.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // expanded items
            if (open) ...[
              Container(
                height: 1,
                margin: const EdgeInsets.symmetric(horizontal: 12),
                color: AppTheme.surfaceBorder,
              ),
              if (_loadingItems)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppTheme.primary,
                      ),
                    ),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_expandedItems.isEmpty)
                        const Center(
                          child: Padding(
                            padding: EdgeInsets.all(8),
                            child: Text(
                              'ບໍ່ມີລາຍການ',
                              style: TextStyle(
                                color: AppTheme.textMuted,
                                fontSize: 11,
                              ),
                            ),
                          ),
                        )
                      else
                        for (final item in _expandedItems)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Row(
                              children: [
                                Icon(
                                  item.remainingQty <= 0
                                      ? Icons.check_circle_rounded
                                      : Icons.radio_button_unchecked_rounded,
                                  size: 14,
                                  color: item.remainingQty <= 0
                                      ? AppTheme.success
                                      : AppTheme.textMuted,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    item.itemName.isNotEmpty
                                        ? item.itemName
                                        : item.itemCode,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      color: AppTheme.textPrimary,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Text(
                                  '${item.selectedQty} ${item.unitCode}',
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                    color: item.remainingQty <= 0
                                        ? AppTheme.success
                                        : AppTheme.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                    ],
                  ),
                ),
            ],

            // actions
            if (hasActions) ...[
              Container(
                height: 1,
                margin: const EdgeInsets.symmetric(horizontal: 12),
                color: AppTheme.surfaceBorder,
              ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Builder(
                  builder: (_) {
                    final contacts = <Widget>[
                      if (hasMap)
                        _contactBtn(
                          'ແຜນທີ່',
                          Icons.map_rounded,
                          AppTheme.primary,
                          () => _openMap(bill),
                        ),
                      if (hasPhone)
                        _contactBtn(
                          'ໂທ',
                          Icons.phone_rounded,
                          AppTheme.info,
                          () => _callPhone(bill),
                        ),
                      if (hasPhone)
                        _contactBtn(
                          'WhatsApp',
                          Icons.chat_rounded,
                          AppTheme.success,
                          () => _openWhatsApp(bill),
                        ),
                    ];
                    final workflow = <Widget>[
                      // Warehouse pickup — a plain tap (no photo). Allowed any
                      // time before the trip closes: pickup_bill auto-receives
                      // the trip when jobStatus=0, and a single trip may pick up
                      // at a second warehouse after start_dispatch too. Hidden
                      // for customer-pickup bills, which use the dedicated
                      // "ຮັບສິນຄ້າ" button below instead.
                      if (!widget.readOnly &&
                          bill.canPickup &&
                          _job.jobStatus < 3 &&
                          !isCustomerPickupBill)
                        _actBtn(
                          'ເບີກ',
                          Icons.inventory_2_rounded,
                          AppTheme.info,
                          _busy ? null : () => _pickupBill(bill),
                        ),
                      // Customer pickup — driver goes to the customer's yard to
                      // collect goods. Needs proof (GPS check-in + photo +
                      // customer signature), unlike the plain warehouse tap, so
                      // it routes through _receiveFromCustomer. After this the
                      // bill is in "pickup" phase and the Check in / ສຳເລັດ
                      // buttons below take over for the delivery leg.
                      if (!widget.readOnly &&
                          bill.canPickup &&
                          _job.jobStatus < 3 &&
                          isCustomerPickupBill)
                        _actBtn(
                          'ຮັບສິນຄ້າ (ລານລູກຄ້າ)',
                          Icons.home_work_rounded,
                          AppTheme.warning,
                          _busy ? null : () => _receiveFromCustomer(bill),
                        ),
                      if (!widget.readOnly &&
                          _job.jobStatus >= 1 &&
                          _job.jobStatus < 3 &&
                          bill.phase == 'pickup' &&
                          !bill.isFinished)
                        Tooltip(
                          message: blockedByActive
                              ? 'ສຳເລັດ ຫຼື ຍົກເລີກບິນທີ່ checkin ແລ້ວກ່ອນ'
                              : '',
                          child: _actBtn(
                            'ສຳເລັດ',
                            Icons.check_circle_rounded,
                            AppTheme.success,
                            _busy || blockedByActive
                                ? null
                                : () => _checkInBill(bill),
                          ),
                        ),
                      // (QR scan moved to the floating "Scan ສຳເລັດ" button —
                      // one scanner finds + completes the matching bill within
                      // 50 m, instead of a per-bill scan button.)
                      // Only shown once the bill is checked in (canComplete) —
                      // e.g. to retry/finish a complete that was cancelled after
                      // check-in. During the "pickup" phase the single "Check in"
                      // button above already runs check-in → item-select → ສຳເລັດ
                      // in one flow, so no separate ສຳເລັດ button is shown there.
                      if (!widget.readOnly && bill.canComplete)
                        _actBtn(
                          'ສຳເລັດ',
                          Icons.check_circle_rounded,
                          AppTheme.success,
                          _busy ? null : () => _completeBill(bill),
                        ),
                      if (!widget.readOnly && bill.canCancel)
                        _actBtn(
                          'ຍົກເລີກ',
                          Icons.cancel_rounded,
                          AppTheme.error,
                          _busy ? null : () => _cancelBill(bill),
                        ),
                      // Edit a completed delivery in-place: change qty,
                      // photos, signature, remark without resetting status.
                      // GPS coordinates are preserved on the server.
                      if (!widget.readOnly &&
                          bill.canEdit &&
                          _job.jobStatus < 3)
                        _actBtn(
                          'ແກ້ໄຂ',
                          Icons.edit_rounded,
                          AppTheme.info,
                          _busy ? null : () => _editBill(bill),
                        ),
                      // Roll back a completed delivery so the driver can
                      // retake the photo + location. Blocked once the trip
                      // is closed (jobStatus >= 3).
                      if (!widget.readOnly &&
                          bill.canRevertComplete &&
                          _job.jobStatus < 3)
                        _actBtn(
                          'ຍົກເລີກສຳເລັດ',
                          Icons.undo_rounded,
                          AppTheme.warning,
                          _busy ? null : () => _revertCompleteBill(bill),
                        ),
                    ];

                    Widget? workflowBlock;
                    if (workflow.isNotEmpty) {
                      if (workflow.length == 1) {
                        workflowBlock = workflow[0];
                      } else if (workflow.length == 2) {
                        workflowBlock = Row(
                          spacing: 8,
                          children: [
                            Expanded(child: workflow[0]),
                            Expanded(child: workflow[1]),
                          ],
                        );
                      } else {
                        workflowBlock = Column(spacing: 6, children: workflow);
                      }
                    }

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (contacts.isNotEmpty)
                          Row(
                            children: [
                              for (var i = 0; i < contacts.length; i++) ...[
                                Expanded(child: contacts[i]),
                                if (i < contacts.length - 1)
                                  const SizedBox(width: 8),
                              ],
                            ],
                          ),
                        if (contacts.isNotEmpty && workflowBlock != null)
                          const SizedBox(height: 10),
                        if (workflowBlock != null) workflowBlock,
                      ],
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _contactBtn(
    String label,
    IconData icon,
    Color c,
    VoidCallback? onPressed,
  ) {
    return Material(
      color: c.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(9),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(9),
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: c.withValues(alpha: 0.35), width: 1),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 15, color: c),
              const SizedBox(height: 3),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: c,
                  height: 1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _actBtn(
    String label,
    IconData icon,
    Color c,
    VoidCallback? onPressed,
  ) {
    return SizedBox(
      height: 36,
      child: FilledButton.icon(
        onPressed: onPressed,
        icon: Icon(icon, size: 14),
        label: Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            height: 1,
          ),
        ),
        style: FilledButton.styleFrom(
          backgroundColor: c,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(36),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        ),
      ),
    );
  }

  Widget _buildPendingApprovalBanner() {
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: AppTheme.warning.withValues(alpha: 0.12),
          border: Border.all(color: AppTheme.warning.withValues(alpha: 0.4)),
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        ),
        child: Row(
          children: [
            const Icon(
              Icons.hourglass_top_rounded,
              color: AppTheme.warning,
              size: 22,
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'ລໍຖ້າອະນຸມັດ',
                    style: TextStyle(
                      color: AppTheme.textBright,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    'ສາມາດເບິ່ງລາຍລະອຽດໄດ້ຢ່າງດຽວ',
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSupervisorApprovalBottom() {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 14),
        decoration: const BoxDecoration(
          color: AppTheme.bgDark,
          border: Border(top: BorderSide(color: AppTheme.surfaceBorder)),
        ),
        child: SizedBox(
          width: double.infinity,
          height: 48,
          child: FilledButton.icon(
            onPressed: _busy ? null : _approveAsSupervisor,
            style: FilledButton.styleFrom(backgroundColor: AppTheme.success),
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.approval_rounded, size: 18),
            label: Text(
              _busy ? 'ກຳລັງອະນຸມັດ...' : 'ອະນຸມັດຖ້ຽວນີ້',
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
        ),
      ),
    );
  }

  // ── Bottom Bar ──
  Widget _buildBottom() {
    if (_job.jobStatus >= 3) return const SizedBox.shrink();
    if (_job.pendingApproval) return _buildPendingApprovalBanner();

    final hasPendingBills = _bills.any((b) => !b.isFinished);
    // Customer-pickup bills don't go through the explicit pickup step — the
    // checkin will set recipt_job for them automatically. So the "ເບີກທັງໝົດ"
    // shortcut should only count bills picked up from a warehouse.
    final unpickedFromWarehouse = _bills
        .where((b) => b.canPickup && b.pickupTransportCode != '__CUSTOMER__')
        .toList();
    final hasUnpickedBills = unpickedFromWarehouse.isNotEmpty;

    final (
      String label,
      IconData icon,
      Color color,
      VoidCallback? action,
      String? hint,
    ) = switch (_job.jobStatus) {
      0 => (
        'ຮັບຖ້ຽວ',
        Icons.check_circle_rounded,
        AppTheme.primary,
        _busy ? null : _receiveJob,
        null,
      ),
      1 => (
        // Driver may dispatch before all bills are picked up — a single trip
        // can collect from multiple warehouses or pick up at the customer's
        // location after leaving, so we don't gate the button on pickup state.
        'ເລີ່ມຈັດສົ່ງ',
        Icons.play_arrow_rounded,
        AppTheme.primary,
        _busy ? null : _startDispatch,
        null,
      ),
      2 => (
        'ປິດງານ',
        Icons.task_alt_rounded,
        hasPendingBills ? AppTheme.textMuted : AppTheme.success,
        _busy || hasPendingBills ? null : _closeJob,
        hasPendingBills ? 'ຕ້ອງສຳເລັດ ຫຼື ຍົກເລີກບິນທັງໝົດກ່ອນ' : null,
      ),
      _ => ('', Icons.circle, AppTheme.textMuted, null, null),
    };

    if (label.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: EdgeInsets.fromLTRB(
        12,
        9,
        12,
        MediaQuery.of(context).padding.bottom + 9,
      ),
      decoration: const BoxDecoration(
        color: AppTheme.bgDark,
        border: Border(top: BorderSide(color: AppTheme.surfaceBorder)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hint != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                children: [
                  const Icon(
                    Icons.info_outline_rounded,
                    size: 14,
                    color: AppTheme.warning,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      hint,
                      style: const TextStyle(
                        fontSize: 10,
                        color: AppTheme.warning,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (_job.jobStatus < 2 && hasUnpickedBills) ...[
            FilledButton.icon(
              onPressed: _busy
                  ? null
                  : () {
                      HapticFeedback.mediumImpact();
                      _pickupBills(unpickedFromWarehouse, 'ທຸກສາງ');
                    },
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.inventory_2_rounded, size: 18),
              label: Text(
                _busy
                    ? 'ກຳລັງເບີກ...'
                    : 'ເບີກທຸກສາງ (${unpickedFromWarehouse.length} ບິນ)',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w900,
                ),
              ),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                backgroundColor: AppTheme.info,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
          FilledButton.icon(
            onPressed: action == null
                ? null
                : () {
                    HapticFeedback.mediumImpact();
                    action();
                  },
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Icon(icon, size: 20),
            label: Text(
              _busy ? 'ກຳລັງດຳເນີນ...' : label,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900),
            ),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              backgroundColor: color,
              foregroundColor: Colors.white,
              elevation: action == null ? 0 : 2,
              shadowColor: color.withValues(alpha: 0.5),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MileResult {
  final String miles;
  final String? img;
  const _MileResult({required this.miles, this.img});
}

class _MileDialog extends StatefulWidget {
  final String title, desc, btn;
  final IconData icon;
  final Color color;
  const _MileDialog({
    required this.title,
    required this.desc,
    required this.btn,
    required this.icon,
    required this.color,
  });
  @override
  State<_MileDialog> createState() => _MileDialogState();
}

class _MileDialogState extends State<_MileDialog> {
  final _c = TextEditingController();
  final _p = ImagePicker();
  bool _sub = false;
  String? _img;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final f = await _p.pickImage(
      source: ImageSource.camera,
      imageQuality: 55,
      maxWidth: 1280,
      maxHeight: 1280,
    );
    if (f == null) return;
    final b = await f.readAsBytes();
    final ext = f.name.toLowerCase().endsWith('.png') ? 'png' : 'jpeg';
    setState(() => _img = 'data:image/$ext;base64,${base64Encode(b)}');
  }

  void _remove() => setState(() => _img = null);

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF1E293B),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      ),
      child: Container(
        width: 340,
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: widget.color.withValues(alpha: 0.15),
                shape: BoxShape.circle,
                border: Border.all(color: widget.color, width: 2),
              ),
              child: Icon(widget.icon, size: 32, color: widget.color),
            ),
            const SizedBox(height: 16),
            Text(
              widget.title,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              widget.desc,
              style: const TextStyle(fontSize: 14, color: Color(0xFF94A3B8)),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _c,
              keyboardType: TextInputType.number,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
              decoration: InputDecoration(
                labelText: 'ເລກ mile',
                labelStyle: const TextStyle(color: Color(0xFF94A3B8)),
                hintText: '0',
                hintStyle: TextStyle(
                  color: const Color(0xFF64748B).withValues(alpha: 0.5),
                ),
                filled: true,
                fillColor: const Color(0xFF0F172A),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFF334155)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Color(0xFF334155)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: widget.color, width: 2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (_img == null)
              InkWell(
                onTap: _pick,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  height: 120,
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F172A),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: const Color(0xFF334155),
                      width: 2,
                    ),
                  ),
                  child: const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.camera_alt,
                        size: 40,
                        color: Color(0xFF64748B),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'ແຕະເພື່ອຖ່າຍຮູບ',
                        style: TextStyle(color: Color(0xFF64748B)),
                      ),
                    ],
                  ),
                ),
              )
            else
              Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.memory(
                      base64Decode(_img!.split(',').last),
                      height: 120,
                      width: double.infinity,
                      fit: BoxFit.cover,
                    ),
                  ),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: InkWell(
                      onTap: _remove,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(
                          color: Colors.black54,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.close,
                          size: 16,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 8,
                    left: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.success,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.check_circle,
                            size: 12,
                            color: Colors.white,
                          ),
                          SizedBox(width: 4),
                          Text(
                            'ຖ່າຍແລ້ວ',
                            style: TextStyle(fontSize: 11, color: Colors.white),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _sub ? null : () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      side: const BorderSide(color: Color(0xFF334155)),
                      foregroundColor: const Color(0xFF94A3B8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('ຍົກເລີກ'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    onPressed: _sub
                        ? null
                        : () {
                            final m = _c.text.trim();
                            if (m.isEmpty) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('ກະລຸນາປ້ອນເລກ mile'),
                                  backgroundColor: Color(0xFF1E293B),
                                ),
                              );
                              return;
                            }
                            if (_img == null) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('ກະລຸນາຖ່າຍຮູບ mile'),
                                  backgroundColor: Color(0xFF1E293B),
                                ),
                              );
                              return;
                            }
                            setState(() => _sub = true);
                            Navigator.pop(
                              context,
                              _MileResult(miles: m, img: _img),
                            );
                          },
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      backgroundColor: widget.color,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: _sub
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: Colors.white,
                            ),
                          )
                        : Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(widget.icon, size: 18),
                              const SizedBox(width: 6),
                              Text(widget.btn),
                            ],
                          ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StartDispatchResult {
  final String miles;
  final String? img;
  const _StartDispatchResult({required this.miles, this.img});
}

class _StartDispatchSheet extends StatefulWidget {
  const _StartDispatchSheet();
  @override
  State<_StartDispatchSheet> createState() => _StartDispatchSheetState();
}

class _StartDispatchSheetState extends State<_StartDispatchSheet> {
  final _c = TextEditingController();
  final _p = ImagePicker();
  int _step = 0; // 0=mile, 1=photo, 2=confirm
  bool _sub = false;
  String? _img;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _nextStep() {
    if (_step == 0) {
      if (_c.text.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('ກະລຸນາປ້ອນເລກ mile'),
            backgroundColor: AppTheme.bgCard,
          ),
        );
        return;
      }
      setState(() => _step = 1);
    } else if (_step == 1) {
      if (_img == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('ກະລຸນາຖ່າຍຮູບ mile'),
            backgroundColor: AppTheme.bgCard,
          ),
        );
        return;
      }
      setState(() => _step = 2);
    }
  }

  Future<void> _pick() async {
    final f = await _p.pickImage(
      source: ImageSource.camera,
      imageQuality: 55,
      maxWidth: 1280,
      maxHeight: 1280,
    );
    if (f == null) return;
    final b = await f.readAsBytes();
    final ext = f.name.toLowerCase().endsWith('.png') ? 'png' : 'jpeg';
    setState(() => _img = 'data:image/$ext;base64,${base64Encode(b)}');
  }

  Future<void> _submit() async {
    if (_sub) return;
    setState(() => _sub = true);
    // Yield a frame so the spinner state actually paints before the sheet
    // pops — without this, setState + Navigator.pop happen in one frame and
    // the user never sees feedback on the tap.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    if (!mounted) return;
    Navigator.pop(
      context,
      _StartDispatchResult(miles: _c.text.trim(), img: _img),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      margin: EdgeInsets.only(bottom: bottom),
      decoration: const BoxDecoration(
        color: AppTheme.bgMid,
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppTheme.radiusXl),
        ),
        border: Border(
          top: BorderSide(color: AppTheme.surfaceBorder),
          left: BorderSide(color: AppTheme.surfaceBorder),
          right: BorderSide(color: AppTheme.surfaceBorder),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // drag handle
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.surfaceBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),

              // ── Step indicator ──
              Row(
                children: List.generate(
                  3,
                  (i) => Expanded(
                    child: Container(
                      height: 3,
                      margin: EdgeInsets.only(right: i < 2 ? 6 : 0),
                      decoration: BoxDecoration(
                        color: i <= _step
                            ? AppTheme.primary
                            : AppTheme.surfaceBorder,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // ── Step Content ──
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: _step == 0
                    ? _buildStepMile()
                    : _step == 1
                    ? _buildStepPhoto()
                    : _buildStepConfirm(),
              ),

              const SizedBox(height: 20),

              // ── Buttons ──
              Row(
                children: [
                  if (_step > 0 && !_sub)
                    Expanded(
                      child: SizedBox(
                        height: 50,
                        child: OutlinedButton(
                          onPressed: () => setState(() => _step--),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(
                              color: AppTheme.surfaceBorder,
                            ),
                            foregroundColor: AppTheme.textSecondary,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: const Text(
                            'ກັບຄືນ',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                    )
                  else
                    Expanded(
                      child: SizedBox(
                        height: 50,
                        child: OutlinedButton(
                          onPressed: _sub ? null : () => Navigator.pop(context),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(
                              color: AppTheme.surfaceBorder,
                            ),
                            foregroundColor: AppTheme.textSecondary,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: const Text(
                            'ຍົກເລີກ',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: SizedBox(
                      height: 50,
                      child: FilledButton.icon(
                        onPressed: _sub
                            ? null
                            : (_step < 2 ? _nextStep : _submit),
                        icon: _sub
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : Icon(
                                _step < 2
                                    ? Icons.arrow_forward_rounded
                                    : Icons.play_arrow_rounded,
                                size: 20,
                              ),
                        label: Text(
                          _sub
                              ? 'ກຳລັງເລີ່ມ...'
                              : _step == 0
                              ? 'ຕໍ່ໄປ'
                              : _step == 1
                              ? 'ຕໍ່ໄປ'
                              : 'ເລີ່ມຈັດສົ່ງ',
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                            height: 1,
                          ),
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: _step == 2
                              ? AppTheme.primary
                              : AppTheme.info,
                          foregroundColor: _step == 2
                              ? AppTheme.bgDark
                              : Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Step 1: Mile ──
  Widget _buildStepMile() {
    return Column(
      key: const ValueKey('mile'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: AppTheme.info.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Icon(
            Icons.speed_rounded,
            color: AppTheme.info,
            size: 26,
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'ປ້ອນເລກ Mile ເລີ່ມ',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w800,
            color: AppTheme.textBright,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'ບັນທຶກເລກ mile ກ່ອນອອກສົ່ງ',
          style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
        ),
        const SizedBox(height: 20),
        Container(
          decoration: BoxDecoration(
            color: AppTheme.bgDark,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppTheme.surfaceBorder),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: _c,
            keyboardType: TextInputType.number,
            autofocus: true,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w900,
              color: AppTheme.textBright,
              letterSpacing: 2,
            ),
            decoration: const InputDecoration(
              hintText: '0',
              hintStyle: TextStyle(
                color: AppTheme.textMuted,
                fontSize: 32,
                fontWeight: FontWeight.w300,
              ),
              border: InputBorder.none,
              contentPadding: EdgeInsets.symmetric(vertical: 20),
            ),
          ),
        ),
      ],
    );
  }

  // ── Step 2: Photo ──
  Widget _buildStepPhoto() {
    return Column(
      key: const ValueKey('photo'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: AppTheme.warning.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(14),
          ),
          child: const Icon(
            Icons.camera_alt_rounded,
            color: AppTheme.warning,
            size: 26,
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'ຖ່າຍຮູບ Mile',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w800,
            color: AppTheme.textBright,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'ຖ່າຍຮູບໝ້ຽນ mile ເປັນຫຼັກຖານ',
          style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
        ),
        const SizedBox(height: 20),
        GestureDetector(
          onTap: _pick,
          child: Container(
            height: 160,
            width: double.infinity,
            decoration: BoxDecoration(
              color: AppTheme.bgDark,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppTheme.surfaceBorder),
            ),
            clipBehavior: Clip.antiAlias,
            child: _img == null
                ? const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.camera_alt_rounded,
                        size: 40,
                        color: AppTheme.textMuted,
                      ),
                      SizedBox(height: 10),
                      Text(
                        'ແຕະເພື່ອຖ່າຍຮູບ',
                        style: TextStyle(
                          fontSize: 13,
                          color: AppTheme.textSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  )
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.memory(
                        base64Decode(_img!.split(',').last),
                        fit: BoxFit.cover,
                      ),
                      Positioned(
                        top: 8,
                        right: 8,
                        child: GestureDetector(
                          onTap: () => setState(() => _img = null),
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.6),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.close_rounded,
                              size: 16,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                      const Positioned(
                        bottom: 10,
                        left: 10,
                        child: _PhotoBadge(),
                      ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  // ── Step 3: Confirm ──
  Widget _buildStepConfirm() {
    return Column(
      key: const ValueKey('confirm'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            gradient: AppTheme.accentGradient,
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Icon(
            Icons.play_arrow_rounded,
            size: 30,
            color: AppTheme.bgDark,
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'ພ້ອມເລີ່ມຈັດສົ່ງ?',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w800,
            color: AppTheme.textBright,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'ກວດສອບຂໍ້ມູນກ່ອນຢືນຢັນ',
          style: TextStyle(fontSize: 12, color: AppTheme.textMuted),
        ),
        const SizedBox(height: 20),

        // summary
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppTheme.bgDark,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppTheme.surfaceBorder),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppTheme.info.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.speed_rounded,
                      size: 18,
                      color: AppTheme.info,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Mile ເລີ່ມ',
                        style: TextStyle(
                          fontSize: 10,
                          color: AppTheme.textMuted,
                        ),
                      ),
                      Text(
                        _c.text.trim(),
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.textBright,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => setState(() => _step = 0),
                    child: const Text(
                      'ແກ້ໄຂ',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppTheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Container(height: 1, color: AppTheme.surfaceBorder),
              const SizedBox(height: 12),
              Row(
                children: [
                  if (_img != null)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.memory(
                        base64Decode(_img!.split(',').last),
                        width: 36,
                        height: 36,
                        fit: BoxFit.cover,
                      ),
                    )
                  else
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: AppTheme.warning.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(
                        Icons.camera_alt_rounded,
                        size: 18,
                        color: AppTheme.warning,
                      ),
                    ),
                  const SizedBox(width: 12),
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'ຮູບ Mile',
                        style: TextStyle(
                          fontSize: 10,
                          color: AppTheme.textMuted,
                        ),
                      ),
                      Text(
                        'ຖ່າຍແລ້ວ',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.success,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => setState(() => _step = 1),
                    child: const Text(
                      'ແກ້ໄຂ',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppTheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PhotoBadge extends StatelessWidget {
  const _PhotoBadge();
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: AppTheme.success,
      borderRadius: BorderRadius.circular(6),
    ),
    child: const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.check_circle_rounded, size: 12, color: Colors.white),
        SizedBox(width: 4),
        Text(
          'ຖ່າຍແລ້ວ',
          style: TextStyle(
            fontSize: 10,
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );
}

class _CloseJobResult {
  final String miles;
  final String? img;
  const _CloseJobResult({required this.miles, this.img});
}

class _CloseJobSheet extends StatefulWidget {
  const _CloseJobSheet();
  @override
  State<_CloseJobSheet> createState() => _CloseJobSheetState();
}

class _CloseJobSheetState extends State<_CloseJobSheet> {
  final _c = TextEditingController();
  final _p = ImagePicker();
  int _step = 0;
  bool _sub = false;
  String? _img;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _nextStep() {
    if (_step == 0) {
      if (_c.text.trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('ກະລຸນາປ້ອນເລກ mile'),
            backgroundColor: AppTheme.bgCard,
          ),
        );
        return;
      }
      setState(() => _step = 1);
      return;
    }

    if (_step == 1) {
      if (_img == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('ກະລຸນາຖ່າຍຮູບ mile'),
            backgroundColor: AppTheme.bgCard,
          ),
        );
        return;
      }
      setState(() => _step = 2);
    }
  }

  Future<void> _pick() async {
    final f = await _p.pickImage(
      source: ImageSource.camera,
      imageQuality: 55,
      maxWidth: 1280,
      maxHeight: 1280,
    );
    if (f == null) return;
    final b = await f.readAsBytes();
    final ext = f.name.toLowerCase().endsWith('.png') ? 'png' : 'jpeg';
    setState(() => _img = 'data:image/$ext;base64,${base64Encode(b)}');
  }

  void _remove() => setState(() => _img = null);

  Future<void> _submit() async {
    if (_sub) return;
    setState(() => _sub = true);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    if (!mounted) return;
    Navigator.pop(context, _CloseJobResult(miles: _c.text.trim(), img: _img));
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      margin: EdgeInsets.only(bottom: bottom),
      decoration: const BoxDecoration(
        color: AppTheme.bgMid,
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppTheme.radiusXl),
        ),
        border: Border(
          top: BorderSide(color: AppTheme.surfaceBorder),
          left: BorderSide(color: AppTheme.surfaceBorder),
          right: BorderSide(color: AppTheme.surfaceBorder),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.surfaceBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: List.generate(
                  3,
                  (i) => Expanded(
                    child: Container(
                      height: 3,
                      margin: EdgeInsets.only(right: i < 2 ? 6 : 0),
                      decoration: BoxDecoration(
                        color: i <= _step
                            ? AppTheme.success
                            : AppTheme.surfaceBorder,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: _step == 0
                    ? _buildStepMiles()
                    : _step == 1
                    ? _buildStepPhoto()
                    : _buildStepConfirm(),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 50,
                      child: OutlinedButton(
                        onPressed: _sub
                            ? null
                            : () {
                                if (_step > 0) {
                                  setState(() => _step--);
                                } else {
                                  Navigator.pop(context);
                                }
                              },
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: AppTheme.surfaceBorder),
                          foregroundColor: AppTheme.textSecondary,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: Text(
                          _step > 0 ? 'ກັບຄືນ' : 'ຍົກເລີກ',
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: SizedBox(
                      height: 50,
                      child: FilledButton.icon(
                        onPressed: _sub
                            ? null
                            : (_step < 2 ? _nextStep : _submit),
                        icon: _sub
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : Icon(
                                _step < 2
                                    ? Icons.arrow_forward_rounded
                                    : Icons.task_alt_rounded,
                                size: 20,
                              ),
                        label: Text(
                          _sub
                              ? 'ກຳລັງບັນທຶກ...'
                              : _step == 0
                              ? 'ຕໍ່ໄປ'
                              : _step == 1
                              ? 'ກວດສອບ'
                              : 'ຢືນຢັນປິດງານ',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: _step == 2 ? 14 : 15,
                            height: 1,
                          ),
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: _step == 2
                              ? AppTheme.success
                              : AppTheme.primary,
                          foregroundColor: _step == 2
                              ? Colors.white
                              : AppTheme.bgDark,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStepMiles() {
    return Column(
      key: const ValueKey('close-mile'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(
            color: AppTheme.success.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Icon(
            Icons.speed_rounded,
            color: AppTheme.success,
            size: 28,
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'ບັນທຶກ Mile ສຸດທ້າຍ',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w800,
            color: AppTheme.textBright,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'ປ້ອນເລກໄມລ໌ກ່ອນປິດງານເພື່ອສະຫຼຸບຖ້ຽວໃຫ້ຄົບ',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12,
            color: AppTheme.textMuted,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 20),
        Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: AppTheme.bgDark,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: AppTheme.surfaceBorder),
          ),
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(
                    Icons.route_rounded,
                    size: 16,
                    color: AppTheme.textMuted,
                  ),
                  SizedBox(width: 8),
                  Text(
                    'ເລກ mile ສຸດທ້າຍ',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textMuted,
                    ),
                  ),
                ],
              ),
              TextField(
                controller: _c,
                keyboardType: TextInputType.number,
                autofocus: true,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w900,
                  color: AppTheme.textBright,
                  letterSpacing: 1.2,
                ),
                decoration: const InputDecoration(
                  hintText: '0',
                  hintStyle: TextStyle(
                    color: AppTheme.textDim,
                    fontSize: 34,
                    fontWeight: FontWeight.w300,
                  ),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 18),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildStepPhoto() {
    return Column(
      key: const ValueKey('close-photo'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(
            color: AppTheme.primary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Icon(
            Icons.camera_alt_rounded,
            color: AppTheme.primary,
            size: 26,
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'ຖ່າຍຮູບໝ້ຽນ Mile',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w800,
            color: AppTheme.textBright,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'ໃຊ້ຮູບທີ່ເຫັນເລກຊັດເຈນ ເພື່ອເກັບເປັນຫຼັກຖານການປິດງານ',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12,
            color: AppTheme.textMuted,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 20),
        GestureDetector(
          onTap: _pick,
          child: Container(
            height: 174,
            width: double.infinity,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: AppTheme.bgDark,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: AppTheme.surfaceBorder),
            ),
            child: _img == null
                ? const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.add_a_photo_rounded,
                        size: 42,
                        color: AppTheme.textMuted,
                      ),
                      SizedBox(height: 12),
                      Text(
                        'ແຕະເພື່ອຖ່າຍຮູບ mile',
                        style: TextStyle(
                          fontSize: 13,
                          color: AppTheme.textSecondary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: 6),
                      Text(
                        'ຮູບນີ້ຈະຖືກໃຊ້ໃນການສະຫຼຸບປິດງານ',
                        style: TextStyle(fontSize: 11, color: AppTheme.textDim),
                      ),
                    ],
                  )
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.memory(
                        base64Decode(_img!.split(',').last),
                        fit: BoxFit.cover,
                      ),
                      Positioned(
                        top: 10,
                        right: 10,
                        child: GestureDetector(
                          onTap: _remove,
                          child: Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.58),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.close_rounded,
                              size: 16,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                      const Positioned(
                        bottom: 10,
                        left: 10,
                        child: _PhotoBadge(),
                      ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildStepConfirm() {
    return Column(
      key: const ValueKey('close-confirm'),
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: AppTheme.success,
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Icon(
            Icons.task_alt_rounded,
            size: 30,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'ພ້ອມປິດງານແລ້ວ?',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w800,
            color: AppTheme.textBright,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'ກວດສອບຂໍ້ມູນໃຫ້ຄົບກ່ອນບັນທຶກການສິ້ນສຸດຖ້ຽວ',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 12,
            color: AppTheme.textMuted,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 20),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppTheme.bgDark,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppTheme.surfaceBorder),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: AppTheme.info.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: const Icon(
                      Icons.speed_rounded,
                      size: 18,
                      color: AppTheme.info,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Mile ສຸດທ້າຍ',
                        style: TextStyle(
                          fontSize: 10,
                          color: AppTheme.textMuted,
                        ),
                      ),
                      Text(
                        _c.text.trim(),
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                          color: AppTheme.textBright,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => setState(() => _step = 0),
                    child: const Text(
                      'ແກ້ໄຂ',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppTheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Container(height: 1, color: AppTheme.surfaceBorder),
              const SizedBox(height: 12),
              Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.memory(
                      base64Decode(_img!.split(',').last),
                      width: 38,
                      height: 38,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'ຮູບຫຼັກຖານ',
                        style: TextStyle(
                          fontSize: 10,
                          color: AppTheme.textMuted,
                        ),
                      ),
                      Text(
                        'ຖ່າຍແລ້ວ',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.success,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () => setState(() => _step = 1),
                    child: const Text(
                      'ແກ້ໄຂ',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppTheme.primary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// Result of the cancel dialog: free-text comment + a standardized reason code
// (Module D) and an optional reschedule date (deferred delivery).
class _CancelResult {
  final String comment;
  final String? reasonCode;
  final String? rescheduleDate; // YYYY-MM-DD
  const _CancelResult({
    required this.comment,
    this.reasonCode,
    this.rescheduleDate,
  });
}

const List<({String code, String label})> _cancelReasons = [
  (code: 'customer_away', label: 'ລູກຄ້າບໍ່ຢູ່ບ້ານ'),
  (code: 'shop_closed', label: 'ຮ້ານປິດ'),
  (code: 'truck_left', label: 'ລົດອອກກ່ອນ'),
  (code: 'truck_full', label: 'ລົດເຕັມ'),
  (code: 'too_late', label: 'ສົ່ງບໍ່ທັນ'),
  (code: 'goods_issue', label: 'ເຄື່ອງມີບັນຫາ'),
  (code: 'other', label: 'ອື່ນໆ'),
];

class _CancelDialog extends StatefulWidget {
  final String billNo;
  const _CancelDialog({required this.billNo});

  @override
  State<_CancelDialog> createState() => _CancelDialogState();
}

class _CancelDialogState extends State<_CancelDialog> {
  final _commentCtrl = TextEditingController();
  String? _error;
  String? _reason;
  DateTime? _reschedule;

  @override
  void dispose() {
    _commentCtrl.dispose();
    super.dispose();
  }

  String _fmt(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _pickReschedule() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now.add(const Duration(days: 1)),
      firstDate: now,
      lastDate: now.add(const Duration(days: 60)),
    );
    if (picked != null) setState(() => _reschedule = picked);
  }

  void _confirm() {
    if (_reason == null) {
      setState(() => _error = 'ກະລຸນາເລືອກສາເຫດການຍົກເລີກ');
      return;
    }
    final text = _commentCtrl.text.trim();
    // Only "ອື່ນໆ" needs a typed explanation; the rest use the chip label.
    if (_reason == 'other' && text.isEmpty) {
      setState(() => _error = 'ກະລຸນາໃສ່ລາຍລະອຽດສຳລັບ "ອື່ນໆ"');
      return;
    }
    final label = _cancelReasons.firstWhere((r) => r.code == _reason).label;
    Navigator.pop(
      context,
      _CancelResult(
        comment: text.isEmpty ? label : text,
        reasonCode: _reason,
        rescheduleDate: _reschedule == null ? null : _fmt(_reschedule!),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.bgCard,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusXl),
        side: const BorderSide(color: AppTheme.surfaceBorder),
      ),
      title: const Row(
        children: [
          Icon(Icons.warning_rounded, color: AppTheme.error),
          SizedBox(width: 8),
          Text(
            'ຢືນຢັນຍົກເລີກ',
            style: TextStyle(color: AppTheme.textBright, fontSize: 18),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'ຍົກເລີກບິນ ${widget.billNo}',
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'ສາເຫດ',
              style: TextStyle(
                color: AppTheme.textBright,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final r in _cancelReasons)
                  ChoiceChip(
                    label: Text(r.label, style: const TextStyle(fontSize: 11)),
                    selected: _reason == r.code,
                    onSelected: (_) => setState(() => _reason = r.code),
                    backgroundColor: AppTheme.bgSurface,
                    selectedColor: AppTheme.error.withValues(alpha: 0.25),
                    labelStyle: TextStyle(
                      color: _reason == r.code
                          ? AppTheme.textBright
                          : AppTheme.textMuted,
                    ),
                    side: const BorderSide(color: AppTheme.surfaceBorder),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _commentCtrl,
              minLines: 2,
              maxLines: 5,
              style: const TextStyle(color: AppTheme.textBright, fontSize: 13),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              decoration: InputDecoration(
                hintText: _reason == 'other'
                    ? 'ລາຍລະອຽດ (ບັງຄັບ) *'
                    : 'ໝາຍເຫດເພີ່ມເຕີມ (ບໍ່ບັງຄັບ)',
                hintStyle: const TextStyle(
                  color: AppTheme.textMuted,
                  fontSize: 12,
                ),
                filled: true,
                fillColor: AppTheme.bgSurface,
                errorText: _error,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                  borderSide: const BorderSide(color: AppTheme.surfaceBorder),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                  borderSide: const BorderSide(color: AppTheme.surfaceBorder),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                  borderSide: const BorderSide(
                    color: AppTheme.error,
                    width: 1.5,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Checkbox(
                  value: _reschedule != null,
                  activeColor: AppTheme.primary,
                  onChanged: (v) {
                    if (v == true) {
                      _pickReschedule();
                    } else {
                      setState(() => _reschedule = null);
                    }
                  },
                ),
                const Text(
                  'ນັດສົ່ງໃໝ່',
                  style: TextStyle(color: AppTheme.textBright, fontSize: 12),
                ),
                const Spacer(),
                if (_reschedule != null)
                  TextButton(
                    onPressed: _pickReschedule,
                    child: Text(
                      _fmt(_reschedule!),
                      style: const TextStyle(
                        color: AppTheme.primary,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: const Text(
            'ຍ້ອນກັບ',
            style: TextStyle(color: AppTheme.textMuted),
          ),
        ),
        FilledButton(
          onPressed: _confirm,
          style: FilledButton.styleFrom(backgroundColor: AppTheme.error),
          child: const Text('ຢືນຢັນຍົກເລີກ'),
        ),
      ],
    );
  }
}

class _CompResult {
  final List<Map<String, dynamic>> items;
  final List<String> images;
  final String? sig;
  final String? comment;
  final bool isCancelled;
  final double? collectedAmount; // COD (Module B)
  final String? paymentMethod;
  const _CompResult({
    required this.items,
    required this.images,
    this.sig,
    this.comment,
    this.isCancelled = false,
    this.collectedAmount,
    this.paymentMethod,
  });
}

class _CompPage extends StatefulWidget {
  final ApiClient api;
  final DeliveryBill bill;
  const _CompPage({required this.api, required this.bill});
  @override
  State<_CompPage> createState() => _CompPageState();
}

class _CompPageState extends State<_CompPage> {
  final _commentC = TextEditingController();
  final _codC = TextEditingController(); // COD collected amount (Module B)
  String _payMethod = 'cash'; // cash | transfer
  late final SignatureController _sigC;
  final _picker = ImagePicker();
  bool _loading = true;
  bool _submitting = false;
  List<DeliveryItem> _items = const [];
  final Map<String, double> _qty = {};
  final Set<String> _removed = {};
  final List<String> _images = [];
  int _step = 0; // 0=items, 1=photo, 2=signature, 3=confirm

  bool get _hasCod => widget.bill.codAmount > 0;

  @override
  void initState() {
    super.initState();
    _sigC = SignatureController(
      penStrokeWidth: 3,
      penColor: Colors.white,
      exportBackgroundColor: AppTheme.bgDark,
    );
    // Prefill COD with the expected amount — driver usually collects in full.
    if (_hasCod) {
      _codC.text = widget.bill.codAmount.toStringAsFixed(
        widget.bill.codAmount.truncateToDouble() == widget.bill.codAmount
            ? 0
            : 2,
      );
    }
    _load();
  }

  @override
  void dispose() {
    _commentC.dispose();
    _codC.dispose();
    _sigC.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final items = await widget.api.getBillItems(billNo: widget.bill.billNo);
      setState(() {
        _items = items;
        for (var i in items) {
          _qty[i.itemCode] = i.remainingQty;
        }
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
    }
  }

  Future<void> _pickImg() async {
    final f = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 55,
      maxWidth: 1280,
      maxHeight: 1280,
    );
    if (f == null) return;
    final b = await f.readAsBytes();
    final ext = f.name.toLowerCase().endsWith('.png') ? 'png' : 'jpeg';
    setState(() => _images.add('data:image/$ext;base64,${base64Encode(b)}'));
  }

  Future<String?> _getSigUri() async {
    if (_sigC.isEmpty) return null;
    final b = await _sigC.toPngBytes();
    if (b == null) return null;
    return 'data:image/png;base64,${base64Encode(b)}';
  }

  void _submit({bool isCancelled = false}) async {
    if (_submitting) return;
    if (isCancelled && _commentC.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ກະລຸນາໃສ່ໝາຍເຫດການຍົກເລີກ')),
      );
      return;
    }
    setState(() => _submitting = true);
    final sig = await _getSigUri();
    final items = _items
        .where((i) => !_removed.contains(i.itemCode))
        .map(
          (i) => {
            'item_code': i.itemCode,
            'qty': _qty[i.itemCode] ?? i.remainingQty,
          },
        )
        .toList();
    if (!mounted) return;
    Navigator.pop(
      context,
      _CompResult(
        items: items,
        images: _images,
        sig: sig,
        comment: _commentC.text.trim(),
        isCancelled: isCancelled,
        collectedAmount: _hasCod && !isCancelled
            ? (double.tryParse(_codC.text.trim().replaceAll(',', '')) ?? 0)
            : null,
        paymentMethod: _hasCod && !isCancelled ? _payMethod : null,
      ),
    );
  }

  // Thousands-separated integer kip, e.g. 1500000 → "1,500,000".
  String _money(double v) => v
      .toStringAsFixed(0)
      .replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');

  String _fq(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: AppTheme.bgDark,
        body: Center(child: CircularProgressIndicator(color: AppTheme.primary)),
      );
    }

    const stepLabels = ['ສິນຄ້າ', 'ຮູບຖ່າຍ', 'ລາຍເຊັນ', 'ຢືນຢັນ'];
    final topPad = MediaQuery.of(context).padding.top;

    return Scaffold(
      backgroundColor: AppTheme.bgDark,
      body: Column(
        children: [
          // ── Top bar ──
          Padding(
            padding: EdgeInsets.fromLTRB(8, topPad + 4, 8, 0),
            child: Row(
              children: [
                IconButton(
                  onPressed: _step > 0
                      ? () => setState(() => _step--)
                      : () => Navigator.pop(context),
                  icon: Icon(
                    _step > 0 ? Icons.arrow_back_rounded : Icons.close_rounded,
                    size: 22,
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        stepLabels[_step],
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.textBright,
                        ),
                      ),
                      Text(
                        '${widget.bill.billNo} · ${widget.bill.custName}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppTheme.textMuted,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                // step counter
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.bgSurface.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(AppTheme.radiusLg),
                    border: Border.all(color: AppTheme.surfaceBorder),
                  ),
                  child: Text(
                    '${_step + 1}/4',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ),
          ),
          const SizedBox(height: 8),

          // ── Step progress ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: List.generate(
                4,
                (i) => Expanded(
                  child: Container(
                    height: 3,
                    margin: EdgeInsets.only(right: i < 3 ? 6 : 0),
                    decoration: BoxDecoration(
                      color: i <= _step
                          ? AppTheme.primary
                          : AppTheme.surfaceBorder,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // ── Content ──
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: _step == 0
                  ? _stepItems()
                  : _step == 1
                  ? _stepPhotos()
                  : _step == 2
                  ? _stepSignature()
                  : _stepConfirm(),
            ),
          ),

          // ── Bottom ──
          Container(
            padding: EdgeInsets.fromLTRB(
              20,
              12,
              20,
              MediaQuery.of(context).padding.bottom + 12,
            ),
            decoration: const BoxDecoration(
              color: AppTheme.bgDark,
              border: Border(top: BorderSide(color: AppTheme.surfaceBorder)),
            ),
            child: _step < 3
                ? SizedBox(
                    height: 52,
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () => setState(() => _step++),
                      icon: const Icon(Icons.arrow_forward_rounded, size: 20),
                      label: const Text(
                        'ຕໍ່ໄປ',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                          height: 1,
                        ),
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.info,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  )
                : Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 52,
                          child: OutlinedButton.icon(
                            onPressed: _submitting
                                ? null
                                : () => _submit(isCancelled: true),
                            icon: const Icon(Icons.cancel_rounded, size: 16),
                            label: const Text(
                              'ຍົກເລີກ',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                height: 1,
                              ),
                            ),
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: AppTheme.error),
                              foregroundColor: AppTheme.error,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 2,
                        child: SizedBox(
                          height: 52,
                          child: FilledButton.icon(
                            onPressed: _submitting ? null : _submit,
                            icon: _submitting
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(
                                    Icons.check_circle_rounded,
                                    size: 18,
                                  ),
                            label: Text(
                              _submitting ? 'ກຳລັງບັນທຶກ...' : 'ບັນທຶກສຳເລັດ',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                height: 1,
                              ),
                            ),
                            style: FilledButton.styleFrom(
                              backgroundColor: AppTheme.success,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════
  //  Step 1: Items
  // ═══════════════════════════════════════
  Widget _stepItems() {
    final visibleItems = _items
        .where((i) => !_removed.contains(i.itemCode))
        .toList();
    return ListView.builder(
      key: const ValueKey('items'),
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      itemCount: visibleItems.length,
      itemBuilder: (_, i) {
        final item = visibleItems[i];
        final qty = _qty[item.itemCode] ?? item.remainingQty;
        final isFull = qty >= item.remainingQty;
        final isEmpty = qty <= 0;

        return Dismissible(
          key: ValueKey(item.itemCode),
          direction: DismissDirection.endToStart,
          onDismissed: (_) => setState(() => _removed.add(item.itemCode)),
          background: Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: AppTheme.error.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(14),
            ),
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 20),
            child: const Icon(
              Icons.delete_rounded,
              color: AppTheme.error,
              size: 22,
            ),
          ),
          child: Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppTheme.bgCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppTheme.surfaceBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: AppTheme.info.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Center(
                        child: Text(
                          '${i + 1}',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            color: AppTheme.info,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        item.itemName.isNotEmpty
                            ? item.itemName
                            : item.itemCode,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.textBright,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    // info
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.bgDark,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'ເຫຼືອ ${_fq(item.remainingQty)} ${item.unitCode}',
                        style: const TextStyle(
                          fontSize: 10,
                          color: AppTheme.textMuted,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const Spacer(),
                    // stepper
                    Container(
                      decoration: BoxDecoration(
                        color: AppTheme.bgDark,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppTheme.surfaceBorder),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          GestureDetector(
                            onTap: isEmpty
                                ? null
                                : () => setState(
                                    () => _qty[item.itemCode] = qty - 1,
                                  ),
                            child: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                borderRadius: const BorderRadius.horizontal(
                                  left: Radius.circular(11),
                                ),
                                color: isEmpty
                                    ? Colors.transparent
                                    : AppTheme.error.withValues(alpha: 0.06),
                              ),
                              child: Icon(
                                Icons.remove_rounded,
                                size: 18,
                                color: isEmpty
                                    ? AppTheme.textMuted
                                    : AppTheme.error,
                              ),
                            ),
                          ),
                          Container(
                            width: 52,
                            height: 40,
                            alignment: Alignment.center,
                            child: Text(
                              _fq(qty),
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w900,
                                color: AppTheme.textBright,
                              ),
                            ),
                          ),
                          GestureDetector(
                            onTap: isFull
                                ? null
                                : () => setState(
                                    () => _qty[item.itemCode] = qty + 1,
                                  ),
                            child: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                borderRadius: const BorderRadius.horizontal(
                                  right: Radius.circular(11),
                                ),
                                color: isFull
                                    ? Colors.transparent
                                    : AppTheme.primary.withValues(alpha: 0.06),
                              ),
                              child: Icon(
                                Icons.add_rounded,
                                size: 18,
                                color: isFull
                                    ? AppTheme.textMuted
                                    : AppTheme.primary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ═══════════════════════════════════════
  //  Step 2: Photos
  // ═══════════════════════════════════════
  Widget _stepPhotos() {
    return ListView(
      key: const ValueKey('photos'),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      children: [
        GestureDetector(
          onTap: _pickImg,
          child: Container(
            height: 156,
            decoration: BoxDecoration(
              color: AppTheme.warning.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: AppTheme.warning.withValues(alpha: 0.32),
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 58,
                  height: 58,
                  decoration: BoxDecoration(
                    color: AppTheme.warning.withValues(alpha: 0.16),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.add_a_photo_rounded,
                    size: 30,
                    color: AppTheme.warning,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'ຖ່າຍຮູບຫຼັກຖານ',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textBright,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _images.isEmpty
                      ? 'ກົດເພື່ອເປີດກ້ອງ'
                      : 'ຖ່າຍແລ້ວ ${_images.length} ຮູບ · ກົດເພີ່ມຮູບ',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 18),
        _label(
          Icons.photo_library_rounded,
          'ຮູບທີ່ຖ່າຍແລ້ວ',
          AppTheme.warning,
          '${_images.length}',
        ),
        const SizedBox(height: 10),
        if (_images.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
            decoration: BoxDecoration(
              color: AppTheme.bgCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppTheme.surfaceBorder),
            ),
            child: const Row(
              children: [
                Icon(
                  Icons.image_not_supported_outlined,
                  size: 22,
                  color: AppTheme.textMuted,
                ),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'ຍັງບໍ່ມີຮູບ',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          )
        else
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _images.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
            ),
            itemBuilder: (_, i) => Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppTheme.surfaceBorder),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(
                    base64Decode(_images[i].split(',').last),
                    fit: BoxFit.cover,
                  ),
                  Positioned(
                    left: 6,
                    bottom: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.62),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        '${i + 1}',
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 6,
                    right: 6,
                    child: GestureDetector(
                      onTap: () => setState(() => _images.removeAt(i)),
                      child: Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.68),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.close_rounded,
                          size: 16,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  // ═══════════════════════════════════════
  //  Step 3: Signature + Comment
  // ═══════════════════════════════════════
  Widget _stepSignature() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final signatureHeight = (constraints.maxHeight - 150).clamp(
          260.0,
          520.0,
        );

        return ListView(
          key: const ValueKey('signature'),
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          children: [
            _label(Icons.draw_rounded, 'ລາຍເຊັນຜູ້ຮັບ', AppTheme.info, null),
            const SizedBox(height: 10),
            Container(
              height: signatureHeight,
              decoration: BoxDecoration(
                color: AppTheme.bgCard,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppTheme.surfaceBorder),
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                children: [
                  Signature(
                    controller: _sigC,
                    backgroundColor: AppTheme.bgCard,
                  ),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: GestureDetector(
                      onTap: () => _sigC.clear(),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: AppTheme.bgDark,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppTheme.surfaceBorder),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.refresh_rounded,
                              size: 13,
                              color: AppTheme.textMuted,
                            ),
                            SizedBox(width: 4),
                            Text(
                              'ລຶບ',
                              style: TextStyle(
                                fontSize: 11,
                                color: AppTheme.textMuted,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // ── COD / ເກັບເງິນ (Module B) ── shown only when the bill has a
            // cash-on-delivery amount.
            if (_hasCod) ...[
              _label(
                Icons.payments_rounded,
                'ເກັບເງິນ (COD ${_money(widget.bill.codAmount)} ກີບ)',
                AppTheme.success,
                null,
              ),
              const SizedBox(height: 10),
              Container(
                decoration: BoxDecoration(
                  color: AppTheme.bgCard,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppTheme.surfaceBorder),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: TextField(
                  controller: _codC,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: const TextStyle(
                    color: AppTheme.textBright,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                  decoration: const InputDecoration(
                    hintText: 'ຈຳນວນເງິນທີ່ເກັບໄດ້',
                    hintStyle: TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 13,
                    ),
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(vertical: 14),
                    suffixText: 'ກີບ',
                    suffixStyle: TextStyle(color: AppTheme.textMuted),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  for (final m in const [
                    (code: 'cash', label: 'ເງິນສົດ'),
                    (code: 'transfer', label: 'ໂອນ'),
                  ])
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(
                          m.label,
                          style: const TextStyle(fontSize: 12),
                        ),
                        selected: _payMethod == m.code,
                        onSelected: (_) => setState(() => _payMethod = m.code),
                        backgroundColor: AppTheme.bgCard,
                        selectedColor: AppTheme.success.withValues(alpha: 0.25),
                        labelStyle: TextStyle(
                          color: _payMethod == m.code
                              ? AppTheme.textBright
                              : AppTheme.textMuted,
                        ),
                        side: const BorderSide(color: AppTheme.surfaceBorder),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 24),
            ],

            _label(Icons.notes_rounded, 'ໝາຍເຫດ', AppTheme.textMuted, null),
            const SizedBox(height: 10),
            Container(
              decoration: BoxDecoration(
                color: AppTheme.bgCard,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppTheme.surfaceBorder),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: TextField(
                controller: _commentC,
                maxLines: 3,
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 13,
                ),
                decoration: const InputDecoration(
                  hintText: 'ບັນທຶກ (ບໍ່ບັງຄັບ)',
                  hintStyle: TextStyle(color: AppTheme.textMuted, fontSize: 13),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  // ═══════════════════════════════════════
  //  Step 4: Confirm
  // ═══════════════════════════════════════
  Widget _stepConfirm() {
    final activeItems = _items
        .where((i) => !_removed.contains(i.itemCode))
        .toList();
    final totalQty = activeItems.fold<double>(
      0,
      (s, i) => s + (_qty[i.itemCode] ?? i.remainingQty),
    );

    return ListView(
      key: const ValueKey('confirm'),
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
      children: [
        // icon
        Center(
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              gradient: AppTheme.accentGradient,
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Icon(
              Icons.check_circle_rounded,
              size: 32,
              color: AppTheme.bgDark,
            ),
          ),
        ),
        const SizedBox(height: 16),
        const Center(
          child: Text(
            'ກວດສອບກ່ອນບັນທຶກ',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: AppTheme.textBright,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Center(
          child: Text(
            widget.bill.custName,
            style: const TextStyle(fontSize: 12, color: AppTheme.textMuted),
          ),
        ),
        const SizedBox(height: 24),

        // summary card
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppTheme.bgCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppTheme.surfaceBorder),
          ),
          child: Column(
            children: [
              _summaryRow(
                Icons.inventory_2_rounded,
                'ສິນຄ້າ',
                '${activeItems.length} ລາຍການ · ${_fq(totalQty)} ຫົວໜ່ວຍ',
                AppTheme.info,
                () => setState(() => _step = 0),
              ),
              const SizedBox(height: 12),
              Container(height: 1, color: AppTheme.surfaceBorder),
              const SizedBox(height: 12),
              _summaryRow(
                Icons.camera_alt_rounded,
                'ຮູບຖ່າຍ',
                '${_images.length} ຮູບ',
                AppTheme.warning,
                () => setState(() => _step = 1),
              ),
              const SizedBox(height: 12),
              Container(height: 1, color: AppTheme.surfaceBorder),
              const SizedBox(height: 12),
              _summaryRow(
                Icons.draw_rounded,
                'ລາຍເຊັນ',
                _sigC.isEmpty ? 'ບໍ່ມີ' : 'ມີ',
                AppTheme.info,
                () => setState(() => _step = 2),
              ),
              if (_commentC.text.trim().isNotEmpty) ...[
                const SizedBox(height: 12),
                Container(height: 1, color: AppTheme.surfaceBorder),
                const SizedBox(height: 12),
                _summaryRow(
                  Icons.notes_rounded,
                  'ໝາຍເຫດ',
                  _commentC.text.trim(),
                  AppTheme.textMuted,
                  () => setState(() => _step = 2),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),

        // item details
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.bgCard,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppTheme.surfaceBorder),
          ),
          child: Column(
            children: [
              for (var i = 0; i < activeItems.length; i++) ...[
                if (i > 0)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Container(height: 1, color: AppTheme.surfaceBorder),
                  ),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        activeItems[i].itemName.isNotEmpty
                            ? activeItems[i].itemName
                            : activeItems[i].itemCode,
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppTheme.textPrimary,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      '${_fq(_qty[activeItems[i].itemCode] ?? activeItems[i].remainingQty)} ${activeItems[i].unitCode}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.primary,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  // ── Helpers ──
  Widget _label(IconData icon, String title, Color color, String? badge) {
    return Row(
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 6),
        Text(
          title,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: AppTheme.textBright,
          ),
        ),
        if (badge != null) ...[
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              badge,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _summaryRow(
    IconData icon,
    String title,
    String value,
    Color color,
    VoidCallback onEdit,
  ) {
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, size: 16, color: color),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 10,
                  color: AppTheme.textMuted,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textBright,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        GestureDetector(
          onTap: onEdit,
          child: const Text(
            'ແກ້ໄຂ',
            style: TextStyle(
              fontSize: 11,
              color: AppTheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// _ReceivePickupPage — proof capture for "ຮັບສິນຄ້າຈາກລານລູກຄ້າ"
// A photo of the goods + the customer's signature, both required. Returned
// to _receiveFromCustomer which sends them with the receive GPS.
// ════════════════════════════════════════════════════════════════════
class _ReceivePickupResult {
  final String photo; // data:image/...;base64,...
  final String signature; // data:image/png;base64,...
  const _ReceivePickupResult({required this.photo, required this.signature});
}

class _ReceivePickupPage extends StatefulWidget {
  final DeliveryBill bill;
  const _ReceivePickupPage({required this.bill});
  @override
  State<_ReceivePickupPage> createState() => _ReceivePickupPageState();
}

class _ReceivePickupPageState extends State<_ReceivePickupPage> {
  final _picker = ImagePicker();
  late final SignatureController _sigC;
  String? _photo; // data URI of the captured goods photo
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _sigC = SignatureController(
      penStrokeWidth: 3,
      penColor: Colors.white,
      exportBackgroundColor: AppTheme.bgDark,
    );
  }

  @override
  void dispose() {
    _sigC.dispose();
    super.dispose();
  }

  Future<void> _capture() async {
    final f = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 55,
      maxWidth: 1280,
      maxHeight: 1280,
    );
    if (f == null) return;
    final b = await f.readAsBytes();
    final ext = f.name.toLowerCase().endsWith('.png') ? 'png' : 'jpeg';
    setState(() => _photo = 'data:image/$ext;base64,${base64Encode(b)}');
  }

  Future<void> _submit() async {
    if (_submitting) return;
    if (_photo == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('ກະລຸນາຖ່າຍຮູບສິນຄ້າກ່ອນ')));
      return;
    }
    if (_sigC.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ກະລຸນາໃຫ້ລູກຄ້າເຊັນຮັບກ່ອນ')),
      );
      return;
    }
    setState(() => _submitting = true);
    final sigBytes = await _sigC.toPngBytes();
    if (sigBytes == null) {
      setState(() => _submitting = false);
      return;
    }
    final sig = 'data:image/png;base64,${base64Encode(sigBytes)}';
    if (!mounted) return;
    Navigator.pop(
      context,
      _ReceivePickupResult(photo: _photo!, signature: sig),
    );
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;
    final canSubmit = _photo != null && !_submitting;
    return Scaffold(
      backgroundColor: AppTheme.bgDark,
      body: Column(
        children: [
          // ── Top bar ──
          Padding(
            padding: EdgeInsets.fromLTRB(8, topPad + 4, 12, 0),
            child: Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(
                    Icons.close_rounded,
                    size: 22,
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'ຮັບສິນຄ້າຈາກລານລູກຄ້າ',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.textBright,
                        ),
                      ),
                      Text(
                        '${widget.bill.billNo} · ${widget.bill.custName}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppTheme.textMuted,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),

          // ── Content ──
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
              children: [
                // Photo capture
                _ReceiveLabel(
                  icon: Icons.add_a_photo_rounded,
                  text: 'ຮູບສິນຄ້າທີ່ຮັບ',
                  color: AppTheme.warning,
                ),
                const SizedBox(height: 10),
                GestureDetector(
                  onTap: _submitting ? null : _capture,
                  child: _photo == null
                      ? Container(
                          height: 170,
                          decoration: BoxDecoration(
                            color: AppTheme.warning.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: AppTheme.warning.withValues(alpha: 0.32),
                            ),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                width: 58,
                                height: 58,
                                decoration: BoxDecoration(
                                  color: AppTheme.warning.withValues(
                                    alpha: 0.16,
                                  ),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.add_a_photo_rounded,
                                  size: 30,
                                  color: AppTheme.warning,
                                ),
                              ),
                              const SizedBox(height: 12),
                              const Text(
                                'ກົດເພື່ອເປີດກ້ອງ',
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.textBright,
                                ),
                              ),
                            ],
                          ),
                        )
                      : ClipRRect(
                          borderRadius: BorderRadius.circular(18),
                          child: Stack(
                            children: [
                              Image.memory(
                                base64Decode(_photo!.split(',').last),
                                width: double.infinity,
                                height: 220,
                                fit: BoxFit.cover,
                              ),
                              Positioned(
                                top: 8,
                                right: 8,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 6,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.62),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.refresh_rounded,
                                        size: 14,
                                        color: Colors.white,
                                      ),
                                      SizedBox(width: 4),
                                      Text(
                                        'ຖ່າຍໃໝ່',
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
                const SizedBox(height: 24),

                // Signature
                _ReceiveLabel(
                  icon: Icons.draw_rounded,
                  text: 'ລາຍເຊັນລູກຄ້າ (ຜູ້ສົ່ງມອບ)',
                  color: AppTheme.info,
                ),
                const SizedBox(height: 10),
                Container(
                  height: 300,
                  decoration: BoxDecoration(
                    color: AppTheme.bgCard,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppTheme.surfaceBorder),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    children: [
                      Signature(
                        controller: _sigC,
                        backgroundColor: AppTheme.bgCard,
                      ),
                      Positioned(
                        top: 8,
                        right: 8,
                        child: GestureDetector(
                          onTap: () => _sigC.clear(),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.bgDark,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: AppTheme.surfaceBorder),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.refresh_rounded,
                                  size: 13,
                                  color: AppTheme.textMuted,
                                ),
                                SizedBox(width: 4),
                                Text(
                                  'ລຶບ',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: AppTheme.textMuted,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // ── Bottom ──
          Container(
            padding: EdgeInsets.fromLTRB(
              20,
              12,
              20,
              MediaQuery.of(context).padding.bottom + 12,
            ),
            decoration: const BoxDecoration(
              color: AppTheme.bgDark,
              border: Border(top: BorderSide(color: AppTheme.surfaceBorder)),
            ),
            child: SizedBox(
              height: 52,
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: canSubmit ? _submit : null,
                icon: _submitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.inventory_2_rounded, size: 18),
                label: Text(
                  _submitting ? 'ກຳລັງບັນທຶກ...' : 'ບັນທຶກການຮັບເຄື່ອງ',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    height: 1,
                  ),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.success,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: AppTheme.surfaceBorder,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReceiveLabel extends StatelessWidget {
  const _ReceiveLabel({
    required this.icon,
    required this.text,
    required this.color,
  });
  final IconData icon;
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Text(
          text,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w800,
            color: AppTheme.textBright,
          ),
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// _PickupProofViewer — view the photo + signature captured at the
// customer's yard ("ຮັບສິນຄ້າຈາກລານລູກຄ້າ"). Bytes are fetched on demand.
// ════════════════════════════════════════════════════════════════════
class _PickupProofViewer extends StatefulWidget {
  final ApiClient api;
  final DeliveryBill bill;
  const _PickupProofViewer({required this.api, required this.bill});
  @override
  State<_PickupProofViewer> createState() => _PickupProofViewerState();
}

class _PickupProofViewerState extends State<_PickupProofViewer> {
  bool _loading = true;
  String? _error;
  String _photo = '';
  String _signature = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await widget.api.getPickupImages(billNo: widget.bill.billNo);
      if (!mounted) return;
      setState(() {
        _photo = r.photo;
        _signature = r.signature;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ApiException ? e.message : '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasPhoto = _photo.isNotEmpty;
    final hasSig = _signature.isNotEmpty;
    return Scaffold(
      backgroundColor: AppTheme.bgDark,
      appBar: AppBar(
        backgroundColor: AppTheme.bgDark,
        foregroundColor: AppTheme.textBright,
        elevation: 0,
        title: Text(
          'ຫຼັກຖານຮັບເຄື່ອງ · ${widget.bill.billNo}',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppTheme.primary),
            )
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'ໂຫຼດຮູບບໍ່ໄດ້: $_error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppTheme.textMuted),
                ),
              ),
            )
          : (!hasPhoto && !hasSig)
          ? const Center(
              child: Text(
                'ບໍ່ມີຮູບຮັບເຄື່ອງ',
                style: TextStyle(color: AppTheme.textMuted),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (hasPhoto) ...[
                  _label('ຮູບສິນຄ້າທີ່ຮັບ'),
                  const SizedBox(height: 8),
                  _zoomImage(_photo),
                  const SizedBox(height: 22),
                ],
                if (hasSig) ...[
                  _label('ລາຍເຊັນລູກຄ້າ'),
                  const SizedBox(height: 8),
                  _zoomImage(_signature),
                ],
              ],
            ),
    );
  }

  Widget _label(String t) => Text(
    t,
    style: const TextStyle(
      color: AppTheme.textBright,
      fontSize: 13,
      fontWeight: FontWeight.w800,
    ),
  );

  Widget _zoomImage(String dataUri) {
    final raw = dataUri.contains(',') ? dataUri.split(',').last : dataUri;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.surfaceBorder),
      ),
      child: InteractiveViewer(
        maxScale: 5,
        child: Image.memory(
          base64Decode(raw),
          width: double.infinity,
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) => const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'ຮູບເສຍຫາຍ',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textMuted),
            ),
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// _HeroJobHeader — gradient hero with status, doc no, miles
// ════════════════════════════════════════════════════════════════════
class _HeroJobHeader extends StatelessWidget {
  const _HeroJobHeader({
    required this.job,
    required this.color,
    required this.icon,
  });

  final DeliveryJob job;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final total = job.itemBill;
    final done = job.completedBillCount + job.cancelledBillCount;
    final pct = total > 0 ? (done / total).clamp(0.0, 1.0) : 0.0;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [color.withValues(alpha: 0.95), color.withValues(alpha: 0.6)],
        ),
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.4),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(icon, size: 12, color: Colors.white),
                    const SizedBox(width: 5),
                    Text(
                      job.statusText,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              Text(
                '$done / $total ບິນ',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w900,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            job.docNo,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w900,
              height: 1.05,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 5),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              _HeroChip(icon: Icons.event_rounded, text: job.dateLogistic),
              _HeroChip(
                icon: Icons.directions_car_filled_rounded,
                text: job.car,
              ),
              _HeroChip(icon: Icons.person_rounded, text: job.driver),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 5,
              backgroundColor: Colors.white.withValues(alpha: 0.2),
              valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
            ),
          ),
          if (job.milesStart.isNotEmpty || job.milesEnd.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                if (job.milesStart.isNotEmpty)
                  Expanded(
                    child: _MileBlock(
                      label: 'Mile ເລີ່ມ',
                      value: job.milesStart,
                    ),
                  ),
                if (job.milesStart.isNotEmpty && job.milesEnd.isNotEmpty)
                  const SizedBox(width: 10),
                if (job.milesEnd.isNotEmpty)
                  Expanded(
                    child: _MileBlock(
                      label: 'Mile ສິ້ນສຸດ',
                      value: job.milesEnd,
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _HeroChip extends StatelessWidget {
  const _HeroChip({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 11, color: Colors.white.withValues(alpha: 0.9)),
        const SizedBox(width: 4),
        Text(
          text,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.95),
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _MileBlock extends StatelessWidget {
  const _MileBlock({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              fontSize: 9,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w900,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// Full-screen blocking overlay shown while a job action is in flight, so the
/// user gets immediate visual feedback and can't double-tap a confirm button.
// Delivery-type pill: "ສົ່ງລູກຄ້າ" when forwardCode is empty, otherwise
// "ສົ່ງສາຂາ <name>". Mirrors the web tracking page so the driver sees the
// same colour coding (green / sky-blue) across surfaces.
class _ParentBillChip extends StatelessWidget {
  const _ParentBillChip({
    required this.parentBillNo,
    required this.siblingCount,
  });

  final String parentBillNo;
  final int siblingCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: AppTheme.warning.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: AppTheme.warning.withValues(alpha: 0.35),
          width: 0.6,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.link_rounded, size: 10, color: AppTheme.warning),
          const SizedBox(width: 2),
          Text(
            siblingCount > 1
                ? '$parentBillNo · $siblingCountບິນ'
                : parentBillNo,
            style: const TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w800,
              color: AppTheme.warning,
            ),
          ),
        ],
      ),
    );
  }
}

class _DeliveryTypePill extends StatelessWidget {
  const _DeliveryTypePill({
    required this.forwardCode,
    required this.forwardName,
  });

  final String forwardCode;
  final String forwardName;

  @override
  Widget build(BuildContext context) {
    final isForward = forwardCode.trim().isNotEmpty;
    final color = isForward ? AppTheme.info : AppTheme.success;
    final label = isForward
        ? 'ສົ່ງສາຂາ${forwardName.isNotEmpty ? " $forwardName" : ""}'
        : 'ສົ່ງລູກຄ້າ';
    final icon = isForward
        ? Icons.business_outlined
        : Icons.person_outline_rounded;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                color: color,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({
    required this.label,
    required this.detail,
    required this.time,
    required this.icon,
    required this.color,
    required this.isLast,
  });

  final String label;
  final String detail;
  final String time;
  final IconData icon;
  final Color color;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final cleanTime = time.trim();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.13),
                shape: BoxShape.circle,
                border: Border.all(color: color.withValues(alpha: 0.45)),
              ),
              child: Icon(icon, size: 14, color: color),
            ),
            if (!isLast)
              Container(width: 2, height: 26, color: AppTheme.surfaceBorder),
          ],
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(bottom: isLast ? 0 : 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.textBright,
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    if (cleanTime.isNotEmpty)
                      Text(
                        cleanTime,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.textMuted,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                  ],
                ),
                if (detail.trim().isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _BusyOverlay extends StatelessWidget {
  const _BusyOverlay();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black54,
      child: const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Material(
            color: Colors.transparent,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 44,
                  height: 44,
                  child: CircularProgressIndicator(
                    color: AppTheme.primary,
                    strokeWidth: 3,
                  ),
                ),
                SizedBox(height: 14),
                Text(
                  'ກຳລັງດຳເນີນການ...',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// Result of the edit page. Each field is independently optional — the
// caller only forwards what the driver actually changed to the API.
class _EditResult {
  final List<Map<String, dynamic>> items;
  final List<String>? newImages;
  final String? newSignature;
  final String? newComment;
  const _EditResult({
    required this.items,
    this.newImages,
    this.newSignature,
    this.newComment,
  });
}

class _EditBillPage extends StatefulWidget {
  final ApiClient api;
  final DeliveryBill bill;
  const _EditBillPage({required this.api, required this.bill});
  @override
  State<_EditBillPage> createState() => _EditBillPageState();
}

class _EditBillPageState extends State<_EditBillPage> {
  final _commentC = TextEditingController();
  final _picker = ImagePicker();
  bool _loading = true;
  bool _submitting = false;
  List<DeliveryItem> _items = const [];
  final Map<String, double> _qty = {};
  // _newImages: null = keep existing, [] or [...] = replace with this set.
  List<String>? _newImages;
  // _newSig: null = keep existing, non-null data URI = replace.
  String? _newSig;
  SignatureController? _sigC;

  @override
  void initState() {
    super.initState();
    _commentC.text = widget.bill.remark;
    _load();
  }

  @override
  void dispose() {
    _commentC.dispose();
    _sigC?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final items = await widget.api.getBillItems(billNo: widget.bill.billNo);
      setState(() {
        _items = items;
        for (final i in items) {
          _qty[i.itemCode] = i.deliveredQty;
        }
        _loading = false;
      });
    } catch (_) {
      setState(() => _loading = false);
    }
  }

  Future<void> _addPhoto() async {
    final f = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 55,
      maxWidth: 1280,
      maxHeight: 1280,
    );
    if (f == null) return;
    final b = await f.readAsBytes();
    final ext = f.name.toLowerCase().endsWith('.png') ? 'png' : 'jpeg';
    setState(() {
      _newImages ??= <String>[];
      _newImages!.add('data:image/$ext;base64,${base64Encode(b)}');
    });
  }

  void _removePhoto(int i) {
    setState(() => _newImages?.removeAt(i));
  }

  void _openSignature() {
    _sigC ??= SignatureController(
      penStrokeWidth: 3,
      penColor: Colors.white,
      exportBackgroundColor: AppTheme.bgDark,
    );
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: AppTheme.bgCard,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'ປ່ຽນລາຍເຊັນ',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: AppTheme.textBright,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                height: 220,
                decoration: BoxDecoration(
                  color: AppTheme.bgDark,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.surfaceBorder),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Signature(
                    controller: _sigC!,
                    backgroundColor: AppTheme.bgDark,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _sigC!.clear(),
                      child: const Text('ລ້າງ'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('ຍ້ອນກັບ'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton(
                      onPressed: () async {
                        if (_sigC!.isEmpty) {
                          Navigator.pop(ctx);
                          return;
                        }
                        final b = await _sigC!.toPngBytes();
                        if (b == null) {
                          if (ctx.mounted) Navigator.pop(ctx);
                          return;
                        }
                        setState(() {
                          _newSig = 'data:image/png;base64,${base64Encode(b)}';
                        });
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      child: const Text('ບັນທຶກ'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _submit() {
    if (_submitting) return;
    setState(() => _submitting = true);
    final items = _items
        .map(
          (i) => {
            'item_code': i.itemCode,
            'qty': _qty[i.itemCode] ?? i.deliveredQty,
          },
        )
        .toList();
    Navigator.pop(
      context,
      _EditResult(
        items: items,
        newImages: _newImages,
        newSignature: _newSig,
        newComment: _commentC.text.trim(),
      ),
    );
  }

  String _fq(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        backgroundColor: AppTheme.bgDark,
        body: Center(child: CircularProgressIndicator(color: AppTheme.primary)),
      );
    }
    final topPad = MediaQuery.of(context).padding.top;
    return Scaffold(
      backgroundColor: AppTheme.bgDark,
      body: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(8, topPad + 4, 8, 0),
            child: Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(
                    Icons.close_rounded,
                    size: 22,
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'ແກ້ໄຂການຈັດສົ່ງ',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: AppTheme.textBright,
                        ),
                      ),
                      Text(
                        '${widget.bill.billNo} · ${widget.bill.custName}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppTheme.textMuted,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              children: [
                _sectionTitle('ສິນຄ້າ'),
                ..._items.map(_itemRow),
                const SizedBox(height: 16),
                _sectionTitle('ຮູບຈັດສົ່ງ'),
                _photoSection(),
                const SizedBox(height: 16),
                _sectionTitle('ລາຍເຊັນ'),
                _signatureSection(),
                const SizedBox(height: 16),
                _sectionTitle('ໝາຍເຫດ'),
                TextField(
                  controller: _commentC,
                  maxLines: 3,
                  style: const TextStyle(color: AppTheme.textBright),
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: AppTheme.bgCard,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: AppTheme.surfaceBorder),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: AppTheme.surfaceBorder),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: EdgeInsets.fromLTRB(
              20,
              12,
              20,
              MediaQuery.of(context).padding.bottom + 12,
            ),
            decoration: const BoxDecoration(
              color: AppTheme.bgDark,
              border: Border(top: BorderSide(color: AppTheme.surfaceBorder)),
            ),
            child: SizedBox(
              height: 52,
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _submitting ? null : _submit,
                icon: const Icon(Icons.save_rounded, size: 20),
                label: Text(
                  _submitting ? 'ກຳລັງບັນທຶກ...' : 'ບັນທຶກການແກ້ໄຂ',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    height: 1,
                  ),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.success,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String s) => Padding(
    padding: const EdgeInsets.only(bottom: 8, top: 4),
    child: Text(
      s,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w800,
        color: AppTheme.textSecondary,
      ),
    ),
  );

  Widget _itemRow(DeliveryItem item) {
    final qty = _qty[item.itemCode] ?? item.deliveredQty;
    final max = item.selectedQty;
    final isFull = qty >= max;
    final isEmpty = qty <= 0;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.surfaceBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            item.itemName.isNotEmpty ? item.itemName : item.itemCode,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: AppTheme.textBright,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                'ສູງສຸດ ${_fq(max)} ${item.unitCode}',
                style: const TextStyle(
                  fontSize: 10,
                  color: AppTheme.textMuted,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Container(
                decoration: BoxDecoration(
                  color: AppTheme.bgDark,
                  borderRadius: BorderRadius.circular(11),
                  border: Border.all(color: AppTheme.surfaceBorder),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    GestureDetector(
                      onTap: isEmpty
                          ? null
                          : () => setState(() => _qty[item.itemCode] = qty - 1),
                      child: Container(
                        width: 36,
                        height: 36,
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.remove_rounded,
                          size: 18,
                          color: isEmpty ? AppTheme.textMuted : AppTheme.error,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 48,
                      child: Center(
                        child: Text(
                          _fq(qty),
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w900,
                            color: AppTheme.textBright,
                          ),
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: isFull
                          ? null
                          : () => setState(() => _qty[item.itemCode] = qty + 1),
                      child: Container(
                        width: 36,
                        height: 36,
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.add_rounded,
                          size: 18,
                          color: isFull ? AppTheme.textMuted : AppTheme.primary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _photoSection() {
    final imgs = _newImages;
    if (imgs == null) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.bgCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.surfaceBorder),
        ),
        child: Column(
          children: [
            const Text(
              'ໃຊ້ຮູບເກົ່າ',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => setState(() => _newImages = <String>[]),
                icon: const Icon(Icons.add_a_photo_rounded, size: 18),
                label: const Text('ປ່ຽນຮູບໃໝ່'),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: AppTheme.warning),
                  foregroundColor: AppTheme.warning,
                ),
              ),
            ),
          ],
        ),
      );
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.warning.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.warning_rounded,
                size: 14,
                color: AppTheme.warning,
              ),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  'ຮູບເກົ່າຈະຖືກແທນ',
                  style: TextStyle(
                    color: AppTheme.warning,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => setState(() => _newImages = null),
                child: const Text(
                  'ກັບໃຊ້ຮູບເກົ່າ',
                  style: TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < imgs.length; i++)
                Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: Image.memory(
                        base64Decode(imgs[i].split(',').last),
                        width: 84,
                        height: 84,
                        fit: BoxFit.cover,
                      ),
                    ),
                    Positioned(
                      top: 2,
                      right: 2,
                      child: GestureDetector(
                        onTap: () => _removePhoto(i),
                        child: Container(
                          decoration: const BoxDecoration(
                            color: Colors.black54,
                            shape: BoxShape.circle,
                          ),
                          padding: const EdgeInsets.all(2),
                          child: const Icon(
                            Icons.close_rounded,
                            size: 14,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              GestureDetector(
                onTap: _addPhoto,
                child: Container(
                  width: 84,
                  height: 84,
                  decoration: BoxDecoration(
                    color: AppTheme.warning.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: AppTheme.warning.withValues(alpha: 0.4),
                    ),
                  ),
                  child: const Icon(
                    Icons.add_a_photo_rounded,
                    color: AppTheme.warning,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _signatureSection() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _newSig != null
              ? AppTheme.warning.withValues(alpha: 0.4)
              : AppTheme.surfaceBorder,
        ),
      ),
      child: Column(
        children: [
          Text(
            _newSig != null
                ? 'ລາຍເຊັນໃໝ່ — ຈະແທນລາຍເຊັນເກົ່າ'
                : 'ໃຊ້ລາຍເຊັນເກົ່າ',
            style: TextStyle(
              color: _newSig != null
                  ? AppTheme.warning
                  : AppTheme.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              if (_newSig != null) ...[
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => setState(() => _newSig = null),
                    child: const Text('ກັບໃຊ້ລາຍເຊັນເກົ່າ'),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _openSignature,
                  icon: const Icon(Icons.edit_rounded, size: 16),
                  label: const Text('ປ່ຽນລາຍເຊັນ'),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: AppTheme.warning),
                    foregroundColor: AppTheme.warning,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
