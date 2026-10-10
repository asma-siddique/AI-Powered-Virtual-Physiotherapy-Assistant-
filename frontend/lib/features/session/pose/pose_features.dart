// Per-frame joint-angle features for user story 3.2 (SCRUM-53).
//
// The app's live twin of `backend/app/pose_features.py`, which is used for
// model training. Both are held to the shared cases in
// `backend/tests/fixtures/pose_feature_cases.json`, so a change to one without
// the other fails a test. The conventions and the meaning of every value are
// described at the top of the Python module; in short:
//
// * x is multiplied by the picture's aspect ratio before any angle is taken,
//   so angles are not skewed on a non-square camera.
// * A landmark below the visibility threshold is never used; a value that
//   needs it is null rather than guessed.
// * Angles are in degrees. Where both sides are measured and one value is
//   reported, the worse side is taken.
import 'dart:math' as math;

import 'pose_models.dart';

const _sides = ['left', 'right'];

/// Joint name -> the three landmarks (without side prefix) whose middle one is
/// the joint.
const jointTriplets = <String, (String, String, String)>{
  'shoulder': ('hip', 'shoulder', 'elbow'),
  'elbow': ('shoulder', 'elbow', 'wrist'),
  'hip': ('shoulder', 'hip', 'knee'),
  'knee': ('hip', 'knee', 'ankle'),
  'ankle': ('knee', 'ankle', 'foot_index'),
};

/// The working joint whose angle is the "depth" of each exercise.
const depthJoint = <String, String>{'push-ups': 'elbow', 'squats': 'knee'};

/// Everything measured in one frame. A null value means the landmarks it needs
/// were not clearly in view.
class FrameFeatures {
  const FrameFeatures({
    required this.jointAngles,
    required this.checks,
    required this.unsupported,
  });

  /// Inner angle at each target joint, per side: `left_knee`, `right_elbow`...
  final Map<String, double?> jointAngles;

  /// Measurements keyed like the exercise template's checks.
  final Map<String, double?> checks;

  /// Check keys of the template that this version cannot measure.
  final List<String> unsupported;
}

typedef _Point = (double, double);

class _Frame {
  _Frame(this._landmarks, this._aspect, this._minVisibility) {
    if (_aspect <= 0) {
      throw ArgumentError.value(_aspect, 'aspectRatio', 'must be positive');
    }
  }

  final Map<String, Landmark> _landmarks;
  final double _aspect;
  final double _minVisibility;

  _Point? point(String name) {
    final landmark = _landmarks[name];
    if (landmark == null || landmark.visibility < _minVisibility) return null;
    return (landmark.x * _aspect, landmark.y);
  }

  List<_Point>? points(List<String> names) {
    final found = <_Point>[];
    for (final name in names) {
      final p = point(name);
      if (p == null) return null;
      found.add(p);
    }
    return found;
  }
}

double _degrees(double radians) => radians * 180 / math.pi;

double _acosClamped(double cos) => math.acos(cos.clamp(-1.0, 1.0));

/// Inner angle at b between b->a and b->c, 0 to 180.
double? _angleAt(_Point a, _Point b, _Point c) {
  final v1x = a.$1 - b.$1, v1y = a.$2 - b.$2;
  final v2x = c.$1 - b.$1, v2y = c.$2 - b.$2;
  final n1 = math.sqrt(v1x * v1x + v1y * v1y);
  final n2 = math.sqrt(v2x * v2x + v2y * v2y);
  if (n1 == 0 || n2 == 0) return null;
  return _degrees(_acosClamped((v1x * v2x + v1y * v2y) / (n1 * n2)));
}

/// Angle of the segment bottom->top from straight up, 0 to 180.
double? _fromVertical(_Point bottom, _Point top) {
  final dx = top.$1 - bottom.$1, dy = top.$2 - bottom.$2;
  final length = math.sqrt(dx * dx + dy * dy);
  if (length == 0) return null;
  // Up is -y in picture coordinates.
  return _degrees(_acosClamped(-dy / length));
}

double _cross(_Point origin, _Point a, _Point b) =>
    (a.$1 - origin.$1) * (b.$2 - origin.$2) -
    (a.$2 - origin.$2) * (b.$1 - origin.$1);

double? _sideAngle(_Frame frame, String side, String joint) {
  final (a, b, c) = jointTriplets[joint]!;
  final pts = frame.points(['${side}_$a', '${side}_$b', '${side}_$c']);
  return pts == null ? null : _angleAt(pts[0], pts[1], pts[2]);
}

double? _worst(Iterable<double?> values, double Function(double, double) pick) {
  final usable = values.whereType<double>();
  return usable.isEmpty ? null : usable.reduce(pick);
}

typedef _Measure = double? Function(_Frame frame, String slug);

double? _trunkLean(_Frame frame, String slug) {
  final both = frame.points([
    'left_shoulder',
    'right_shoulder',
    'left_hip',
    'right_hip',
  ]);
  if (both != null) {
    final [ls, rs, lh, rh] = both;
    final top = ((ls.$1 + rs.$1) / 2, (ls.$2 + rs.$2) / 2);
    final bottom = ((lh.$1 + rh.$1) / 2, (lh.$2 + rh.$2) / 2);
    return _fromVertical(bottom, top);
  }
  // Side view: the far side is often hidden, so use whichever side is visible.
  for (final side in _sides) {
    final pts = frame.points(['${side}_shoulder', '${side}_hip']);
    if (pts != null) return _fromVertical(pts[1], pts[0]);
  }
  return null;
}

_Measure _bend(String joint) => (frame, slug) {
  final values = <double?>[];
  for (final side in _sides) {
    final angle = _sideAngle(frame, side, joint);
    values.add(angle == null ? null : 180 - angle);
  }
  return _worst(values, math.max);
};

double? _kneeValgus(_Frame frame, String slug) {
  final values = <double?>[];
  for (final (side, other) in [('left', 'right'), ('right', 'left')]) {
    final pts = frame.points([
      '${side}_hip',
      '${side}_knee',
      '${side}_ankle',
      '${other}_hip',
    ]);
    if (pts == null) {
      values.add(null);
      continue;
    }
    final [hip, knee, ankle, otherHip] = pts;
    final angle = _angleAt(hip, knee, ankle);
    if (angle == null) {
      values.add(null);
      continue;
    }
    // The knee is on the midline side when it lies on the same side of the
    // hip-ankle line as the other hip.
    final inward = _cross(hip, ankle, knee) * _cross(hip, ankle, otherHip) > 0;
    values.add(inward ? 180 - angle : 0.0);
  }
  return _worst(values, math.max);
}

double? _kneeForward(_Frame frame, String slug) {
  (double, double)? best; // (knee angle, shin angle)
  for (final side in _sides) {
    final pts = frame.points(['${side}_hip', '${side}_knee', '${side}_ankle']);
    if (pts == null) continue;
    final [hip, knee, ankle] = pts;
    final kneeAngle = _angleAt(hip, knee, ankle);
    final shin = _fromVertical(ankle, knee);
    if (kneeAngle == null || shin == null) continue;
    if (best == null || kneeAngle < best.$1) best = (kneeAngle, shin);
  }
  return best?.$2;
}

double? _hipSag(_Frame frame, String slug) {
  final values = <double?>[];
  for (final side in _sides) {
    final pts = frame.points([
      '${side}_shoulder',
      '${side}_hip',
      '${side}_ankle',
    ]);
    final angle = pts == null ? null : _angleAt(pts[0], pts[1], pts[2]);
    values.add(angle == null ? null : 180 - angle);
  }
  return _worst(values, math.max);
}

double? _depth(_Frame frame, String slug) {
  final joint = depthJoint[slug];
  if (joint == null) return null;
  return _worst([
    for (final side in _sides) _sideAngle(frame, side, joint),
  ], math.min);
}

final Map<String, _Measure> _checks = {
  'trunk_lean': _trunkLean,
  'elbow_bend': _bend('elbow'),
  'knee_bend': _bend('knee'),
  'knee_valgus': _kneeValgus,
  'knee_forward': _kneeForward,
  'hip_sag': _hipSag,
  'depth': _depth,
};

/// The check keys this version knows how to measure.
Iterable<String> get knownChecks => _checks.keys;

bool isCheckSupported(String checkKey, String exerciseSlug) {
  if (checkKey == 'depth') return depthJoint.containsKey(exerciseSlug);
  return _checks.containsKey(checkKey);
}

/// The joint angles and check measurements of one frame, driven by the
/// exercise's template rather than a fixed generic set.
FrameFeatures frameFeatures(
  Map<String, Landmark> landmarks, {
  required double aspectRatio,
  required String exerciseSlug,
  required List<String> targetJoints,
  required List<String> checkKeys,
  required double minVisibility,
}) {
  final frame = _Frame(landmarks, aspectRatio, minVisibility);
  final jointAngles = <String, double?>{
    for (final joint in targetJoints)
      if (jointTriplets.containsKey(joint))
        for (final side in _sides)
          '${side}_$joint': _sideAngle(frame, side, joint),
  };
  final checks = <String, double?>{};
  final unsupported = <String>[];
  for (final key in checkKeys) {
    if (!isCheckSupported(key, exerciseSlug)) {
      unsupported.add(key);
      continue;
    }
    checks[key] = _checks[key]!(frame, exerciseSlug);
  }
  return FrameFeatures(
    jointAngles: jointAngles,
    checks: checks,
    unsupported: unsupported,
  );
}
