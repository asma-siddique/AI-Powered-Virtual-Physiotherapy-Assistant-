// US 1.4 - Advisory disclaimer and consent capture.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:physioai/core/api/api_exception.dart';
import 'package:physioai/core/widgets/common.dart';
import 'package:physioai/features/auth/auth_controller.dart';
import 'package:physioai/features/auth/auth_models.dart';
import 'package:physioai/router.dart';

import 'auth_flow_test.dart';

SessionUser newPatient() => user(
  UserRole.patient,
  'Jane Cooper',
  physiotherapist: 'Dr. Sarah Malik',
  advisoryAcknowledged: false,
);

bool continueEnabled(WidgetTester tester) =>
    tester
        .widget<FilledButton>(
          find.descendant(
            of: find.byKey(const Key('advisory-continue')),
            matching: find.byType(FilledButton),
          ),
        )
        .onPressed !=
    null;

void go(WidgetTester tester, String location) =>
    GoRouter.of(tester.element(find.byType(Scaffold).first)).go(location);

void main() {
  group('redirectFor', () {
    final waiting = SignedIn(newPatient());
    final done = SignedIn(user(UserRole.patient, 'Jane Cooper'));

    test('a patient who has not acknowledged can only open the advisory', () {
      expect(redirectFor(waiting, '/patient'), advisoryPath);
      expect(redirectFor(waiting, '/patient/plan'), advisoryPath);
      expect(redirectFor(waiting, '/patient/help'), advisoryPath);
      expect(redirectFor(waiting, '/sign-in'), advisoryPath);
      expect(redirectFor(waiting, advisoryPath), isNull);
    });

    test('once acknowledged, the advisory screen is no longer a stop', () {
      expect(redirectFor(done, '/patient'), isNull);
      expect(redirectFor(done, '/patient/help'), isNull);
      expect(redirectFor(done, advisoryPath), '/patient');
    });

    test('physiotherapists and admins are never sent to the advisory', () {
      final physio = SignedIn(user(UserRole.physiotherapist, 'Dr. Sarah'));
      final admin = SignedIn(user(UserRole.admin, 'Alex Morgan'));
      expect(redirectFor(physio, '/physio'), isNull);
      expect(redirectFor(physio, advisoryPath), '/physio');
      expect(redirectFor(admin, '/admin'), isNull);
      expect(redirectFor(admin, advisoryPath), '/admin');
    });
  });

  testWidgets(
    'a new patient is stopped at the advisory and cannot go around it',
    (tester) async {
      await pumpApp(tester, auth: FakeAuthRepository(saved: newPatient()));

      expect(find.text('Before your first session'), findsOneWidget);
      expect(find.text('It does not diagnose.'), findsOneWidget);
      // No app navigation and no way to skip, close or postpone.
      expect(find.text('My Exercise Plan'), findsNothing);
      for (final label in ['Skip', 'Later', 'Not now', 'Close', 'Cancel']) {
        expect(find.text(label), findsNothing);
      }
      expect(find.byIcon(Icons.close), findsNothing);

      go(tester, '/patient/plan');
      await tester.pumpAndSettle();
      expect(find.text('Before your first session'), findsOneWidget);

      go(tester, '/patient');
      await tester.pumpAndSettle();
      expect(find.text('Before your first session'), findsOneWidget);
    },
  );

  testWidgets(
    'continuing needs the box ticked, then records the version read',
    (tester) async {
      final consent = FakeConsentRepository();
      await pumpApp(
        tester,
        auth: FakeAuthRepository(saved: newPatient()),
        consent: consent,
      );

      expect(continueEnabled(tester), isFalse);
      expect(find.text('Tick the box above to continue.'), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('advisory-continue')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(consent.acknowledgedVersions, isEmpty);

      await tester.tap(find.byKey(const Key('advisory-checkbox')));
      await tester.pumpAndSettle();
      expect(continueEnabled(tester), isTrue);

      await tester.tap(find.byKey(const Key('advisory-continue')));
      await tester.pumpAndSettle();

      expect(consent.acknowledgedVersions, ['2026-10']);
      // Into the app proper: the patient home with its navigation.
      expect(find.byKey(const Key('linked-physio')), findsOneWidget);
      expect(find.text('My Exercise Plan'), findsOneWidget);
      expect(find.text('Before your first session'), findsNothing);
    },
  );

  testWidgets('unticking the box disables continuing again', (tester) async {
    await pumpApp(tester, auth: FakeAuthRepository(saved: newPatient()));

    await tester.tap(find.byKey(const Key('advisory-checkbox')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('advisory-checkbox')));
    await tester.pumpAndSettle();

    expect(continueEnabled(tester), isFalse);
  });

  testWidgets('registration leads straight to the advisory', (tester) async {
    final auth = await pumpApp(
      tester,
      auth: FakeAuthRepository(patientNeedsAdvisory: true),
    );
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
      'Recover-2026',
    );
    await tester.enterText(
      find.byKey(const Key('register-invite')),
      'PHY-4K7M-9QXD',
    );
    await tester.ensureVisible(find.byKey(const Key('register-submit')));
    await tester.tap(find.byKey(const Key('register-submit')));
    await tester.pumpAndSettle();

    expect(auth.registrations, hasLength(1));
    expect(find.text('Before your first session'), findsOneWidget);
    expect(find.byKey(const Key('linked-physio')), findsNothing);
  });

  testWidgets(
    'a failed save keeps the patient on the advisory with the reason',
    (tester) async {
      final consent = FakeConsentRepository()
        ..failure = const ApiException(
          code: 'network_error',
          message:
              'Could not reach PhysioAI. Check your connection and try again.',
        );
      await pumpApp(
        tester,
        auth: FakeAuthRepository(saved: newPatient()),
        consent: consent,
      );

      await tester.tap(find.byKey(const Key('advisory-checkbox')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('advisory-continue')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('advisory-error')), findsOneWidget);
      expect(find.text('Before your first session'), findsOneWidget);
      expect(find.text('My Exercise Plan'), findsNothing);
    },
  );

  testWidgets('an advisory acknowledged on another device is not asked again', (
    tester,
  ) async {
    final consent = FakeConsentRepository()
      ..acknowledgedAt = DateTime(2026, 10, 1, 9);
    await pumpApp(
      tester,
      // This device's saved session still says "not acknowledged".
      auth: FakeAuthRepository(saved: newPatient()),
      consent: consent,
    );

    expect(find.byKey(const Key('linked-physio')), findsOneWidget);
    expect(consent.acknowledgedVersions, isEmpty);
  });

  testWidgets('logging out is the only other way off the advisory', (
    tester,
  ) async {
    final auth = await pumpApp(
      tester,
      auth: FakeAuthRepository(saved: newPatient()),
    );

    await tester.tap(find.byKey(const Key('advisory-sign-out')));
    await tester.pumpAndSettle();

    expect(auth.signOuts, 1);
    expect(find.text('Choose your role'), findsOneWidget);
  });

  testWidgets(
    'Help shows the same advisory text and when it was acknowledged',
    (tester) async {
      final consent = FakeConsentRepository()
        ..acknowledgedAt = DateTime(2026, 10, 8, 18, 30);
      await pumpApp(
        tester,
        auth: FakeAuthRepository(saved: user(UserRole.patient, 'Jane Cooper')),
        consent: consent,
      );

      await tester.tap(find.text('Help'));
      await tester.pumpAndSettle();

      expect(find.text('Before your first session'), findsOneWidget);
      expect(find.text('It does not diagnose.'), findsOneWidget);
      expect(
        find.text(FakeConsentRepository.disclaimer.caution),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(Pill, 'You acknowledged this on 8 Oct 2026, 18:30'),
        findsOneWidget,
      );
      // Reading it again asks for nothing.
      expect(find.byKey(const Key('advisory-checkbox')), findsNothing);
      expect(find.byKey(const Key('advisory-continue')), findsNothing);
    },
  );

  testWidgets('physiotherapists go straight to their dashboard', (
    tester,
  ) async {
    await pumpApp(
      tester,
      auth: FakeAuthRepository(
        saved: user(UserRole.physiotherapist, 'Dr. Sarah Malik'),
      ),
    );

    expect(find.text('Invite a patient'), findsOneWidget);
    expect(find.text('Before your first session'), findsNothing);
    expect(find.text('Help'), findsNothing);
  });
}
