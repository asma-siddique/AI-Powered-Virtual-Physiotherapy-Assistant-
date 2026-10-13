// US 9.2: the app degrades gracefully. A dropped connection never loses a
// repetition, and nothing waits for ever without a way to try again.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' hide within;
import 'package:physioai/core/api/api_exception.dart';
import 'package:physioai/features/auth/auth_models.dart';
import 'package:physioai/features/session/repetitions.dart';

import 'auth_flow_test.dart';
import 'live_session_test.dart' hide main;
import 'plans_test.dart' show lunge, plan, squats;
import 'session_test.dart' hide main;

/// A camera whose tracker takes as long to load as the test decides.
class SlowCamera extends FakeCamera {
  var _ready = Completer<void>();
  int stops = 0;

  void finishStarting() => _ready.complete();

  @override
  Future<void> start() async {
    starts++;
    await _ready.future;
  }

  @override
  Future<void> stop() async {
    stops++;
    // What was being waited for is given up; the next start waits afresh.
    _ready = Completer<void>();
  }
}

/// Jane opens the camera check for Squats with a camera that has not started
/// yet. The screen keeps moving while it waits, so it is not waited on.
Future<void> openWith(WidgetTester tester, SlowCamera camera) async {
  await pumpApp(
    tester,
    auth: FakeAuthRepository(
      saved: user(
        UserRole.patient,
        'Jane Cooper',
        physiotherapist: 'Dr. Sarah Malik',
      ),
    ),
    patient: FakePatientRepository()
      ..plan = plan('Knee plan', [squats, lunge])
      ..requirements['item-0'] = requirementsFor(squats),
    camera: camera,
  );
  await tester.tap(find.text('My Exercise Plan'));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.byKey(const Key('start-item-item-0')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('start-item-item-0')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  group('A camera that is slow to start', () {
    testWidgets('offers a way to try again instead of waiting for ever', (
      tester,
    ) async {
      final camera = SlowCamera();
      await openWith(tester, camera);
      expect(find.text('Starting your camera…'), findsOneWidget);

      await tester.pump(const Duration(seconds: 19));
      expect(find.byKey(const Key('camera-slow')), findsNothing);

      await tester.pump(const Duration(seconds: 2));
      expect(find.byKey(const Key('camera-slow')), findsOneWidget);
      expect(find.byKey(const Key('camera-slow-retry')), findsOneWidget);

      await tester.tap(find.byKey(const Key('camera-slow-retry')));
      await tester.pump();

      // The start that hung is given up and a new one begins.
      expect((camera.starts, camera.stops), (2, 1));
      expect(find.byKey(const Key('camera-slow')), findsNothing);
      expect(find.text('Starting your camera…'), findsOneWidget);

      camera.finishStarting();
      await tester.pump();
      expect(find.text('Starting your camera…'), findsNothing);
      expect(find.byKey(const Key('camera-preview')), findsOneWidget);
    });

    testWidgets('says nothing about being slow once it has started', (
      tester,
    ) async {
      final camera = SlowCamera();
      await openWith(tester, camera);

      camera.finishStarting();
      await tester.pump();
      await tester.pump(const Duration(seconds: 30));

      expect(find.byKey(const Key('camera-slow')), findsNothing);
      expect(camera.starts, 1);
    });
  });

  group('A connection that drops during a session', () {
    testWidgets('loses no repetition over a minute without a connection', (
      tester,
    ) async {
      final opened = await startArmSession(tester);
      await doRep(tester, opened.camera);
      expect(opened.patient.storedRepetitions, hasLength(1));

      opened.patient.repetitionFailure = ApiException.network;
      // She carries on exercising: the rest of the set and into the next.
      await doRep(tester, opened.camera, elbow: 25);
      await doRep(tester, opened.camera);
      await doRep(tester, opened.camera, lean: 7);

      // The count on screen keeps up with her; the server's verdicts wait.
      expect(textOf(tester, 'set-progress'), 'Set 2 of 2');
      expect(textOf(tester, 'rep-count'), '1');
      expect(find.byKey(const Key('save-problem')), findsOneWidget);
      expect(opened.patient.storedRepetitions, hasLength(1));

      // A whole minute of failed attempts.
      for (var second = 0; second < 60; second += 2) {
        await tester.pump(const Duration(seconds: 2));
      }
      expect(opened.patient.storedRepetitions, hasLength(1));
      expect(find.byKey(const Key('save-problem')), findsOneWidget);

      opened.patient.repetitionFailure = null;
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();

      // Everything arrives by itself, once each, in the order it was done.
      expect(find.byKey(const Key('save-problem')), findsNothing);
      expect(
        [
          for (final stored in opened.patient.storedRepetitions)
            (stored.setNumber, stored.repNumber, stored.tier),
        ],
        [
          (1, 1, FeedbackTier.ok),
          (1, 2, FeedbackTier.amber),
          (1, 3, FeedbackTier.ok),
          (2, 1, FeedbackTier.info),
        ],
      );
      // Every retry of a repetition carried the same key, so the server
      // could never have stored it twice.
      final keys = <(int, int), Set<String>>{};
      for (final write in opened.patient.repetitionWrites) {
        keys
            .putIfAbsent((
              write.repetition.setNumber,
              write.repetition.repNumber,
            ), () => {})
            .add(write.repetition.clientKey);
      }
      expect(keys.values.every((used) => used.length == 1), isTrue);
      expect(keys, hasLength(4));
    });

    testWidgets('the session can still be ended once the connection is back', (
      tester,
    ) async {
      final opened = await startArmSession(tester);
      opened.patient.repetitionFailure = ApiException.network;
      await doRep(tester, opened.camera);
      await tester.pump(const Duration(seconds: 10));

      opened.patient.repetitionFailure = null;
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      await tapKey(tester, 'session-back');
      await tapKey(tester, 'confirm-end-session');

      expect(find.text('Session complete'), findsWidgets);
      expect(opened.patient.storedRepetitions, hasLength(1));
    });
  });
}
