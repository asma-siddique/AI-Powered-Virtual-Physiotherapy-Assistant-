/// How one exercise's repetitions are recognised (US 3.3): which joint's
/// angle follows the movement, and the angles that mark its two ends.
///
/// The numbers are starting values chosen from how each movement looks to the
/// camera. Like the severity thresholds, they have not been derived from the
/// REHAB24-6 recordings or clinically reviewed yet.
class RepProfile {
  const RepProfile({
    required this.joint,
    required this.rest,
    required this.peak,
  }) : assert(rest != peak);

  /// The target joint whose angle rises and falls with each repetition.
  final String joint;

  /// The angle at the resting end of the movement. A repetition begins when
  /// the angle leaves this end and is counted when it comes back.
  final double rest;

  /// The angle the movement has to reach to count as a repetition.
  final double peak;

  /// True when the angle grows towards the peak (an arm being raised), false
  /// when it shrinks (a knee bending).
  bool get rising => peak > rest;

  /// The side to follow when both are in view: the one further into the
  /// movement.
  double? signal(double? left, double? right) {
    if (left == null) return right;
    if (right == null) return left;
    return rising
        ? (left > right ? left : right)
        : (left < right ? left : right);
  }
}

/// The exercises whose repetitions can be counted, by the exercise's slug.
const repProfiles = <String, RepProfile>{
  // Hip-shoulder-elbow: about 15 with the arm by the side, 90 at shoulder height.
  'arm-abduction': RepProfile(joint: 'shoulder', rest: 30, peak: 70),
  // Hip-knee-ankle: 180 standing, about 90 at the bottom of a squat.
  'squats': RepProfile(joint: 'knee', rest: 160, peak: 115),
};

/// One counted repetition: when the movement left the resting position and
/// when it returned, on the camera's clock.
typedef CountedRep = ({double startedMs, double endedMs});

enum _Phase {
  /// Not yet seen at rest, so nothing can be counted.
  unknown,
  resting,

  /// Left the resting end, has not reached the peak.
  leaving,

  /// Reached the peak; waiting for the return.
  returning,
}

/// Counts repetitions from a joint angle, one for each full cycle: away from
/// the resting position, all the way to the peak, and back.
///
/// It cannot count the same movement twice, because a count needs the angle
/// to cross the whole gap between [RepProfile.rest] and [RepProfile.peak] in
/// both directions, and it does not drop a slow one, because there is no time
/// limit on a repetition. A brief wobble or one bad camera frame is removed
/// before the angle is judged.
class RepCounter {
  RepCounter(this.profile);

  final RepProfile profile;

  /// A repetition faster than this is a camera glitch, not a movement.
  static const minRepMs = 400.0;

  /// After this long without seeing the joint, a movement in progress is
  /// forgotten: what happened out of view is not guessed.
  static const lostAfterMs = 1500.0;

  var _phase = _Phase.unknown;
  final _recent = <double>[];
  double? _lastSeenMs;
  double _startedMs = 0;

  /// True from the moment the movement leaves the resting position until it
  /// is back there.
  bool get inRep => _phase == _Phase.leaving || _phase == _Phase.returning;

  /// Forgets any movement in progress. The next repetition is counted only
  /// after the resting position has been seen again.
  void reset() {
    _phase = _Phase.unknown;
    _recent.clear();
    _lastSeenMs = null;
  }

  bool _atRest(double angle) =>
      profile.rising ? angle <= profile.rest : angle >= profile.rest;

  bool _atPeak(double angle) =>
      profile.rising ? angle >= profile.peak : angle <= profile.peak;

  /// The middle of the last three angles: one wild frame changes nothing.
  double _steady(double angle) {
    _recent.add(angle);
    if (_recent.length > 3) _recent.removeAt(0);
    if (_recent.length < 3) return angle;
    final sorted = [..._recent]..sort();
    return sorted[1];
  }

  /// Takes the joint's angle at one moment (null when it is not clearly in
  /// view) and returns a repetition when this moment completes one.
  CountedRep? add(double timeMs, double? angle) {
    if (angle == null) {
      final last = _lastSeenMs;
      if (last != null && timeMs - last > lostAfterMs) reset();
      return null;
    }
    final last = _lastSeenMs;
    if (last != null && timeMs - last > lostAfterMs) reset();
    _lastSeenMs = timeMs;
    final steady = _steady(angle);

    switch (_phase) {
      case _Phase.unknown:
        if (_atRest(steady)) _phase = _Phase.resting;
      case _Phase.resting:
        if (!_atRest(steady)) {
          _phase = _Phase.leaving;
          _startedMs = timeMs;
        }
      case _Phase.leaving:
        if (_atPeak(steady)) {
          _phase = _Phase.returning;
        } else if (_atRest(steady)) {
          // Came back without reaching the peak: not a repetition.
          _phase = _Phase.resting;
        }
      case _Phase.returning:
        if (_atRest(steady)) {
          _phase = _Phase.resting;
          if (timeMs - _startedMs >= minRepMs) {
            return (startedMs: _startedMs, endedMs: timeMs);
          }
        }
    }
    return null;
  }
}
