// Runs the app's real repositories against a running PhysioAI API, to prove the
// client and server agree on every request and response used so far.
//
// Skipped by default. `tool/live_api_test.sh` starts a throwaway API with its
// own empty database and runs this against it.
@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:physioai/core/api/api_client.dart';
import 'package:physioai/core/api/api_exception.dart';
import 'package:physioai/core/api/token_store.dart';
import 'package:physioai/features/admin/admin_repository.dart';
import 'package:physioai/features/admin/exercise_library_repository.dart';
import 'package:physioai/features/auth/auth_models.dart';
import 'package:physioai/features/auth/auth_repository.dart';
import 'package:physioai/features/consent/consent_repository.dart';
import 'package:physioai/features/exercises/exercise_models.dart';
import 'package:physioai/features/notifications/notifications_repository.dart';
import 'package:physioai/features/patient/patient_repository.dart';
import 'package:physioai/features/physio/physio_repository.dart';

const _live = bool.fromEnvironment('LIVE_API');
const _baseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://localhost:8000/api/v1',
);
const _physioEmail = String.fromEnvironment('PHYSIO_EMAIL');
const _physioPassword = String.fromEnvironment('PHYSIO_PASSWORD');
const _adminEmail = String.fromEnvironment('ADMIN_EMAIL');
const _adminPassword = String.fromEnvironment('ADMIN_PASSWORD');

ApiClient _client() =>
    ApiClient(baseUrl: _baseUrl, tokens: InMemoryTokenStore());

void main() {
  test(
    'invite, register, sign in and role boundaries work against the live API',
    () async {
      // A physiotherapist signs in and generates an invite code.
      final physioApi = _client();
      final physioAuth = AuthRepository(physioApi);
      final physio = await physioAuth.signIn(
        identifier: _physioEmail,
        password: _physioPassword,
        role: UserRole.physiotherapist,
      );
      expect(physio.account.role, UserRole.physiotherapist);
      final physioRepo = PhysioRepository(physioApi);
      final invite = await physioRepo.createInviteCode();
      expect(invite.isActive, isTrue);
      expect(
        (await physioRepo.inviteCodes()).map((c) => c.code),
        contains(invite.code),
      );

      // Choosing the wrong role is refused exactly like a wrong password.
      await expectLater(
        AuthRepository(_client()).signIn(
          identifier: _physioEmail,
          password: _physioPassword,
          role: UserRole.admin,
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'invalid_credentials',
          ),
        ),
      );

      // A new patient registers with that code and is linked to the physiotherapist.
      final patientApi = _client();
      final patientAuth = AuthRepository(patientApi);
      final email =
          'live-${DateTime.now().millisecondsSinceEpoch}@physioai.test';
      final patient = await patientAuth.register(
        fullName: 'Live Test Patient',
        identifier: email,
        password: 'Recover-2026',
        inviteCode: invite.code.toLowerCase(),
      );
      expect(patient.account.role, UserRole.patient);
      expect(patient.physiotherapist?.fullName, physio.account.fullName);
      expect((await patientAuth.restore())?.account.id, patient.account.id);

      // A new patient has not acknowledged the advisory; doing so is explicit,
      // tied to the wording they were shown, and remembered by the server.
      expect(patient.advisoryAcknowledged, isFalse);
      expect(physio.advisoryAcknowledged, isNull);
      final consent = ConsentRepository(patientApi);
      final advisory = await consent.status();
      expect(advisory.acknowledged, isFalse);
      expect(advisory.disclaimer.points, isNotEmpty);
      await expectLater(
        consent.acknowledge('1999-01'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'disclaimer_outdated',
          ),
        ),
      );
      final acknowledged = await consent.acknowledge(
        advisory.disclaimer.version,
      );
      expect(acknowledged.acknowledged, isTrue);
      expect(acknowledged.acknowledgedAt, isNotNull);
      expect((await patientAuth.restore())?.advisoryAcknowledged, isTrue);

      // The code cannot be used a second time.
      await expectLater(
        AuthRepository(_client()).register(
          fullName: 'Second Person',
          identifier:
              'second-${DateTime.now().millisecondsSinceEpoch}@physioai.test',
          password: 'Recover-2026',
          inviteCode: invite.code,
        ),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'invite_invalid'),
        ),
      );

      // The server, not the UI, keeps a patient out of physiotherapist data.
      await expectLater(
        PhysioRepository(patientApi).patients(),
        throwsA(
          isA<ApiException>().having((e) => e.statusCode, 'statusCode', 403),
        ),
      );

      // The physiotherapist builds a plan from the active library and the
      // patient sees it; a second plan archives the first instead of replacing it.
      final library = await physioRepo.activeExercises();
      expect(library.map((e) => e.name), containsAll(['Squats', 'Leg Lunge']));
      final squats = library.firstWhere((e) => e.name == 'Squats');
      final lunge = library.firstWhere((e) => e.name == 'Leg Lunge');
      final patientRepo = PatientRepository(patientApi);
      expect(await patientRepo.currentPlan(), isNull);
      final weekOne = await physioRepo.assignPlan(
        patientId: patient.account.id,
        name: 'Week 1',
        items: [
          PlanItemDraft(squats)
            ..sets = 2
            ..reps = 12
            ..note = 'Go slowly.',
        ],
      );
      final seen = await patientRepo.currentPlan();
      expect(seen?.id, weekOne.id);

      // Assigning the plan told the patient, and only the patient.
      final notices = NotificationsRepository(patientApi);
      var feed = await notices.feed();
      expect(feed.unreadCount, 1);
      expect(feed.items.single.kind, 'plan_assigned');
      expect(feed.items.single.link, '/patient/plan');
      expect(feed.items.single.body, contains('Week 1'));
      expect((await NotificationsRepository(physioApi).feed()).items, isEmpty);
      await notices.markRead(feed.items.single.id);
      expect((await notices.feed()).unreadCount, 0);
      expect(seen?.items.single.prescription, '2 sets × 12 reps');
      expect(seen?.items.single.note, 'Go slowly.');
      await physioRepo.assignPlan(
        patientId: patient.account.id,
        name: 'Week 2',
        items: [
          PlanItemDraft(squats),
          PlanItemDraft(lunge)..difficulty = Difficulty.easy,
        ],
      );
      feed = await notices.feed();
      expect(feed.unreadCount, 1);
      expect(feed.items.map((n) => n.isUnread), [true, false]);
      await notices.markAllRead();
      expect((await notices.feed()).unreadCount, 0);
      final current = await patientRepo.currentPlan();
      expect(current?.name, 'Week 2');
      expect(current?.items.map((i) => i.exercise.name), [
        'Squats',
        'Leg Lunge',
      ]);
      expect(current?.items.last.difficulty, Difficulty.easy);
      final plans = await physioRepo.plans(patient.account.id);
      expect(plans.map((p) => (p.name, p.isActive)), [
        ('Week 2', true),
        ('Week 1', false),
      ]);

      // The physiotherapist now sees the patient and the redeemed code.
      expect(
        (await physioRepo.patients()).map((p) => p.id),
        contains(patient.account.id),
      );
      final redeemed = (await physioRepo.inviteCodes()).firstWhere(
        (c) => c.code == invite.code,
      );
      expect(redeemed.status, 'redeemed');
      expect(redeemed.redeemedBy?.fullName, 'Live Test Patient');

      // An admin sees the account and the audit trail of the registration.
      final adminApi = _client();
      await AuthRepository(adminApi).signIn(
        identifier: _adminEmail,
        password: _adminPassword,
        role: UserRole.admin,
      );
      final admin = AdminRepository(adminApi);
      expect(
        (await admin.users()).map((u) => u.id),
        contains(patient.account.id),
      );
      expect(
        (await admin.auditLog()).map((e) => e.action),
        containsAll([
          'account.registered',
          'invite_code.created',
          'consent.acknowledged',
        ]),
      );

      // The admin's exercise library: thresholds are visible, a new exercise
      // starts switched off, an edit makes a new version, and physiotherapists
      // are only offered what is switched on.
      final exercises = ExerciseLibraryRepository(adminApi);
      final all = await exercises.all();
      expect(
        all.map((e) => e.name),
        containsAll([
          'Arm Abduction',
          'Leg Abduction',
          'Leg Lunge',
          'Push-ups',
          'Squats',
        ]),
      );
      expect(all.every((e) => e.checks.isNotEmpty), isTrue);
      final exerciseName = 'Live Test ${DateTime.now().millisecondsSinceEpoch}';
      Map<String, dynamic> fields({required double amber}) => {
        'name': exerciseName,
        'domain': 'Hip and gluteal rehabilitation',
        'body_area': 'hip',
        'primary_targets': 'Glutes, hamstrings',
        'target_joints': ['hip', 'knee'],
        'movement_pattern':
            'Lying on the back, the hips lift until the body is straight.',
        'instructions':
            'Lie on your back with your knees bent and lift your hips.',
        'checks': [
          {
            'key': 'hip_height',
            'label': 'Hip height',
            'measure': 'Hip angle short of a straight line',
            'unit': 'degrees',
            'info': 5.0,
            'amber': amber,
            'red': null,
            'corrective_message': 'Lift your hips a little higher.',
          },
        ],
      };
      final added = await exercises.create(fields(amber: 15));
      expect(added.isActive, isFalse);
      expect(added.version, 1);
      expect(added.checks.single.red, isNull);
      Future<Iterable<String>> offered() async =>
          (await physioRepo.activeExercises()).map((e) => e.name);
      expect(await offered(), isNot(contains(exerciseName)));

      final edited = await exercises.update(added.id, fields(amber: 12));
      expect(edited.version, 2);
      expect(edited.checks.single.amber, 12);
      await expectLater(
        exercises.update(added.id, fields(amber: 4)), // not above INFO
        throwsA(
          isA<ApiException>().having((e) => e.statusCode, 'statusCode', 422),
        ),
      );
      expect(
        (await exercises.setActive(added.id, active: true)).isActive,
        isTrue,
      );
      expect(await offered(), contains(exerciseName));
      expect(
        (await exercises.setActive(added.id, active: false)).isActive,
        isFalse,
      );
      expect(await offered(), isNot(contains(exerciseName)));
      await expectLater(
        ExerciseLibraryRepository(physioApi).all(),
        throwsA(
          isA<ApiException>().having((e) => e.statusCode, 'statusCode', 403),
        ),
      );
      expect(
        (await admin.auditLog()).map((e) => e.action),
        containsAll([
          'plan.assigned',
          'exercise_template.created',
          'exercise_template.updated',
          'exercise_template.deactivated',
        ]),
      );

      // Signing out ends the session on the server.
      await patientAuth.signOut();
      expect(await patientAuth.restore(), isNull);
    },
    skip: _live ? false : 'Needs a running API: see tool/live_api_test.sh',
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
