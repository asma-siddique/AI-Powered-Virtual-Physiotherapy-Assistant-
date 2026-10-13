// The spoken coach: what is said aloud during a session, for a patient who
// is standing back from the screen and cannot read it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' hide within;
import 'package:physioai/core/voice/voice_coach.dart';
import 'package:physioai/features/exercises/exercise_models.dart';
import 'package:physioai/features/session/narrator.dart';
import 'package:physioai/features/session/precheck.dart';
import 'package:physioai/features/session/repetitions.dart';

import 'auth_flow_test.dart';
import 'live_session_test.dart' hide main;
import 'plans_test.dart' show plan;
import 'session_test.dart' hide main;

const prescription = PrecheckRequirements(
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

RecordedRepetition stored(
  int rep, {
  int set = 1,
  FeedbackTier tier = FeedbackTier.ok,
  String? message,
  bool paused = false,
}) => RecordedRepetition(
  id: 'repetition-$set-$rep',
  setNumber: set,
  repNumber: rep,
  startedMs: 0,
  endedMs: 900,
  tier: tier,
  feedback: [
    if (message != null)
      RepetitionFeedback(
        check: 'trunk_lean',
        label: 'Trunk lean',
        tier: tier,
        value: 12,
        message: message,
      ),
  ],
  pause: paused
      ? SessionPause(
          repetitionId: 'repetition-$set-$rep',
          check: 'trunk_lean',
          message: message!,
        )
      : null,
);

const upright = 'Keep your body upright as you lift.';
const straight = 'Keep your elbows straight as you lift.';

void main() {
  late FakeVoiceCoach voice;
  late SessionNarrator narrator;
  var muted = false;

  setUp(() {
    voice = FakeVoiceCoach();
    muted = false;
    narrator = SessionNarrator(voice, muted: () => muted);
  });

  void rep(RecordedRepetition repetition) =>
      narrator.repetition(repetition, requirements: prescription);

  group('What the coach says', () {
    test('the start: the exercise, the prescription and how to do it', () {
      narrator.started(prescription);

      expect(voice.said.single, startsWith('You are all set. Arm Abduction: '));
      expect(voice.said.single, contains('2 sets of 3.'));
      expect(voice.said.single, contains(armAbduction.instructions));
      expect(voice.said.single, endsWith('Start when you are ready.'));
      expect(voice.lines.single.urgency, Urgency.background);
    });

    test('good repetitions are simply counted', () {
      rep(stored(1));
      rep(stored(2));

      expect(voice.said, ['1.', '2.']);
      expect(voice.lines.every((line) => line.tone == null), isTrue);
      expect(voice.lines.first.urgency, Urgency.repetition);
    });

    test('a small correction is spoken with the count, without an alarm', () {
      rep(stored(1, tier: FeedbackTier.info, message: straight));

      expect(voice.said, ['1. $straight']);
      expect(voice.lines.single.tone, isNull);
    });

    test('an AMBER repetition sounds the alert before the correction', () {
      rep(stored(1, tier: FeedbackTier.amber, message: upright));

      expect(voice.said, ['1. $upright']);
      expect(voice.lines.single.tone, CoachTone.amber);
      expect(voice.lines.single.urgency, Urgency.repetition);
    });

    test('a RED repetition sounds the alarm and says to stop, at once', () {
      rep(stored(2, tier: FeedbackTier.red, message: upright, paused: true));

      final line = voice.lines.single;
      expect(line.tone, CoachTone.red);
      // It cuts off whatever was being said.
      expect(line.urgency, Urgency.urgent);
      expect(line.text, startsWith('Stop. $upright'));
      expect(line.text, contains('Your session is paused.'));
      expect(line.text, contains('confirm before you continue'));
    });

    test('praise follows a correction that worked, not every repetition', () {
      rep(stored(1, tier: FeedbackTier.amber, message: upright));
      rep(stored(2));
      rep(stored(1, set: 2));

      expect(voice.said, ['1. $upright', '2. Good.', '1.']);
    });

    test('the same small correction is a reminder, not a drone', () {
      for (var i = 1; i <= 3; i++) {
        narrator.repetition(
          stored(i, tier: FeedbackTier.info, message: straight),
          requirements: const PrecheckRequirements(
            itemId: 'item-0',
            exercise: armAbduction,
            sets: 1,
            reps: 10,
            restSeconds: 0,
            difficulty: Difficulty.easy,
            requiredLandmarks: arms,
            minVisibility: 0.6,
            minBrightness: 0.25,
            holdMs: 1500,
          ),
        );
      }
      rep(stored(1, set: 2, tier: FeedbackTier.info, message: upright));

      // Said, then just counted twice; a different one is said straight away.
      expect(voice.said, ['1. $straight', '2.', '3.', '1. $upright']);
    });

    test('an AMBER correction is repeated every time it happens', () {
      rep(stored(1, tier: FeedbackTier.amber, message: upright));
      rep(stored(2, tier: FeedbackTier.amber, message: upright));

      expect(voice.said, ['1. $upright', '2. $upright']);
    });

    test('the end of a set says how long to rest and what comes next', () {
      rep(stored(3));

      expect(
        voice.said.single,
        '3. Set 1 complete. Rest for 30 seconds, '
        'then start set 2.',
      );
      expect(voice.lines.single.tone, CoachTone.done);
    });

    test('the last repetition of the last set says the exercise is done', () {
      rep(stored(3, set: 2, tier: FeedbackTier.amber, message: upright));

      expect(voice.said.single, startsWith('3. $upright All sets complete.'));
      // The correction's alert is what sounds, not the chime.
      expect(voice.lines.single.tone, CoachTone.amber);
    });

    test('carrying on after the safety stop is acknowledged', () {
      narrator.resumed();

      expect(voice.said.single, contains('Return to your starting position'));
    });

    test('the summary: how many repetitions and the score', () {
      narrator.finished(
        ExerciseSession(
          id: 'session-1',
          status: 'completed',
          startedAt: DateTime(2026, 10, 14),
          totals: const SessionTotals(repetitions: 6, ok: 5, amber: 1),
        ),
      );

      expect(voice.said.single, 'Session complete. 6 repetitions.');
      expect(voice.lines.single.tone, CoachTone.done);
      // Anything still being said about the last repetition is dropped.
      expect(voice.stops, 1);
    });
  });

  group('Where to stand', () {
    const stepBack = 'Step back until your whole body fits in the picture.';

    test('guidance is said once, then again only after a while', () {
      narrator.guidance(stepBack, 0);
      narrator.guidance(stepBack, 100);
      narrator.guidance(stepBack, 6900);
      expect(voice.said, [stepBack]);

      narrator.guidance(stepBack, 7000);
      expect(voice.said, [stepBack, stepBack]);
    });

    test('different guidance is said straight away', () {
      narrator.guidance(stepBack, 0);
      narrator.guidance('Stand in front of the camera so it can see you.', 300);

      expect(voice.said, hasLength(2));
    });

    test('guidance that was put right is said afresh if needed again', () {
      narrator.guidance(stepBack, 0);
      narrator.guidance(null, 500);
      narrator.guidance(stepBack, 900);

      expect(voice.said, [stepBack, stepBack]);
    });
  });

  group('Switched off', () {
    test('a muted coach says nothing at all', () {
      muted = true;

      narrator.started(prescription);
      narrator.guidance('Step back.', 0);
      rep(stored(1, tier: FeedbackTier.red, message: upright, paused: true));

      expect(voice.lines, isEmpty);
    });

    test('switching it off stops it mid-sentence', () {
      narrator.started(prescription);

      narrator.silence();

      expect(voice.stops, 1);
    });
  });

  group('During a session', () {
    testWidgets('the camera check and the start are spoken', (tester) async {
      final patient = FakePatientRepository()
        ..plan = plan('Shoulder plan', [armAbduction]);
      final opened = await openArmCheck(tester, patient);

      // Only her head and shoulders are in the picture.
      await see(
        tester,
        opened.camera,
        armFrame(0, hidden: {'left_hip', 'right_hip'}),
      );
      expect(spokenCoach.said, hasLength(1));
      expect(spokenCoach.said.single, contains('Step back'));

      await passCheck(tester, opened.camera);

      expect(spokenCoach.said.last, startsWith('You are all set.'));
      expect(spokenCoach.said.last, contains(armAbduction.instructions));
    });

    testWidgets('each repetition is counted aloud with the server\'s verdict', (
      tester,
    ) async {
      final opened = await startArmSession(tester);
      spokenCoach.lines.clear();

      await doRep(tester, opened.camera);
      await doRep(tester, opened.camera, elbow: 25);

      expect(spokenCoach.said, ['1.', '2. ${elbowBend.message}']);
      expect(spokenCoach.lines.last.tone, CoachTone.amber);

      // The third closes the set.
      await doRep(tester, opened.camera);
      expect(spokenCoach.said.last, startsWith('3. Good. Set 1 complete.'));
    });

    testWidgets(
      'a RED repetition raises the alarm, and resuming is confirmed',
      (tester) async {
        final opened = await startArmSession(tester);
        spokenCoach.lines.clear();

        await doRep(tester, opened.camera, lean: 25);

        final alarm = spokenCoach.lines.single;
        expect(alarm.tone, CoachTone.red);
        expect(alarm.urgency, Urgency.urgent);
        expect(alarm.text, startsWith('Stop. ${trunkLean.message}'));

        // Nothing more is said while the session is paused.
        await doRep(tester, opened.camera);
        expect(spokenCoach.lines, hasLength(1));

        await acknowledgePause(tester);
        expect(spokenCoach.said.last, contains('continue when you are ready'));
      },
    );

    testWidgets('the summary is read out when the session ends', (
      tester,
    ) async {
      final opened = await startArmSession(tester);
      await doRep(tester, opened.camera);

      await tapKey(tester, 'session-back');
      await tapKey(tester, 'confirm-end-session');

      expect(spokenCoach.said.last, startsWith('Session complete.'));
      expect(spokenCoach.lines.last.tone, CoachTone.done);
    });

    testWidgets('the speaker button switches the coach off and on', (
      tester,
    ) async {
      final opened = await startArmSession(tester);
      spokenCoach.lines.clear();
      final stopsBefore = spokenCoach.stops;

      await tapKey(tester, 'voice-toggle');
      expect(spokenCoach.stops, stopsBefore + 1);
      expect(find.byIcon(Icons.volume_off_rounded), findsOneWidget);
      await doRep(tester, opened.camera, elbow: 25);
      expect(spokenCoach.lines, isEmpty);
      // What is on the screen does not depend on the voice.
      expect(within('rep-feedback-amber', elbowBend.message), findsOneWidget);

      await tapKey(tester, 'voice-toggle');
      await doRep(tester, opened.camera);
      // It kept following along while it was silent: the correction worked.
      expect(spokenCoach.said, ['2. Good.']);
    });
  });
}
