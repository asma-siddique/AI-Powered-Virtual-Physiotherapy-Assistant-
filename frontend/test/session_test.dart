// US 3.1: the camera check before a session, and the session it opens.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:physioai/core/api/api_exception.dart';
import 'package:physioai/features/auth/auth_models.dart';
import 'package:physioai/features/exercises/exercise_models.dart';
import 'package:physioai/features/session/pose/pose_models.dart';
import 'package:physioai/features/session/pose/pose_source.dart';
import 'package:physioai/features/session/precheck.dart';

import 'auth_flow_test.dart';
import 'plans_test.dart';

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

PrecheckRequirements requirementsFor(
  ExerciseBrief exercise, {
  List<String> landmarks = legs,
}) => PrecheckRequirements(
  itemId: 'item-0',
  exercise: exercise,
  sets: 3,
  reps: 12,
  restSeconds: 60,
  difficulty: Difficulty.medium,
  requiredLandmarks: landmarks,
  minVisibility: 0.6,
  minBrightness: 0.25,
  holdMs: 1500,
);

/// The camera at one moment: everyone fully in view unless told otherwise.
PoseFrame frame(
  double timeMs, {
  double brightness = 0.6,
  Set<String> hidden = const {},
  bool nobody = false,
  double visibility = 0.95,
}) => PoseFrame(
  timeMs: timeMs,
  brightness: brightness,
  landmarks: nobody
      ? const {}
      : {
          for (final name in poseLandmarkNames)
            name: Landmark(0.5, 0.5, hidden.contains(name) ? 0.1 : visibility),
        },
);

/// A camera the test controls.
class FakeCamera implements PoseSource {
  FakeCamera({this.problem});

  CameraException? problem;
  int starts = 0;
  bool stopped = false;
  final _frames = StreamController<PoseFrame>.broadcast(sync: true);

  @override
  double get aspectRatio => 4 / 3;

  @override
  Stream<PoseFrame> get frames => _frames.stream;

  @override
  Widget preview() =>
      const ColoredBox(key: Key('camera-preview'), color: Color(0xFF223344));

  @override
  Future<void> start() async {
    starts++;
    if (problem != null) throw problem!;
  }

  @override
  Future<void> stop() async => stopped = true;

  void show(PoseFrame frame) => _frames.add(frame);
}

/// Jane opens the camera check for Squats, the first exercise of her plan.
Future<({FakeCamera camera, FakePatientRepository patient})> openSession(
  WidgetTester tester, {
  FakeCamera? camera,
  FakePatientRepository? patient,
  bool withCamera = true,
}) async {
  final fakeCamera = camera ?? FakeCamera();
  final repository =
      patient ??
      (FakePatientRepository()
        ..plan = plan('Knee plan', [squats, lunge])
        ..requirements['item-0'] = requirementsFor(squats));
  await pumpApp(
    tester,
    auth: FakeAuthRepository(
      saved: user(
        UserRole.patient,
        'Jane Cooper',
        physiotherapist: 'Dr. Sarah Malik',
      ),
    ),
    patient: repository,
    camera: withCamera ? fakeCamera : null,
  );
  await tester.tap(find.text('My Exercise Plan'));
  await tester.pumpAndSettle();
  await tapKey(tester, 'start-item-item-0');
  return (camera: fakeCamera, patient: repository);
}

Future<void> see(
  WidgetTester tester,
  FakeCamera camera,
  PoseFrame frame,
) async {
  camera.show(frame);
  await tester.pump();
}

String guidance(WidgetTester tester) => tester
    .widget<Text>(
      find.descendant(
        of: find.byKey(const Key('setup-guidance')),
        matching: find.byType(Text),
      ),
    )
    .data!;

/// Holds a good setup long enough for the session to start.
Future<void> holdGoodSetup(
  WidgetTester tester,
  FakeCamera camera, {
  double from = 0,
}) async {
  for (final t in [0.0, 500.0, 1000.0, 1600.0]) {
    await see(tester, camera, frame(from + t));
  }
  await tester.pumpAndSettle();
}

void main() {
  group('Judging the camera setup', () {
    final requirements = requirementsFor(squats);
    String? advice(PoseFrame frame) => judgeSetup(frame, requirements).guidance;

    test('a good setup needs no guidance', () {
      final reading = judgeSetup(frame(0), requirements);
      expect(reading.ok, isTrue);
      expect(reading.guidance, isNull);
      // Arms are not needed for a leg exercise, so hidden arms do not matter.
      expect(
        judgeSetup(
          frame(0, hidden: {'left_wrist', 'right_elbow', 'nose'}),
          requirements,
        ).ok,
        isTrue,
      );
    });

    test('each problem gets its own, specific advice', () {
      expect(advice(frame(0, brightness: 0.1)), contains('too dark'));
      expect(advice(frame(0, nobody: true)), contains('Stand in front'));
      expect(
        advice(frame(0, hidden: legs.toSet())),
        contains('Stand in front'),
      );
      expect(
        advice(
          frame(
            0,
            hidden: {'left_knee', 'right_knee', 'left_ankle', 'right_ankle'},
          ),
        ),
        'Step back so your legs are visible.',
      );
      expect(
        advice(frame(0, hidden: {'left_ankle', 'right_ankle'})),
        'Step back so your feet are visible.',
      );
      expect(
        advice(frame(0, hidden: {'left_shoulder', 'right_shoulder'})),
        contains('shoulders are visible'),
      );
      expect(
        advice(frame(0, hidden: {'left_hip', 'left_knee', 'left_ankle'})),
        'Move a little to your right so your whole body is in view.',
      );
      expect(
        advice(frame(0, hidden: {'right_shoulder', 'right_ankle'})),
        'Move a little to your left so your whole body is in view.',
      );
      expect(
        advice(frame(0, hidden: {'left_shoulder', 'right_ankle'})),
        contains('whole body fits'),
      );
    });

    test('poor light is reported before anything about the body', () {
      final reading = judgeSetup(
        frame(0, brightness: 0.05, nobody: true),
        requirements,
      );
      expect(reading.lightingOk, isFalse);
      expect(reading.guidance, contains('too dark'));
    });

    test('an arm exercise asks for arms', () {
      final arms = requirementsFor(
        squats,
        landmarks: [
          'left_shoulder',
          'right_shoulder',
          'left_elbow',
          'right_elbow',
          'left_wrist',
          'right_wrist',
          'left_hip',
          'right_hip',
        ],
      );
      expect(
        judgeSetup(
          frame(0, hidden: {'left_wrist', 'right_wrist'}),
          arms,
        ).guidance,
        'Step back so your arms stay in view.',
      );
      // Legs out of view are fine for it.
      expect(
        judgeSetup(frame(0, hidden: {'left_ankle', 'right_knee'}), arms).ok,
        isTrue,
      );
    });

    test('the hold restarts when the setup is lost, and the evidence keeps '
        'the weakest values seen', () {
      final tracker = PrecheckTracker(requirements);
      tracker.add(frame(0, brightness: 0.7));
      tracker.add(frame(800, brightness: 0.4, visibility: 0.8));
      expect(tracker.ready, isFalse);
      expect(tracker.progress, closeTo(800 / 1500, 0.001));

      tracker.add(frame(900, hidden: {'left_knee'}));
      expect(tracker.progress, 0);

      tracker.add(frame(1000, brightness: 0.7));
      tracker.add(frame(1700, brightness: 0.45, visibility: 0.75));
      expect(tracker.ready, isFalse);
      tracker.add(frame(2500, brightness: 0.6));
      expect(tracker.ready, isTrue);

      final evidence = tracker.evidence();
      expect(evidence['held_ms'], 1500);
      expect(evidence['brightness'], 0.45);
      expect(evidence['visibility'], {for (final name in legs) name: 0.75});
      expect(evidence.containsKey('passed'), isFalse);
    });

    test('the camera bridge numbers unpack into 33 named landmarks', () {
      final packed = Float32List(2 + 33 * 3);
      packed[0] = 0.5;
      packed[1] = 1234;
      packed[2 + 25 * 3] = 0.25; // left_knee x
      packed[3 + 25 * 3] = 0.75; // left_knee y
      packed[4 + 25 * 3] = 0.875; // left_knee visibility
      final unpacked = PoseFrame.fromPacked(packed);

      expect(unpacked.landmarks, hasLength(33));
      expect((unpacked.brightness, unpacked.timeMs), (0.5, 1234));
      final knee = unpacked.landmarks['left_knee']!;
      expect((knee.x, knee.y, knee.visibility), (0.25, 0.75, 0.875));
      // Nobody in the picture: brightness and time only.
      expect(
        PoseFrame.fromPacked(Float32List.fromList([0.3, 10])).landmarks,
        isEmpty,
      );
    });
  });

  group('Starting from the plan', () {
    testWidgets('each exercise has Start, except one that is switched off', (
      tester,
    ) async {
      await pumpApp(
        tester,
        auth: FakeAuthRepository(saved: user(UserRole.patient, 'Jane Cooper')),
        patient: FakePatientRepository()
          ..plan = plan('Plan', [squats, retired]),
      );
      await tester.tap(find.text('My Exercise Plan'));
      await tester.pumpAndSettle();

      FilledButton start(String id) =>
          tester.widget<FilledButton>(find.byKey(Key('start-item-$id')));
      expect(start('item-0').onPressed, isNotNull);
      expect(start('item-1').onPressed, isNull);
      expect(find.text('Being updated by your clinic'), findsOneWidget);
    });
  });

  group('Camera check', () {
    testWidgets('shows the exercise, what must be in view, and waits', (
      tester,
    ) async {
      final opened = await openSession(tester);

      expect(opened.camera.starts, 1);
      expect(find.text('Squats'), findsOneWidget);
      expect(find.textContaining('3 sets × 12 reps'), findsOneWidget);
      expect(find.text('Camera check'), findsOneWidget);
      expect(
        find.text('Body in view: shoulders, hips, knees and ankles'),
        findsOneWidget,
      );
      expect(guidance(tester), 'Looking for you…');
      expect(find.textContaining('video stays on this device'), findsOneWidget);
      // No sidebar and no way to begin by hand: it starts when it is ready.
      expect(find.byKey(const Key('sign-out')), findsNothing);
      expect(find.byKey(const Key('end-session')), findsNothing);
      expect(opened.patient.started, isEmpty);
    });

    testWidgets('gives specific guidance as the picture changes', (
      tester,
    ) async {
      final opened = await openSession(tester);
      final camera = opened.camera;

      await see(tester, camera, frame(0, brightness: 0.1));
      expect(guidance(tester), contains('too dark'));

      await see(tester, camera, frame(100, nobody: true));
      expect(
        guidance(tester),
        'Stand in front of the camera so it can see you.',
      );

      await see(
        tester,
        camera,
        frame(
          200,
          hidden: {'left_knee', 'right_knee', 'left_ankle', 'right_ankle'},
        ),
      );
      expect(guidance(tester), 'Step back so your legs are visible.');

      await see(tester, camera, frame(300));
      expect(guidance(tester), 'Looking good. Hold that position…');
      expect(find.byKey(const Key('hold-progress')), findsOneWidget);
      expect(find.byKey(const Key('pose-overlay')), findsOneWidget);
      expect(opened.patient.started, isEmpty);
    });

    testWidgets('never starts a session while the check has not passed', (
      tester,
    ) async {
      final opened = await openSession(tester);

      // A long time in front of the camera, but never fully in view.
      for (var t = 0.0; t < 20000; t += 400) {
        await see(
          tester,
          opened.camera,
          frame(t, hidden: {'left_ankle', 'right_ankle'}),
        );
      }
      await tester.pumpAndSettle();

      expect(opened.patient.started, isEmpty);
      expect(find.byKey(const Key('session-timer')), findsNothing);
      expect(guidance(tester), 'Step back so your feet are visible.');
    });

    testWidgets('losing the setup restarts the hold', (tester) async {
      final opened = await openSession(tester);
      final camera = opened.camera;

      await see(tester, camera, frame(0));
      await see(tester, camera, frame(1000));
      await see(tester, camera, frame(1200, hidden: {'left_knee'}));
      await see(tester, camera, frame(1300));
      await see(tester, camera, frame(2000)); // good for 0.7 s only
      await tester.pumpAndSettle();
      expect(opened.patient.started, isEmpty);

      await see(tester, camera, frame(2900));
      await tester.pumpAndSettle();
      expect(opened.patient.started, hasLength(1));
    });

    testWidgets('starts the session by itself once the setup has held', (
      tester,
    ) async {
      final opened = await openSession(tester);

      await see(tester, opened.camera, frame(0, brightness: 0.7));
      await see(tester, opened.camera, frame(700, brightness: 0.5));
      await see(tester, opened.camera, frame(1400, visibility: 0.8));
      expect(opened.patient.started, isEmpty);
      await see(tester, opened.camera, frame(1600));
      await tester.pumpAndSettle();

      // Measurements only: the server decides whether they pass.
      final sent = opened.patient.started.single;
      expect(sent.itemId, 'item-0');
      expect(sent.evidence['brightness'], 0.5);
      expect(sent.evidence['held_ms'], 1600);
      expect(sent.evidence['visibility'], {for (final name in legs) name: 0.8});
      expect(find.text('Session in progress'), findsOneWidget);
      expect(find.text('Camera check'), findsNothing);
      expect(
        tester.widget<Text>(find.byKey(const Key('session-timer'))).data,
        '00:00',
      );
    });

    testWidgets('a refusal from the server is shown and not retried in a loop', (
      tester,
    ) async {
      final patient = FakePatientRepository()
        ..plan = plan('Knee plan', [squats])
        ..requirements['item-0'] = requirementsFor(squats)
        ..startFailure = const ApiException(
          code: 'precheck_failed',
          message:
              'Your camera setup has not passed the check yet. Follow the guidance on screen and try again.',
          statusCode: 422,
        );
      final opened = await openSession(tester, patient: patient);

      await holdGoodSetup(tester, opened.camera);
      expect(find.byKey(const Key('session-error')), findsOneWidget);
      expect(find.byKey(const Key('session-timer')), findsNothing);

      // Still in view for a long while: no second attempt on its own.
      await holdGoodSetup(tester, opened.camera, from: 5000);
      expect(patient.started, hasLength(1));

      patient.startFailure = null;
      await tapKey(tester, 'retry-start');
      await holdGoodSetup(tester, opened.camera, from: 10000);
      expect(patient.started, hasLength(2));
      expect(find.text('Session in progress'), findsOneWidget);
    });

    testWidgets('going back before it starts creates no session', (
      tester,
    ) async {
      final opened = await openSession(tester);
      await see(tester, opened.camera, frame(0));

      await tapKey(tester, 'session-back');

      expect(opened.patient.started, isEmpty);
      expect(find.text('Knee plan'), findsOneWidget);
      expect(opened.camera.stopped, isTrue);
    });

    testWidgets(
      'a blocked camera explains how to allow it, and can be retried',
      (tester) async {
        final camera = FakeCamera(
          problem: const CameraException(CameraProblem.permissionDenied),
        );
        await openSession(tester, camera: camera);

        expect(find.byKey(const Key('camera-problem')), findsOneWidget);
        expect(find.textContaining('The camera is blocked'), findsOneWidget);
        expect(find.textContaining('never uploaded'), findsOneWidget);

        camera.problem = null;
        await tapKey(tester, 'camera-retry');
        expect(find.byKey(const Key('camera-problem')), findsNothing);
        expect(camera.starts, 2);
        expect(find.byKey(const Key('check-camera')), findsOneWidget);
      },
    );

    testWidgets('a device without the camera bridge says so plainly', (
      tester,
    ) async {
      await openSession(tester, withCamera: false);

      expect(
        find.textContaining('Sessions need the web app for now'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('camera-retry')), findsNothing);
      await tester.tap(find.text('Back to my plan'));
      await tester.pumpAndSettle();
      expect(find.text('Knee plan'), findsOneWidget);
    });

    testWidgets('an exercise that is no longer in the plan is explained', (
      tester,
    ) async {
      final patient = FakePatientRepository()
        ..plan = plan('Knee plan', [
          squats,
        ]); // no requirements: the API says 404
      await openSession(tester, patient: patient);

      expect(
        find.text('That exercise is not in your current plan.'),
        findsOneWidget,
      );
      expect(patient.started, isEmpty);
    });
  });

  group('Session', () {
    testWidgets('the clock runs, and leaving the picture is reported', (
      tester,
    ) async {
      final opened = await openSession(tester);
      await holdGoodSetup(tester, opened.camera);

      await tester.pump(const Duration(seconds: 3));
      expect(
        tester.widget<Text>(find.byKey(const Key('session-timer'))).data,
        '00:03',
      );
      expect(find.text('Tracking your movement.'), findsOneWidget);

      await see(
        tester,
        opened.camera,
        frame(9000, hidden: {'left_ankle', 'right_ankle'}),
      );
      expect(find.text('Step back so your feet are visible.'), findsOneWidget);
      // Still the same session: stepping out of view does not start another.
      expect(opened.patient.started, hasLength(1));
      await tester.pump(const Duration(seconds: 2));
      expect(
        tester.widget<Text>(find.byKey(const Key('session-timer'))).data,
        '00:05',
      );
    });

    testWidgets(
      'ending asks first, saves the session and shows what was done',
      (tester) async {
        final opened = await openSession(tester);
        await holdGoodSetup(tester, opened.camera);
        await tester.pump(const Duration(seconds: 65));
        opened.patient.sessionSeconds = 68;

        await tapKey(tester, 'end-session');
        expect(find.text('End this session?'), findsOneWidget);
        await tester.tap(find.text('Keep going'));
        await tester.pumpAndSettle();
        expect(opened.patient.ended, isEmpty);

        await tapKey(tester, 'end-session');
        await tapKey(tester, 'confirm-end-session');

        expect(opened.patient.ended, ['session-1']);
        expect(find.byKey(const Key('session-summary')), findsOneWidget);
        // The time is the server's, not the clock on the screen.
        expect(
          find.descendant(
            of: find.byKey(const Key('summary-time')),
            matching: find.text('1 min 08 s'),
          ),
          findsOneWidget,
        );
        // Repetitions are not counted for this exercise, so none are claimed.
        expect(find.byKey(const Key('summary-repetitions')), findsNothing);
        expect(opened.camera.stopped, isTrue);

        await tapKey(tester, 'summary-done');
        expect(find.text('Knee plan'), findsOneWidget);
      },
    );

    testWidgets('an exercise whose repetitions cannot be counted says so', (
      tester,
    ) async {
      final opened = await openSession(tester);
      await holdGoodSetup(tester, opened.camera);

      expect(find.byKey(const Key('counting-unavailable')), findsOneWidget);
      expect(find.byKey(const Key('rep-count')), findsNothing);
      expect(opened.patient.repetitionWrites, isEmpty);
    });

    testWidgets('"My plan" during a session also asks before ending it', (
      tester,
    ) async {
      final opened = await openSession(tester);
      await holdGoodSetup(tester, opened.camera);

      await tapKey(tester, 'session-back');

      expect(find.text('End this session?'), findsOneWidget);
      expect(opened.patient.ended, isEmpty);
    });

    testWidgets('a failure while ending keeps the session on screen', (
      tester,
    ) async {
      final opened = await openSession(tester);
      await holdGoodSetup(tester, opened.camera);
      opened.patient.endFailure = ApiException.network;

      await tapKey(tester, 'end-session');
      await tapKey(tester, 'confirm-end-session');

      expect(find.textContaining('Could not reach PhysioAI'), findsOneWidget);
      expect(find.byKey(const Key('session-timer')), findsOneWidget);
      expect(opened.patient.ended, isEmpty);
    });
  });
}
