import '../../core/voice/voice_coach.dart';
import 'precheck.dart';
import 'repetitions.dart';

/// Says aloud what the session screen shows, so a patient standing back from
/// the camera does not have to read it: where to stand, the instructions,
/// each repetition's count and correction, and when to stop.
///
/// It adds nothing of its own to the feedback. Every correction it speaks is
/// the server's message for a repetition the server has stored and judged.
class SessionNarrator {
  SessionNarrator(this._coach, {required bool Function() muted})
    : _muted = muted;

  final VoiceCoach _coach;
  final bool Function() _muted;

  /// How long before the same guidance is said again, in milliseconds.
  static const repeatGuidanceMs = 7000;

  /// The same correction on repetition after repetition is said the first
  /// time and then on every third, so it stays a reminder, not a drone.
  static const repeatCorrectionEvery = 3;

  String? _guidance;
  double _guidanceAt = 0;
  String? _correction;
  int _sameCorrection = 0;
  FeedbackTier? _lastTier;

  void _say(
    String text, {
    Urgency urgency = Urgency.background,
    CoachTone? tone,
  }) {
    if (_muted()) return;
    _coach.say(text, urgency: urgency, tone: tone);
  }

  /// Where to stand or what to fix about the setup, from the camera check
  /// and whenever the patient drifts out of view. Null when all is well.
  /// [nowMs] is the camera's clock.
  void guidance(String? text, double nowMs) {
    if (text == null) {
      // Said afresh the next time it is needed.
      _guidance = null;
      return;
    }
    if (text == _guidance && nowMs - _guidanceAt < repeatGuidanceMs) return;
    _guidance = text;
    _guidanceAt = nowMs;
    _say(text);
  }

  /// The camera check has passed and the session exists.
  void started(PrecheckRequirements requirements) {
    _guidance = null;
    final sets = requirements.sets == 1 ? '1 set' : '${requirements.sets} sets';
    _say(
      'You are all set. ${requirements.exercise.name}: $sets of '
      '${requirements.reps}. ${requirements.exercise.instructions} '
      'Start when you are ready.',
    );
  }

  /// One repetition the server has stored: its count, then what the server
  /// made of it, then the end of the set when this was its last one.
  void repetition(
    RecordedRepetition stored, {
    required PrecheckRequirements requirements,
  }) {
    final pause = stored.pause;
    if (pause != null) {
      _correction = null;
      _lastTier = stored.tier;
      _say(
        'Stop. ${pause.message} Your session is paused. Read the message '
        'on the screen and confirm before you continue.',
        urgency: Urgency.urgent,
        tone: CoachTone.red,
      );
      return;
    }

    final parts = <String>['${stored.repNumber}.'];
    CoachTone? tone;
    final message = stored.feedback.firstOrNull?.message;
    if (stored.tier == FeedbackTier.ok || message == null) {
      // Praise after a correction says the correction worked; on every
      // repetition it would only be noise.
      if (_lastTier != null && _lastTier != FeedbackTier.ok) parts.add('Good.');
      _correction = null;
      _sameCorrection = 0;
    } else {
      _sameCorrection = message == _correction ? _sameCorrection + 1 : 0;
      _correction = message;
      final serious = stored.tier != FeedbackTier.info;
      if (serious) tone = CoachTone.amber;
      if (serious || _sameCorrection % repeatCorrectionEvery == 0) {
        parts.add(message);
      }
    }
    _lastTier = stored.tier;

    if (stored.repNumber >= requirements.reps) {
      tone ??= CoachTone.done;
      if (stored.setNumber < requirements.sets) {
        final rest = requirements.restSeconds > 0
            ? 'Rest for ${requirements.restSeconds} seconds, then start '
            : 'Start ';
        parts.add(
          'Set ${stored.setNumber} complete. ${rest}set '
          '${stored.setNumber + 1}.',
        );
      } else {
        parts.add(
          'All sets complete. Well done. End the session to see your '
          'summary.',
        );
      }
    }
    _say(parts.join(' '), urgency: Urgency.repetition, tone: tone);
  }

  /// The patient has confirmed the safety message and the session carries on.
  void resumed() {
    _lastTier = null;
    _say(
      'Thank you. Return to your starting position and continue when you '
      'are ready.',
    );
  }

  /// The session has ended: what it came to.
  void finished(ExerciseSession ended) {
    final summary = ended.summary;
    final count = (summary?.totals ?? ended.totals).repetitions;
    final score = summary?.formScore;
    _coach.stop();
    _say(
      [
        'Session complete.',
        if (count > 0) count == 1 ? '1 repetition.' : '$count repetitions.',
        if (score != null) 'Your form score is $score out of 100.',
      ].join(' '),
      tone: CoachTone.done,
    );
  }

  /// Stops talking: the coach was switched off or the screen was left.
  void silence() {
    _guidance = null;
    _coach.stop();
  }
}
