import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_theme.dart';
import '../models/app_update_info.dart';

/// Full-screen, non-dismissable gate shown when the backend forces an update.
/// The driver can't get past it without updating — back navigation is blocked.
class UpdateRequiredScreen extends StatelessWidget {
  const UpdateRequiredScreen({super.key, required this.info});

  final AppUpdateInfo info;

  Future<void> _openStore(BuildContext context) async {
    final url = info.updateUrl.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('ຍັງບໍ່ໄດ້ຕັ້ງລິ້ງອັບເດດ — ກະລຸນາຕິດຕໍ່ admin'),
        ),
      );
      return;
    }
    final uri = Uri.tryParse(url);
    final ok = uri != null &&
        await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ເປີດລິ້ງອັບເດດບໍ່ສຳເລັດ')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    // PopScope(canPop: false) — the user cannot dismiss this screen.
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: AppTheme.bgDark,
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(AppTheme.space6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 84,
                    height: 84,
                    decoration: BoxDecoration(
                      color: AppTheme.primary,
                      borderRadius: BorderRadius.circular(AppTheme.radiusXl),
                    ),
                    child: const Icon(
                      Icons.system_update_rounded,
                      color: AppTheme.bgDark,
                      size: 44,
                    ),
                  ),
                  const SizedBox(height: AppTheme.space6),
                  const Text(
                    'ມີເວີຊັນໃໝ່',
                    style: TextStyle(
                      color: AppTheme.textBright,
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: AppTheme.space3),
                  const Text(
                    'ກະລຸນາອັບເດດແອັບເປັນເວີຊັນຫຼ້າສຸດ\nເພື່ອສືບຕໍ່ການໃຊ້ງານ',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 14,
                      height: 1.5,
                    ),
                  ),
                  if (info.minVersion.isNotEmpty ||
                      info.currentVersion.isNotEmpty) ...[
                    const SizedBox(height: AppTheme.space5),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppTheme.space4,
                        vertical: AppTheme.space3,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.bgCard,
                        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                        border: Border.all(color: AppTheme.surfaceBorder),
                      ),
                      child: Text(
                        'ເວີຊັນປັດຈຸບັນ: ${info.currentVersion.isEmpty ? '-' : info.currentVersion}'
                        '   •   ຕ້ອງການ: ${info.minVersion.isEmpty ? '-' : info.minVersion}',
                        style: const TextStyle(
                          color: AppTheme.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: AppTheme.space8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.primary,
                        foregroundColor: AppTheme.bgDark,
                        padding: const EdgeInsets.symmetric(
                          vertical: AppTheme.space4,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(AppTheme.radiusLg),
                        ),
                      ),
                      onPressed: () => _openStore(context),
                      icon: const Icon(Icons.download_rounded),
                      label: const Text(
                        'ອັບເດດດຽວນີ້',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
