// In-app notifications: the bell, the list, and where a notification leads.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:physioai/core/api/api_exception.dart';
import 'package:physioai/features/auth/auth_models.dart';
import 'package:physioai/features/notifications/notifications_repository.dart';

import 'auth_flow_test.dart';
import 'plans_test.dart';

AppNotification notice(
  String id, {
  String kind = 'plan_assigned',
  String title = 'You have a new exercise plan',
  String body = 'Dr. Sarah Malik assigned you "Knee plan" with 2 exercises.',
  String? link = '/patient/plan',
  bool read = false,
}) => AppNotification(
  id: id,
  kind: kind,
  title: title,
  body: body,
  link: link,
  createdAt: DateTime(2026, 10, 8, 18, 30),
  readAt: read ? DateTime(2026, 10, 8, 18, 45) : null,
);

SessionUser patient() =>
    user(UserRole.patient, 'Jane Cooper', physiotherapist: 'Dr. Sarah Malik');

Future<void> openBell(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('notification-bell')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the bell shows how many notifications are unread', (
    tester,
  ) async {
    await pumpApp(
      tester,
      auth: FakeAuthRepository(saved: patient()),
      notifications: FakeNotificationsRepository([
        notice('n1'),
        notice('n2'),
        notice('n3', read: true),
      ]),
    );

    expect(
      tester.widget<Text>(find.byKey(const Key('notification-count'))).data,
      '2',
    );
    expect(find.byTooltip('2 unread notifications'), findsOneWidget);
  });

  testWidgets('with nothing unread the bell has no count', (tester) async {
    await pumpApp(
      tester,
      auth: FakeAuthRepository(saved: patient()),
      notifications: FakeNotificationsRepository([notice('n1', read: true)]),
    );

    expect(find.byKey(const Key('notification-count')), findsNothing);
    expect(find.byTooltip('Notifications'), findsOneWidget);
  });

  testWidgets('an empty list says so', (tester) async {
    await pumpApp(tester, auth: FakeAuthRepository(saved: patient()));

    await openBell(tester);

    expect(find.text('You have no notifications.'), findsOneWidget);
    expect(find.byKey(const Key('notifications-read-all')), findsNothing);
  });

  testWidgets('opening a plan notification marks it read and shows the plan', (
    tester,
  ) async {
    final notifications = FakeNotificationsRepository([notice('n1')]);
    await pumpApp(
      tester,
      auth: FakeAuthRepository(saved: patient()),
      notifications: notifications,
      patient: FakePatientRepository()
        ..plan = plan('Knee plan', [squats, lunge]),
    );
    await openBell(tester);
    expect(find.text('You have a new exercise plan'), findsOneWidget);

    await tester.tap(find.byKey(const Key('notification-n1')));
    await tester.pumpAndSettle();

    expect(notifications.items.single.isUnread, isFalse);
    // The dialog closed and the app is on My Exercise Plan.
    expect(find.text('Notifications'), findsNothing);
    expect(
      find.text('Assigned by Dr. Sarah Malik on 1 Oct 2026'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('notification-count')), findsNothing);
  });

  testWidgets('a notice with nowhere to go is marked read and stays open', (
    tester,
  ) async {
    final notifications = FakeNotificationsRepository([
      notice(
        'n1',
        kind: 'security_lockout',
        title: 'Sign-in to your account was paused',
        body:
            'Sign-in was paused for 15 minutes after 5 unsuccessful attempts.',
        link: null,
      ),
    ]);
    await pumpApp(
      tester,
      auth: FakeAuthRepository(saved: patient()),
      notifications: notifications,
    );
    await openBell(tester);

    await tester.tap(find.byKey(const Key('notification-n1')));
    await tester.pumpAndSettle();

    expect(notifications.items.single.isUnread, isFalse);
    expect(find.text('Sign-in to your account was paused'), findsOneWidget);
  });

  testWidgets('"Mark all as read" clears the count', (tester) async {
    final notifications = FakeNotificationsRepository([
      notice('n1'),
      notice('n2'),
    ]);
    await pumpApp(
      tester,
      auth: FakeAuthRepository(saved: patient()),
      notifications: notifications,
    );
    await openBell(tester);

    await tester.tap(find.byKey(const Key('notifications-read-all')));
    await tester.pumpAndSettle();

    expect(notifications.items.every((n) => !n.isUnread), isTrue);
    expect(find.byKey(const Key('notifications-read-all')), findsNothing);
    expect(find.byKey(const Key('notification-count')), findsNothing);
  });

  testWidgets('a failure while marking read is shown in the list', (
    tester,
  ) async {
    final notifications = FakeNotificationsRepository([notice('n1')])
      ..failure = const ApiException(
        code: 'network_error',
        message:
            'Could not reach PhysioAI. Check your connection and try again.',
      );
    await pumpApp(
      tester,
      auth: FakeAuthRepository(saved: patient()),
      notifications: notifications,
    );
    await openBell(tester);

    await tester.tap(find.byKey(const Key('notifications-read-all')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not reach PhysioAI'), findsOneWidget);
    expect(notifications.items.single.isUnread, isTrue);
  });

  testWidgets('every role has the bell', (tester) async {
    for (final role in UserRole.values) {
      await pumpApp(
        tester,
        auth: FakeAuthRepository(saved: user(role, 'Someone Signed In')),
      );
      expect(
        find.byKey(const Key('notification-bell')),
        findsOneWidget,
        reason: role.label,
      );
    }
  });

  testWidgets(
    'a plan notice arriving while the app is open refreshes the plan',
    (tester) async {
      final notifications = FakeNotificationsRepository();
      final patientData = FakePatientRepository();
      await pumpApp(
        tester,
        auth: FakeAuthRepository(saved: patient()),
        notifications: notifications,
        patient: patientData,
      );
      expect(
        find.textContaining('No exercises have been assigned yet.'),
        findsOneWidget,
      );

      // The physiotherapist assigns a plan; the app notices on its next check.
      patientData.plan = plan('Knee plan', [squats]);
      notifications.items = [notice('n1')];
      await tester.pump(const Duration(seconds: 61));
      await tester.pumpAndSettle();

      expect(find.text('You have 1 exercise in your plan.'), findsOneWidget);
      expect(find.byKey(const Key('notification-count')), findsOneWidget);
    },
  );
}
