// The camera check makes the patient face the camera, or stand side-on to it,
// as the exercise needs; from the side it asks for the near side of each joint.
import 'package:flutter_test/flutter_test.dart';
import 'package:physioai/features/exercises/exercise_models.dart';
import 'package:physioai/features/session/precheck.dart';

import 'plans_test.dart' show lunge, squats;
import 'session_test.dart' hide main;

const legs = [
  'left_shoulder',
  'right_shoulder',
  'left_hip',
  'right_hip',
  'left_knee',
  'right_knee',
  'left_ankle',
  'right_ankle',
];

PrecheckRequirements needs(CameraView view) => PrecheckRequirements(
  itemId: 'item-0',
  exercise: view == CameraView.side ? lunge : squats,
  sets: 2,
  reps: 5,
  restSeconds: 30,
  difficulty: Difficulty.easy,
  requiredLandmarks: legs,
  minVisibility: 0.6,
  minBrightness: 0.25,
  holdMs: 1500,
  cameraView: view,
);

void main() {
  group('Which way the patient faces', () {
    test(
      'shoulders are wide against the trunk from the front, narrow side-on',
      () {
        final front = shoulderRatio(frame(0), 4 / 3)!;
        final side = shoulderRatio(frame(0, sideOn: true), 4 / 3)!;

        expect(front, greaterThan(0.55));
        expect(side, lessThan(0.35));
        // The picture's shape matters: the same frame on a square camera is narrower.
        expect(shoulderRatio(frame(0), 1)!, lessThan(front));
      },
    );

    test('it cannot be judged without the shoulders and hips', () {
      expect(shoulderRatio(frame(0, nobody: true), 4 / 3), isNull);
      expect(
        shoulderRatio(
          frame(0, hidden: {'left_shoulder', 'right_shoulder'}),
          4 / 3,
        ),
        isNull,
      );
    });

    test('an exercise done facing the camera asks the patient to turn', () {
      final reading = judgeSetup(
        frame(0, sideOn: true),
        needs(CameraView.front),
      );

      expect(reading.ok, isFalse);
      expect(reading.facingOk, isFalse);
      expect(reading.guidance, 'Turn to face the camera.');
      expect(judgeSetup(frame(0), needs(CameraView.front)).ok, isTrue);
    });

    test('a side-on exercise asks the patient to turn sideways', () {
      final reading = judgeSetup(frame(0), needs(CameraView.side));

      expect(reading.facingOk, isFalse);
      expect(reading.guidance, 'Turn sideways so the camera sees your side.');
    });

    test('side-on, the hidden far leg does not stop the check', () {
      // The right leg is behind the left one. (The hips stay visible from the
      // side: in REHAB24-6 both pass in every side-view frame.)
      final farLegHidden = frame(
        0,
        sideOn: true,
        hidden: {'right_knee', 'right_ankle'},
      );

      final reading = judgeSetup(farLegHidden, needs(CameraView.side));

      expect(reading.missing, isEmpty);
      expect(reading.ok, isTrue);
      // Facing the camera, both sides are still needed.
      expect(
        judgeSetup(
          frame(0, hidden: {'right_knee'}),
          needs(CameraView.front),
        ).missing,
        ['right_knee'],
      );
    });

    test('side-on, a joint hidden on both sides still stops the check', () {
      final reading = judgeSetup(
        frame(0, sideOn: true, hidden: {'left_knee', 'right_knee'}),
        needs(CameraView.side),
      );

      expect(reading.missing, ['left_knee', 'right_knee']);
      expect(reading.guidance, 'Step back so your legs are visible.');
    });

    test('what is wrong with the body is said before which way to face', () {
      final reading = judgeSetup(
        frame(0, sideOn: true, hidden: {'left_ankle', 'right_ankle'}),
        needs(CameraView.front),
      );

      expect(reading.guidance, 'Step back so your feet are visible.');
    });

    test('the evidence carries the ratio furthest from what is needed', () {
      final front = PrecheckTracker(needs(CameraView.front));
      for (final t in [0.0, 500.0, 1000.0, 1600.0]) {
        front.add(frame(t));
      }
      final side = PrecheckTracker(needs(CameraView.side));
      for (final t in [0.0, 500.0, 1000.0, 1600.0]) {
        side.add(frame(t, sideOn: true));
      }

      expect(front.ready, isTrue);
      expect(front.evidence()['shoulder_ratio'], greaterThan(0.55));
      expect(side.ready, isTrue);
      expect(side.evidence()['shoulder_ratio'], lessThan(0.35));
    });

    test('turning away during the hold starts it again', () {
      final tracker = PrecheckTracker(needs(CameraView.front))
        ..add(frame(0))
        ..add(frame(1000));
      expect(tracker.progress, greaterThan(0));

      tracker.add(frame(1200, sideOn: true));

      expect(tracker.progress, 0);
      expect(tracker.ready, isFalse);
    });

    test('the requirements say which way to face, as the API sends them', () {
      final parsed = PrecheckRequirements.fromJson({
        'item_id': 'item-0',
        'exercise': {
          'id': 'ex-1',
          'slug': 'leg-lunge',
          'name': 'Leg Lunge',
          'domain': 'Functional',
          'body_area': 'lower_body',
          'primary_targets': 'Quadriceps',
          'target_joints': ['hip', 'knee', 'ankle'],
          'instructions': 'Stand side-on to the camera.',
        },
        'sets': 2,
        'reps': 5,
        'rest_seconds': 30,
        'difficulty': 'easy',
        'required_landmarks': legs,
        'min_visibility': 0.6,
        'min_brightness': 0.25,
        'hold_ms': 1500,
        'camera_view': 'side',
        'front_min_ratio': 0.55,
        'side_max_ratio': 0.35,
      });

      expect(parsed.cameraView, CameraView.side);
      expect((parsed.frontMinRatio, parsed.sideMaxRatio), (0.55, 0.35));
    });
  });
}
