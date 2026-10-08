// Runs the app's real repositories against a running PhysioAI API, to prove the
// client and server agree on every request and response used so far.
//
// Skipped by default. Start the API with seeded demo accounts, then run
// `tool/live_api_test.sh` (it passes the demo credentials from backend/.env).
@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:physioai/core/api/api_client.dart';
import 'package:physioai/core/api/api_exception.dart';
import 'package:physioai/core/api/token_store.dart';
import 'package:physioai/features/admin/admin_repository.dart';
import 'package:physioai/features/auth/auth_models.dart';
import 'package:physioai/features/auth/auth_repository.dart';
import 'package:physioai/features/consent/consent_repository.dart';
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

      // Signing out ends the session on the server.
      await patientAuth.signOut();
      expect(await patientAuth.restore(), isNull);
    },
    skip: _live ? false : 'Needs a running API: see tool/live_api_test.sh',
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
