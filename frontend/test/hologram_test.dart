// The 3D hologram figures shown wherever a pose or a movement appears.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:physioai/core/widgets/hologram/holo_figure.dart';
import 'package:physioai/core/widgets/hologram/holo_pose.dart';

void main() {
  group('Choosing what to show', () {
    test('each exercise of the library has its own movement', () {
      expect(HoloExercise.fromSlug('squats'), HoloExercise.squat);
      expect(HoloExercise.fromSlug('leg-lunge'), HoloExercise.lunge);
      expect(HoloExercise.fromSlug('push-ups'), HoloExercise.pushUp);
      expect(HoloExercise.fromSlug('arm-abduction'), HoloExercise.armAbduction);
      expect(HoloExercise.fromSlug('leg-abduction'), HoloExercise.legAbduction);
      expect(HoloExercise.fromSlug('wall-sit'), HoloExercise.stand);
    });

    test('a record without a slug is recognised by its name', () {
      expect(HoloExercise.of('', 'Leg Lunge'), HoloExercise.lunge);
      expect(HoloExercise.of('', 'Arm Abduction'), HoloExercise.armAbduction);
      expect(HoloExercise.of('squats', 'Anything'), HoloExercise.squat);
    });

    test('each check the server reports has a fault to act out', () {
      for (final (key, fault) in [
        ('knee_valgus', HoloFault.kneeValgus),
        ('trunk_lean', HoloFault.trunkLean),
        ('knee_forward', HoloFault.kneeForward),
        ('hip_sag', HoloFault.hipSag),
        ('depth', HoloFault.shallowDepth),
        ('elbow_bend', HoloFault.elbowBend),
        ('knee_bend', HoloFault.kneeBend),
      ]) {
        expect(HoloFault.fromCheck(key), fault, reason: key);
      }
      expect(HoloFault.fromCheck('something_new'), HoloFault.none);
      expect(HoloFault.fromCheck(null), HoloFault.none);
    });
  });

  group('The body model', () {
    test('a standing figure stands on the floor at about 1.75 m', () {
      final joints = skeletonFor(const BodyPose());
      final lowest = joints.values
          .map((p) => p.y)
          .reduce((a, b) => a < b ? a : b);
      expect(lowest, closeTo(0.02, 0.05));
      expect(joints[Joint.head]!.y, closeTo(1.65, 0.12));
    });

    test('knees that cave in end up closer together than the ankles', () {
      final scene = HoloScene.of(HoloExercise.squat, HoloFault.kneeValgus);
      final peak = skeletonFor(scene.peak);
      final knees = (peak[Joint.leftKnee]!.x - peak[Joint.rightKnee]!.x).abs();
      final ankles = (peak[Joint.leftAnkle]!.x - peak[Joint.rightAnkle]!.x)
          .abs();
      expect(knees, lessThan(ankles));

      final correct = skeletonFor(
        HoloScene.correctFor(HoloExercise.squat, HoloFault.kneeValgus).peak,
      );
      expect(
        (correct[Joint.leftKnee]!.x - correct[Joint.rightKnee]!.x).abs(),
        greaterThan(knees),
      );
    });

    test('a forward trunk lean moves the shoulders ahead of the hips', () {
      final upright = skeletonFor(HoloScene.of(HoloExercise.squat).peak);
      final leaning = skeletonFor(
        HoloScene.of(HoloExercise.squat, HoloFault.trunkLean).peak,
      );
      expect(
        leaning[Joint.chest]!.z - leaning[Joint.pelvis]!.z,
        greaterThan(upright[Joint.chest]!.z - upright[Joint.pelvis]!.z),
      );
    });

    test('in a plank the body is close to horizontal', () {
      final plank = skeletonFor(HoloScene.of(HoloExercise.pushUp).rest);
      final rise = (plank[Joint.head]!.y - plank[Joint.leftAnkle]!.y).abs();
      final reach = (plank[Joint.head]!.z - plank[Joint.leftAnkle]!.z).abs();
      expect(reach, greaterThan(rise * 1.5));
    });
  });

  testWidgets('every exercise and fault draws in every tone', (tester) async {
    final figures = <Widget>[
      for (final exercise in HoloExercise.values)
        for (final fault in HoloFault.values)
          for (final tone in HoloTone.values)
            SizedBox(
              width: 80,
              height: 100,
              child: HoloFigure(
                exercise: exercise,
                fault: fault,
                tone: tone,
                mark: HoloMark.cross,
              ),
            ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: SingleChildScrollView(child: Wrap(children: figures)),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(find.byType(HoloFigure), findsWidgets);
  });
}
