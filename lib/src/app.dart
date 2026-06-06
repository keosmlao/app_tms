import 'package:flutter/material.dart';

import 'app_controller.dart';
import 'core/app_config.dart';
import 'core/app_theme.dart';
import 'screens/home_shell.dart';
import 'screens/login_screen.dart';
import 'screens/supervisor_dashboard_screen.dart';
import 'screens/update_required_screen.dart';
import 'services/location_tracking_service.dart';

class TmsApp extends StatelessWidget {
  const TmsApp({super.key, required this.controller});

  final AppController controller;
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConfig.appName,
      debugShowCheckedModeBanner: false,
      navigatorKey: LocationTrackingService.navigatorKey,
      theme: AppTheme.lightTheme,
      home: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          if (!controller.isReady) return const _SplashScreen();
          // A forced update blocks everything — authed or not.
          if (controller.mustUpdate) {
            return UpdateRequiredScreen(info: controller.appUpdate!);
          }
          if (!controller.isAuthenticated) {
            return LoginScreen(controller: controller);
          }
          return controller.user?.isOperationsUser == true
              ? SupervisorDashboardScreen(controller: controller)
              : HomeShell(controller: controller);
        },
      ),
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgDark,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: AppTheme.primary,
                borderRadius: BorderRadius.circular(AppTheme.radiusLg),
              ),
              child: const Icon(
                Icons.local_shipping_rounded,
                color: AppTheme.bgDark,
                size: 36,
              ),
            ),
            const SizedBox(height: 22),
            const Text(
              'ODG TMS',
              style: TextStyle(
                color: AppTheme.textBright,
                fontSize: 26,
                fontWeight: FontWeight.w800,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'ລະບົບຈັດສົ່ງສິນຄ້າ',
              style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
            ),
            const SizedBox(height: 40),
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: AppTheme.primary.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
