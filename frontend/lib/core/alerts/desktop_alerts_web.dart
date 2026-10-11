import 'dart:js_interop';

import 'desktop_alerts.dart';

/// web/alert_bridge.js: the browser's own notifications.
@JS('physioAlerts')
external _AlertBridge? get _bridge;

extension type _AlertBridge._(JSObject _) implements JSObject {
  external JSString permission();
  external JSPromise<JSString> request();
  external JSBoolean show(
    JSString title,
    JSString body,
    JSString link,
    JSString tag,
  );
  external void onOpen(JSFunction? callback);
}

DesktopAlerts createDesktopAlerts() => _WebAlerts();

class _WebAlerts implements DesktopAlerts {
  @override
  AlertPermission get permission {
    final bridge = _bridge;
    return bridge == null
        ? AlertPermission.unsupported
        : AlertPermission.fromBrowser(bridge.permission().toDart);
  }

  @override
  Future<AlertPermission> request() async {
    final bridge = _bridge;
    if (bridge == null) return AlertPermission.unsupported;
    try {
      return AlertPermission.fromBrowser(
        (await bridge.request().toDart).toDart,
      );
    } catch (_) {
      return permission;
    }
  }

  @override
  void show({
    required String id,
    required String title,
    required String body,
    String? link,
  }) {
    _bridge?.show(title.toJS, body.toJS, (link ?? '').toJS, id.toJS);
  }

  @override
  set onOpen(void Function(String? link)? handler) {
    _bridge?.onOpen(
      handler == null
          ? null
          : ((JSString link) {
              final value = link.toDart;
              handler(value.isEmpty ? null : value);
            }).toJS,
    );
  }
}
