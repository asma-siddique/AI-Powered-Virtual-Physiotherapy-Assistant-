import 'desktop_alerts.dart';

DesktopAlerts createDesktopAlerts() => _NoAlerts();

/// Outside the browser there are no desktop alerts yet.
class _NoAlerts implements DesktopAlerts {
  @override
  AlertPermission get permission => AlertPermission.unsupported;

  @override
  Future<AlertPermission> request() async => AlertPermission.unsupported;

  @override
  void show({
    required String id,
    required String title,
    required String body,
    String? link,
  }) {}

  @override
  set onOpen(void Function(String? link)? handler) {}
}
