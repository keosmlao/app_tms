abstract final class AppConfig {
  static const String appName = 'odg_tms';
  static const String defaultBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://tms.odienmall.com',
  );
  static const Duration requestTimeout = Duration(seconds: 30);
}
