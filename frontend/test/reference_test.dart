// The patient's own reference: a physiotherapist ticks two repetitions they
// saw done correctly, and later sessions are judged against them.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:physioai/core/api/api_client.dart';
import 'package:physioai/core/api/api_exception.dart';
import 'package:physioai/core/api/token_store.dart';
import 'package:physioai/features/auth/auth_models.dart';
import 'package:physioai/features/physio/physio_repository.dart';
import 'package:physioai/features/session/repetitions.dart';
import 'package:physioai/features/session/session_records.dart';

import 'auth_flow_test.dart';
import 'plans_test.dart';
import 'progress_test.dart' hide main;

RepetitionDetail rep(
  int number, {
  bool kept = true,
  bool inReference = false,
  double? distance,
  bool? correct,
}) => RepetitionDetail(
  id: 'rep-$number',
  setNumber: 1,
  repNumber: number,
  startedMs: number * 3000,
  endedMs: number * 3000 + 2000,
  tier: FeedbackTier.ok,
  canBeReference: kept,
  inReference: inReference,
  referenceDistance: distance,
  judgedCorrect: correct,
);

SessionDetail supervised({
  List<RepetitionDetail>? repetitions,
  String scoringVersion = 'rules-1',
  bool supported = true,
}) {
  final brief = past('session-1', daysAgo: 1, score: 80);
  return SessionDetail(
    id: brief.id,
    status: brief.status,
    startedAt: brief.startedAt,
    endedAt: brief.endedAt,
    exercise: brief.exercise,
    sets: brief.sets,
    reps: brief.reps,
    durationSeconds: brief.durationSeconds,
    totals: const SessionTotals(repetitions: 3, ok: 3),
    formScore: 80,
    scoringVersion: scoringVersion,
    referenceSupported: supported,
    repetitions: repetitions ?? [rep(1), rep(2), rep(3, kept: false)],
  );
}

Future<FakePhysioRepository> openReference(
  WidgetTester tester, {
  SessionDetail? session,
}) async {
  final detail = session ?? supervised();
  final physio = FakePhysioRepository()
    ..roster.add(jane)
    ..sessionsByPatient[jane.id] = [past('session-1', daysAgo: 1, score: 80)]
    ..sessionDetails['session-1'] = detail;
  await pumpApp(
    tester,
    auth: FakeAuthRepository(
      saved: user(UserRole.physiotherapist, 'Dr. Sarah Malik'),
    ),
    physio: physio,
  );
  await tester.tap(find.text('Patients'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key('reference-for-${jane.id}')));
  await tester.pumpAndSettle();
  return physio;
}

Future<void> openSession(WidgetTester tester) async {
  await tester.tap(find.text('Arm Abduction').last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a patient without a reference is scored by the usual model', (
    tester,
  ) async {
    await openReference(tester);

    expect(find.byKey(const Key('reference-dialog')), findsOneWidget);
    expect(find.byKey(const Key('no-references')), findsOneWidget);
  });

  testWidgets('two repetitions seen done correctly become the reference', (
    tester,
  ) async {
    final physio = await openReference(tester);
    await openSession(tester);

    // Only repetitions whose angles were kept can be ticked.
    expect(find.byKey(const Key('pick-rep-1-1')), findsOneWidget);
    expect(find.byKey(const Key('pick-rep-1-3')), findsNothing);
    Widget button() =>
        tester.widget<FilledButton>(find.byKey(const Key('make-reference')));
    expect((button() as FilledButton).onPressed, isNull);
    expect(find.text('0 of 2 chosen'), findsOneWidget);

    await tester.tap(find.byKey(const Key('pick-rep-1-1')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('pick-rep-1-2')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('make-reference')));
    await tester.tap(find.byKey(const Key('make-reference')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Choose only repetitions you saw'), findsOne);
    await tester.tap(find.byKey(const Key('confirm-reference')));
    await tester.pumpAndSettle();

    expect(physio.referencesMade.single.patientId, jane.id);
    expect(physio.referencesMade.single.ids, ['rep-1', 'rep-2']);
    expect(find.byKey(const Key('reference-done')), findsOneWidget);

    // Back in the dialog, the reference is listed.
    await tester.tap(find.byKey(const Key('close-session-detail')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reference-arm-abduction')), findsOneWidget);
    expect(find.textContaining('From set 1 rep 1 and set 1 rep 2'), findsOne);
  });

  testWidgets('a refused reference says why and changes nothing', (
    tester,
  ) async {
    final physio = await openReference(tester);
    physio.referenceFailure = const ApiException(
      code: 'reference_red',
      message:
          'A repetition that crossed a safety threshold cannot be a reference.',
      statusCode: 422,
    );
    await openSession(tester);
    await tester.tap(find.byKey(const Key('pick-rep-1-1')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('pick-rep-1-2')));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('make-reference')));
    await tester.tap(find.byKey(const Key('make-reference')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-reference')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('reference-error')), findsOneWidget);
    expect(find.textContaining('crossed a safety threshold'), findsOneWidget);
    expect(physio.referencesByPatient[jane.id], isNull);
  });

  testWidgets('a session judged against the reference says so, rep by rep', (
    tester,
  ) async {
    await openReference(
      tester,
      session: supervised(
        scoringVersion: personalScoringVersion,
        repetitions: [
          rep(1, kept: false, distance: 1.2, correct: true),
          rep(2, kept: false, distance: 7.5, correct: false),
        ],
      ),
    );
    await openSession(tester);

    expect(
      find.text("Judged against the patient's own reference (personal-2)."),
      findsOneWidget,
    );
    expect(find.text('1.2 from the reference: done correctly'), findsOneWidget);
    expect(
      find.text('7.5 from the reference: different from it'),
      findsOneWidget,
    );
    // Nothing left to pick from: no picker.
    expect(find.byKey(const Key('reference-picker')), findsNothing);
  });

  testWidgets('stopping a reference asks first, then goes back to the model', (
    tester,
  ) async {
    final physio = await openReference(tester);
    await physio.setReference(jane.id, ['rep-1', 'rep-2']);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('reference-for-${jane.id}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reference-arm-abduction')), findsOneWidget);

    await tester.tap(find.byKey(const Key('retire-reference-arm-abduction')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-retire-reference')));
    await tester.pumpAndSettle();

    expect(physio.referencesRetired, ['reference-1']);
    expect(find.byKey(const Key('no-references')), findsOneWidget);
  });

  test('the references are read, made and stopped at the API', () async {
    final seen = <http.Request>[];
    final tokens = InMemoryTokenStore();
    await tokens.write(
      const AuthTokens(accessToken: 'access-1', refreshToken: 'refresh-1'),
    );
    const reference = {
      'id': 'ref-1',
      'exercise': {
        'id': 'ex-arm',
        'slug': 'arm-abduction',
        'name': 'Arm Abduction',
        'domain': 'Shoulder rehabilitation',
        'body_area': 'shoulder',
        'primary_targets': 'Deltoid',
        'target_joints': ['shoulder'],
        'instructions': 'Raise both arms.',
      },
      'repetitions': [
        {
          'id': 'rep-1',
          'session_id': 's-1',
          'session_started_at': '2026-11-20T09:00:00Z',
          'set_number': 1,
          'rep_number': 1,
        },
      ],
      'created_at': '2026-11-20T10:00:00Z',
      'created_by': {'id': 'physio-1', 'full_name': 'Dr. Sarah Malik'},
      'sessions_judged': 3,
    };
    final repository = PhysioRepository(
      ApiClient(
        baseUrl: 'http://api.test/api/v1',
        tokens: tokens,
        httpClient: MockClient((request) async {
          seen.add(request);
          if (request.method == 'DELETE') return http.Response('', 204);
          final body = request.method == 'GET' ? [reference] : reference;
          return http.Response(
            jsonEncode(body),
            request.method == 'POST' ? 201 : 200,
            headers: {'content-type': 'application/json'},
          );
        }),
      ),
    );

    final listed = await repository.references('p-1');
    final made = await repository.setReference('p-1', ['rep-1', 'rep-2']);
    await repository.retireReference('p-1', 'ref-1');

    expect(listed.single.sessionsJudged, 3);
    expect(made.repetitions.single.repNumber, 1);
    expect(made.createdBy.fullName, 'Dr. Sarah Malik');
    expect(
      [for (final r in seen) '${r.method} ${r.url.path}'],
      [
        'GET /api/v1/physio/patients/p-1/references',
        'POST /api/v1/physio/patients/p-1/references',
        'DELETE /api/v1/physio/patients/p-1/references/ref-1',
      ],
    );
    expect(jsonDecode(seen[1].body), {
      'repetition_ids': ['rep-1', 'rep-2'],
    });
  });
}
