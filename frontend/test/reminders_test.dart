// US 6.1 and 6.2: the prescribed days of a plan, the patient's reminder,
// and desktop alerts for what arrives while the app is open.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:physioai/core/alerts/desktop_alerts.dart';
import 'package:physioai/core/api/api_client.dart';
import 'package:physioai/core/api/api_exception.dart';
import 'package:physioai/core/api/token_store.dart';
import 'package:physioai/features/auth/auth_models.dart';
import 'package:physioai/features/exercises/exercise_models.dart';
import 'package:physioai/features/patient/patient_repository.dart';
import 'package:physioai/features/patient/reminders.dart';
import 'package:physioai/features/physio/physio_repository.dart';

import 'auth_flow_test.dart';
import 'notifications_test.dart' hide main;
import 'plans_test.dart' hide main;

/// The device's alerts, as the test decides they behave.
class FakeAlerts implements DesktopAlerts {
  FakeAlerts([this.permission = AlertPermission.granted]);

  @override
  AlertPermission permission;

  /// What the person answers when asked.
  AlertPermission answer = AlertPermission.granted;
  int asked = 0;
  final shown = <({String id, String title, String body, String? link})>[];
  void Function(String? link)? _open;

  @override
  Future<AlertPermission> request() async {
    asked++;
    return permission = answer;
  }

  @override
  void show({
    required String id,
    required String title,
    required String body,
    String? link,
  }) {
    if (permission == AlertPermission.granted) {
      shown.add((id: id, title: title, body: body, link: link));
    }
  }

  @override
  set onOpen(void Function(String? link)? handler) => _open = handler;

  /// The person clicks an alert.
  void click(String? link) => _open?.call(link);
}

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

Future<FakePatientRepository> openPlan(
  WidgetTester tester, {
  List<int> days = const [0, 2, 4],
  ReminderSettings? settings,
}) async {
  final base = plan('Knee plan', [squats]);
  final patient = FakePatientRepository()
    ..plan = ExercisePlan(
      id: base.id,
      name: base.name,
      createdAt: base.createdAt,
      isActive: true,
      assignedBy: base.assignedBy,
      items: base.items,
      days: days,
    )
    ..reminderSettings =
        settings ??
        const ReminderSettings(
          enabled: true,
          time: '18:00',
          utcOffsetMinutes: 300,
        );
  await pumpApp(
    tester,
    auth: FakeAuthRepository(saved: user(UserRole.patient, 'Jane Cooper')),
    patient: patient,
  );
  await tester.tap(find.text('My Exercise Plan').first);
  await tester.pumpAndSettle();
  return patient;
}

void main() {
  group('The prescribed days', () {
    test('are said the way a person would', () {
      expect(describeDays([0, 1, 2, 3, 4, 5, 6]), 'Every day');
      expect(describeDays([4, 0, 2]), 'Mon, Wed and Fri');
      expect(describeDays([5, 6]), 'Sat and Sun');
      expect(describeDays([3]), 'Thu');
      expect(describeDays([]), 'No days set');
    });

    test('a plan from an older server is daily', () {
      final read = ExercisePlan.fromJson(const {
        'id': 'plan-1',
        'name': 'Week 1',
        'created_at': '2026-10-01T09:00:00Z',
        'archived_at': null,
        'is_active': true,
        'assigned_by': {'id': 'physio-1', 'full_name': 'Dr. Sarah Malik'},
        'items': <Object>[],
      });
      expect(read.days, [0, 1, 2, 3, 4, 5, 6]);
    });

    test('are sent with the plan and read back', () async {
      late Map<String, dynamic> sent;
      final repository = PhysioRepository(
        await _api((request) async {
          sent = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({
              'id': 'plan-1',
              'name': 'Week 1',
              'created_at': '2026-10-01T09:00:00Z',
              'archived_at': null,
              'is_active': true,
              'assigned_by': {'id': 'physio-1', 'full_name': 'Dr. Sarah Malik'},
              'days': [0, 2, 4],
              'items': <Object>[],
            }),
            201,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final assigned = await repository.assignPlan(
        patientId: 'patient-jane',
        name: 'Week 1',
        items: [PlanItemDraft(squats)],
        days: [0, 2, 4],
      );

      expect(sent['days'], [0, 2, 4]);
      expect(assigned.days, [0, 2, 4]);
    });

    testWidgets('are chosen in the Plan Builder, every day to begin with', (
      tester,
    ) async {
      final physio = await openPlanBuilder(tester);
      await choosePatient(tester, 'Jane Cooper');
      await tapKey(tester, 'add-exercise-ex-squats');

      // Weekdays only.
      await tapKey(tester, 'plan-day-5');
      await tapKey(tester, 'plan-day-6');
      await tapKey(tester, 'assign-plan');

      expect(physio.assignedDays.single, [0, 1, 2, 3, 4]);

      // The next plan starts from every day again.
      await tapKey(tester, 'add-exercise-ex-squats');
      await tapKey(tester, 'assign-plan');
      expect(physio.assignedDays.last, [0, 1, 2, 3, 4, 5, 6]);
    });

    testWidgets('a plan always keeps at least one day', (tester) async {
      final physio = await openPlanBuilder(tester);
      await choosePatient(tester, 'Jane Cooper');
      await tapKey(tester, 'add-exercise-ex-squats');

      for (var day = 0; day <= 6; day++) {
        await tapKey(tester, 'plan-day-$day');
      }
      await tapKey(tester, 'assign-plan');

      // Sunday was the last one left, and it stayed.
      expect(physio.assignedDays.single, [6]);
    });
  });

  group('Reminder settings', () {
    test('are read, and only what is given is sent', () async {
      final seen = <http.Request>[];
      final repository = PatientRepository(
        await _api((request) async {
          seen.add(request);
          return _json({
            'enabled': true,
            'time': '07:30',
            'utc_offset_minutes': 300,
            'days': [0, 2, 4],
          });
        }),
      );

      final read = await repository.reminders();
      await repository.saveReminders(time: '07:30');
      await repository.saveReminders(enabled: false, utcOffsetMinutes: 300);

      expect(seen[0].method, 'GET');
      expect(seen[0].url.path, '/api/v1/patient/reminders');
      expect(
        (read.enabled, read.time, read.utcOffsetMinutes),
        (true, '07:30', 300),
      );
      expect(read.days, [0, 2, 4]);
      expect(seen[1].method, 'PUT');
      expect(jsonDecode(seen[1].body), {'time': '07:30'});
      expect(jsonDecode(seen[2].body), {
        'enabled': false,
        'utc_offset_minutes': 300,
      });
    });

    testWidgets('the plan page shows the days and the reminder', (
      tester,
    ) async {
      final patient = await openPlan(tester);

      expect(
        tester.widget<Text>(find.byKey(const Key('plan-days'))).data,
        'Mon, Wed and Fri',
      );
      expect(
        tester.widget<Switch>(find.byKey(const Key('reminder-enabled'))).value,
        isTrue,
      );
      expect(find.text('18:00'), findsOneWidget);
      // The server already has this device's clock: nothing is sent.
      expect(patient.reminderSaves, isEmpty);
    });

    testWidgets('the app tells the server its clock when the server lacks it', (
      tester,
    ) async {
      final patient = await openPlan(
        tester,
        settings: const ReminderSettings(enabled: true, time: '18:00'),
      );

      // Once, and only the clock: the patient's choices are left alone.
      expect(patient.reminderSaves, [
        (enabled: null, time: null, utcOffsetMinutes: 300),
      ]);
      expect(patient.reminderSettings.utcOffsetMinutes, 300);
    });

    testWidgets('a clock that has changed is reported again', (tester) async {
      final patient = await openPlan(
        tester,
        settings: const ReminderSettings(
          enabled: true,
          time: '18:00',
          utcOffsetMinutes: 0,
        ),
      );

      expect(patient.reminderSaves.single.utcOffsetMinutes, 300);
    });

    testWidgets('reminders can be switched off and on', (tester) async {
      final patient = await openPlan(tester);

      await tapKey(tester, 'reminder-enabled');

      expect(patient.reminderSaves.single.enabled, isFalse);
      expect(find.text('Reminders are off'), findsOneWidget);
      expect(find.byKey(const Key('reminder-time')), findsNothing);

      await tapKey(tester, 'reminder-enabled');
      expect(patient.reminderSaves.last.enabled, isTrue);
      expect(find.byKey(const Key('reminder-time')), findsOneWidget);
    });

    testWidgets('the time can be changed', (tester) async {
      final patient = await openPlan(tester);

      await tapKey(tester, 'reminder-time');
      // The list opens at the time chosen now; the next one down is in view.
      await tester.tap(find.text('18:30').last);
      await tester.pumpAndSettle();

      expect(patient.reminderSaves.single.time, '18:30');
      expect(patient.reminderSettings.time, '18:30');
    });

    testWidgets('a failure to save says so and changes nothing', (
      tester,
    ) async {
      final patient = await openPlan(tester);
      patient.reminderFailure = ApiException.network;

      await tapKey(tester, 'reminder-enabled');

      expect(find.byKey(const Key('reminder-error')), findsOneWidget);
      expect(
        tester.widget<Switch>(find.byKey(const Key('reminder-enabled'))).value,
        isTrue,
      );
    });
  });

  group('Desktop alerts', () {
    testWidgets('something new and unread is shown by the device, once', (
      tester,
    ) async {
      final alerts = FakeAlerts();
      final notifications = FakeNotificationsRepository([
        notice('old', read: true),
        notice('waiting'),
      ]);
      await pumpApp(
        tester,
        auth: FakeAuthRepository(saved: patient()),
        notifications: notifications,
        alerts: alerts,
      );
      // What was already there when the app opened is not news.
      expect(alerts.shown, isEmpty);

      notifications.items = [
        notice(
          'reminder',
          kind: 'session_reminder',
          title: 'Time for your exercises',
          body: 'Squats is next.',
          link: '/patient/session/item-0',
        ),
        ...notifications.items,
      ];
      await tester.pump(const Duration(seconds: 61));
      await tester.pumpAndSettle();

      expect(alerts.shown, [
        (
          id: 'reminder',
          title: 'Time for your exercises',
          body: 'Squats is next.',
          link: '/patient/session/item-0',
        ),
      ]);

      // The next check brings nothing new: nothing is shown again.
      await tester.pump(const Duration(seconds: 61));
      await tester.pumpAndSettle();
      expect(alerts.shown, hasLength(1));
    });

    testWidgets('clicking an alert opens what it is about', (tester) async {
      final alerts = FakeAlerts();
      await pumpApp(
        tester,
        auth: FakeAuthRepository(saved: patient()),
        patient: FakePatientRepository()..plan = plan('Knee plan', [squats]),
        alerts: alerts,
      );

      alerts.click('/patient/plan');
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('reminder-card')), findsOneWidget);
    });

    testWidgets('can be turned on from the notification list', (tester) async {
      final alerts = FakeAlerts(AlertPermission.undecided);
      await pumpApp(
        tester,
        auth: FakeAuthRepository(saved: patient()),
        alerts: alerts,
      );
      await openBell(tester);

      await tapKey(tester, 'enable-desktop-alerts');

      expect(alerts.asked, 1);
      expect(find.byKey(const Key('desktop-alerts-on')), findsOneWidget);
      expect(find.byKey(const Key('enable-desktop-alerts')), findsNothing);
    });

    testWidgets('a refusal is respected and explained', (tester) async {
      final alerts = FakeAlerts(AlertPermission.undecided)
        ..answer = AlertPermission.denied;
      final notifications = FakeNotificationsRepository();
      await pumpApp(
        tester,
        auth: FakeAuthRepository(saved: patient()),
        notifications: notifications,
        alerts: alerts,
      );
      await openBell(tester);
      await tapKey(tester, 'enable-desktop-alerts');

      expect(find.byKey(const Key('desktop-alerts-blocked')), findsOneWidget);

      // Nothing is shown by the device, but the list still has it.
      notifications.items = [notice('n1')];
      await tester.pump(const Duration(seconds: 61));
      await tester.pumpAndSettle();
      expect(alerts.shown, isEmpty);
      expect(find.text('You have a new exercise plan'), findsOneWidget);
    });

    testWidgets('where the device cannot show them, nothing is offered', (
      tester,
    ) async {
      await pumpApp(
        tester,
        auth: FakeAuthRepository(saved: patient()),
        alerts: FakeAlerts(AlertPermission.unsupported),
      );
      await openBell(tester);

      expect(find.byKey(const Key('enable-desktop-alerts')), findsNothing);
      expect(find.byKey(const Key('desktop-alerts-on')), findsNothing);
    });
  });
}
