import 'voice_coach.dart';

/// Outside the browser the app cannot speak yet.
VoiceCoach createVoiceCoach() => const _SilentCoach();

class _SilentCoach implements VoiceCoach {
  const _SilentCoach();

  @override
  bool get supported => false;

  @override
  void say(
    String text, {
    Urgency urgency = Urgency.background,
    CoachTone? tone,
  }) {}

  @override
  void stop() {}
}
