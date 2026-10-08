import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:physioai/app.dart';
import 'package:physioai/core/api/api_client.dart';
import 'package:physioai/core/api/api_exception.dart';
import 'package:physioai/core/api/token_store.dart';
import 'package:physioai/features/auth/auth_controller.dart';
import 'package:physioai/features/auth/auth_models.dart';
import 'package:physioai/features/auth/auth_repository.dart';
import 'package:physioai/features/consent/consent_repository.dart';
import 'package:physioai/features/physio/physio_repository.dart';
import 'package:physioai/router.dart';

SessionUser user(
  UserRole role,
  String name, {
  String? physiotherapist,
  bool advisoryAcknowledged = true,
}) => SessionUser(
  account: Account(
    id: 'id-${role.apiValue}',
    fullName: name,
    role: role,
    email: '${role.apiValue}@example.test',
  ),
  physiotherapist: physiotherapist == null
      ? null
      : PersonRef(id: 'physio-1', fullName: physiotherapist),
  // Only patients are ever asked to acknowledge the advisory.
  advisoryAcknowledged: role == UserRole.patient ? advisoryAcknowledged : null,
);

class FakeAuthRepository implements AuthRepository {
  FakeAuthRepository({this.saved, this.patientNeedsAdvisory = false});

  SessionUser? saved;
  ApiException? failure;

  /// When true, patients come back from sign-in and registration without an
  /// acknowledged advisory, as a real new patient does.
  bool patientNeedsAdvisory;
  final signIns = <({String identifier, String password, UserRole role})>[];
  final registrations =
      <
        ({
          String fullName,
          String identifier,
          String password,
          String inviteCode,
        })
      >[];
  int signOuts = 0;

  @override
  Future<SessionUser?> restore() async => saved;

  @override
  Future<SessionUser> signIn({
    required String identifier,
    required String password,
    required UserRole role,
  }) async {
    signIns.add((identifier: identifier, password: password, role: role));
    if (failure != null) throw failure!;
    if (role == UserRole.patient) {
      return user(
        role,
        'Jane Cooper',
        physiotherapist: 'Dr. Sarah Malik',
        advisoryAcknowledged: !patientNeedsAdvisory,
      );
    }
    return user(role, 'Dr. Sarah Malik');
  }

  @override
  Future<SessionUser> register({
    required String fullName,
    required String identifier,
    required String password,
    required String inviteCode,
  }) async {
    registrations.add((
      fullName: fullName,
      identifier: identifier,
      password: password,
      inviteCode: inviteCode,
    ));
    if (failure != null) throw failure!;
    return user(
      UserRole.patient,
      fullName,
      physiotherapist: 'Dr. Sarah Malik',
      advisoryAcknowledged: !patientNeedsAdvisory,
    );
  }

  @override
  Future<void> signOut() async => signOuts++;
}

class FakePhysioRepository implements PhysioRepository {
  final codes = <InviteCode>[];

  @override
  Future<List<InviteCode>> inviteCodes() async => List.of(codes);

  @override
  Future<InviteCode> createInviteCode() async {
    final now = DateTime.utc(2026, 10, 7);
    final code = InviteCode(
      id: 'code-${codes.length}',
      code: 'PHY-TEST-000${codes.length}',
      createdAt: now,
      expiresAt: now.add(const Duration(days: 7)),
      status: 'active',
    );
    codes.insert(0, code);
    return code;
  }

  @override
  Future<List<PatientSummary>> patients() async => const [];
}

class FakeConsentRepository implements ConsentRepository {
  static const disclaimer = Disclaimer(
    version: '2026-10',
    title: 'Before your first session',
    intro: 'A few things to know so you can exercise safely and confidently.',
    points: [
      DisclaimerPoint(
        heading: 'PhysioAI gives movement feedback.',
        body: 'It suggests small corrections in real time.',
      ),
      DisclaimerPoint(
        heading: 'It does not diagnose.',
        body: 'It does not replace your physiotherapist.',
      ),
    ],
    caution: 'If you feel sharp pain, stop and contact your physiotherapist.',
    acknowledgment:
        'I understand that PhysioAI provides movement feedback only.',
  );

  DateTime? acknowledgedAt;
  ApiException? failure;
  final acknowledgedVersions = <String>[];

  @override
  Future<ConsentStatus> status() async => ConsentStatus(
    disclaimer: disclaimer,
    acknowledged: acknowledgedAt != null,
    acknowledgedAt: acknowledgedAt,
  );

  @override
  Future<ConsentStatus> acknowledge(String version) async {
    if (failure != null) throw failure!;
    acknowledgedVersions.add(version);
    acknowledgedAt = DateTime(2026, 10, 8, 18, 30);
    return status();
  }
}

Future<FakeAuthRepository> pumpApp(
  WidgetTester tester, {
  FakeAuthRepository? auth,
  FakePhysioRepository? physio,
  FakeConsentRepository? consent,
}) async {
  tester.view.physicalSize = const Size(1400, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final repository = auth ?? FakeAuthRepository();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
        authRepositoryProvider.overrideWithValue(repository),
        physioRepositoryProvider.overrideWithValue(
          physio ?? FakePhysioRepository(),
        ),
        consentRepositoryProvider.overrideWithValue(
          consent ?? FakeConsentRepository(),
        ),
      ],
      child: const PhysioAiApp(),
    ),
  );
  await tester.pumpAndSettle();
  return repository;
}

/// Welcome -> "Choose your role".
Future<void> openRoleChooser(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(OutlinedButton, 'Sign In'));
  await tester.pumpAndSettle();
}

/// Welcome -> "Choose your role" -> the sign-in form for [role].
Future<void> openSignInAs(WidgetTester tester, UserRole role) async {
  await openRoleChooser(tester);
  await tester.tap(find.byKey(Key('role-${role.apiValue}')));
  await tester.pumpAndSettle();
}

/// Welcome -> role chooser -> patient sign-in -> "Create an account".
Future<void> openRegistration(WidgetTester tester) async {
  await openSignInAs(tester, UserRole.patient);
  await tester.ensureVisible(find.byKey(const Key('create-account')));
  await tester.tap(find.byKey(const Key('create-account')));
  await tester.pumpAndSettle();
}

void main() {
  group('redirectFor', () {
    const signedOut = SignedOut();
    final patient = SignedIn(user(UserRole.patient, 'Jane Cooper'));
    final admin = SignedIn(user(UserRole.admin, 'Alex Morgan'));

    test('signed-out visitors can only open the public screens', () {
      expect(redirectFor(signedOut, '/'), isNull);
      expect(redirectFor(signedOut, '/register'), isNull);
      expect(redirectFor(signedOut, '/sign-in'), isNull);
      expect(redirectFor(signedOut, '/sign-in/admin'), isNull);
      expect(redirectFor(signedOut, '/admin/users'), '/sign-in');
      expect(redirectFor(signedOut, '/patient'), '/sign-in');
    });

    test('a signed-in user is kept inside their own role area', () {
      expect(redirectFor(patient, '/patient/plan'), isNull);
      expect(redirectFor(patient, '/admin'), '/patient');
      expect(redirectFor(patient, '/physio/patients'), '/patient');
      expect(redirectFor(admin, '/admin/audit-log'), isNull);
      expect(redirectFor(admin, '/sign-in'), '/admin');
      expect(redirectFor(admin, '/sign-in/patient'), '/admin');
    });

    test(
      'a path that only shares a prefix is not treated as the same area',
      () {
        expect(redirectFor(patient, '/patients'), '/patient');
        expect(redirectFor(signedOut, '/sign-in-admin'), '/sign-in');
      },
    );

    test('the address is left alone while the saved session is checked', () {
      expect(redirectFor(const AuthLoading(), '/physio/patients'), isNull);
      expect(redirectFor(const AuthLoading(), '/sign-in/admin'), isNull);
    });
  });

  testWidgets('the first sign-in step only asks for a role', (tester) async {
    await pumpApp(tester);
    expect(
      find.text('Smarter rehabilitation.\nBetter movement.'),
      findsOneWidget,
    );

    await openRoleChooser(tester);

    expect(find.text('Choose your role'), findsOneWidget);
    expect(find.text('Login as Patient'), findsOneWidget);
    expect(find.text('Login as Physiotherapist'), findsOneWidget);
    expect(find.text('Login as Admin'), findsOneWidget);
    // No form and no account creation on this screen.
    expect(find.byKey(const Key('sign-in-identifier')), findsNothing);
    expect(find.byKey(const Key('sign-in-password')), findsNothing);
    expect(find.byKey(const Key('sign-in-submit')), findsNothing);
    expect(find.byKey(const Key('create-account')), findsNothing);
  });

  testWidgets('Get Started also begins with choosing a role', (tester) async {
    await pumpApp(tester);

    await tester.tap(find.widgetWithText(FilledButton, 'Get Started'));
    await tester.pumpAndSettle();

    expect(find.text('Choose your role'), findsOneWidget);
  });

  testWidgets('patients can sign in or create an account on the second step', (
    tester,
  ) async {
    await pumpApp(tester);

    await openSignInAs(tester, UserRole.patient);

    expect(find.text('Sign in as Patient'), findsOneWidget);
    expect(find.byKey(const Key('sign-in-submit')), findsOneWidget);
    expect(find.byKey(const Key('create-account')), findsOneWidget);
  });

  for (final role in [UserRole.physiotherapist, UserRole.admin]) {
    testWidgets('${role.label} gets sign-in only, with no account creation', (
      tester,
    ) async {
      await pumpApp(tester);

      await openSignInAs(tester, role);

      expect(find.text('Sign in as ${role.label}'), findsOneWidget);
      expect(find.byKey(const Key('sign-in-submit')), findsOneWidget);
      expect(find.byKey(const Key('create-account')), findsNothing);
      expect(find.text('Create an account'), findsNothing);
      expect(
        find.text(
          '${role.label} accounts are created by your clinic administrator.',
        ),
        findsOneWidget,
      );
    });
  }

  testWidgets('Change role goes back to the role step', (tester) async {
    await pumpApp(tester);
    await openSignInAs(tester, UserRole.admin);

    await tester.tap(find.byKey(const Key('change-role')));
    await tester.pumpAndSettle();

    expect(find.text('Choose your role'), findsOneWidget);
    expect(find.byKey(const Key('sign-in-submit')), findsNothing);
  });

  testWidgets('an unknown role in the address falls back to the role step', (
    tester,
  ) async {
    await pumpApp(tester);

    GoRouter.of(
      tester.element(find.byType(Scaffold).first),
    ).go('/sign-in/nurse');
    await tester.pumpAndSettle();

    expect(find.text('Choose your role'), findsOneWidget);
    expect(find.byKey(const Key('sign-in-submit')), findsNothing);
  });

  testWidgets('empty form is rejected without calling the server', (
    tester,
  ) async {
    final auth = await pumpApp(tester);
    await openSignInAs(tester, UserRole.patient);

    await tester.tap(find.byKey(const Key('sign-in-submit')));
    await tester.pumpAndSettle();

    expect(find.text('Enter your email or mobile number.'), findsOneWidget);
    expect(find.text('Enter your password.'), findsOneWidget);
    expect(auth.signIns, isEmpty);
  });

  testWidgets("signing in sends the chosen role and opens that role's home", (
    tester,
  ) async {
    final auth = await pumpApp(tester);
    await openSignInAs(tester, UserRole.physiotherapist);

    await tester.enterText(
      find.byKey(const Key('sign-in-identifier')),
      '  dr.sarah@example.test ',
    );
    await tester.enterText(
      find.byKey(const Key('sign-in-password')),
      'Physio-Pass-1',
    );
    await tester.tap(find.byKey(const Key('sign-in-submit')));
    await tester.pumpAndSettle();

    expect(auth.signIns.single, (
      identifier: 'dr.sarah@example.test',
      password: 'Physio-Pass-1',
      role: UserRole.physiotherapist,
    ));
    expect(find.text('Invite a patient'), findsOneWidget);
    expect(find.text('Plan Builder'), findsOneWidget);
    expect(find.text('Users & Roles'), findsNothing);
  });

  testWidgets('a locked account shows the server message and stays on the form', (
    tester,
  ) async {
    final auth = await pumpApp(tester);
    auth.failure = const ApiException(
      code: 'account_locked',
      message:
          'Too many unsuccessful sign-in attempts. Try again in about 15 minutes.',
      statusCode: 423,
      retryAfterSeconds: 900,
    );
    await openSignInAs(tester, UserRole.patient);

    await tester.enterText(
      find.byKey(const Key('sign-in-identifier')),
      'jane@example.test',
    );
    await tester.enterText(
      find.byKey(const Key('sign-in-password')),
      'wrong-password',
    );
    await tester.tap(find.byKey(const Key('sign-in-submit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('sign-in-error')), findsOneWidget);
    expect(
      find.textContaining('Too many unsuccessful sign-in attempts'),
      findsOneWidget,
    );
    expect(find.text('Sign in as Patient'), findsOneWidget);
  });

  testWidgets(
    'registration checks the form, then links the patient to their physiotherapist',
    (tester) async {
      final auth = await pumpApp(tester);
      await openRegistration(tester);

      await tester.enterText(
        find.byKey(const Key('register-name')),
        'Jane Cooper',
      );
      await tester.enterText(
        find.byKey(const Key('register-identifier')),
        'jane@example.test',
      );
      await tester.enterText(
        find.byKey(const Key('register-password')),
        'Recover-2026',
      );
      await tester.enterText(
        find.byKey(const Key('register-confirm')),
        'Recover-2027',
      );
      await tester.ensureVisible(find.byKey(const Key('register-submit')));
      await tester.tap(find.byKey(const Key('register-submit')));
      await tester.pumpAndSettle();

      expect(find.text('The passwords do not match.'), findsOneWidget);
      expect(
        find.text('Enter the invite code from your physiotherapist.'),
        findsOneWidget,
      );
      expect(auth.registrations, isEmpty);

      await tester.enterText(
        find.byKey(const Key('register-confirm')),
        'Recover-2026',
      );
      await tester.enterText(
        find.byKey(const Key('register-invite')),
        ' phy-4k7m-9qxd ',
      );
      await tester.tap(find.byKey(const Key('register-submit')));
      await tester.pumpAndSettle();

      expect(auth.registrations.single.inviteCode, 'phy-4k7m-9qxd');
      expect(find.byKey(const Key('linked-physio')), findsOneWidget);
      expect(find.text('Dr. Sarah Malik'), findsOneWidget);
    },
  );

  testWidgets('an invalid invite code is explained on the registration form', (
    tester,
  ) async {
    final auth = await pumpApp(tester);
    auth.failure = const ApiException(
      code: 'invite_invalid',
      message:
          'This invite code is not valid or has expired. Ask your physiotherapist for a new one.',
      statusCode: 400,
    );
    await openRegistration(tester);

    await tester.enterText(
      find.byKey(const Key('register-name')),
      'Jane Cooper',
    );
    await tester.enterText(
      find.byKey(const Key('register-identifier')),
      '0300 1234567',
    );
    await tester.enterText(
      find.byKey(const Key('register-password')),
      'Recover-2026',
    );
    await tester.enterText(
      find.byKey(const Key('register-confirm')),
      'Recover-2026',
    );
    await tester.enterText(
      find.byKey(const Key('register-invite')),
      'PHY-NOPE-NOPE',
    );
    await tester.ensureVisible(find.byKey(const Key('register-submit')));
    await tester.tap(find.byKey(const Key('register-submit')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('register-error')), findsOneWidget);
    expect(find.textContaining('not valid or has expired'), findsOneWidget);
    expect(find.text('Create your account'), findsOneWidget);
  });

  testWidgets('registration links back to the patient sign-in', (tester) async {
    await pumpApp(tester);
    await openRegistration(tester);

    await tester.tap(find.widgetWithText(TextButton, 'Sign In').first);
    await tester.pumpAndSettle();

    expect(find.text('Sign in as Patient'), findsOneWidget);
  });

  testWidgets(
    'a saved session opens the role home directly and logging out returns to the role step',
    (tester) async {
      final auth = await pumpApp(
        tester,
        auth: FakeAuthRepository(
          saved: user(UserRole.physiotherapist, 'Dr. Sarah Malik'),
        ),
      );

      expect(find.text('Invite a patient'), findsOneWidget);

      await tester.tap(find.byKey(const Key('generate-invite')));
      await tester.pumpAndSettle();
      expect(find.text('PHY-TEST-0000'), findsOneWidget);

      await tester.tap(find.byKey(const Key('sign-out')));
      await tester.pumpAndSettle();

      expect(auth.signOuts, 1);
      expect(find.text('Choose your role'), findsOneWidget);
    },
  );
}
