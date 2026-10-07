import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:physioai/app.dart';
import 'package:physioai/core/api/api_client.dart';
import 'package:physioai/core/api/api_exception.dart';
import 'package:physioai/core/api/token_store.dart';
import 'package:physioai/features/auth/auth_controller.dart';
import 'package:physioai/features/auth/auth_models.dart';
import 'package:physioai/features/auth/auth_repository.dart';
import 'package:physioai/features/physio/physio_repository.dart';
import 'package:physioai/router.dart';

SessionUser user(UserRole role, String name, {String? physiotherapist}) =>
    SessionUser(
      account: Account(
        id: 'id-${role.apiValue}',
        fullName: name,
        role: role,
        email: '${role.apiValue}@example.test',
      ),
      physiotherapist: physiotherapist == null
          ? null
          : PersonRef(id: 'physio-1', fullName: physiotherapist),
    );

class FakeAuthRepository implements AuthRepository {
  FakeAuthRepository({this.saved});

  SessionUser? saved;
  ApiException? failure;
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
    return user(UserRole.patient, fullName, physiotherapist: 'Dr. Sarah Malik');
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

Future<FakeAuthRepository> pumpApp(
  WidgetTester tester, {
  FakeAuthRepository? auth,
  FakePhysioRepository? physio,
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
      ],
      child: const PhysioAiApp(),
    ),
  );
  await tester.pumpAndSettle();
  return repository;
}

Future<void> openSignIn(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(OutlinedButton, 'Sign In'));
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
      expect(redirectFor(signedOut, '/admin/users'), '/sign-in');
      expect(redirectFor(signedOut, '/patient'), '/sign-in');
    });

    test('a signed-in user is kept inside their own role area', () {
      expect(redirectFor(patient, '/patient/plan'), isNull);
      expect(redirectFor(patient, '/admin'), '/patient');
      expect(redirectFor(patient, '/physio/patients'), '/patient');
      expect(redirectFor(admin, '/admin/audit-log'), isNull);
      expect(redirectFor(admin, '/sign-in'), '/admin');
    });

    test(
      'a path that only shares a prefix is not treated as the same area',
      () {
        expect(redirectFor(patient, '/patients'), '/patient');
      },
    );
  });

  testWidgets(
    'welcome screen leads to the role-based sign-in with Patient preselected',
    (tester) async {
      await pumpApp(tester);
      expect(
        find.text('Smarter rehabilitation.\nBetter movement.'),
        findsOneWidget,
      );

      await openSignIn(tester);

      expect(find.text('Login as Patient'), findsOneWidget);
      expect(find.text('Login as Physiotherapist'), findsOneWidget);
      expect(find.text('Login as Admin'), findsOneWidget);
      expect(find.text('Sign in as Patient'), findsOneWidget);
      expect(find.text('Create an account'), findsOneWidget);
    },
  );

  testWidgets(
    'choosing a role changes the form and hides patient registration',
    (tester) async {
      await pumpApp(tester);
      await openSignIn(tester);

      await tester.tap(find.byKey(const Key('role-admin')));
      await tester.pumpAndSettle();

      expect(find.text('Sign in as Admin'), findsOneWidget);
      expect(find.text('Create an account'), findsNothing);
      expect(
        find.text('Admin accounts are created by your clinic administrator.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('empty form is rejected without calling the server', (
    tester,
  ) async {
    final auth = await pumpApp(tester);
    await openSignIn(tester);

    await tester.tap(find.byKey(const Key('sign-in-submit')));
    await tester.pumpAndSettle();

    expect(find.text('Enter your email or mobile number.'), findsOneWidget);
    expect(find.text('Enter your password.'), findsOneWidget);
    expect(auth.signIns, isEmpty);
  });

  testWidgets('signing in sends the chosen role and opens that role\'s home', (
    tester,
  ) async {
    final auth = await pumpApp(tester);
    await openSignIn(tester);

    await tester.tap(find.byKey(const Key('role-physiotherapist')));
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
    await openSignIn(tester);

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
      await tester.tap(find.widgetWithText(FilledButton, 'Get Started'));
      await tester.pumpAndSettle();

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
    await tester.tap(find.widgetWithText(FilledButton, 'Get Started'));
    await tester.pumpAndSettle();

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

  testWidgets(
    'a saved session opens the role home directly and logging out returns to sign-in',
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
      expect(find.text('Welcome back'), findsOneWidget);
    },
  );
}
