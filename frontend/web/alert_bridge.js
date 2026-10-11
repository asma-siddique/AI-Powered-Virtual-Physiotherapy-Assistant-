// Desktop alerts for PhysioAI's web app: a notification from the browser
// when something new arrives while the app is open in a tab, such as a
// session reminder or a flagged session.
//
// These are the browser's own notifications, shown by this page. They are not
// push messages: nothing arrives while the app is closed.
//
// The Dart side is lib/core/alerts/desktop_alerts_web.dart.

let opened = null;

window.physioAlerts = {
  // "granted", "denied", "default" (not asked yet) or "unsupported".
  permission() {
    return 'Notification' in window ? Notification.permission : 'unsupported';
  },

  // Asks the person; must be called from a click.
  async request() {
    if (!('Notification' in window)) return 'unsupported';
    try {
      return await Notification.requestPermission();
    } catch (_) {
      return Notification.permission;
    }
  },

  // Shows one alert. The tag makes the same notification replace itself
  // rather than appear twice.
  show(title, body, link, tag) {
    if (!('Notification' in window) || Notification.permission !== 'granted') {
      return false;
    }
    try {
      const alert = new Notification(title, {
        body,
        tag,
        icon: 'icons/Icon-192.png',
      });
      alert.onclick = () => {
        window.focus();
        alert.close();
        if (opened) opened(link || '');
      };
      return true;
    } catch (_) {
      return false;
    }
  },

  // Called with the alert's link when the person clicks it.
  onOpen(callback) {
    opened = callback;
  },
};
