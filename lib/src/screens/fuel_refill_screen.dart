import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';

import '../app_controller.dart';
import '../core/app_theme.dart';
import '../models/delivery_job.dart';
import '../services/api_client.dart';

class FuelRefillScreen extends StatefulWidget {
  const FuelRefillScreen({
    super.key,
    required this.controller,
    this.docNo,
    this.car,
  });

  final AppController controller;
  final String? docNo;
  final String? car;

  @override
  State<FuelRefillScreen> createState() => _FuelRefillScreenState();
}

class _FuelRefillScreenState extends State<FuelRefillScreen> {
  final _formKey = GlobalKey<FormState>();
  final _liters = TextEditingController();
  final _amount = TextEditingController();
  final _odometer = TextEditingController();
  final _station = TextEditingController();
  final _note = TextEditingController();
  final _customCar = TextEditingController();

  final _picker = ImagePicker();
  Uint8List? _imageBytes;
  String? _imageDataUri;
  bool _submitting = false;
  Position? _position;

  // Cars from the driver's jobs — the first one is the "currently driving"
  // default; the driver can pick any other car or fall back to manual entry.
  List<String> _availableCars = const [];
  String? _selectedCar; // null = "ຄັນອື່ນ" (manual)
  bool _loadingCars = true;

  @override
  void initState() {
    super.initState();
    _resolvePosition();
    _loadCars();
  }

  @override
  void dispose() {
    _liters.dispose();
    _amount.dispose();
    _odometer.dispose();
    _station.dispose();
    _note.dispose();
    _customCar.dispose();
    super.dispose();
  }

  Future<void> _loadCars() async {
    final user = widget.controller.user;
    if (user == null) {
      setState(() => _loadingCars = false);
      return;
    }
    try {
      final jobs = await widget.controller.api.getJobs(driverId: user.driverId);
      // Prioritise the car the driver is actively using: jobStatus 2 (in
      // transit) first, then 1 (received), then anything else. De-dupe so
      // each car appears once.
      int rank(DeliveryJob j) {
        if (j.jobStatus == 2) return 0;
        if (j.jobStatus == 1) return 1;
        if (j.jobStatus == 0) return 2;
        return 3;
      }

      final sorted = [...jobs]..sort((a, b) => rank(a).compareTo(rank(b)));
      final seen = <String>{};
      final unique = <String>[];
      for (final j in sorted) {
        final c = j.car.trim();
        if (c.isEmpty || !seen.add(c)) continue;
        unique.add(c);
      }

      if (!mounted) return;
      final initial = (widget.car != null && widget.car!.trim().isNotEmpty)
          ? widget.car!.trim()
          : (unique.isNotEmpty ? unique.first : null);
      setState(() {
        _availableCars = unique;
        _selectedCar = initial;
        _loadingCars = false;
        if (initial != null && !unique.contains(initial)) {
          // Caller passed a car that isn't in the driver's job list — keep it
          // selected by adding to the list so the chip is rendered.
          _availableCars = [initial, ...unique];
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingCars = false);
    }
  }

  String? get _carValue {
    if (_selectedCar != null) return _selectedCar;
    final manual = _customCar.text.trim();
    return manual.isEmpty ? null : manual;
  }

  Future<void> _resolvePosition() async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      ).timeout(const Duration(seconds: 10));
      if (!mounted) return;
      setState(() => _position = pos);
    } catch (_) {
      // GPS optional — silent failure is fine.
    }
  }

  Future<void> _pickPhoto({required ImageSource source}) async {
    try {
      // Resize on capture so the inline base64 payload stays small. A
      // full-resolution photo (several MB) sent inside the fuel_refill request
      // can blow past the reverse-proxy body limit (413) — which surfaces as a
      // failed save, especially on weak signal. 1280px @ q60 → ~100-300KB.
      final f = await _picker.pickImage(
        source: source,
        maxWidth: 1280,
        maxHeight: 1280,
        imageQuality: 60,
      );
      if (f == null) return;
      final bytes = await f.readAsBytes();
      // image_picker re-encodes to JPEG when resizing, so always tag jpeg.
      setState(() {
        _imageBytes = bytes;
        _imageDataUri = 'data:image/jpeg;base64,${base64Encode(bytes)}';
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('ບໍ່ສາມາດເລືອກຮູບ: $e')));
    }
  }

  void _showPhotoSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.bgCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt, color: AppTheme.primary),
              title: const Text(
                'ຖ່າຍຮູບ',
                style: TextStyle(color: AppTheme.textPrimary),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _pickPhoto(source: ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library, color: AppTheme.info),
              title: const Text(
                'ເລືອກຈາກອັນບັມ',
                style: TextStyle(color: AppTheme.textPrimary),
              ),
              onTap: () {
                Navigator.pop(ctx);
                _pickPhoto(source: ImageSource.gallery);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (_submitting) return;
    final user = widget.controller.user;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ກະລຸນາ login ຄືນ')),
      );
      return;
    }

    setState(() => _submitting = true);
    try {
      await widget.controller.api.submitFuelRefill(
        userCode: user.code,
        driverName: user.displayName.isNotEmpty
            ? user.displayName
            : user.username,
        car: _carValue,
        docNo: widget.docNo,
        liters: double.parse(_liters.text.trim()),
        amount: double.parse(_amount.text.trim()),
        odometer: _odometer.text.trim().isEmpty
            ? null
            : double.tryParse(_odometer.text.trim()),
        station: _station.text.trim().isEmpty ? null : _station.text.trim(),
        note: _note.text.trim().isEmpty ? null : _note.text.trim(),
        imageDataUri: _imageDataUri,
        lat: _position?.latitude.toString(),
        lng: _position?.longitude.toString(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('ບັນທຶກສຳເລັດ'),
          backgroundColor: AppTheme.success,
        ),
      );
      Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message), backgroundColor: AppTheme.error),
      );
    } catch (e) {
      if (!mounted) return;
      if (e is SocketException ||
          e.toString().toLowerCase().contains('socket')) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('ບັນທຶກໄວ້ ແລະຈະສົ່ງເມື່ອມີເນັດ'),
            backgroundColor: AppTheme.warning,
          ),
        );
        Navigator.pop(context, true);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('ບໍ່ສຳເລັດ: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  InputDecoration _decoration({
    required String label,
    String? hint,
    Widget? prefix,
    String? suffixText,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: prefix,
      suffixText: suffixText,
      labelStyle: const TextStyle(color: AppTheme.textSecondary),
      hintStyle: const TextStyle(color: Color(0xFF64748B)),
      filled: true,
      fillColor: AppTheme.bgSurface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        borderSide: BorderSide(color: AppTheme.surfaceBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        borderSide: BorderSide(color: AppTheme.surfaceBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        borderSide: const BorderSide(color: AppTheme.primary, width: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgDark,
      appBar: AppBar(
        backgroundColor: AppTheme.bgMid,
        title: const Text('ບັນທຶກເຕີມນ້ຳມັນ'),
        elevation: 0,
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _photoCard(),
            const SizedBox(height: 16),
            TextFormField(
              controller: _liters,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
              decoration: _decoration(
                label: 'ຈຳນວນລິດ',
                hint: '0.00',
                prefix: const Icon(
                  Icons.local_gas_station,
                  color: AppTheme.warning,
                ),
                suffixText: 'L',
              ),
              validator: (v) {
                final t = v?.trim() ?? '';
                if (t.isEmpty) return 'ກະລຸນາໃສ່ຈຳນວນລິດ';
                final n = double.tryParse(t);
                if (n == null || n <= 0) return 'ຄ່າບໍ່ຖືກຕ້ອງ';
                return null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
              decoration: _decoration(
                label: 'ຈຳນວນເງິນ',
                hint: '0',
                prefix: const Icon(Icons.payments, color: AppTheme.success),
                suffixText: '₭',
              ),
              validator: (v) {
                final t = v?.trim() ?? '';
                if (t.isEmpty) return 'ກະລຸນາໃສ່ຈຳນວນເງິນ';
                final n = double.tryParse(t);
                if (n == null || n <= 0) return 'ຄ່າບໍ່ຖືກຕ້ອງ';
                return null;
              },
            ),
            const SizedBox(height: 12),
            _carSelector(),
            const SizedBox(height: 12),
            TextFormField(
              controller: _odometer,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              style: const TextStyle(color: AppTheme.textPrimary),
              decoration: _decoration(
                label: 'ໄມລ (odometer, ບໍ່ບັງຄັບ)',
                prefix: const Icon(Icons.speed, color: AppTheme.textSecondary),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _station,
              style: const TextStyle(color: AppTheme.textPrimary),
              decoration: _decoration(
                label: 'ສະຖານີ (ບໍ່ບັງຄັບ)',
                prefix: const Icon(
                  Icons.store,
                  color: AppTheme.textSecondary,
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _note,
              maxLines: 2,
              style: const TextStyle(color: AppTheme.textPrimary),
              decoration: _decoration(
                label: 'ໝາຍເຫດ (ບໍ່ບັງຄັບ)',
                prefix: const Icon(
                  Icons.notes,
                  color: AppTheme.textSecondary,
                ),
              ),
            ),
            const SizedBox(height: 8),
            if (_position != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    const Icon(
                      Icons.gps_fixed,
                      size: 14,
                      color: AppTheme.success,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'GPS: ${_position!.latitude.toStringAsFixed(5)}, ${_position!.longitude.toStringAsFixed(5)}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _submitting ? null : _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                ),
              ),
              child: _submitting
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.5,
                        color: Colors.white,
                      ),
                    )
                  : const Text(
                      'ບັນທຶກ',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _carSelector() {
    final isManual = _selectedCar == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(
              Icons.local_shipping_rounded,
              size: 14,
              color: AppTheme.info,
            ),
            const SizedBox(width: 6),
            const Text(
              'ລົດ',
              style: TextStyle(
                color: AppTheme.textBright,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(width: 8),
            if (_selectedCar != null &&
                _availableCars.isNotEmpty &&
                _selectedCar == _availableCars.first)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: AppTheme.success.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  'ກຳລັງຂັບ',
                  style: TextStyle(
                    color: AppTheme.success,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            if (_loadingCars) ...[
              const SizedBox(width: 8),
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: AppTheme.textMuted,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in _availableCars) _carChip(c, selected: _selectedCar == c),
            _carChip(
              'ຄັນອື່ນ…',
              selected: isManual,
              isOther: true,
            ),
          ],
        ),
        if (isManual) ...[
          const SizedBox(height: 10),
          TextFormField(
            controller: _customCar,
            style: const TextStyle(color: AppTheme.textPrimary),
            onChanged: (_) => setState(() {}),
            decoration: _decoration(
              label: 'ໃສ່ປ້າຍລົດ',
              prefix: const Icon(
                Icons.edit_rounded,
                color: AppTheme.textSecondary,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _carChip(
    String label, {
    required bool selected,
    bool isOther = false,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      onTap: () => setState(() {
        _selectedCar = isOther ? null : label;
      }),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.primary.withValues(alpha: 0.18)
              : AppTheme.bgSurface,
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
          border: Border.all(
            color: selected ? AppTheme.primary : AppTheme.surfaceBorder,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isOther ? Icons.edit_rounded : Icons.local_shipping_rounded,
              size: 14,
              color: selected ? AppTheme.primary : AppTheme.textSecondary,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: selected ? AppTheme.primary : AppTheme.textBright,
                fontSize: 12,
                fontWeight: selected ? FontWeight.w900 : FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _photoCard() {
    return GestureDetector(
      onTap: _submitting ? null : _showPhotoSheet,
      child: Container(
        height: 200,
        decoration: BoxDecoration(
          color: AppTheme.bgSurface,
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          border: Border.all(color: AppTheme.surfaceBorder),
        ),
        clipBehavior: Clip.antiAlias,
        child: _imageBytes == null
            ? const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.add_a_photo_outlined,
                      size: 40,
                      color: AppTheme.textSecondary,
                    ),
                    SizedBox(height: 8),
                    Text(
                      'ກົດເພື່ອຖ່າຍ/ເລືອກຮູບ',
                      style: TextStyle(color: AppTheme.textSecondary),
                    ),
                  ],
                ),
              )
            : Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(_imageBytes!, fit: BoxFit.cover),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Material(
                      color: Colors.black.withValues(alpha: 0.5),
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => setState(() {
                          _imageBytes = null;
                          _imageDataUri = null;
                        }),
                        child: const Padding(
                          padding: EdgeInsets.all(6),
                          child: Icon(
                            Icons.close,
                            color: Colors.white,
                            size: 18,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

