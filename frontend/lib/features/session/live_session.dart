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
    this.series,
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

  /// Set when a trained model scores the session: every frame of a
  /// repetition is then kept, measured the way the model was trained.
  final SeriesSpec? series;

  final RepCounter? _counter;
  final _worst = <String, double>{};

  /// One entry per frame of the repetition in progress, in the order of
  /// [SeriesSpec.channels].
  final _frames = <List<double?>>[];

  /// The lowest working-joint angle reached during the repetition, for the
  /// depth check: it is judged on the lowest point, not the worst frame.
  double? _lowestDepth;

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

  /// Whether this version can measure a check for this exercise.
  bool _measurable(String key) => isCheckSupported(key, exerciseSlug);

  /// Forgets what was measured during the repetition in progress.
  void _clearRep() {
    _worst.clear();
    _lowestDepth = null;
    _frames.clear();
  }

  /// Keeps what the session's classifier reads from one frame.
  void _keepFrame(PoseFrame frame) {
    final spec = series;
    if (spec == null) return;
    final features = frameFeatures(
      frame.landmarks,
      aspectRatio: aspectRatio,
      exerciseSlug: exerciseSlug,
      targetJoints: spec.joints,
      checkKeys: spec.checks,
      minVisibility: minVisibility,
    );
    _frames.add([
      for (final channel in spec.channels)
        features.jointAngles[channel] ?? features.checks[channel],
    ]);
  }

  /// The repetition's frames as they are sent: all of them, or evenly
  /// thinned to the most the server reads. Null when the session does not
  /// ask for them or there are too few to say anything.
  List<List<double?>>? _framesToSend() {
    final spec = series;
    if (spec == null || _frames.length < 2) return null;
    final count = _frames.length;
    if (count <= spec.maxFrames) return List.of(_frames);
    return [
      for (var i = 0; i < spec.maxFrames; i++)
        _frames[(i * (count - 1) / (spec.maxFrames - 1)).round()],
    ];
  }

  /// What is sent for one check when a repetition ends. Most checks send the
  /// worst value held during it; depth sends how far its lowest point stayed
  /// short of the target. Null when the check was never clearly in view.
  double? _measureOf(String key) {
    if (key != 'depth') return _worst[key];
    final lowest = _lowestDepth;
    return lowest == null ? null : depthShortfall(exerciseSlug, lowest);
  }

  /// Forgets a movement in progress, for example when the session is paused.
  /// Counting starts again once the resting position has been seen.
  void interrupt() {
    _counter?.reset();
    _clearRep();
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
    if (measuring) _keepFrame(frame);

    for (final key in checkKeys) {
      final value = features.checks[key];
      if (value == null || !_measurable(key)) continue;
      final steady = _steady(key, value);
      // Only what happens during the movement itself is held against it.
      if (!measuring) continue;
      if (key == 'depth') {
        final lowest = _lowestDepth;
        if (lowest == null || steady < lowest) _lowestDepth = steady;
        continue;
      }
      final worst = _worst[key];
      if (worst == null || steady > worst) _worst[key] = steady;
    }
    if (!measuring && wasInRep) {
      // The movement was given up half-way or lost from view.
      _clearRep();
    }
    if (rep == null) return null;

    final draft = RepetitionDraft(
      setNumber: _set,
      repNumber: _repsInSet + 1,
      startedMs: rep.startedMs.round(),
      endedMs: rep.endedMs.round(),
      // Every check is accounted for; one that was never in view is null
      // rather than left out or guessed.
      measures: {for (final key in checkKeys) key: _measureOf(key)},
      frames: _framesToSend(),
    );
    _clearRep();
    _repsInSet += 1;
    _counted += 1;
    _rollOver();
    return draft;
  }
}
