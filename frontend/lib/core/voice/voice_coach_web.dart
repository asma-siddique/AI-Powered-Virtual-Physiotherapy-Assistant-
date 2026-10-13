import 'dart:js_interop';

import 'voice_coach.dart';

/// web/voice_bridge.js: the browser's own speech and tones.
@JS('physioVoice')
external _VoiceBridge? get _bridge;

extension type _VoiceBridge._(JSObject _) implements JSObject {
  external JSBoolean supported();
  external void say(JSString text, JSNumber priority, JSString? tone);
  external void stop();
}

VoiceCoach createVoiceCoach() => const _BrowserCoach();

class _BrowserCoach implements VoiceCoach {
  const _BrowserCoach();

  @override
  bool get supported => _bridge?.supported().toDart ?? false;

  @override
  void say(
    String text, {
    Urgency urgency = Urgency.background,
    CoachTone? tone,
  }) => _bridge?.say(text.toJS, urgency.index.toJS, tone?.name.toJS);

  @override
  void stop() => _bridge?.stop();
}
