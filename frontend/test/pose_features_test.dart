// US 3.2 (SCRUM-53): per-exercise joint-angle features. The same cases are
// checked against the Python twin in backend/tests/test_pose_features.py.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:physioai/features/session/pose/pose_features.dart';
import 'package:physioai/features/session/pose/pose_models.dart';

final Map<String, dynamic> fixture =
    jsonDecode(
          File(
            '../backend/tests/fixtures/pose_feature_cases.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;

double get tolerance => (fixture['tolerance_degrees'] as num).toDouble();

List<Map<String, dynamic>> get cases => [
  for (final c in fixture['cases'] as List<dynamic>) c as Map<String, dynamic>,
];

Map<String, dynamic> caseNamed(String name) =>
    cases.firstWhere((c) => c['name'] == name);

Map<String, Landmark> landmarksOf(Map<String, dynamic> c) => {
  for (final entry in (c['landmarks'] as Map<String, dynamic>).entries)
    entry.key: Landmark(
      ((entry.value as List<dynamic>)[0] as num).toDouble(),
      ((entry.value as List<dynamic>)[1] as num).toDouble(),
      ((entry.value as List<dynamic>)[2] as num).toDouble(),
    ),
};

List<String> strings(Object? list) => [
  for (final s in list as List<dynamic>) s as String,
];

FrameFeatures run(
  Map<String, dynamic> c, {
  Map<String, Landmark>? landmarks,
  double? aspectRatio,
}) => frameFeatures(
  landmarks ?? landmarksOf(c),
  aspectRatio: aspectRatio ?? (c['aspect_ratio'] as num).toDouble(),
  exerciseSlug: c['exercise_slug'] as String,
  targetJoints: strings(c['target_joints']),
  checkKeys: strings(c['check_keys']),
  minVisibility: (fixture['min_visibility'] as num).toDouble(),
);

void expectClose(Map<String, double?> got, Object? expected) {
  final want = expected as Map<String, dynamic>;
  expect(got.keys.toSet(), want.keys.toSet());
  for (final entry in want.entries) {
    if (entry.value == null) {
      expect(got[entry.key], isNull, reason: entry.key);
    } else {
      expect(
        got[entry.key],
        closeTo((entry.value as num).toDouble(), tolerance),
        reason: entry.key,
      );
    }
  }
}

void main() {
  group('shared cases', () {
    for (final c in cases) {
      test(c['name'] as String, () {
        final features = run(c);
        final expected = c['expected'] as Map<String, dynamic>;
        expectClose(features.jointAngles, expected['joint_angles']);
        expectClose(features.checks, expected['checks']);
        expect(features.unsupported, strings(expected['unsupported']));
      });
    }
  });

  test('ignoring the aspect ratio would skew the angles', () {
    final features = run(
      caseNamed('squat_side_knee_90_trunk_30'),
      aspectRatio: 1,
    );
    expect((features.jointAngles['right_knee']! - 90).abs(), greaterThan(1));
  });

  test('a landmark below the visibility threshold is never used', () {
    final c = caseNamed('lunge_front_left_knee_valgus_20');
    final landmarks = landmarksOf(c);
    final knee = landmarks['left_knee']!;
    final minVisibility = (fixture['min_visibility'] as num).toDouble();
    landmarks['left_knee'] = Landmark(knee.x, knee.y, minVisibility - 0.01);
    final features = run(c, landmarks: landmarks);
    expect(features.jointAngles['left_knee'], isNull);
    expect(features.jointAngles['left_hip'], isNull);
    // The right knee is still measured, and it is not valgus.
    expect(features.checks['knee_valgus'], closeTo(0, tolerance));
  });

  test('every check the seeded templates use is supported', () {
    const seeded = [
      'trunk_lean',
      'elbow_bend',
      'knee_bend',
      'knee_valgus',
      'knee_forward',
      'hip_sag',
      'depth',
    ];
    expect(knownChecks.toSet().containsAll(seeded), isTrue);
    expect(isCheckSupported('depth', 'push-ups'), isTrue);
    expect(isCheckSupported('depth', 'squats'), isTrue);
    expect(isCheckSupported('depth', 'arm-abduction'), isFalse);
  });

  test('a frame takes well under ten milliseconds', () {
    final c = caseNamed('squat_side_knee_90_trunk_30');
    final landmarks = landmarksOf(c);
    const runs = 1000;
    final watch = Stopwatch()..start();
    for (var i = 0; i < runs; i++) {
      run(c, landmarks: landmarks);
    }
    final perFrameMs = watch.elapsedMicroseconds / 1000 / runs;
    expect(perFrameMs, lessThan(10));
  });
}
