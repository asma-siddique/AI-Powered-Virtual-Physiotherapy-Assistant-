// US 5.3: the optional pain scale around a session, notes, and the
// physiotherapist's exported report.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:physioai/core/api/api_client.dart';
import 'package:physioai/core/api/api_exception.dart';
import 'package:physioai/core/api/token_store.dart';
import 'package:physioai/core/files/file_saver.dart';
import 'package:physioai/core/widgets/common.dart';
import 'package:physioai/features/auth/auth_models.dart';
import 'package:physioai/features/patient/patient_repository.dart';
import 'package:physioai/features/physio/physio_repository.dart';
import 'package:physioai/features/session/pain.dart';
import 'package:physioai/features/session/session_records.dart';

import 'auth_flow_test.dart';
import 'live_session_test.dart' hide main;
import 'plans_test.dart';
import 'progress_test.dart' hide main;

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

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

const _detailJson = {
  'id': 'session-9',
  'status': 'completed',
  'started_at': '2026-10-10T09:00:00Z',
  'ended_at': '2026-10-10T09:05:00Z',
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
  'sets': 2,
  'reps': 3,
  'duration_seconds': 300,
  'totals': {'repetitions': 0, 'ok': 0, 'info': 0, 'amber': 0, 'red': 0},
  'form_score': null,
  'flag_reasons': <String>[],
  'reviewed_at': null,
  'pain_before': 3,
  'pain_after': null,
  'has_notes': true,
  'patient_note': 'A pinch near the top.',
  'clinician_note': 'Keep the range smaller this week.',
  'clinician_note_at': '2026-10-10T12:00:00Z',
  'repetitions': <Object>[],
};

Future<({FakePhysioRepository physio, List<String> saved})> openPatients(
  WidgetTester tester, {
  FileSaver? saver,
}) async {
  final saved = <String>[];
  final physio = FakePhysioRepository()..roster.addAll([jane, marcus]);
  await pumpApp(
    tester,
    auth: FakeAuthRepository(
      saved: user(UserRole.physiotherapist, 'Dr. Sarah Malik'),
    ),
    physio: physio,
    saver:
        saver ??
        (Uint8List bytes, String name, String type) async =>
            saved.add('$name $type ${bytes.length}'),
  );
  await tester.tap(find.text('Patients'));
  await tester.pumpAndSettle();
  return (physio: physio, saved: saved);
}

void main() {
  group('Requests', () {
    test(
      'a pain rating is sent as it was given, and the reply is read',
      () async {
        final seen = <http.Request>[];
        final repository = PatientRepository(
          await _api((request) async {
            seen.add(request);
            return _json(_detailJson);
          }),
        );

        final detail = await repository.logPain(
          sessionId: 'session-9',
          moment: 'before',
          score: 3,
        );
        await repository.logPain(
          sessionId: 'session-9',
          moment: 'after',
          note: '',
        );

        expect(seen.first.method, 'PUT');
        expect(seen.first.url.path, '/api/v1/patient/sessions/session-9/pain');
        // No note key at all leaves the stored note alone.
        expect(jsonDecode(seen.first.body), {'moment': 'before', 'score': 3});
        // No answer is null, never 0; an empty note removes the note.
        expect(jsonDecode(seen.last.body), {
          'moment': 'after',
          'score': null,
          'note': '',
        });
        expect((detail.painBefore, detail.painAfter), (3, null));
        expect(detail.patientNote, 'A pinch near the top.');
        expect(detail.clinicianNote, 'Keep the range smaller this week.');
        expect(detail.hasNotes, isTrue);
      },
    );

    test('a note and a report use the physiotherapist\'s own paths', () async {
      final seen = <http.Request>[];
      final repository = PhysioRepository(
        await _api((request) async {
          seen.add(request);
          if (request.url.path.endsWith('/report')) {
            return http.Response.bytes(
              '%PDF-1.4 report'.codeUnits,
              200,
              headers: {
                'content-type': 'application/pdf',
                'content-disposition':
                    'attachment; filename="physioai-report-ab12cd34-20260701-20261001.pdf"',
              },
            );
          }
          return _json(_detailJson);
        }),
      );

      await repository.saveSessionNote('session-9', 'Keep going.');
      final file = await repository.patientReport(
        'patient-jane',
        since: DateTime.utc(2026, 7, 1),
        until: DateTime.utc(2026, 10, 1),
      );

      expect(seen.first.method, 'PUT');
      expect(seen.first.url.path, '/api/v1/physio/sessions/session-9/note');
      expect(jsonDecode(seen.first.body), {'note': 'Keep going.'});
      expect(seen.last.method, 'GET');
      expect(seen.last.url.path, '/api/v1/physio/patients/patient-jane/report');
      expect(seen.last.url.queryParameters, {
        'since': '2026-07-01T00:00:00.000Z',
        'until': '2026-10-01T00:00:00.000Z',
      });
      expect(seen.last.headers['Authorization'], 'Bearer access-1');
      expect(file.filename, 'physioai-report-ab12cd34-20260701-20261001.pdf');
      expect(String.fromCharCodes(file.bytes), '%PDF-1.4 report');
    });

    test('a refused report is an error, not a file', () async {
      final repository = PhysioRepository(
        await _api(
          (_) async => http.Response(
            jsonEncode({
              'detail': {'code': 'not_found', 'message': 'Patient not found.'},
            }),
            404,
            headers: {'content-type': 'application/json'},
          ),
        ),
      );

      await expectLater(
        repository.patientReport(
          'someone-else',
          since: DateTime.utc(2026, 7, 1),
          until: DateTime.utc(2026, 10, 1),
        ),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 404)),
      );
    });
  });

  group('The pain scale', () {
    testWidgets('nothing is chosen until tapped, and a tap can be taken back', (
      tester,
    ) async {
      int? value;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => PainScale(
                name: 'pain',
                value: value,
                onChanged: (v) => setState(() => value = v),
              ),
            ),
          ),
        ),
      );
      expect(value, isNull);
      for (var score = 0; score <= 10; score++) {
        expect(find.byKey(Key('pain-$score')), findsOneWidget);
      }

      await tester.tap(find.byKey(const Key('pain-0')));
      await tester.pump();
      // Zero is an answer ("no pain"), different from not answering.
      expect(value, 0);
      await tester.tap(find.byKey(const Key('pain-7')));
      await tester.pump();
      expect(value, 7);
      await tester.tap(find.byKey(const Key('pain-7')));
      await tester.pump();
      expect(value, isNull);
    });
  });

  group('Pain around a session', () {
    testWidgets('a session starts and ends without any answer', (tester) async {
      final opened = await startArmSession(tester);
      await doRep(tester, opened.camera);

      await tapKey(tester, 'end-session');
      await tapKey(tester, 'confirm-end-session');

      expect(opened.patient.ended, ['session-1']);
      expect(find.byKey(const Key('pain-after')), findsOneWidget);
      // Skipping is just leaving: nothing was sent, and nothing is in the way.
      await tapKey(tester, 'summary-done');
      expect(find.text('Shoulder plan'), findsOneWidget);
      expect(opened.patient.painLogs, isEmpty);
    });

    testWidgets('a rating chosen during the camera check is stored once the '
        'session exists', (tester) async {
      final patient = FakePatientRepository()
        ..plan = plan('Shoulder plan', [armAbduction]);
      final opened = await openArmCheck(tester, patient);

      await tapKey(tester, 'pain-before-3');
      // Choosing it starts nothing by itself.
      expect(patient.started, isEmpty);
      expect(patient.painLogs, isEmpty);

      await passCheck(tester, opened.camera);

      expect(patient.started, hasLength(1));
      expect(patient.painLogs, [
        (sessionId: 'session-1', moment: 'before', score: 3, note: null),
      ]);
    });

    testWidgets('a rating that could not be saved is tried again at the end '
        'and never blocks the session', (tester) async {
      final patient = FakePatientRepository()
        ..plan = plan('Shoulder plan', [armAbduction])
        ..painFailure = ApiException.network;
      final opened = await openArmCheck(tester, patient);
      await tapKey(tester, 'pain-before-6');

      await passCheck(tester, opened.camera);
      expect(find.text('Session in progress'), findsOneWidget);
      expect(patient.painLogs, isEmpty);

      patient.painFailure = null;
      await tapKey(tester, 'end-session');
      await tapKey(tester, 'confirm-end-session');

      expect(patient.ended, ['session-1']);
      expect(patient.painLogs.single.score, 6);
    });

    testWidgets('after the session a rating and a note can be saved', (
      tester,
    ) async {
      final opened = await startArmSession(tester);
      await tapKey(tester, 'end-session');
      await tapKey(tester, 'confirm-end-session');

      // Nothing to save until something is answered.
      BusyButton save() =>
          tester.widget<BusyButton>(find.byKey(const Key('pain-save')));
      expect(save().onPressed, isNull);

      await tapKey(tester, 'pain-after-5');
      await fill(tester, 'pain-note', 'A pinch near the top of the lift.');
      expect(save().onPressed, isNotNull);
      await tapKey(tester, 'pain-save');

      expect(opened.patient.painLogs, [
        (
          sessionId: 'session-1',
          moment: 'after',
          score: 5,
          note: 'A pinch near the top of the lift.',
        ),
      ]);
      expect(find.byKey(const Key('pain-saved')), findsOneWidget);
    });

    testWidgets('a failure to save says so and can be retried', (tester) async {
      final opened = await startArmSession(tester);
      await tapKey(tester, 'end-session');
      await tapKey(tester, 'confirm-end-session');
      opened.patient.painFailure = ApiException.network;

      await tapKey(tester, 'pain-after-2');
      await tapKey(tester, 'pain-save');
      expect(find.byKey(const Key('pain-error')), findsOneWidget);
      expect(find.byKey(const Key('pain-saved')), findsNothing);

      opened.patient.painFailure = null;
      await tapKey(tester, 'pain-save');
      expect(find.byKey(const Key('pain-saved')), findsOneWidget);
      expect(opened.patient.painLogs.single.score, 2);
    });
  });

  group('Pain and notes on a past session', () {
    SessionDetail withNotes(SessionBrief session) {
      final base = detailOf(session);
      return SessionDetail(
        id: base.id,
        status: base.status,
        startedAt: base.startedAt,
        endedAt: base.endedAt,
        exercise: base.exercise,
        sets: base.sets,
        reps: base.reps,
        durationSeconds: base.durationSeconds,
        totals: base.totals,
        formScore: base.formScore,
        repetitions: base.repetitions,
        painBefore: 2,
        patientNote: 'Felt stiff at first.',
        clinicianNote: 'Warm up for longer.',
      );
    }

    testWidgets('are shown with the session, and no answer is said as such', (
      tester,
    ) async {
      final session = past('s1', daysAgo: 1, score: 80);
      final patient = await openAsPatient(
        tester,
        'Session History',
        history: [session],
      );
      patient.sessionDetails['s1'] = withNotes(session);

      await tapKey(tester, 'open-session-s1');

      expect(
        tester.widget<Text>(find.byKey(const Key('detail-pain'))).data,
        'Pain (0 to 10): 2 before, not answered after.',
      );
      expect(find.text('Felt stiff at first.'), findsOneWidget);
      expect(find.text('Warm up for longer.'), findsOneWidget);
    });

    testWidgets('a session without them shows nothing about pain', (
      tester,
    ) async {
      await openAsPatient(
        tester,
        'Session History',
        history: [past('s1', daysAgo: 1, score: 80)],
      );

      await tapKey(tester, 'open-session-s1');

      expect(find.byKey(const Key('detail-pain')), findsNothing);
      expect(find.byKey(const Key('detail-patient-note')), findsNothing);
    });
  });

  group('The physiotherapist', () {
    testWidgets('writes a note on a flagged session', (tester) async {
      final physio = await openFlagged(tester, [
        flaggedEntry('f1', 'Jane Cooper', daysAgo: 1, score: 40),
      ]);

      await tapKey(tester, 'open-session-f1');
      await fill(tester, 'clinician-note', 'Reduce to two sets this week.');
      await tapKey(tester, 'save-note');

      expect(physio.notes, [
        (sessionId: 'f1', note: 'Reduce to two sets this week.'),
      ]);
      expect(find.byKey(const Key('note-saved')), findsOneWidget);
      // Writing a note is not the same as reviewing: it is still to review.
      expect(physio.reviewed, isEmpty);
      expect(find.byKey(const Key('mark-reviewed')), findsOneWidget);
    });

    testWidgets('exports a patient\'s report for the range chosen', (
      tester,
    ) async {
      final opened = await openPatients(tester);

      await tapKey(tester, 'report-for-${jane.id}');
      expect(find.byKey(const Key('report-dialog')), findsOneWidget);
      expect(find.textContaining('Jane Cooper'), findsWidgets);
      await tapKey(tester, 'report-range-month');
      await tapKey(tester, 'report-download');

      final asked = opened.physio.reports.single;
      expect(asked.patientId, jane.id);
      expect(asked.until.difference(asked.since).inDays, 30);
      expect(opened.saved, ['physioai-report-test.pdf application/pdf 13']);
      expect(find.byKey(const Key('report-done')), findsOneWidget);

      // Another range is another export.
      await tapKey(tester, 'report-range-year');
      expect(find.byKey(const Key('report-done')), findsNothing);
      await tapKey(tester, 'report-download');
      expect(
        opened.physio.reports.last.until
            .difference(opened.physio.reports.last.since)
            .inDays,
        365,
      );
    });

    testWidgets('is told when a report could not be produced', (tester) async {
      final opened = await openPatients(tester);
      opened.physio.reportFailure = const ApiException(
        code: 'not_found',
        message: 'Patient not found.',
        statusCode: 404,
      );

      await tapKey(tester, 'report-for-${marcus.id}');
      await tapKey(tester, 'report-download');

      expect(find.text('Patient not found.'), findsOneWidget);
      expect(opened.saved, isEmpty);
      expect(find.byKey(const Key('report-done')), findsNothing);
    });

    testWidgets('is told where a download is not possible', (tester) async {
      await openPatients(
        tester,
        saver: (bytes, name, type) => throw const FileSavingUnsupported(),
      );

      await tapKey(tester, 'report-for-${jane.id}');
      await tapKey(tester, 'report-download');

      expect(
        find.text('Reports can be downloaded from the web app for now.'),
        findsOneWidget,
      );
    });
  });
}
