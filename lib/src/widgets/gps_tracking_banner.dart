import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../services/location_tracking_service.dart';

/// In-app banner that ONLY appears when tracking is *broken* mid-trip — GPS
/// turned off or location permission missing — so the driver is pushed to fix
/// it. Normal operation ([TrackingState.active]) and no-trip ([off]) render
/// nothing: the driver is never shown a "sending GPS" indicator.
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
          // Silent in normal operation — no "sending GPS" reveal.
          case TrackingState.off:
          case TrackingState.active:
            return const SizedBox.shrink();
          case TrackingState.needsPermission:
            return _Banner(
              color: AppTheme.error,
              icon: Icons.location_disabled_rounded,
              text: 'ກະລຸນາເປີດສິດ "ຕຳແໜ່ງ" ເພື່ອສືບຕໍ່ຖ້ຽວ',
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
