// US 3.3 and 3.4: counting repetitions during a session, the feedback each
// one gets, and the safety pause on a RED repetition.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:physioai/core/api/api_exception.dart';
import 'package:physioai/features/exercises/exercise_models.dart';
import 'package:physioai/features/session/live_session.dart';
import 'package:physioai/features/session/pose/pose_models.dart';
import 'package:physioai/features/progress/session_widgets.dart';
import 'package:physioai/features/session/precheck.dart';
import 'package:physioai/features/session/rep_counter.dart';
import 'package:physioai/features/session/repetitions.dart';
import 'package:physioai/features/session/session_records.dart';

import 'auth_flow_test.dart';
import 'plans_test.dart';
import 'session_test.dart' hide main;

const armAbduction = ExerciseBrief(
  id: 'ex-arm-abduction',
  slug: 'arm-abduction',
  name: 'Arm Abduction',
  domain: 'Shoulder rehabilitation',
  bodyArea: 'shoulder',
  primaryTargets: 'Deltoid, supraspinatus',
  targetJoints: ['shoulder', 'elbow', 'hip'],
  instructions: 'Raise both arms out to the side to shoulder height.',
);

const trunkLean = SessionCheck(
  key: 'trunk_lean',
  label: 'Trunk lean',
  unit: 'degrees',
  info: 5,
  amber: 10,
  red: 20,
  message: 'Stand tall and keep your body upright as you lift.',
);
const elbowBend = SessionCheck(
  key: 'elbow_bend',
  label: 'Elbow bend',
  unit: 'degrees',
  info: 10,
  amber: 20,
  message: 'Keep your elbows straight as you lift.',
);

const arms = [
  'left_shoulder',
  'right_shoulder',
  'left_elbow',
  'right_elbow',
  'left_wrist',
  'right_wrist',
  'left_hip',
  'right_hip',
];

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

/// Someone facing the camera with both arms raised [raise] degrees from their
/// sides, elbows bent by [elbow] and the trunk leaning by [lean]. Built in
/// true proportions, then squeezed into the picture's 0 to 1 width as a
/// camera with this [aspect] would report it.
PoseFrame armFrame(
  double timeMs, {
  double raise = 15,
  double elbow = 0,
  double lean = 0,
  Set<String> hidden = const {},
  double aspect = 4 / 3,
}) {
  final hipMid = (0.5 * aspect, 0.60);
  final down = _turn((0, 1), lean);
  final points = <String, _Point>{};
  for (final (side, sign) in [('left', 1.0), ('right', -1.0)]) {
    final shoulder = _plus(hipMid, _turn((sign * 0.10, -0.30), lean));
    final upperArm = _turn(down, -sign * raise);
    final elbowAt = _plus(shoulder, upperArm, 0.14);
    points['${side}_hip'] = _plus(hipMid, _turn((sign * 0.10, 0), lean));
    points['${side}_shoulder'] = shoulder;
    points['${side}_elbow'] = elbowAt;
    points['${side}_wrist'] = _plus(
      elbowAt,
      _turn(upperArm, -sign * elbow),
      0.13,
    );
  }
  return PoseFrame(
    timeMs: timeMs,
    brightness: 0.6,
    landmarks: {
      for (final name in poseLandmarkNames)
        name: Landmark(
          (points[name]?.$1 ?? 0.5 * aspect) / aspect,
          points[name]?.$2 ?? 0.9,
          hidden.contains(name) ? 0.1 : 0.95,
        ),
    },
  );
}

/// How far the arms are raised through one repetition, ten frames a second.
const lift = [15.0, 15.0, 50.0, 90.0, 90.0, 90.0, 50.0, 15.0, 15.0, 15.0];

/// One full repetition as the camera sees it, starting at [from].
List<PoseFrame> repFrames(
  double from, {
  double lean = 0,
  double elbow = 0,
  Set<String> hidden = const {},
}) => [
  for (final (i, raise) in lift.indexed)
    armFrame(
      from + i * 100,
      raise: raise,
      lean: lean,
      elbow: elbow,
      hidden: hidden,
    ),
];

LiveSessionEngine engineFor({
  String slug = 'arm-abduction',
  List<String> checks = const ['trunk_lean', 'elbow_bend'],
  int sets = 2,
  int reps = 3,
}) => LiveSessionEngine(
  exerciseSlug: slug,
  targetJoints: const ['shoulder', 'elbow', 'hip'],
  checkKeys: checks,
  sets: sets,
  repsPerSet: reps,
  minVisibility: 0.6,
  aspectRatio: 4 / 3,
);

/// Feeds the frames and returns the repetitions they complete.
List<RepetitionDraft> feed(LiveSessionEngine engine, List<PoseFrame> frames) =>
    [for (final frame in frames) ?engine.add(frame, frame.timeMs)];

/// Jane starts a session of Arm Abduction: two sets of three.
Future<({FakeCamera camera, FakePatientRepository patient})> startArmSession(
  WidgetTester tester, {
  FakePatientRepository? patient,
}) async {
  final repository = (patient ?? FakePatientRepository())
    ..plan = plan('Shoulder plan', [armAbduction])
    ..checks = const [trunkLean, elbowBend]
    ..requirements['item-0'] = const PrecheckRequirements(
      itemId: 'item-0',
      exercise: armAbduction,
      sets: 2,
      reps: 3,
      restSeconds: 30,
      difficulty: Difficulty.easy,
      requiredLandmarks: arms,
      minVisibility: 0.6,
      minBrightness: 0.25,
      holdMs: 1500,
    );
  final opened = await openSession(tester, patient: repository);
  for (final t in [0.0, 500.0, 1000.0, 1600.0]) {
    await see(tester, opened.camera, armFrame(t));
  }
  await tester.pumpAndSettle();
  return opened;
}

/// The next moment on the camera's clock, so each repetition follows the last.
double _clock = 2000;

/// Jane does one repetition in front of the camera.
Future<void> doRep(
  WidgetTester tester,
  FakeCamera camera, {
  double lean = 0,
  double elbow = 0,
}) async {
  for (final frame in repFrames(_clock, lean: lean, elbow: elbow)) {
    await see(tester, camera, frame);
  }
  _clock += 1000;
  await tester.pump();
}

String textOf(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key))).data!;

Finder within(String key, String text) =>
    find.descendant(of: find.byKey(Key(key)), matching: find.text(text));

void main() {
  setUp(() => _clock = 2000);

  group('Counting repetitions from a joint angle', () {
    const arm = RepProfile(joint: 'shoulder', rest: 30, peak: 70);

    /// The repetitions counted from [angles], one every [step] milliseconds.
    List<CountedRep> count(
      RepCounter counter,
      List<double?> angles, {
      double from = 0,
      double step = 100,
    }) => [
      for (final (i, angle) in angles.indexed)
        ?counter.add(from + i * step, angle),
    ];

    test('one for each full lift and return, with when it happened', () {
      final counter = RepCounter(arm);
      final reps = count(counter, [...lift, ...lift, ...lift]);

      expect(reps, hasLength(3));
      // From leaving the resting position to being back in it.
      expect(reps.first, (startedMs: 300.0, endedMs: 800.0));
      expect(reps[1].startedMs, greaterThan(reps[0].endedMs));
      expect(counter.inRep, isFalse);
    });

    test('a lift that does not reach the top is not a repetition', () {
      final counter = RepCounter(arm);
      expect(count(counter, [15, 15, 40, 55, 60, 55, 40, 15, 15, 15]), isEmpty);
      // And it does not spoil the next one.
      expect(count(counter, lift, from: 1000), hasLength(1));
    });

    test('one wild camera frame is not a repetition', () {
      final counter = RepCounter(arm);
      expect(
        count(counter, [15, 15, 15, 140, 15, 15, 15, 15, 140, 15, 15]),
        isEmpty,
      );
    });

    test('wobbling at the top is still one repetition', () {
      final counter = RepCounter(arm);
      expect(
        count(counter, [
          15,
          15,
          50,
          90,
          72,
          66,
          74,
          68,
          90,
          71,
          50,
          15,
          15,
          15,
        ]),
        hasLength(1),
      );
    });

    test('a slow repetition is counted, however long it takes', () {
      final counter = RepCounter(arm);
      final reps = count(counter, [
        15,
        15,
        ...List.filled(40, 50.0),
        ...List.filled(200, 90.0),
        ...List.filled(40, 50.0),
        15,
        15,
        15,
      ]);
      expect(reps, hasLength(1));
      expect(reps.single.endedMs - reps.single.startedMs, greaterThan(25000));
    });

    test('nothing is counted until the resting position has been seen', () {
      final counter = RepCounter(arm);
      // The camera's first sight of the patient is with the arms already up.
      expect(count(counter, [90, 90, 90, 50, 15, 15, 15]), isEmpty);
      expect(count(counter, lift, from: 1000), hasLength(1));
    });

    test('a movement lost from view for too long is forgotten', () {
      final counter = RepCounter(arm);
      expect(count(counter, [15, 15, 50, 90, 90, 90]), isEmpty);
      expect(counter.inRep, isTrue);
      // Two seconds out of the picture, then standing at rest again.
      expect(
        count(counter, [...List.filled(20, null), 15, 15, 15], from: 600),
        isEmpty,
      );
      expect(counter.inRep, isFalse);
      expect(count(counter, lift, from: 4000), hasLength(1));
    });

    test('a moment out of view does not lose the repetition', () {
      final counter = RepCounter(arm);
      expect(
        count(counter, [15, 15, 50, 90, 90, null, null, null, 50, 15, 15, 15]),
        hasLength(1),
      );
    });

    test('a movement too fast to be real is not counted', () {
      final counter = RepCounter(arm);
      expect(
        count(counter, [15, 15, 15, 90, 90, 90, 15, 15, 15, 15], step: 30),
        isEmpty,
      );
    });

    test('an exercise where the angle shrinks is counted the same way', () {
      final counter = RepCounter(repProfiles['squats']!);
      expect(
        count(counter, [
          175,
          175,
          140,
          100,
          100,
          100,
          140,
          175,
          175,
          175,
          // Half-way down and up again is not a squat.
          150,
          130,
          130,
          150,
          175,
          175,
          175,
        ]),
        hasLength(1),
      );
    });

    test('with both sides in view it follows the one further along', () {
      expect(arm.signal(40, 85), 85);
      expect(arm.signal(null, 85), 85);
      expect(arm.signal(40, null), 40);
      expect(arm.signal(null, null), isNull);
      expect(repProfiles['squats']!.signal(170, 100), 100);
    });
  });

  group('The frames the tests draw', () {
    test('measure what they were drawn with', () {
      final draft = feed(engineFor(), repFrames(0, lean: 7, elbow: 12)).single;
      expect(draft.measures['trunk_lean'], closeTo(7, 0.01));
      expect(draft.measures['elbow_bend'], closeTo(12, 0.01));
    });
  });

  group('Turning frames into repetitions', () {
    test('each repetition carries the worst of what was measured in it', () {
      final engine = engineFor();
      final leans = <double>[0, 0, 0, 2, 8, 8, 3, 1, 0, 0];
      final elbows = <double>[0, 0, 0, 4, 6, 13, 13, 5, 0, 0];
      final drafts = feed(engine, [
        for (final (i, raise) in lift.indexed)
          armFrame(i * 100, raise: raise, lean: leans[i], elbow: elbows[i]),
      ]);

      final draft = drafts.single;
      expect((draft.setNumber, draft.repNumber), (1, 1));
      expect((draft.startedMs, draft.endedMs), (300, 800));
      expect(draft.measures.keys, ['trunk_lean', 'elbow_bend']);
      expect(draft.measures['trunk_lean'], closeTo(8, 0.01));
      expect(draft.measures['elbow_bend'], closeTo(13, 0.01));
    });

    test('one wild camera frame is not held against the repetition', () {
      // A single frame where the tracking jumps would otherwise read as a
      // dangerous lean and pause the session.
      final leans = <double>[0, 0, 0, 1, 45, 2, 1, 0, 0, 0];
      final draft = feed(engineFor(), [
        for (final (i, raise) in lift.indexed)
          armFrame(i * 100, raise: raise, lean: leans[i]),
      ]).single;

      expect(draft.measures['trunk_lean'], closeTo(2, 0.01));
    });

    test('what happens between repetitions is not held against the next', () {
      final engine = engineFor();
      // Bending over to pick something up, then an abandoned half lift with
      // a bad lean, then a clean repetition.
      final drafts = feed(engine, [
        armFrame(0, lean: 40),
        armFrame(100, lean: 40),
        armFrame(200),
        armFrame(300),
        armFrame(400, raise: 50, lean: 30),
        armFrame(500, raise: 55, lean: 30),
        armFrame(600, raise: 55, lean: 30),
        armFrame(700, lean: 0),
        armFrame(800, lean: 0),
        armFrame(900, lean: 0),
        ...repFrames(1000),
      ]);

      expect(drafts, hasLength(1));
      expect(drafts.single.measures['trunk_lean'], closeTo(0, 0.01));
    });

    test('a check that was never in view is sent as unknown, not guessed', () {
      final drafts = feed(
        engineFor(),
        repFrames(0, hidden: {'left_wrist', 'right_wrist'}),
      );

      expect(drafts.single.measures, containsPair('elbow_bend', null));
      expect(drafts.single.measures['trunk_lean'], isNotNull);
      expect(
        drafts.single.toJson()['measures'],
        containsPair('elbow_bend', null),
      );
    });

    test('a check this version cannot measure is sent as unknown too', () {
      final drafts = feed(
        engineFor(checks: const ['trunk_lean', 'depth', 'shoulder_hike']),
        repFrames(0),
      );
      expect(drafts.single.measures.keys, [
        'trunk_lean',
        'depth',
        'shoulder_hike',
      ]);
      expect(drafts.single.measures['depth'], isNull);
      expect(drafts.single.measures['shoulder_hike'], isNull);
    });

    test('sets fill up in turn, and nothing is counted past the last', () {
      final engine = engineFor();
      final drafts = feed(engine, [
        for (var i = 0; i < 8; i++) ...repFrames(i * 1000.0),
      ]);

      expect(
        [for (final draft in drafts) (draft.setNumber, draft.repNumber)],
        [(1, 1), (1, 2), (1, 3), (2, 1), (2, 2), (2, 3)],
      );
      expect(engine.prescriptionDone, isTrue);
      expect(engine.counted, 6);
      // Every repetition has its own key.
      expect({for (final draft in drafts) draft.clientKey}, hasLength(6));
    });

    test('the count can be put back to what the server holds', () {
      final engine = engineFor();
      feed(engine, [for (var i = 0; i < 5; i++) ...repFrames(i * 1000.0)]);
      expect((engine.currentSet, engine.repsInSet), (2, 2));

      engine.rewindTo(setNumber: 1, repNumber: 2);
      expect((engine.currentSet, engine.repsInSet, engine.counted), (1, 2, 2));
      final next = feed(engine, repFrames(6000)).single;
      expect((next.setNumber, next.repNumber), (1, 3));

      engine.rewindToCount(3);
      expect((engine.currentSet, engine.repsInSet), (2, 0));
      engine.rewindToCount(0);
      expect((engine.currentSet, engine.repsInSet), (1, 0));
    });

    test('an interrupted movement is not finished off as a repetition', () {
      final engine = engineFor();
      expect(feed(engine, repFrames(0).sublist(0, 6)), isEmpty);
      engine.interrupt();
      // The arms come down after the interruption: that is not a repetition.
      expect(feed(engine, repFrames(0).sublist(6)), isEmpty);
      expect(feed(engine, repFrames(1000)), hasLength(1));
    });

    test('an exercise it has no profile for is not counted', () {
      final engine = engineFor(slug: 'leg-lunge');
      expect(engine.canCount, isFalse);
      expect(feed(engine, repFrames(0)), isEmpty);
      expect(engineFor(slug: '').canCount, isFalse);
    });
  });

  group('Session with counting', () {
    testWidgets(
      'counts each repetition, stores it and moves through the sets',
      (tester) async {
        final opened = await startArmSession(tester);

        expect(textOf(tester, 'rep-count'), '0');
        expect(textOf(tester, 'set-progress'), 'Set 1 of 2');
        expect(find.byKey(const Key('rep-feedback')), findsOneWidget);
        expect(find.byKey(const Key('counting-unavailable')), findsNothing);
        expect(opened.patient.repetitionWrites, isEmpty);

        await doRep(tester, opened.camera);

        expect(textOf(tester, 'rep-count'), '1');
        expect(within('rep-feedback-ok', 'Good repetition.'), findsOneWidget);
        final sent = opened.patient.repetitionWrites.single;
        expect(sent.sessionId, 'session-1');
        expect((sent.repetition.setNumber, sent.repetition.repNumber), (1, 1));
        // Measurements only, one for each check of the session.
        expect(sent.repetition.measures.keys, ['trunk_lean', 'elbow_bend']);
        expect(sent.repetition.endedMs, greaterThan(sent.repetition.startedMs));

        await doRep(tester, opened.camera);
        await doRep(tester, opened.camera);
        expect(textOf(tester, 'rep-count'), '0');
        expect(textOf(tester, 'set-progress'), 'Set 2 of 2');

        for (var i = 0; i < 3; i++) {
          await doRep(tester, opened.camera);
        }
        expect(find.byKey(const Key('prescription-done')), findsOneWidget);
        expect(textOf(tester, 'rep-count'), '3');
        expect(textOf(tester, 'set-progress'), 'Set 2 of 2');

        // Carrying on past the prescription adds nothing.
        await doRep(tester, opened.camera);
        expect(opened.patient.storedRepetitions, hasLength(6));
        expect(
          [
            for (final stored in opened.patient.storedRepetitions)
              (stored.setNumber, stored.repNumber),
          ],
          [(1, 1), (1, 2), (1, 3), (2, 1), (2, 2), (2, 3)],
        );
      },
    );

    testWidgets('INFO and AMBER show the corrective message and carry on', (
      tester,
    ) async {
      final opened = await startArmSession(tester);

      await doRep(tester, opened.camera, lean: 7);
      expect(within('rep-feedback-info', trunkLean.message), findsOneWidget);

      await doRep(tester, opened.camera, elbow: 25);
      expect(within('rep-feedback-amber', elbowBend.message), findsOneWidget);
      expect(find.byKey(const Key('safety-pause')), findsNothing);
      expect(find.text('Session in progress'), findsOneWidget);

      // The worst check is the one shown.
      await doRep(tester, opened.camera, lean: 12, elbow: 12);
      expect(within('rep-feedback-amber', trunkLean.message), findsOneWidget);

      await doRep(tester, opened.camera);
      expect(within('rep-feedback-ok', 'Good repetition.'), findsOneWidget);
      expect(
        [for (final stored in opened.patient.storedRepetitions) stored.tier],
        [
          FeedbackTier.info,
          FeedbackTier.amber,
          FeedbackTier.amber,
          FeedbackTier.ok,
        ],
      );
    });

    testWidgets(
      'a RED repetition pauses the session until it is acknowledged',
      (tester) async {
        final opened = await startArmSession(tester);
        await doRep(tester, opened.camera);

        await doRep(tester, opened.camera, lean: 25);

        expect(find.byKey(const Key('safety-pause')), findsOneWidget);
        expect(textOf(tester, 'pause-message'), trunkLean.message);
        expect(find.text('Session paused'), findsNWidgets(2));
        expect(find.byKey(const Key('rep-count')), findsNothing);
        expect(opened.patient.storedRepetitions.last.tier, FeedbackTier.red);

        // Exercising on regardless is not counted and not sent.
        await doRep(tester, opened.camera);
        await doRep(tester, opened.camera);
        expect(opened.patient.repetitionWrites, hasLength(2));
        expect(find.byKey(const Key('safety-pause')), findsOneWidget);

        await tapKey(tester, 'acknowledge-pause');

        expect(opened.patient.acknowledged, ['repetition-2']);
        expect(find.byKey(const Key('safety-pause')), findsNothing);
        expect(find.text('Session in progress'), findsOneWidget);
        expect(textOf(tester, 'rep-count'), '2');

        await doRep(tester, opened.camera);
        expect(textOf(tester, 'rep-count'), '0');
        expect(textOf(tester, 'set-progress'), 'Set 2 of 2');
        final last = opened.patient.repetitionWrites.last.repetition;
        expect((last.setNumber, last.repNumber), (1, 3));
      },
    );

    testWidgets('the session stays paused when acknowledging fails', (
      tester,
    ) async {
      final opened = await startArmSession(tester);
      await doRep(tester, opened.camera, lean: 25);
      opened.patient.acknowledgeFailure = ApiException.network;

      await tapKey(tester, 'acknowledge-pause');

      expect(find.byKey(const Key('pause-error')), findsOneWidget);
      expect(find.byKey(const Key('safety-pause')), findsOneWidget);
      await doRep(tester, opened.camera);
      expect(opened.patient.repetitionWrites, hasLength(1));

      opened.patient.acknowledgeFailure = null;
      await tapKey(tester, 'acknowledge-pause');
      expect(find.byKey(const Key('safety-pause')), findsNothing);
    });

    testWidgets('a repetition that could not be saved is sent again with the '
        'same key and stored once', (tester) async {
      final opened = await startArmSession(tester);
      opened.patient.repetitionFailure = ApiException.network;

      await doRep(tester, opened.camera);

      expect(find.byKey(const Key('save-problem')), findsOneWidget);
      // No feedback is shown for a repetition the server has not judged.
      expect(find.byKey(const Key('rep-feedback-ok')), findsNothing);
      expect(opened.patient.storedRepetitions, isEmpty);

      // The next one waits its turn behind it.
      await doRep(tester, opened.camera, elbow: 25);
      opened.patient.repetitionFailure = null;
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();

      expect(find.byKey(const Key('save-problem')), findsNothing);
      final writes = opened.patient.repetitionWrites;
      expect(writes.length, greaterThanOrEqualTo(3));
      expect(writes[0].repetition.clientKey, writes[1].repetition.clientKey);
      expect(
        [
          for (final stored in opened.patient.storedRepetitions)
            (stored.repNumber, stored.tier),
        ],
        [(1, FeedbackTier.ok), (2, FeedbackTier.amber)],
      );
      expect(within('rep-feedback-amber', elbowBend.message), findsOneWidget);
    });

    testWidgets('a session paused somewhere else shows that pause', (
      tester,
    ) async {
      final opened = await startArmSession(tester);
      await doRep(tester, opened.camera);
      opened.patient.pauseElsewhere('Stop and rest your shoulder.');

      await doRep(tester, opened.camera);
      await tester.pump();

      expect(opened.patient.sessionReads, 1);
      expect(textOf(tester, 'pause-message'), 'Stop and rest your shoulder.');
      // The repetition the server refused is not in the count.
      expect(opened.patient.storedRepetitions, hasLength(1));
      await tapKey(tester, 'acknowledge-pause');
      expect(textOf(tester, 'rep-count'), '1');
    });

    testWidgets('a session that ended somewhere else stops counting', (
      tester,
    ) async {
      final opened = await startArmSession(tester);
      opened.patient.repetitionFailure = const ApiException(
        code: 'session_not_active',
        message: 'This session has already ended.',
        statusCode: 409,
      );

      await doRep(tester, opened.camera);
      expect(
        within('session-stopped', 'This session has already ended.'),
        findsOneWidget,
      );

      await doRep(tester, opened.camera);
      await tester.pump(const Duration(seconds: 3));
      expect(opened.patient.repetitionWrites, hasLength(1));
    });

    testWidgets('ending shows what the session came to', (tester) async {
      final opened = await startArmSession(tester);
      await doRep(tester, opened.camera);
      await doRep(tester, opened.camera, elbow: 25);
      await doRep(tester, opened.camera, lean: 25);
      await tapKey(tester, 'acknowledge-pause');
      await doRep(tester, opened.camera, lean: 6);

      await tapKey(tester, 'end-session');
      await tapKey(tester, 'confirm-end-session');

      expect(opened.patient.ended, ['session-1']);
      expect(find.byKey(const Key('session-summary')), findsOneWidget);
      expect(find.text('Arm Abduction'), findsOneWidget);
      expect(within('summary-repetitions', '4'), findsOneWidget);
      expect(within('summary-ok', '1'), findsOneWidget);
      expect(within('summary-info', '1'), findsOneWidget);
      expect(within('summary-amber', '1'), findsOneWidget);
      expect(within('summary-red', '1'), findsOneWidget);
      // (100 + 55 + 0 + 85) / 4: the score comes from the server's summary.
      expect(
        tester.widget<ScoreBadge>(find.byKey(const Key('summary-score'))).score,
        60,
      );
      expect(
        textOf(tester, 'summary-trend'),
        'This is your first session of this exercise.',
      );
      expect(opened.camera.stopped, isTrue);
      expect(find.byKey(const Key('end-session')), findsNothing);

      await tapKey(tester, 'summary-done');
      expect(find.text('Shoulder plan'), findsOneWidget);
    });

    testWidgets('the summary compares with the previous session', (
      tester,
    ) async {
      final patient = FakePatientRepository()
        ..previous = PreviousSession(
          id: 'session-0',
          endedAt: DateTime.utc(2026, 10, 9, 17),
          repetitions: 6,
          formScore: 78,
        );
      final opened = await startArmSession(tester, patient: patient);
      await doRep(tester, opened.camera);
      await doRep(tester, opened.camera, lean: 6);

      await tapKey(tester, 'end-session');
      await tapKey(tester, 'confirm-end-session');

      // (100 + 85) / 2 = 93 after rounding.
      expect(
        tester.widget<ScoreBadge>(find.byKey(const Key('summary-score'))).score,
        93,
      );
      expect(
        textOf(tester, 'summary-trend'),
        'Up 15 points from your last session (78).',
      );
    });

    testWidgets(
      'a session with nothing to score says so instead of showing 0',
      (tester) async {
        final opened = await startArmSession(tester);

        await tapKey(tester, 'end-session');
        await tapKey(tester, 'confirm-end-session');

        expect(
          tester
              .widget<ScoreBadge>(find.byKey(const Key('summary-score')))
              .score,
          isNull,
        );
        expect(
          textOf(tester, 'summary-score-label'),
          'No form score: there was nothing to score.',
        );
        expect(within('summary-repetitions', '0'), findsOneWidget);
        expect(opened.patient.ended, ['session-1']);
      },
    );

    testWidgets('a paused session can be ended without acknowledging', (
      tester,
    ) async {
      final opened = await startArmSession(tester);
      await doRep(tester, opened.camera, lean: 25);

      await tapKey(tester, 'end-session');
      await tapKey(tester, 'confirm-end-session');

      expect(opened.patient.ended, ['session-1']);
      expect(opened.patient.acknowledged, isEmpty);
      expect(within('summary-red', '1'), findsOneWidget);
      expect(within('summary-repetitions', '1'), findsOneWidget);
    });
  });
}
