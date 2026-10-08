// US 1.2: the account's own device list, changing a password, and the
// screen that replaces a temporary password issued by an admin.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:physioai/core/api/api_exception.dart';
import 'package:physioai/features/account/account_repository.dart';
import 'package:physioai/features/auth/auth_controller.dart';
import 'package:physioai/features/auth/auth_models.dart';
import 'package:physioai/router.dart';

import 'auth_flow_test.dart';

Device device(String id, String name, {bool current = false}) => Device(
  id: id,
  name: name,
  signedInAt: DateTime(2026, 10, 8, 9),
  lastActiveAt: DateTime(2026, 10, 8, 18, 30),
  current: current,
  ip: '203.0.113.7',
);

FakeAccountRepository threeDevices() => FakeAccountRepository(
  devices: [
    device('this', 'Chrome on Windows', current: true),
    device('phone', 'Safari on iPhone'),
    device('tablet', 'Safari on iPad'),
  ],
);

SessionUser jane() =>
    user(UserRole.patient, 'Jane Cooper', physiotherapist: 'Dr. Sarah Malik');

Future<FakeAccountRepository> openSecurity(
  WidgetTester tester, {
  FakeAccountRepository? account,
  SessionUser? as,
}) async {
  final repository = account ?? threeDevices();
  await pumpApp(
    tester,
    auth: FakeAuthRepository(saved: as ?? jane()),
    account: repository,
  );
  await tapKey(tester, 'account-security');
  return repository;
}

Future<void> typePasswords(
  WidgetTester tester, {
  required String current,
  required String next,
  String? again,
}) async {
  await fill(tester, 'password-current', current);
  await fill(tester, 'password-new', next);
  await fill(tester, 'password-confirm', again ?? next);
  await tapKey(tester, 'password-submit');
}

void main() {
  group('Account & Security', () {
    testWidgets('shows who is signed in and where', (tester) async {
      await openSecurity(tester);

      // The page title, in the top bar and above the content.
      expect(find.text('Account & Security'), findsNWidgets(3));
      expect(find.text('patient@example.test'), findsOneWidget);
      expect(find.text('Dr. Sarah Malik'), findsOneWidget);
      expect(find.text('Chrome on Windows'), findsOneWidget);
      expect(find.text('This device'), findsOneWidget);
      expect(find.text('Safari on iPhone'), findsOneWidget);
      expect(find.text('Last active 8 Oct 2026, 18:30'), findsNWidgets(2));
      // This device has no "Sign out" of its own: that is what Log out is for.
      expect(find.byKey(const Key('device-sign-out-this')), findsNothing);
      expect(find.byKey(const Key('device-sign-out-phone')), findsOneWidget);
    });

    testWidgets('every role has the page, from the sidebar and the top bar', (
      tester,
    ) async {
      for (final role in UserRole.values) {
        await pumpApp(
          tester,
          auth: FakeAuthRepository(saved: user(role, 'Someone Signed In')),
        );
        await tapKey(tester, 'account-security');
        expect(find.text('Your details'), findsOneWidget, reason: role.label);
        expect(find.text(role.label), findsWidgets);

        await tester.tap(find.text(_firstNavLabel(role)).first);
        await tester.pumpAndSettle();
        expect(find.text('Your details'), findsNothing);
        await tapKey(tester, 'open-account');
        expect(find.text('Your details'), findsOneWidget, reason: role.label);
      }
    });

    testWidgets('signing one device out asks first, then removes it', (
      tester,
    ) async {
      final account = await openSecurity(tester);

      await tapKey(tester, 'device-sign-out-phone');
      expect(find.text('Sign out Safari on iPhone?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(account.deviceList, hasLength(3));

      await tapKey(tester, 'device-sign-out-phone');
      await tapKey(tester, 'confirm-device-sign-out');

      expect(account.deviceList.map((d) => d.id), ['this', 'tablet']);
      expect(find.text('Safari on iPhone'), findsNothing);
      expect(find.text('Safari on iPhone was signed out.'), findsOneWidget);
    });

    testWidgets('"Sign out everywhere else" keeps only this device', (
      tester,
    ) async {
      final account = await openSecurity(tester);

      await tapKey(tester, 'sign-out-others');
      expect(find.text('Sign out everywhere else?'), findsOneWidget);
      await tapKey(tester, 'confirm-device-sign-out');

      expect(account.deviceList.single.current, isTrue);
      expect(find.text('2 other devices were signed out.'), findsOneWidget);
      // With nothing else signed in there is nothing left to offer.
      expect(find.byKey(const Key('sign-out-others')), findsNothing);
    });

    testWidgets('a failure while signing a device out is shown', (
      tester,
    ) async {
      final account = threeDevices()..failure = ApiException.network;
      await openSecurity(tester, account: account);

      await tapKey(tester, 'device-sign-out-phone');
      await tapKey(tester, 'confirm-device-sign-out');

      expect(find.byKey(const Key('devices-error')), findsOneWidget);
      expect(find.text('Safari on iPhone'), findsOneWidget);
    });

    testWidgets('a new password is checked before anything is sent', (
      tester,
    ) async {
      final account = await openSecurity(tester);

      await tapKey(tester, 'password-submit');
      expect(find.text('Enter the password you use now.'), findsOneWidget);

      await typePasswords(tester, current: 'Old-Pass-1', next: 'short1');
      expect(
        find.text(
          'Use at least 8 characters, including a letter and a number.',
        ),
        findsOneWidget,
      );

      await typePasswords(
        tester,
        current: 'Old-Pass-1',
        next: 'Brand-New-2026',
        again: 'Brand-New-2027',
      );
      expect(find.text('The two new passwords do not match.'), findsOneWidget);

      await typePasswords(tester, current: 'Old-Pass-1', next: 'Old-Pass-1');
      expect(
        find.text('Choose a password that is different from your current one.'),
        findsOneWidget,
      );
      expect(account.passwordChanges, isEmpty);
    });

    testWidgets('changing the password signs the other devices out', (
      tester,
    ) async {
      final account = threeDevices()..signedIn = jane();
      await openSecurity(tester, account: account);

      await typePasswords(
        tester,
        current: 'Old-Pass-1',
        next: 'Brand-New-2026',
      );

      expect(account.passwordChanges.single, (
        current: 'Old-Pass-1',
        next: 'Brand-New-2026',
      ));
      expect(
        find.text('Your password was changed. Other devices were signed out.'),
        findsOneWidget,
      );
      // The form is emptied and the device list shows what is true now.
      for (final key in [
        'password-current',
        'password-new',
        'password-confirm',
      ]) {
        expect(
          tester.widget<TextFormField>(find.byKey(Key(key))).controller!.text,
          isEmpty,
        );
      }
      expect(find.text('Safari on iPhone'), findsNothing);
      expect(find.text('Your details'), findsOneWidget);
    });

    testWidgets('a wrong current password is reported on the form', (
      tester,
    ) async {
      final account = threeDevices()
        ..failure = const ApiException(
          code: 'current_password_incorrect',
          message: 'Your current password is not correct.',
          statusCode: 400,
        );
      await openSecurity(tester, account: account);

      await typePasswords(
        tester,
        current: 'Not-Mine-1',
        next: 'Brand-New-2026',
      );

      expect(find.byKey(const Key('password-error')), findsOneWidget);
      expect(
        find.text('Your current password is not correct.'),
        findsOneWidget,
      );
      expect(find.text('Safari on iPhone'), findsOneWidget);
    });
  });

  group('Temporary password', () {
    SessionUser newcomer(UserRole role) =>
        user(role, 'Omar Farooq', passwordChangeRequired: true);

    test('opens nothing but the screen that replaces it', () {
      for (final role in UserRole.values) {
        final state = SignedIn(newcomer(role));
        for (final location in [
          role.homePath,
          '${role.homePath}/security',
          '/admin/users',
          advisoryPath,
          '/',
        ]) {
          expect(redirectFor(state, location), setPasswordPath);
        }
        expect(redirectFor(state, setPasswordPath), isNull);
      }
      // Once the password is the person's own, the screen is closed to them.
      final settled = SignedIn(user(UserRole.admin, 'Alex Morgan'));
      expect(redirectFor(settled, setPasswordPath), '/admin');
      // A new patient replaces the password first and reads the advisory second.
      final patient = SignedIn(
        user(
          UserRole.patient,
          'Marcus Johnson',
          advisoryAcknowledged: false,
          passwordChangeRequired: true,
        ),
      );
      expect(redirectFor(patient, advisoryPath), setPasswordPath);
    });

    testWidgets('holds the person on one screen with no way around it', (
      tester,
    ) async {
      await pumpApp(
        tester,
        auth: FakeAuthRepository(saved: newcomer(UserRole.physiotherapist)),
      );

      expect(find.text('Choose your own password'), findsOneWidget);
      expect(find.textContaining('Welcome, Omar.'), findsOneWidget);
      expect(find.text('Temporary password'), findsOneWidget);
      // No sidebar, no bell: only the form and Log out.
      expect(find.byKey(const Key('sign-out')), findsNothing);
      expect(find.byKey(const Key('notification-bell')), findsNothing);
      expect(find.byKey(const Key('set-password-sign-out')), findsOneWidget);
    });

    testWidgets('choosing a password opens the app', (tester) async {
      final account = FakeAccountRepository(
        signedIn: user(UserRole.physiotherapist, 'Omar Farooq'),
      );
      await pumpApp(
        tester,
        auth: FakeAuthRepository(saved: newcomer(UserRole.physiotherapist)),
        account: account,
      );

      await typePasswords(
        tester,
        current: 'Temp-4821-Kite',
        next: 'Chosen-By-Omar-1',
      );

      expect(account.passwordChanges.single, (
        current: 'Temp-4821-Kite',
        next: 'Chosen-By-Omar-1',
      ));
      expect(find.text('Choose your own password'), findsNothing);
      expect(find.byKey(const Key('sign-out')), findsOneWidget);
      expect(find.text('Plan Builder'), findsOneWidget);
    });

    testWidgets('a new patient then reads the advisory', (tester) async {
      final account = FakeAccountRepository(
        signedIn: user(
          UserRole.patient,
          'Marcus Johnson',
          physiotherapist: 'Dr. Sarah Malik',
          advisoryAcknowledged: false,
        ),
      );
      await pumpApp(
        tester,
        auth: FakeAuthRepository(saved: newcomer(UserRole.patient)),
        account: account,
      );

      await typePasswords(
        tester,
        current: 'Temp-4821-Kite',
        next: 'Chosen-By-Marcus-1',
      );

      expect(find.text('Choose your own password'), findsNothing);
      expect(find.byKey(const Key('advisory-continue')), findsOneWidget);
    });

    testWidgets('a rejected temporary password keeps the person here', (
      tester,
    ) async {
      final account = FakeAccountRepository()
        ..failure = const ApiException(
          code: 'current_password_incorrect',
          message: 'Your current password is not correct.',
          statusCode: 400,
        );
      await pumpApp(
        tester,
        auth: FakeAuthRepository(saved: newcomer(UserRole.admin)),
        account: account,
      );

      await typePasswords(tester, current: 'Wrong-Temp-1', next: 'Chosen-2026');

      expect(
        find.text('Your current password is not correct.'),
        findsOneWidget,
      );
      expect(find.text('Choose your own password'), findsOneWidget);
    });

    testWidgets('logging out is always possible', (tester) async {
      final auth = FakeAuthRepository(saved: newcomer(UserRole.admin));
      await pumpApp(tester, auth: auth);

      await tapKey(tester, 'set-password-sign-out');

      expect(auth.signOuts, 1);
      expect(find.text('Choose your own password'), findsNothing);
      // Signed out: back to choosing a role to sign in with.
      expect(find.text('Choose your role'), findsOneWidget);
    });
  });
}

String _firstNavLabel(UserRole role) => switch (role) {
  UserRole.patient => 'My Exercise Plan',
  UserRole.physiotherapist => 'Patients',
  UserRole.admin => 'Audit Log',
};
