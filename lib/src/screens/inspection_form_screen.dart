import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../core/app_theme.dart';
import '../models/inspection.dart';
import '../services/api_client.dart';

/// Driver fills out the vehicle inspection checklist and submits for approval.
class InspectionFormScreen extends StatefulWidget {
  const InspectionFormScreen({super.key, required this.controller});

  final AppController controller;

  @override
  State<InspectionFormScreen> createState() => _InspectionFormScreenState();
}

class _InspectionFormScreenState extends State<InspectionFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _odometerCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  final _customCarCtrl = TextEditingController();

  // Car selector
  List<DriverCar> _availableCars = const [];
  DriverCar? _selectedCar;
  bool _loadingCars = true;

  // Inspection meta
  InspectMeta? _meta;
  bool _loadingMeta = true;
  String? _metaError;

  // item_code → selected status_code
  final Map<String, int?> _selections = {};

  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _loadCars();
    _loadMeta();
  }

  @override
  void dispose() {
    _odometerCtrl.dispose();
    _noteCtrl.dispose();
    _customCarCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadCars() async {
    final user = widget.controller.user;
    if (user == null) {
      setState(() => _loadingCars = false);
      return;
    }
    try {
      final cars = await widget.controller.api.getDriverCars(driverId: user.driverId);
      if (!mounted) return;
      setState(() {
        _availableCars = cars;
        _selectedCar = cars.isNotEmpty ? cars.first : null;
        _loadingCars = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingCars = false);
      _showSnack(
        'ດຶງຂໍ້ມູນລົດບໍ່ໄດ້: ${e is ApiException ? e.message : "$e"}',
        isError: true,
      );
    }
  }

  Future<void> _loadMeta() async {
    setState(() {
      _loadingMeta = true;
      _metaError = null;
    });
    try {
      final meta = await widget.controller.api.getInspectMeta();
      if (!mounted) return;
      setState(() {
        _meta = meta;
        _loadingMeta = false;
        for (final item in meta.items) {
          _selections[item.itemCode] = meta.statuses.isNotEmpty
              ? meta.statuses.first.statusCode
              : 0;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingMeta = false;
        _metaError = e is ApiException ? e.message : '$e';
      });
    }
  }

  String? get _carValue {
    if (_selectedCar != null) return _selectedCar!.code;
    final m = _customCarCtrl.text.trim();
    return m.isEmpty ? null : m;
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_meta == null) return;
    if (_submitting) return;

    final car = _carValue;
    if (car == null || car.isEmpty) {
      _showSnack('ກະລຸນາເລືອກລົດ', isError: true);
      return;
    }

    final unselected =
        _meta!.items.where((i) => _selections[i.itemCode] == null).toList();
    if (unselected.isNotEmpty) {
      _showSnack('ກະລຸນາເລືອກສະຖານະສຳລັບທຸກລາຍການ', isError: true);
      return;
    }

    setState(() => _submitting = true);
    try {
      final now = DateTime.now();
      final date =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final time =
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

      final details = _meta!.items
          .map((item) => {
                'item_code': item.itemCode,
                'status_code': _selections[item.itemCode]!,
              })
          .toList();

      final odoText = _odometerCtrl.text.trim();

      await widget.controller.api.submitInspection(
        vehicleCode: car,
        inspectDate: date,
        inspectTime: time,
        odometer: odoText.isNotEmpty ? double.tryParse(odoText) : null,
        note: _noteCtrl.text.trim(),
        details: details,
      );

      if (!mounted) return;
      _showSnack('ສົ່ງສຳເລັດ — ລໍຖ້າຫົວໜ້າອານຸມັດ',
          isError: false);
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      _showSnack(e is ApiException ? e.message : '$e', isError: true);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _showSnack(String msg, {required bool isError}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? AppTheme.error : AppTheme.success,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  InputDecoration _deco({
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
        borderSide: const BorderSide(color: AppTheme.surfaceBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
        borderSide: const BorderSide(color: AppTheme.surfaceBorder),
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
        title: const Text('ກວດສະພາບລົດ'),
        actions: [
          if (_submitting)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
        ],
      ),
      body: _loadingMeta
          ? const Center(child: CircularProgressIndicator())
          : _metaError != null
              ? _errorView()
              : Form(
                  key: _formKey,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _carSelector(),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _odometerCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true),
                        style: const TextStyle(color: AppTheme.textPrimary),
                        decoration: _deco(
                          label: 'ໄມລ໌ (ບໍ່ບັງຄັບ)',
                          prefix: const Icon(Icons.speed_rounded,
                              color: AppTheme.textSecondary),
                          suffixText: 'km',
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                              RegExp(r'[\d.]')),
                        ],
                      ),
                      const SizedBox(height: 20),
                      _checklistSection(),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _noteCtrl,
                        maxLines: 2,
                        style: const TextStyle(color: AppTheme.textPrimary),
                        decoration: _deco(
                          label: 'ໝາຍເຫດ (ບໍ່ບັງຄັບ)',
                          prefix: const Icon(Icons.notes_rounded,
                              color: AppTheme.textSecondary),
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
                            borderRadius:
                                BorderRadius.circular(AppTheme.radiusSm),
                          ),
                        ),
                        child: _submitting
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2.5, color: Colors.white),
                              )
                            : const Text(
                                'ຍືນຍັນສົ່ງກວດ',
                                style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold),
                              ),
                      ),
                    ],
                  ),
                ),
    );
  }

  Widget _errorView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: AppTheme.error, size: 48),
          const SizedBox(height: 12),
          Text(_metaError!,
              style: const TextStyle(color: AppTheme.textSecondary),
              textAlign: TextAlign.center),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _loadMeta,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('ລອງໃໝ່'),
          ),
        ],
      ),
    );
  }

  Widget _carSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.directions_car_rounded,
                size: 14, color: AppTheme.info),
            const SizedBox(width: 6),
            const Text(
              'ລົດ *',
              style: TextStyle(
                color: AppTheme.textBright,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
            if (_loadingCars) ...[
              const SizedBox(width: 8),
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                    strokeWidth: 1.5, color: AppTheme.textMuted),
              ),
            ],
          ],
        ),
        const SizedBox(height: 8),
        // ຖ້າດຶງໄດ້ຈາກ job → ສະແດງ chips (ບໍ່ໃຫ້ໃສ່ຄັນອື່ນ)
        if (_availableCars.isNotEmpty) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _availableCars
                .map((c) => _carChip(c, selected: _selectedCar?.code == c.code))
                .toList(),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const Icon(Icons.info_outline,
                  size: 12, color: AppTheme.textMuted),
              const SizedBox(width: 4),
              Text(
                'ລົດທີ່ assign ກັບທ່ານ${_availableCars.length == 1 ? ' — ເລືອກອັດຕະໂນມັດ' : ''}',
                style: const TextStyle(
                    color: AppTheme.textMuted, fontSize: 10),
              ),
            ],
          ),
        ] else ...[
          // ບໍ່ມີ job → ໃຫ້ໃສ່ຄ້ອຍ
          TextFormField(
            controller: _customCarCtrl,
            style: const TextStyle(color: AppTheme.textPrimary),
            onChanged: (_) => setState(() {}),
            decoration: _deco(
              label: 'ລະຫັດລົດ',
              hint: 'ເຊັ່ນ: LA-1234',
              prefix: const Icon(Icons.directions_car_rounded,
                  color: AppTheme.info),
            ),
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'ກະລຸນາໃສ່ລະຫັດລົດ' : null,
          ),
        ],
      ],
    );
  }

  Widget _carChip(DriverCar car, {required bool selected}) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      onTap: () {
        HapticFeedback.selectionClick();
        setState(() => _selectedCar = car);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.info.withValues(alpha: 0.18)
              : AppTheme.bgSurface,
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
          border: Border.all(
            color: selected ? AppTheme.info : AppTheme.surfaceBorder,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.directions_car_rounded,
              size: 14,
              color: selected ? AppTheme.info : AppTheme.textSecondary,
            ),
            const SizedBox(width: 6),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  car.code,
                  style: TextStyle(
                    color: selected ? AppTheme.info : AppTheme.textBright,
                    fontSize: 12,
                    fontWeight:
                        selected ? FontWeight.w900 : FontWeight.w600,
                  ),
                ),
                if (car.plateNo.isNotEmpty)
                  Text(
                    car.plateNo,
                    style: TextStyle(
                      color: selected
                          ? AppTheme.info.withValues(alpha: 0.8)
                          : AppTheme.textMuted,
                      fontSize: 10,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _checklistSection() {
    final meta = _meta!;
    if (meta.items.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppTheme.bgCard,
          borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          border: Border.all(color: AppTheme.surfaceBorder),
        ),
        child: const Center(
          child: Text('ບໍ່ມີລາຍການກວດ',
              style: TextStyle(color: AppTheme.textMuted)),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(Icons.checklist_rounded,
                size: 14, color: AppTheme.textSecondary),
            SizedBox(width: 6),
            Text(
              'ລາຍການກວດ',
              style: TextStyle(
                color: AppTheme.textBright,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ...meta.items.asMap().entries.map(
              (e) => _checkItem(e.value, meta.statuses, e.key),
            ),
      ],
    );
  }

  Widget _checkItem(
    InspectCheckItem item,
    List<InspectStatusOption> statuses,
    int index,
  ) {
    final selected = _selections[item.itemCode];
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.bgCard,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        border: Border.all(color: AppTheme.surfaceBorder),
      ),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              '${index + 1}',
              style: const TextStyle(
                color: AppTheme.primary,
                fontSize: 10,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              item.itemName,
              style: const TextStyle(
                color: AppTheme.textBright,
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: statuses.map((s) {
              final isSelected = selected == s.statusCode;
              final isPass = s == statuses.first;
              final color =
                  isPass ? AppTheme.success : AppTheme.error;
              return Padding(
                padding: const EdgeInsets.only(left: 6),
                child: GestureDetector(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    setState(
                        () => _selections[item.itemCode] = s.statusCode);
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? color.withValues(alpha: 0.18)
                          : AppTheme.bgSurface,
                      borderRadius:
                          BorderRadius.circular(AppTheme.radiusFull),
                      border: Border.all(
                        color: isSelected
                            ? color
                            : AppTheme.surfaceBorder,
                        width: isSelected ? 1.5 : 1,
                      ),
                    ),
                    child: Text(
                      s.statusName,
                      style: TextStyle(
                        color: isSelected
                            ? color
                            : AppTheme.textMuted,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}
