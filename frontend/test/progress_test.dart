// US 4.2, 5.1 and 5.2: what a session came to, the patient's history and
// progress trend, and the physiotherapist's flagged-session queue.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:physioai/core/api/api_client.dart';
import 'package:physioai/core/api/api_exception.dart';
import 'package:physioai/core/api/token_store.dart';
import 'package:physioai/features/auth/auth_models.dart';
import 'package:physioai/features/exercises/exercise_models.dart';
import 'package:physioai/features/patient/patient_repository.dart';
import 'package:physioai/features/physio/physio_repository.dart';
import 'package:physioai/features/progress/progress_pages.dart';
import 'package:physioai/features/progress/session_widgets.dart';
import 'package:physioai/features/session/repetitions.dart';
import 'package:physioai/features/session/session_records.dart';

import 'auth_flow_test.dart';
import 'live_session_test.dart' show armAbduction, elbowBend, trunkLean;
import 'plans_test.dart';

final _now = DateTime.now();

SessionBrief past(
  String id, {
  required int daysAgo,
  int? score,
  ExerciseBrief exercise = armAbduction,
  String status = 'completed',
  SessionTotals totals = const SessionTotals(repetitions: 6, ok: 4, amber: 2),
  List<String> flagReasons = const [],
  DateTime? reviewedAt,
}) {
  final at = _now.subtract(Duration(days: daysAgo, hours: 1));
  return SessionBrief(
    id: id,
    status: status,
    startedAt: at,
    endedAt: at.add(const Duration(minutes: 5)),
    exercise: exercise,
    sets: 2,
    reps: 3,
    durationSeconds: 300,
    totals: totals,
    formScore: score,
    scoringVersion: 'rules-1',
    flagReasons: flagReasons,
    reviewedAt: reviewedAt,
  );
}

SessionDetail detailOf(SessionBrief session) => SessionDetail(
  id: session.id,
  status: session.status,
  startedAt: session.startedAt,
  endedAt: session.endedAt,
  exercise: session.exercise,
  sets: session.sets,
  reps: session.reps,
  durationSeconds: session.durationSeconds,
  totals: const SessionTotals(repetitions: 3, ok: 1, amber: 1, red: 1),
  formScore: session.formScore,
  scoringVersion: session.scoringVersion,
  flagReasons: session.flagReasons,
  reviewedAt: session.reviewedAt,
  checks: const [trunkLean, elbowBend],
  repetitions: [
    const RepetitionDetail(
      setNumber: 1,
      repNumber: 1,
      startedMs: 0,
      endedMs: 2000,
      tier: FeedbackTier.ok,
    ),
    RepetitionDetail(
      setNumber: 1,
      repNumber: 2,
      startedMs: 3000,
      endedMs: 5000,
      tier: FeedbackTier.amber,
      feedback: [
        RepetitionFeedback(
          check: 'elbow_bend',
          label: elbowBend.label,
          tier: FeedbackTier.amber,
          value: 25,
          message: elbowBend.message,
        ),
      ],
      unmeasured: const ['trunk_lean'],
    ),
    RepetitionDetail(
      setNumber: 2,
      repNumber: 1,
      startedMs: 9000,
      endedMs: 11000,
      tier: FeedbackTier.red,
      feedback: [
        RepetitionFeedback(
          check: 'trunk_lean',
          label: trunkLean.label,
          tier: FeedbackTier.red,
          value: 24,
          message: trunkLean.message,
        ),
      ],
    ),
  ],
);

Future<FakePatientRepository> openAsPatient(
  WidgetTester tester,
  String page, {
  List<SessionBrief> history = const [],
}) async {
  final patient = FakePatientRepository()
    ..history.addAll(history)
    ..sessionDetails.addAll({
      for (final session in history) session.id: detailOf(session),
    });
  await pumpApp(
    tester,
    auth: FakeAuthRepository(saved: user(UserRole.patient, 'Jane Cooper')),
    patient: patient,
  );
  await tester.tap(find.text(page));
  await tester.pumpAndSettle();
  return patient;
}

FlaggedSession flaggedEntry(
  String id,
  String patient, {
  required int daysAgo,
  int? score,
  List<String> reasons = const ['red'],
  String status = 'completed',
}) => FlaggedSession(
  session: past(
    id,
    daysAgo: daysAgo,
    score: score,
    flagReasons: reasons,
    status: status,
  ),
  patient: PersonRef(id: 'patient-$id', fullName: patient),
  flaggedAt: _now.subtract(Duration(days: daysAgo)),
  flagThreshold: reasons.contains('low_score') ? 60 : null,
);

Future<FakePhysioRepository> openFlagged(
  WidgetTester tester,
  List<FlaggedSession> flagged,
) async {
  final physio = FakePhysioRepository()
    ..flagged.addAll(flagged)
    ..sessionDetails.addAll({
      for (final entry in flagged) entry.session.id: detailOf(entry.session),
    });
  await pumpApp(
    tester,
    auth: FakeAuthRepository(
      saved: user(UserRole.physiotherapist, 'Dr. Sarah Malik'),
    ),
    physio: physio,
  );
  await tester.tap(find.text('Flagged Sessions'));
  await tester.pumpAndSettle();
  return physio;
}

List<int?> scoresShown(WidgetTester tester) => [
  for (final badge in tester.widgetList<ScoreBadge>(find.byType(ScoreBadge)))
    badge.score,
];

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

Future<ApiClient> _api(MockClientHandler handler) async {
  final tokens = InMemoryTokenStore();
  await tokens.write(
    const AuthTokens(accessToken: 'access-1', refreshToken: 'refresh-1'),
  );
  return ApiClient(
    baseUrl: 'http://api.test/api/v1',
    tokens: tokens,
    httpClient: MockClient(handler),
  );
}

const _exerciseJson = {
  'id': 'ex-arm',
  'slug': 'arm-abduction',
  'name': 'Arm Abduction',
  'domain': 'Shoulder rehabilitation',
  'body_area': 'shoulder',
  'primary_targets': 'Deltoid',
  'target_joints': ['shoulder', 'elbow', 'hip'],
  'instructions': 'Raise both arms.',
  'is_active': true,
};

const _briefJson = {
  'id': 'session-9',
  'status': 'completed',
  'started_at': '2026-10-10T09:00:00Z',
  'ended_at': '2026-10-10T09:05:00Z',
  'exercise': _exerciseJson,
  'sets': 2,
  'reps': 3,
  'duration_seconds': 300,
  'totals': {'repetitions': 4, 'ok': 2, 'info': 0, 'amber': 1, 'red': 1},
  'form_score': 64,
  'scoring_version': 'rules-1',
  'flag_reasons': ['red'],
  'reviewed_at': null,
};

void main() {
  group('What a session came to', () {
    SessionSummary summary({int? score, int? before, bool first = false}) =>
        SessionSummary(
          durationSeconds: 300,
          formScore: score,
          previous: first
              ? null
              : PreviousSession(
                  id: 'session-0',
                  endedAt: DateTime.utc(2026, 10, 9),
                  repetitions: 6,
                  formScore: before,
                ),
          scoreChange: score == null || before == null ? null : score - before,
        );

    test('the comparison is worded for the patient', () {
      expect(
        summary(score: 80, first: true).trend,
        'This is your first session of this exercise.',
      );
      expect(
        summary(score: 85, before: 78).trend,
        'Up 7 points from your last session (78).',
      );
      expect(
        summary(score: 79, before: 78).trend,
        'Up 1 point from your last session (78).',
      );
      expect(
        summary(score: 70, before: 78).trend,
        'Down 8 points from your last session (78).',
      );
      expect(
        summary(score: 78, before: 78).trend,
        'The same as your last session (78).',
      );
    });

    test('a missing score is never compared as if it were 0', () {
      expect(summary(score: 80).trend, contains('no comparison'));
      expect(summary(before: 78).trend, contains('nothing to score this time'));
    });

    test('is read from the reply to ending a session', () async {
      final repository = PatientRepository(
        await _api(
          (request) async => _json({
            'id': 'session-9',
            'status': 'completed',
            'started_at': '2026-10-10T09:00:00Z',
            'ended_at': '2026-10-10T09:05:00Z',
            'summary': {
              'duration_seconds': 300,
              'totals': {
                'repetitions': 4,
                'ok': 2,
                'info': 0,
                'amber': 1,
                'red': 1,
              },
              'form_score': 64,
              'scored_repetitions': 4,
              'scoring_version': 'rules-1',
              'previous': {
                'id': 'session-8',
                'ended_at': '2026-10-09T09:05:00Z',
                'repetitions': 6,
                'form_score': null,
              },
              'score_change': null,
            },
          }),
        ),
      );

      final summary = (await repository.endSession('session-9')).summary!;

      expect((summary.formScore, summary.scoredRepetitions), (64, 4));
      expect(summary.totals.red, 1);
      expect(summary.scoringVersion, 'rules-1');
      expect(summary.previous!.formScore, isNull);
      expect(summary.scoreChange, isNull);
    });
  });

  group('Requests', () {
    test('history is asked for with its filters, and read', () async {
      final seen = <Uri>[];
      final repository = PatientRepository(
        await _api((request) async {
          seen.add(request.url);
          return _json([_briefJson]);
        }),
      );

      final all = await repository.sessions();
      await repository.sessions(
        exerciseId: 'ex-arm',
        since: DateTime.utc(2026, 9, 1),
        until: DateTime.utc(2026, 10, 1),
      );

      expect(seen.first.path, '/api/v1/patient/sessions');
      expect(seen.first.hasQuery, isFalse);
      expect(seen.last.queryParameters, {
        'exercise_id': 'ex-arm',
        'since': '2026-09-01T00:00:00.000Z',
        'until': '2026-10-01T00:00:00.000Z',
      });
      final session = all.single;
      expect((session.id, session.formScore), ('session-9', 64));
      expect(session.exercise.slug, 'arm-abduction');
      expect(session.totals.repetitions, 4);
      expect(session.flagReasons, ['red']);
      expect(session.isReviewed, isFalse);
    });

    test(
      'the flagged queue, a session and a review use their own paths',
      () async {
        final seen = <String>[];
        final repository = PhysioRepository(
          await _api((request) async {
            seen.add(
              '${request.method} ${request.url.path}?${request.url.query}',
            );
            if (request.url.path.endsWith('flagged-sessions')) {
              return _json([
                {
                  'session': _briefJson,
                  'patient': {'id': 'p-1', 'full_name': 'Jane Cooper'},
                  'flagged_at': '2026-10-10T09:03:00Z',
                  'flag_threshold': null,
                  'reviewed_by': null,
                },
              ]);
            }
            return _json({
              ..._briefJson,
              'reviewed_at': '2026-10-11T08:00:00Z',
              'difficulty': 'easy',
              'rest_seconds': 30,
              'checks': <Object>[],
              'scored_repetitions': 4,
              'repetitions': [
                {
                  'set_number': 1,
                  'rep_number': 1,
                  'started_ms': 0,
                  'ended_ms': 2000,
                  'tier': 'red',
                  'feedback': <Object>[],
                  'unmeasured': ['elbow_bend'],
                },
              ],
            });
          }),
        );

        final queue = await repository.flaggedSessions(state: 'reviewed');
        final opened = await repository.session('session-9');
        final reviewed = await repository.markSessionReviewed('session-9');

        expect(seen, [
          'GET /api/v1/physio/flagged-sessions?state=reviewed',
          'GET /api/v1/physio/sessions/session-9?',
          'POST /api/v1/physio/sessions/session-9/review?',
        ]);
        expect(queue.single.patient.fullName, 'Jane Cooper');
        expect(queue.single.reasons, ['Paused for safety']);
        expect(opened.repetitions.single.tier, FeedbackTier.red);
        expect(opened.repetitions.single.unmeasured, ['elbow_bend']);
        expect(reviewed.isReviewed, isTrue);
      },
    );
  });

  group('Session History', () {
    testWidgets('says so when there is nothing yet', (tester) async {
      await openAsPatient(tester, 'Session History');

      expect(
        find.textContaining('You have not finished a session yet'),
        findsOneWidget,
      );
    });

    testWidgets('lists sessions newest first, without inventing a score', (
      tester,
    ) async {
      await openAsPatient(
        tester,
        'Session History',
        history: [
          past('s3', daysAgo: 1, score: 92),
          past(
            's2',
            daysAgo: 3,
            status: 'abandoned',
            totals: const SessionTotals(),
          ),
          past('s1', daysAgo: 8, score: 55, exercise: squats),
        ],
      );

      expect(scoresShown(tester), [92, null, 55]);
      expect(find.text('Arm Abduction'), findsNWidgets(2));
      expect(find.text('Squats'), findsOneWidget);
      // The session with no score says so; it is not shown as 0.
      expect(find.text('Not scored'), findsOneWidget);
      expect(find.text('Not finished'), findsOneWidget);
      expect(find.text('0'), findsNothing);
      expect(find.text('4 good'), findsNWidgets(2));
      expect(find.text('2 to work on'), findsNWidgets(2));
    });

    testWidgets('a session opens in full, repetition by repetition', (
      tester,
    ) async {
      await openAsPatient(
        tester,
        'Session History',
        history: [past('s1', daysAgo: 1, score: 52)],
      );

      await tapKey(tester, 'open-session-s1');

      expect(find.byKey(const Key('session-detail')), findsOneWidget);
      expect(
        tester.widget<Text>(find.byKey(const Key('detail-score'))).data,
        'Form score 52 out of 100, from 3 repetitions.',
      );
      expect(find.text('Set 1'), findsOneWidget);
      expect(find.text('Set 2'), findsOneWidget);
      expect(
        find.text('${elbowBend.label}: ${elbowBend.message}'),
        findsOneWidget,
      );
      expect(
        find.text('${trunkLean.label}: ${trunkLean.message}'),
        findsOneWidget,
      );
      expect(find.text('Not in view: trunk lean'), findsOneWidget);
      expect(find.text('Scored with rules-1.'), findsOneWidget);

      await tapKey(tester, 'close-session-detail');
      expect(find.byKey(const Key('session-detail')), findsNothing);
    });

    testWidgets('a failure to load can be retried', (tester) async {
      final patient = FakePatientRepository()
        ..historyFailure = ApiException.network;
      await pumpApp(
        tester,
        auth: FakeAuthRepository(saved: user(UserRole.patient, 'Jane Cooper')),
        patient: patient,
      );
      await tester.tap(find.text('Session History'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not reach PhysioAI'), findsOneWidget);

      patient
        ..historyFailure = null
        ..history.add(past('s1', daysAgo: 1, score: 80));
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();

      expect(scoresShown(tester), [80]);
    });
  });

  group('Progress', () {
    final history = [
      past('a4', daysAgo: 2, score: 90),
      past('a3', daysAgo: 10, totals: const SessionTotals()),
      past('q1', daysAgo: 12, score: 40, exercise: squats),
      past('a2', daysAgo: 20, score: 75),
      past('a1', daysAgo: 120, score: 60),
    ];

    List<int> plotted(WidgetTester tester) => [
      for (final point
          in tester
              .widget<TrendChart>(find.byKey(const Key('progress-chart')))
              .points)
        point.score,
    ];

    String reading(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const Key('progress-reading'))).data!;

    testWidgets(
      'plots the scored sessions of the latest exercise, oldest first',
      (tester) async {
        await openAsPatient(tester, 'Progress', history: history);

        // Three months by default: the session from 120 days ago is outside,
        // and the one with nothing to score is not on the graph.
        expect(plotted(tester), [75, 90]);
        expect(reading(tester), 'Up from 75 to 90 over 2 scored sessions.');
        expect(
          tester.widget<Text>(find.byKey(const Key('progress-unscored'))).data,
          '1 session in this period had nothing to score and is not on the graph.',
        );
        // The sessions behind the graph are listed, the unscored one included.
        expect(scoresShown(tester), [90, null, 75]);
      },
    );

    testWidgets('the range can be changed', (tester) async {
      await openAsPatient(tester, 'Progress', history: history);

      await tapKey(tester, 'progress-range-all');
      expect(plotted(tester), [60, 75, 90]);
      expect(reading(tester), 'Up from 60 to 90 over 3 scored sessions.');

      await tapKey(tester, 'progress-range-month');
      expect(plotted(tester), [75, 90]);

      await tapKey(tester, 'progress-range-year');
      expect(plotted(tester), [60, 75, 90]);
    });

    testWidgets('another exercise has its own trend', (tester) async {
      await openAsPatient(tester, 'Progress', history: history);

      await tapKey(tester, 'progress-exercise');
      await tester.tap(find.text('Squats').last);
      await tester.pumpAndSettle();

      expect(plotted(tester), [40]);
      expect(reading(tester), 'One scored session so far: 40 out of 100.');
      expect(find.byKey(const Key('progress-unscored')), findsNothing);
    });

    testWidgets('a period with nothing scored draws no graph', (tester) async {
      await openAsPatient(
        tester,
        'Progress',
        history: [
          past('a2', daysAgo: 3, totals: const SessionTotals()),
          past('a1', daysAgo: 200, score: 70),
        ],
      );

      expect(find.byKey(const Key('progress-chart')), findsNothing);
      expect(
        tester.widget<Text>(find.byKey(const Key('progress-empty'))).data,
        'No session in this period had anything to score.',
      );

      await tapKey(tester, 'progress-range-all');
      expect(plotted(tester), [70]);
    });

    testWidgets('a session on the trend opens in full', (tester) async {
      await openAsPatient(tester, 'Progress', history: history);

      await tapKey(tester, 'open-session-a4');

      expect(find.byKey(const Key('session-detail')), findsOneWidget);
    });

    test('the range includes its first day and nothing older', () {
      final now = DateTime(2026, 10, 11, 12);
      expect(
        ProgressRange.month.includes(DateTime(2026, 9, 11, 12), now),
        isTrue,
      );
      expect(
        ProgressRange.month.includes(DateTime(2026, 9, 11, 11, 59), now),
        isFalse,
      );
      expect(ProgressRange.all.includes(DateTime(2020), now), isTrue);
    });
  });

  group('Flagged Sessions', () {
    testWidgets('says so when nothing is waiting', (tester) async {
      await openFlagged(tester, []);

      expect(
        find.textContaining('Nothing is waiting for review'),
        findsOneWidget,
      );
    });

    testWidgets('lists what is waiting with the patient and the reason', (
      tester,
    ) async {
      await openFlagged(tester, [
        flaggedEntry('f2', 'Marcus Johnson', daysAgo: 0, status: 'paused'),
        flaggedEntry(
          'f1',
          'Jane Cooper',
          daysAgo: 2,
          score: 40,
          reasons: ['red', 'low_score'],
        ),
      ]);

      expect(find.text('Marcus Johnson'), findsOneWidget);
      expect(find.text('Jane Cooper'), findsOneWidget);
      expect(find.text('Paused for safety'), findsNWidgets(2));
      expect(find.text('Score below 60'), findsOneWidget);
      // Flagged while the patient is still in the session.
      expect(find.text('In progress'), findsOneWidget);
      expect(scoresShown(tester), [null, 40]);
    });

    testWidgets('marking a session reviewed moves it to Reviewed', (
      tester,
    ) async {
      final physio = await openFlagged(tester, [
        flaggedEntry('f1', 'Jane Cooper', daysAgo: 1, score: 40),
      ]);

      await tapKey(tester, 'open-session-f1');
      expect(find.byKey(const Key('session-detail')), findsOneWidget);
      expect(find.text('Jane Cooper'), findsNWidgets(2));
      expect(find.text('Set 2'), findsOneWidget);
      await tapKey(tester, 'mark-reviewed');

      expect(physio.reviewed, ['f1']);
      expect(find.byKey(const Key('session-detail')), findsNothing);
      expect(
        find.textContaining('Nothing is waiting for review'),
        findsOneWidget,
      );

      await tester.tap(find.text('Reviewed'));
      await tester.pumpAndSettle();
      expect(find.text('Jane Cooper'), findsOneWidget);
      expect(find.text('Reviewed by Dr. Sarah Malik'), findsOneWidget);

      // Opened again, it shows when it was reviewed and offers nothing more.
      physio.sessionDetails['f1'] = detailOf(physio.flagged.single.session);
      await tapKey(tester, 'open-session-f1');
      expect(find.byKey(const Key('reviewed-note')), findsOneWidget);
      expect(find.byKey(const Key('mark-reviewed')), findsNothing);
    });

    testWidgets('a session stays in the queue when the review fails', (
      tester,
    ) async {
      final physio = await openFlagged(tester, [
        flaggedEntry('f1', 'Jane Cooper', daysAgo: 1, score: 40),
      ]);
      physio.reviewFailure = ApiException.network;

      await tapKey(tester, 'open-session-f1');
      await tapKey(tester, 'mark-reviewed');

      expect(find.byKey(const Key('review-error')), findsOneWidget);
      expect(find.byKey(const Key('session-detail')), findsOneWidget);
      expect(physio.reviewed, isEmpty);

      await tapKey(tester, 'close-session-detail');
      expect(find.text('Jane Cooper'), findsOneWidget);
    });
  });
}
