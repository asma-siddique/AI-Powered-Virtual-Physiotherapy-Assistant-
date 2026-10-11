// US 3.3 (SCRUM-61): counting repetitions of every supported exercise, and
// the depth check of Squats and Push-ups (part of US 3.4, SCRUM-66).
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:physioai/features/session/live_session.dart';
import 'package:physioai/features/session/pose/pose_features.dart';
import 'package:physioai/features/session/pose/pose_models.dart';
import 'package:physioai/features/session/rep_counter.dart';
import 'package:physioai/features/session/repetitions.dart';

const _aspect = 4 / 3;

typedef _Point = (double, double);

_Point _turn(_Point v, double degrees) {
  final r = degrees * math.pi / 180;
  return (
    v.$1 * math.cos(r) - v.$2 * math.sin(r),
    v.$1 * math.sin(r) + v.$2 * math.cos(r),
  );
}

_Point _plus(_Point a, _Point b, [double length = 1]) =>
    (a.$1 + b.$1 * length, a.$2 + b.$2 * length);

/// A frame with the same points for both sides (a side view), built in true
/// proportions and squeezed into the picture's 0 to 1 width.
PoseFrame _sideFrame(
  double timeMs,
  Map<String, _Point> points, {
  Set<String> hidden = const {},
}) => PoseFrame(
  timeMs: timeMs,
  brightness: 0.6,
  landmarks: {
    for (final name in poseLandmarkNames)
      name: () {
        final part = name.replaceFirst(RegExp('^(left|right)_'), '');
        final at = points[part];
        return Landmark(
          (at?.$1 ?? 0.5 * _aspect) / _aspect,
          at?.$2 ?? 0.9,
          at == null || hidden.contains(name) ? 0.1 : 0.95,
        );
      }(),
  },
);

/// Someone squatting, seen from the side, with the knees at [knee] degrees
/// and the trunk upright.
PoseFrame squatFrame(double timeMs, double knee) {
  final ankle = (0.5 * _aspect, 0.9);
  final shin = (180 - knee) / 2;
  final kneeAt = _plus(ankle, _turn((0, -1), shin), 0.2);
  final toAnkle = _turn((0, 1), shin);
  final hip = _plus(kneeAt, _turn(toAnkle, knee), 0.2);
  return _sideFrame(timeMs, {
    'ankle': ankle,
    'knee': kneeAt,
    'hip': hip,
    'shoulder': _plus(hip, (0, -1), 0.3),
    'foot_index': _plus(ankle, (1, 0), 0.1),
  });
}

/// A push-up seen from the side: the body level, the elbows at [elbow]
/// degrees.
PoseFrame pushUpFrame(
  double timeMs,
  double elbow, {
  Set<String> hidden = const {},
}) {
  const shoulder = (0.3, 0.5);
  final elbowAt = _plus(shoulder, (0, 1), 0.14);
  return _sideFrame(timeMs, {
    'shoulder': shoulder,
    'elbow': elbowAt,
    'wrist': _plus(elbowAt, _turn((0, -1), elbow), 0.13),
    'hip': (0.6, 0.5),
    'knee': (0.75, 0.5),
    'ankle': (0.9, 0.5),
  }, hidden: hidden);
}

/// One repetition of a working-joint angle, ten frames a second: at rest,
/// down to [bottom] and held there, then back.
List<double> cycle(double rest, double bottom) => [
  rest,
  rest,
  rest,
  (rest + bottom) / 2,
  bottom,
  bottom,
  bottom,
  bottom,
  (rest + bottom) / 2,
  rest,
  rest,
  rest,
];

/// The repetitions a counter finds in these angles, one frame every 100 ms.
int countReps(RepProfile profile, List<double> angles) {
  final counter = RepCounter(profile);
  var reps = 0;
  for (final (i, angle) in angles.indexed) {
    if (counter.add(i * 100.0, angle) != null) reps += 1;
  }
  return reps;
}

LiveSessionEngine engine(
  String slug,
  List<String> joints,
  List<String> checks,
) => LiveSessionEngine(
  exerciseSlug: slug,
  targetJoints: joints,
  checkKeys: checks,
  sets: 1,
  repsPerSet: 10,
  minVisibility: 0.6,
  aspectRatio: _aspect,
);

List<RepetitionDraft> run(LiveSessionEngine engine, List<PoseFrame> frames) => [
  for (final frame in frames) ?engine.add(frame, frame.timeMs),
];

void main() {
  test('every exercise the project supports has a counting profile', () {
    for (final slug in [
      'arm-abduction',
      'leg-abduction',
      'leg-lunge',
      'push-ups',
      'squats',
    ]) {
      expect(repProfiles, contains(slug));
    }
  });

  group('Counting profiles', () {
    test('Leg Abduction counts the leg moving out about 20 degrees', () {
      final profile = repProfiles['leg-abduction']!;
      // Standing is about 173 at the hip; 150 is a little over 20 degrees out.
      expect(countReps(profile, [...cycle(173, 150), ...cycle(173, 150)]), 2);
      // A small sway of the leg is not a repetition.
      expect(countReps(profile, cycle(173, 160)), 0);
      // The standing leg stays near rest, so the moving one is followed.
      expect(profile.signal(173, 150), 150);
    });

    test('Leg Lunge counts the front knee bending towards a right angle', () {
      final profile = repProfiles['leg-lunge']!;
      expect(countReps(profile, [...cycle(175, 95), ...cycle(175, 100)]), 2);
      // Barely bending the knee is not a lunge.
      expect(countReps(profile, cycle(175, 140)), 0);
      // The more bent knee is the front one.
      expect(profile.signal(170, 95), 95);
    });

    test('Push-ups count the elbows bending and straightening again', () {
      final profile = repProfiles['push-ups']!;
      expect(countReps(profile, [...cycle(175, 90), ...cycle(175, 100)]), 2);
      // A small dip at the top is not a push-up.
      expect(countReps(profile, cycle(175, 135)), 0);
    });

    test('a repetition is not counted until the resting position is seen', () {
      final profile = repProfiles['push-ups']!;
      // The camera first sees someone already at the bottom.
      expect(countReps(profile, [90, 90, 90, 175, 175, 175]), 0);
    });
  });

  group('Depth', () {
    test('it is how far the lowest point stayed short of the target', () {
      expect(depthShortfall('squats', 115), closeTo(25, 1e-9));
      expect(depthShortfall('push-ups', 100), closeTo(10, 1e-9));
      expect(depthShortfall('squats', 90), 0);
      expect(depthShortfall('push-ups', 80), 0);
      expect(depthShortfall('arm-abduction', 100), isNull);
      expect(depthTarget.keys.toSet(), depthJoint.keys.toSet());
    });

    test('a deep squat is sent with a small shortfall', () {
      final squats = engine(
        'squats',
        const ['hip', 'knee', 'ankle'],
        const ['trunk_lean', 'depth'],
      );
      final drafts = run(squats, [
        for (final (i, knee) in cycle(175, 95).indexed)
          squatFrame(i * 100.0, knee),
      ]);
      expect(drafts, hasLength(1));
      // Judged on the lowest point reached: 95, five degrees short of 90.
      expect(drafts.single.measures['depth'], closeTo(5, 1e-6));
      expect(drafts.single.measures['trunk_lean'], closeTo(0, 1e-6));
    });

    test('a shallow squat is sent with a large shortfall', () {
      final squats = engine(
        'squats',
        const ['hip', 'knee', 'ankle'],
        const ['depth'],
      );
      final drafts = run(squats, [
        for (final (i, knee) in cycle(175, 112).indexed)
          squatFrame(i * 100.0, knee),
      ]);
      expect(drafts.single.measures['depth'], closeTo(22, 1e-6));
    });

    test('a push-up is judged on its elbows at the lowest point', () {
      final pushUps = engine(
        'push-ups',
        const ['shoulder', 'elbow', 'hip', 'knee', 'ankle'],
        const ['hip_sag', 'depth'],
      );
      final drafts = run(pushUps, [
        for (final (i, elbow) in cycle(175, 100).indexed)
          pushUpFrame(i * 100.0, elbow),
      ]);
      expect(drafts, hasLength(1));
      expect(drafts.single.measures['depth'], closeTo(10, 1e-6));
      expect(drafts.single.measures['hip_sag'], closeTo(0, 1e-6));
    });

    test('depth is not guessed when the wrists were never in view', () {
      final pushUps = engine(
        'push-ups',
        const ['shoulder', 'elbow', 'hip', 'knee', 'ankle'],
        const ['hip_sag', 'depth'],
      );
      // Counting follows the elbow, so without the wrists nothing is counted,
      // and nothing is sent with a made-up depth.
      final drafts = run(pushUps, [
        for (final (i, elbow) in cycle(175, 100).indexed)
          pushUpFrame(
            i * 100.0,
            elbow,
            hidden: const {'left_wrist', 'right_wrist'},
          ),
      ]);
      expect(drafts, isEmpty);
    });

    test('an exercise without depth still sends it as unknown', () {
      final lunge = engine(
        'leg-lunge',
        const ['hip', 'knee', 'ankle'],
        const ['knee_forward', 'depth'],
      );
      final drafts = run(lunge, [
        for (final (i, knee) in cycle(175, 95).indexed)
          squatFrame(i * 100.0, knee),
      ]);
      expect(drafts, hasLength(1));
      expect(drafts.single.measures, containsPair('depth', null));
      expect(drafts.single.measures['knee_forward'], isNotNull);
    });
  });
}
