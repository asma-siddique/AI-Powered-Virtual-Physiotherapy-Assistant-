import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'desktop_alerts_stub.dart'
    if (dart.library.js_interop) 'desktop_alerts_web.dart'
    as platform;

/// Whether the device will show an alert from the app.
enum AlertPermission {
  granted,
  denied,

  /// Not asked yet.
  undecided,

  /// This device or browser cannot show them.
  unsupported;

  static AlertPermission fromBrowser(String value) => switch (value) {
    'granted' => granted,
    'denied' => denied,
    'default' => undecided,
    _ => unsupported,
  };
}

/// Notifications from the device itself (US 6.1, 6.2): shown when something
/// new arrives while the app is open, so a reminder is noticed even when the
/// app is in another tab. They are not push messages: nothing arrives while
/// the app is closed.
abstract class DesktopAlerts {
  AlertPermission get permission;

  /// Asks the person. Must be called from a tap.
  Future<AlertPermission> request();

  /// Shows one alert; [id] stops the same one appearing twice.
  void show({
    required String id,
    required String title,
    required String body,
    String? link,
  });

  /// Called with an alert's link when the person clicks it.
  set onOpen(void Function(String? link)? handler);
}

final desktopAlertsProvider = Provider<DesktopAlerts>(
  (ref) => platform.createDesktopAlerts(),
);
