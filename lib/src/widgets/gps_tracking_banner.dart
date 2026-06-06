import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../services/location_tracking_service.dart';

/// Small in-app banner that mirrors [LocationTrackingService.state]:
///   * active         → reassures the driver GPS is being sent
///   * needsPermission → prompts opening app settings to grant location
///   * gpsOff          → prompts turning the device GPS on
///   * off            → hidden (no active trip)
///
/// Drop it near the top of the home + job-detail screens.
class GpsTrackingBanner extends StatelessWidget {
  const GpsTrackingBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<TrackingState>(
      valueListenable: LocationTrackingService.instance.state,
      builder: (context, st, _) {
        switch (st) {
          case TrackingState.off:
            return const SizedBox.shrink();
          case TrackingState.active:
            return const _Banner(
              color: AppTheme.success,
              icon: Icons.gps_fixed_rounded,
              text: 'ກຳລັງສົ່ງຕຳແໜ່ງ GPS',
            );
          case TrackingState.needsPermission:
            return _Banner(
              color: AppTheme.error,
              icon: Icons.location_disabled_rounded,
              text: 'GPS ບໍ່ມີສິດ — ກົດເພື່ອເປີດ "ອະນຸຍາດຕະຫຼອດເວລາ"',
              onTap: LocationTrackingService.instance.openAppPermissionSettings,
            );
          case TrackingState.gpsOff:
            return _Banner(
              color: AppTheme.warning,
              icon: Icons.gps_off_rounded,
              text: 'GPS ປິດ — ກົດເພື່ອເປີດ',
              onTap: LocationTrackingService.instance.openLocationSettings,
            );
        }
      },
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.color,
    required this.icon,
    required this.text,
    this.onTap,
  });

  final Color color;
  final IconData icon;
  final String text;
  final Future<void> Function()? onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Material(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap == null ? null : () => onTap!(),
          borderRadius: BorderRadius.circular(10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: color.withValues(alpha: 0.35)),
            ),
            child: Row(
              children: [
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    text,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: color,
                    ),
                  ),
                ),
                if (onTap != null)
                  Icon(Icons.chevron_right_rounded, size: 18, color: color),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
