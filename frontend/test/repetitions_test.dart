// Storing counted repetitions (US 3.3): what the app sends, what it reads
// back, and that a retry is safe.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:physioai/core/api/api_client.dart';
import 'package:physioai/core/api/api_exception.dart';
import 'package:physioai/core/api/token_store.dart';
import 'package:physioai/features/patient/patient_repository.dart';
import 'package:physioai/features/session/precheck.dart';
import 'package:physioai/features/session/repetitions.dart';

import 'auth_flow_test.dart';

const _stored = {
  'id': '5b0e8f0e-0b0a-4c1e-9d6e-3f1f3b0f8a11',
  'set_number': 1,
  'rep_number': 3,
  'started_ms': 12840,
  'ended_ms': 15210,
};

http.Response _json(Object body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

/// The real repository over a pretend server, so the requests it makes can be
/// read back.
Future<PatientRepository> _repository(MockClientHandler handler) async {
  final tokens = InMemoryTokenStore();
  await tokens.write(
    const AuthTokens(accessToken: 'access-1', refreshToken: 'refresh-1'),
  );
  return PatientRepository(
    ApiClient(
      baseUrl: 'http://api.test/api/v1',
      tokens: tokens,
      httpClient: MockClient(handler),
    ),
  );
}

RepetitionDraft _draft({String? clientKey}) => RepetitionDraft(
  setNumber: 1,
  repNumber: 3,
  startedMs: 12840,
  endedMs: 15210,
  measures: const {'trunk_lean': 4.2049, 'elbow_bend': 12.5},
  clientKey: clientKey,
);

void main() {
  group('a repetition draft', () {
    test('gets a key that is a random UUID, different each time', () {
      final uuid = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );
      final keys = {for (var i = 0; i < 50; i++) _draft().clientKey};

      expect(keys, hasLength(50));
      expect(keys.every(uuid.hasMatch), isTrue);
    });

    test('is sent as measurements, with no verdict of its own', () {
      final json = _draft(clientKey: 'key-1').toJson();

      expect(json, {
        'client_key': 'key-1',
        'set_number': 1,
        'rep_number': 3,
        'started_ms': 12840,
        'ended_ms': 15210,
        // Two decimals are plenty for an angle and keep the payload small.
        'measures': {'trunk_lean': 4.2, 'elbow_bend': 12.5},
      });
      expect(json.keys, isNot(contains('tier')));
    });

    test('cannot describe a repetition that makes no sense', () {
      RepetitionDraft build({
        int set = 1,
        int rep = 1,
        int started = 0,
        int ended = 10,
        Map<String, double> measures = const {},
      }) => RepetitionDraft(
        setNumber: set,
        repNumber: rep,
        startedMs: started,
        endedMs: ended,
        measures: measures,
      );

      expect(() => build(set: 0), throwsArgumentError);
      expect(() => build(rep: 0), throwsArgumentError);
      expect(() => build(started: -1), throwsArgumentError);
      expect(() => build(started: 20, ended: 10), throwsArgumentError);
      expect(
        () => build(measures: {'trunk_lean': double.nan}),
        throwsArgumentError,
      );
      expect(
        () => build(measures: {'trunk_lean': double.infinity}),
        throwsArgumentError,
      );
      // A repetition that takes no measurable time is still a repetition.
      expect(build(started: 10, ended: 10).endedMs, 10);
    });

    test('cannot have its measures changed after it is made', () {
      final measures = {'trunk_lean': 4.0};
      final draft = RepetitionDraft(
        setNumber: 1,
        repNumber: 1,
        startedMs: 0,
        endedMs: 10,
        measures: measures,
      );
      measures['trunk_lean'] = 99;

      expect(draft.measures['trunk_lean'], 4.0);
      expect(() => draft.measures['elbow_bend'] = 1, throwsUnsupportedError);
    });
  });

  group('storing a repetition', () {
    test('posts it to its session, signed in, and reads the reply', () async {
      late http.Request seen;
      final repository = await _repository((request) async {
        seen = request;
        return _json(_stored, 201);
      });

      final recorded = await repository.recordRepetition(
        sessionId: 'session-1',
        repetition: _draft(clientKey: 'key-1'),
      );

      expect(seen.method, 'POST');
      expect(
        seen.url.toString(),
        'http://api.test/api/v1/patient/sessions/session-1/repetitions',
      );
      expect(seen.headers['Authorization'], 'Bearer access-1');
      expect(jsonDecode(seen.body), _draft(clientKey: 'key-1').toJson());
      expect(recorded.id, _stored['id']);
      expect(recorded.setNumber, 1);
      expect(recorded.repNumber, 3);
      expect(recorded.startedMs, 12840);
      expect(recorded.endedMs, 15210);
    });

    test('reads how the server classified it', () async {
      final repository = await _repository(
        (_) async => _json({
          ..._stored,
          'tier': 'red',
          'feedback': [
            {
              'check': 'trunk_lean',
              'label': 'Trunk lean',
              'tier': 'red',
              'value': 24.5,
              'unit': 'degrees',
              'message': 'Stand tall.',
            },
            {
              'check': 'elbow_bend',
              'label': 'Elbow bend',
              'tier': 'info',
              'value': 12,
              'unit': 'degrees',
              'message': 'Keep your elbows straight.',
            },
          ],
          'unmeasured': ['knee_bend'],
          'session_status': 'paused',
          'pause': {
            'repetition_id': _stored['id'],
            'check': 'trunk_lean',
            'message': 'Stand tall.',
          },
        }, 201),
      );

      final recorded = await repository.recordRepetition(
        sessionId: 'session-1',
        repetition: _draft(),
      );

      expect(recorded.tier, FeedbackTier.red);
      expect(
        [for (final item in recorded.feedback) (item.check, item.tier)],
        [('trunk_lean', FeedbackTier.red), ('elbow_bend', FeedbackTier.info)],
      );
      expect(recorded.feedback.first.value, 24.5);
      expect(recorded.unmeasured, ['knee_bend']);
      expect(recorded.sessionStatus, 'paused');
      expect(recorded.pause!.repetitionId, _stored['id']);
      expect(recorded.pause!.message, 'Stand tall.');
    });

    test('a reply with nothing to report is a good repetition', () async {
      final repository = await _repository((_) async => _json(_stored, 201));

      final recorded = await repository.recordRepetition(
        sessionId: 'session-1',
        repetition: _draft(),
      );

      expect(recorded.tier, FeedbackTier.ok);
      expect(recorded.feedback, isEmpty);
      expect(recorded.pause, isNull);
    });

    test('a measure that was not in view is sent as null, not left out', () {
      final json = RepetitionDraft(
        setNumber: 1,
        repNumber: 1,
        startedMs: 0,
        endedMs: 900,
        measures: const {'trunk_lean': 3.14159, 'elbow_bend': null},
      ).toJson();

      expect(json['measures'], {'trunk_lean': 3.14, 'elbow_bend': null});
    });

    test('sends the same key when the same repetition is retried', () async {
      final keys = <String>[];
      var calls = 0;
      final repository = await _repository((request) async {
        keys.add(
          (jsonDecode(request.body) as Map<String, dynamic>)['client_key']
              as String,
        );
        calls += 1;
        // The first reply is lost on the way back.
        if (calls == 1) throw http.ClientException('connection reset');
        return _json(_stored, 200);
      });
      final draft = _draft();

      await expectLater(
        repository.recordRepetition(sessionId: 'session-1', repetition: draft),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'network_error'),
        ),
      );
      final recorded = await repository.recordRepetition(
        sessionId: 'session-1',
        repetition: draft,
      );

      expect(keys, [draft.clientKey, draft.clientKey]);
      expect(recorded.id, _stored['id']);
    });

    for (final (status, code, message) in [
      (404, 'not_found', 'Session not found.'),
      (409, 'session_not_active', 'This session has already ended.'),
      (
        409,
        'session_paused',
        'Read the message on screen before you continue.',
      ),
    ]) {
      test('passes on the refusal "$code" as the server worded it', () async {
        final repository = await _repository(
          (_) async => _json({
            'detail': {'code': code, 'message': message},
          }, status),
        );

        await expectLater(
          repository.recordRepetition(
            sessionId: 'session-1',
            repetition: _draft(),
          ),
          throwsA(
            isA<ApiException>()
                .having((e) => e.code, 'code', code)
                .having((e) => e.message, 'message', message)
                .having((e) => e.statusCode, 'statusCode', status),
          ),
        );
      });
    }
  });

  group('the session as the server holds it', () {
    const session = {
      'id': 'session-1',
      'status': 'paused',
      'started_at': '2026-10-10T09:00:00Z',
      'ended_at': null,
      'checks': [
        {
          'key': 'trunk_lean',
          'label': 'Trunk lean',
          'unit': 'degrees',
          'info': 5,
          'amber': 10,
          'red': 20,
          'corrective_message': 'Stand tall.',
        },
        {
          'key': 'elbow_bend',
          'label': 'Elbow bend',
          'unit': 'degrees',
          'info': 10,
          'amber': 20,
          'red': null,
          'corrective_message': 'Keep your elbows straight.',
        },
      ],
      'totals': {'repetitions': 4, 'ok': 2, 'info': 0, 'amber': 1, 'red': 1},
      'pause': {
        'repetition_id': 'rep-4',
        'check': 'trunk_lean',
        'message': 'Stand tall.',
      },
    };

    test('is read with its checks, totals and pause', () async {
      late http.Request seen;
      final repository = await _repository((request) async {
        seen = request;
        return _json(session, 200);
      });

      final read = await repository.session('session-1');

      expect(seen.method, 'GET');
      expect(
        seen.url.toString(),
        'http://api.test/api/v1/patient/sessions/session-1',
      );
      expect(read.isPaused, isTrue);
      expect(
        [for (final check in read.checks) check.key],
        ['trunk_lean', 'elbow_bend'],
      );
      expect(read.checks.first.red, 20);
      expect(read.checks.last.red, isNull);
      expect(read.checks.last.message, 'Keep your elbows straight.');
      expect(
        (read.totals.repetitions, read.totals.ok, read.totals.amber),
        (4, 2, 1),
      );
      expect(read.totals.red, 1);
      expect(read.pause!.repetitionId, 'rep-4');
    });

    test('a pause is acknowledged by naming its repetition', () async {
      late http.Request seen;
      final repository = await _repository((request) async {
        seen = request;
        return _json({...session, 'status': 'active', 'pause': null}, 200);
      });

      final after = await repository.acknowledgePause(
        sessionId: 'session-1',
        repetitionId: 'rep-4',
      );

      expect(seen.method, 'POST');
      expect(
        seen.url.toString(),
        'http://api.test/api/v1/patient/sessions/session-1/acknowledge',
      );
      expect(jsonDecode(seen.body), {'repetition_id': 'rep-4'});
      expect(after.isPaused, isFalse);
      expect(after.pause, isNull);
    });

    test('a session from an older server still reads', () {
      final read = ExerciseSession.fromJson(const {
        'id': 'session-1',
        'status': 'active',
        'started_at': '2026-10-10T09:00:00Z',
      });
      expect(read.checks, isEmpty);
      expect(read.totals.repetitions, 0);
      expect(read.pause, isNull);
    });
  });

  group('the test double used by widget tests', () {
    test('stores a retried repetition once, like the server', () async {
      final fake = FakePatientRepository();
      final draft = _draft();

      final first = await fake.recordRepetition(
        sessionId: 'session-1',
        repetition: draft,
      );
      final again = await fake.recordRepetition(
        sessionId: 'session-1',
        repetition: draft,
      );
      final next = await fake.recordRepetition(
        sessionId: 'session-1',
        repetition: _draft(),
      );

      expect(again.id, first.id);
      expect(next.id, isNot(first.id));
      expect(fake.repetitionWrites, hasLength(3));
      expect(fake.storedRepetitions, hasLength(2));
    });

    test('can be made to refuse, and then stores nothing', () async {
      final fake = FakePatientRepository()
        ..repetitionFailure = const ApiException(
          code: 'session_paused',
          message: 'Read the message on screen before you continue.',
          statusCode: 409,
        );

      await expectLater(
        fake.recordRepetition(sessionId: 'session-1', repetition: _draft()),
        throwsA(isA<ApiException>()),
      );
      expect(fake.storedRepetitions, isEmpty);
    });
  });
}
