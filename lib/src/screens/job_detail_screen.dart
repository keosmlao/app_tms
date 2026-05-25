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
import 'qr_scan_screen.dart';

import '../app_controller.dart';
import '../core/app_theme.dart';
import '../models/delivery_bill.dart';
import '../models/delivery_item.dart';
import '../models/delivery_job.dart';
import '../services/api_client.dart';
import '../services/offline_outbox.dart';

class JobDetailScreen extends StatefulWidget {
  final AppController controller;
  final DeliveryJob initialJob;
  const JobDetailScreen({
    super.key,
    required this.controller,
    required this.initialJob,
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

  // Location tracking for travel history
  Timer? _locationTimer;
  static const _locationInterval = Duration(seconds: 5);

  @override
  void initState() {
    super.initState();
    _job = widget.initialJob;
    _loadData();
    _startLocationTracking();
  }

  @override
  void dispose() {
    _locationTimer?.cancel();
    super.dispose();
  }

  void _startLocationTracking() {
    _locationTimer?.cancel();
    _locationTimer = Timer.periodic(_locationInterval, (_) => _saveLocation());
  }

  Future<void> _saveLocation() async {
    if (_job.jobStatus != 2) return; // Only track during dispatch
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      await widget.controller.api.saveTravelHistory(
        docNo: _job.docNo,
        lat: pos.latitude.toString(),
        lng: pos.longitude.toString(),
      );
    } catch (_) {
      // Silently fail - don't interrupt user
    }
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
    final pos = await Geolocator.getCurrentPosition(
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
      final results = await Future.wait([
        widget.controller.api.getJobs(
          driverId: widget.controller.user!.driverId,
        ),
        widget.controller.api.getBills(docNo: _job.docNo),
      ]);
      final jobs = results[0] as List<DeliveryJob>;
      final bills = results[1] as List<DeliveryBill>;
      final updated = jobs.where((j) => j.docNo == _job.docNo).firstOrNull;
      setState(() {
        if (updated != null) _job = updated;
        _bills = bills;
        if (!silent) _loading = false;
      });
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

      widget.controller.api.resetFetchState();
      await _loadData(silent: true);
      final usedCache = widget.controller.api.lastFetchUsedCache;

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
          msg =
              '$successMsg — ໂຫຼດຂໍ້ມູນໃໝ່ບໍ່ໄດ້, ດຶງລົງເພື່ອອັບເດດ';
          bg = AppTheme.warning;
        } else {
          msg = successMsg;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), backgroundColor: bg),
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
            isCustomerPickup
                ? Icons.home_outlined
                : Icons.warehouse_outlined,
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 0,
                ),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _checkInBill(DeliveryBill b) async {
    // Open the map screen so the driver can verify location before sending.
    final pos = await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => CheckinMapScreen(bill: b)));
    if (pos == null) return; // user cancelled
    setState(() => _busy = true);
    try {
      await widget.controller.api.checkInBill(
        billNo: b.billNo,
        lat: pos.latitude.toString(),
        lng: pos.longitude.toString(),
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
              .where((x) =>
                  x.billNo != b.billNo &&
                  x.parentBillNo == b.parentBillNo &&
                  x.custCode == b.custCode &&
                  (x.phase == 'pickup' || x.phase == 'inprogress'))
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
                  style: const TextStyle(color: AppTheme.textBright, fontSize: 12),
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
    final comment = await showDialog<String>(
      context: context,
      builder: (_) => _CancelDialog(billNo: b.billNo),
    );
    if (comment == null || comment.isEmpty) return;
    await _runAction(
      () async {
        final l = await _getLocation();
        await widget.controller.api.cancelBill(
          billNo: b.billNo,
          comment: comment,
          lat: l['lat'],
          lng: l['lng'],
          latEnd: l['lat'],
          lngEnd: l['lng'],
        );
      },
      'ຍົກເລີກບິນແລ້ວ',
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

  Future<void> _scanBillQr(DeliveryBill b) async {
    HapticFeedback.selectionClick();
    await Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => QrScanVerifyScreen(bill: b),
      ),
    );
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
            wasQueued
                ? 'ປິດງານໄວ້ — ຈະສົ່ງເມື່ອມີເນັດ'
                : 'ປິດງານແລ້ວ',
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
                _buildBottom(),
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
    final hasActions =
        hasMap ||
        hasPhone ||
        (bill.canPickup && _job.jobStatus == 1) ||
        (_job.jobStatus >= 2 && bill.phase == 'pickup' && !bill.isFinished) ||
        bill.canComplete ||
        bill.canCancel;

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
                                      .where((x) => x.parentBillNo == bill.parentBillNo)
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
                          if (bill.pickupTransportName.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Row(
                              children: [
                                const Icon(
                                  Icons.warehouse_outlined,
                                  size: 10,
                                  color: AppTheme.textMuted,
                                ),
                                const SizedBox(width: 2),
                                Expanded(
                                  child: Text(
                                    'ຮັບ: ${bill.pickupTransportName}',
                                    style: const TextStyle(
                                      fontSize: 10,
                                      color: AppTheme.textMuted,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ],
                          if (bill.destination.isNotEmpty) ...[
                            const SizedBox(height: 2),
                            Row(
                              children: [
                                const Icon(
                                  Icons.location_on_outlined,
                                  size: 10,
                                  color: AppTheme.textMuted,
                                ),
                                const SizedBox(width: 2),
                                Expanded(
                                  child: Text(
                                    'ສົ່ງ: ${bill.destination}',
                                    style: const TextStyle(
                                      fontSize: 10,
                                      color: AppTheme.textMuted,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ],
                          // Delivery type pill: forwardTransportCode empty
                          // means delivered to the customer; otherwise the
                          // bill is being forwarded to a sister branch.
                          const SizedBox(height: 4),
                          _DeliveryTypePill(
                            forwardCode: bill.forwardTransportCode,
                            forwardName: bill.forwardTransportName,
                          ),
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
                      // Pickup is allowed any time before the trip closes —
                      // pickup_bill auto-receives the trip when jobStatus=0,
                      // and a single trip may pick up at a second warehouse
                      // after start_dispatch too. Customer-pickup bills don't
                      // surface this button: their recipt_job is backfilled
                      // automatically when the driver checks in at the
                      // customer (see mobile.js:checkin_bill).
                      if (bill.canPickup &&
                          _job.jobStatus < 3 &&
                          bill.pickupTransportCode != '__CUSTOMER__')
                        _actBtn(
                          'ເບີກ',
                          Icons.inventory_2_rounded,
                          AppTheme.info,
                          _busy ? null : () => _pickupBill(bill),
                        ),
                      if (_job.jobStatus >= 1 &&
                          _job.jobStatus < 3 &&
                          bill.phase == 'pickup' &&
                          !bill.isFinished)
                        Tooltip(
                          message: blockedByActive
                              ? 'ສຳເລັດ ຫຼື ຍົກເລີກບິນທີ່ checkin ແລ້ວກ່ອນ'
                              : '',
                          child: _actBtn(
                            'Check in',
                            Icons.location_on_rounded,
                            AppTheme.info,
                            _busy || blockedByActive
                                ? null
                                : () => _checkInBill(bill),
                          ),
                        ),
                      // QR verify: driver scans the printed bill QR to confirm
                      // they're at the right delivery point. Visible whenever
                      // the bill is still in the active delivery window —
                      // useful right before check-in and again before
                      // completing if the driver wants to double-check. Gated
                      // by the server feature flag so admins can disable it
                      // app-wide from /manage/settings.
                      if (widget.controller.settings.qrScanVerifyEnabled &&
                          _job.jobStatus >= 1 &&
                          _job.jobStatus < 3 &&
                          (bill.phase == 'pickup' || bill.phase == 'inprogress'))
                        _actBtn(
                          'Scan QR',
                          Icons.qr_code_scanner_rounded,
                          AppTheme.primary,
                          _busy ? null : () => _scanBillQr(bill),
                        ),
                      if (bill.canComplete || bill.phase == 'pickup')
                        _actBtn(
                          'ສຳເລັດ',
                          Icons.check_circle_rounded,
                          AppTheme.success,
                          _busy
                              ? null
                              : bill.canComplete
                              ? () => _completeBill(bill)
                              : () {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('ກະລຸນາ Check in ກ່ອນ'),
                                    ),
                                  );
                                },
                        ),
                      if (bill.canCancel)
                        _actBtn(
                          'ຍົກເລີກ',
                          Icons.cancel_rounded,
                          AppTheme.error,
                          _busy ? null : () => _cancelBill(bill),
                        ),
                      // Edit a completed delivery in-place: change qty,
                      // photos, signature, remark without resetting status.
                      // GPS coordinates are preserved on the server.
                      if (bill.canEdit && _job.jobStatus < 3)
                        _actBtn(
                          'ແກ້ໄຂ',
                          Icons.edit_rounded,
                          AppTheme.info,
                          _busy ? null : () => _editBill(bill),
                        ),
                      // Roll back a completed delivery so the driver can
                      // retake the photo + location. Blocked once the trip
                      // is closed (jobStatus >= 3).
                      if (bill.canRevertComplete && _job.jobStatus < 3)
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

class _CancelDialog extends StatefulWidget {
  final String billNo;
  const _CancelDialog({required this.billNo});

  @override
  State<_CancelDialog> createState() => _CancelDialogState();
}

class _CancelDialogState extends State<_CancelDialog> {
  final _commentCtrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _commentCtrl.dispose();
    super.dispose();
  }

  void _confirm() {
    final text = _commentCtrl.text.trim();
    if (text.isEmpty) {
      setState(() => _error = 'ກະລຸນາໃສ່ໝາຍເຫດການຍົກເລີກ');
      return;
    }
    Navigator.pop(context, text);
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
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'ຍົກເລີກບິນ ${widget.billNo}',
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _commentCtrl,
            autofocus: true,
            minLines: 3,
            maxLines: 5,
            style: const TextStyle(color: AppTheme.textBright, fontSize: 13),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            decoration: InputDecoration(
              hintText: 'ໝາຍເຫດການຍົກເລີກ (ບັງຄັບ) *',
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
                borderSide: const BorderSide(color: AppTheme.error, width: 1.5),
              ),
            ),
          ),
        ],
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
  const _CompResult({
    required this.items,
    required this.images,
    this.sig,
    this.comment,
    this.isCancelled = false,
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
  late final SignatureController _sigC;
  final _picker = ImagePicker();
  bool _loading = true;
  bool _submitting = false;
  List<DeliveryItem> _items = const [];
  final Map<String, double> _qty = {};
  final Set<String> _removed = {};
  final List<String> _images = [];
  int _step = 0; // 0=items, 1=photo, 2=signature, 3=confirm

  @override
  void initState() {
    super.initState();
    _sigC = SignatureController(
      penStrokeWidth: 3,
      penColor: Colors.white,
      exportBackgroundColor: AppTheme.bgDark,
    );
    _load();
  }

  @override
  void dispose() {
    _commentC.dispose();
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
        border: Border.all(color: AppTheme.warning.withValues(alpha: 0.35), width: 0.6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.link_rounded, size: 10, color: AppTheme.warning),
          const SizedBox(width: 2),
          Text(
            siblingCount > 1
                ? '$parentBillNo · ${siblingCount}ບິນ'
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
                  child: Signature(controller: _sigC!, backgroundColor: AppTheme.bgDark),
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
        .map((i) => {
              'item_code': i.itemCode,
              'qty': _qty[i.itemCode] ?? i.deliveredQty,
            })
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
                          : () => setState(
                              () => _qty[item.itemCode] = qty - 1),
                      child: Container(
                        width: 36,
                        height: 36,
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.remove_rounded,
                          size: 18,
                          color: isEmpty
                              ? AppTheme.textMuted
                              : AppTheme.error,
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
                          : () => setState(
                              () => _qty[item.itemCode] = qty + 1),
                      child: Container(
                        width: 36,
                        height: 36,
                        alignment: Alignment.center,
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
              const Icon(Icons.warning_rounded,
                  size: 14, color: AppTheme.warning),
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
                child: const Text('ກັບໃຊ້ຮູບເກົ່າ',
                    style: TextStyle(fontSize: 11)),
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
