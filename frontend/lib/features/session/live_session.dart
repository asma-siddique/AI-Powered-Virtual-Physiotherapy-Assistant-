import 'pose/pose_features.dart';
import 'pose/pose_models.dart';
import 'rep_counter.dart';
import 'repetitions.dart';

/// Turns the camera's frames into counted repetitions during a session
/// (US 3.2 to 3.4): it measures each frame, follows the movement, and when a
/// repetition is complete hands back what was measured during it.
///
/// It decides nothing about how good a repetition was. That is the server's
/// job, from the measurements this produces.
class LiveSessionEngine {
  LiveSessionEngine({
    required this.exerciseSlug,
    required this.targetJoints,
    required List<String> checkKeys,
    required this.sets,
    required this.repsPerSet,
    required this.minVisibility,
    required this.aspectRatio,
  }) : checkKeys = List.unmodifiable(checkKeys),
       _counter = repProfiles[exerciseSlug] == null
           ? null
           : RepCounter(repProfiles[exerciseSlug]!);

  final String exerciseSlug;
  final List<String> targetJoints;
  final List<String> checkKeys;

  /// The prescription this session started with.
  final int sets;
  final int repsPerSet;
  final double minVisibility;

  /// Width over height of the camera picture; angles are skewed without it.
  final double aspectRatio;

  final RepCounter? _counter;
  final _worst = <String, double>{};

  /// The last three values seen for each check, so one wild camera frame
  /// cannot become the "worst" of a repetition and pause a session by itself.
  final _recent = <String, List<double>>{};
  int _set = 1;
  int _repsInSet = 0;
  int _counted = 0;

  /// False for an exercise whose repetitions this version cannot recognise.
  bool get canCount => _counter != null;

  /// The set the next repetition belongs to, from 1.
  int get currentSet => _set;

  /// Repetitions counted so far in the current set.
  int get repsInSet => _repsInSet;

  /// Repetitions counted in the whole session.
  int get counted => _counted;

  /// True once every prescribed set has all its repetitions.
  bool get prescriptionDone => _set > sets;

  /// Whether a check's value can be judged as "the worst seen during the
  /// repetition". Depth is the one that cannot: it is about the lowest point
  /// reached, which needs its own rule and is not built yet.
  bool _measurable(String key) =>
      key != 'depth' && isCheckSupported(key, exerciseSlug);

  /// Forgets a movement in progress, for example when the session is paused.
  /// Counting starts again once the resting position has been seen.
  void interrupt() {
    _counter?.reset();
    _worst.clear();
    _recent.clear();
  }

  /// The middle of the last three values of a check: what it has held for
  /// more than a single frame.
  double _steady(String key, double value) {
    final recent = _recent.putIfAbsent(key, () => []);
    recent.add(value);
    if (recent.length > 3) recent.removeAt(0);
    if (recent.length < 3) return value;
    final sorted = [...recent]..sort();
    return sorted[1];
  }

  /// Puts the count back to just after [repNumber] of [setNumber]. Used when
  /// the server paused the session on that repetition, so anything counted
  /// after it was never part of the session.
  void rewindTo({required int setNumber, required int repNumber}) =>
      rewindToCount((setNumber - 1) * repsPerSet + repNumber);

  /// Puts the count back to [stored] repetitions, the number the server holds.
  void rewindToCount(int stored) {
    _counted = stored;
    _set = stored ~/ repsPerSet + 1;
    _repsInSet = stored % repsPerSet;
    interrupt();
  }

  void _rollOver() {
    if (_repsInSet >= repsPerSet) {
      _set += 1;
      _repsInSet = 0;
    }
  }

  /// Takes one camera frame. [sessionMs] is the time since the session
  /// started. Returns a repetition when this frame completes one.
  RepetitionDraft? add(PoseFrame frame, double sessionMs) {
    final counter = _counter;
    if (counter == null || prescriptionDone) return null;

    final features = frameFeatures(
      frame.landmarks,
      aspectRatio: aspectRatio,
      exerciseSlug: exerciseSlug,
      targetJoints: targetJoints,
      checkKeys: checkKeys,
      minVisibility: minVisibility,
    );
    final profile = counter.profile;
    final angle = profile.signal(
      features.jointAngles['left_${profile.joint}'],
      features.jointAngles['right_${profile.joint}'],
    );
    final wasInRep = counter.inRep;
    final rep = counter.add(sessionMs, angle);
    final measuring = counter.inRep || rep != null;

    for (final key in checkKeys) {
      final value = features.checks[key];
      if (value == null || !_measurable(key)) continue;
      final steady = _steady(key, value);
      // Only what happens during the movement itself is held against it.
      if (!measuring) continue;
      final worst = _worst[key];
      if (worst == null || steady > worst) _worst[key] = steady;
    }
    if (!measuring && wasInRep) {
      // The movement was given up half-way or lost from view.
      _worst.clear();
    }
    if (rep == null) return null;

    final draft = RepetitionDraft(
      setNumber: _set,
      repNumber: _repsInSet + 1,
      startedMs: rep.startedMs.round(),
      endedMs: rep.endedMs.round(),
      // Every check is accounted for; one that was never in view is null
      // rather than left out or guessed.
      measures: {for (final key in checkKeys) key: _worst[key]},
    );
    _worst.clear();
    _repsInSet += 1;
    _counted += 1;
    _rollOver();
    return draft;
  }
}
