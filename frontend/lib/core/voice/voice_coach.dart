import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'voice_coach_stub.dart'
    if (dart.library.js_interop) 'voice_coach_web.dart'
    as platform;

/// A short sound played before a line, so the patient knows what kind of
/// thing they are about to hear without looking at the screen.
enum CoachTone {
  /// Two short beeps: something to correct, carry on.
  amber,

  /// An alarm: stop.
  red,

  /// A rising chime: a set or the session is complete.
  done,
}

/// How important a spoken line is. A more important line cuts off a less
/// important one; otherwise a line waits its turn.
enum Urgency {
  /// Instructions and where to stand.
  background,

  /// A repetition's count and correction.
  repetition,

  /// The safety stop.
  urgent,
}

/// Reads guidance aloud and sounds alert tones during a session, so a
/// patient standing back from the screen does not have to read it. It only
/// ever says what the app already shows; it decides nothing.
abstract class VoiceCoach {
  /// False where the device cannot speak; nothing is said there.
  bool get supported;

  /// Says [text], after [tone] when one is given.
  void say(
    String text, {
    Urgency urgency = Urgency.background,
    CoachTone? tone,
  });

  /// Stops talking at once and forgets anything waiting to be said.
  void stop();
}

final voiceCoachProvider = Provider<VoiceCoach>(
  (ref) => platform.createVoiceCoach(),
);

/// The patient has switched the spoken coach off. Kept while the app is open.
final voiceMutedProvider = StateProvider<bool>((ref) => false);
