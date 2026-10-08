// US 7.3 user and role management and the audited role change of US 1.3, as
// the admin uses them.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:physioai/core/api/api_exception.dart';
import 'package:physioai/core/widgets/common.dart';
import 'package:physioai/features/admin/admin_repository.dart';
import 'package:physioai/features/admin/user_management_repository.dart';
import 'package:physioai/features/auth/auth_models.dart';

import 'auth_flow_test.dart';

/// "id-admin" is the account [user] signs in as: the admin's own row.
List<ManagedUser> people() => [
  managed(
    'id-admin',
    'Alex Morgan',
    UserRole.admin,
    lastSeen: DateTime(2026, 10, 9, 9),
  ),
  managed('sarah', 'Dr. Sarah Malik', UserRole.physiotherapist, patients: 2),
  managed(
    'omar',
    'Dr. Omar Farooq',
    UserRole.physiotherapist,
    temporaryPassword: true,
  ),
  managed('left', 'Dr. Hina Raza', UserRole.physiotherapist, active: false),
  managed(
    'jane',
    'Jane Cooper',
    UserRole.patient,
    physiotherapistId: 'sarah',
    physiotherapist: 'Dr. Sarah Malik',
  ),
  managed(
    'marcus',
    'Marcus Johnson',
    UserRole.patient,
    physiotherapistId: 'sarah',
    physiotherapist: 'Dr. Sarah Malik',
    active: false,
  ),
];

Future<FakeUserManagementRepository> openUsers(
  WidgetTester tester, {
  FakeUserManagementRepository? users,
}) async {
  final repository = users ?? FakeUserManagementRepository(people());
  await pumpApp(
    tester,
    auth: FakeAuthRepository(saved: user(UserRole.admin, 'Alex Morgan')),
    users: repository,
  );
  await tester.tap(find.text('Users & Roles'));
  await tester.pumpAndSettle();
  return repository;
}

Future<void> openMenu(WidgetTester tester, String id) =>
    tapKey(tester, 'user-menu-$id');

Future<void> act(WidgetTester tester, String id, String action) async {
  await openMenu(tester, id);
  await tester.tap(find.byKey(Key('action-$action')));
  await tester.pumpAndSettle();
}

/// Picks [label] in the dropdown with [key].
Future<void> choose(WidgetTester tester, String key, String label) async {
  await tapKey(tester, key);
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

/// A physiotherapist offered by the dropdown that is open.
Finder option(String name) =>
    find.widgetWithText(DropdownMenuItem<String>, name);

Finder row(String id) => find.byKey(Key('user-row-$id'));

Finder inRow(String id, String text) =>
    find.descendant(of: row(id), matching: find.text(text));

String count(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('user-count'))).data!;

const refused = ApiException(
  code: 'has_active_patients',
  message:
      'This physiotherapist is responsible for 2 active patients. '
      'Reassign them before you deactivate this account.',
  statusCode: 409,
);

void main() {
  testWidgets('lists every account with its role, status and what matters', (
    tester,
  ) async {
    await openUsers(tester);

    expect(count(tester), '6 users');
    expect(inRow('id-admin', 'You'), findsOneWidget);
    expect(inRow('id-admin', 'Last active 9 Oct 2026, 09:00'), findsOneWidget);
    expect(
      inRow('sarah', '2 active patients  ·  Has not signed in yet'),
      findsOneWidget,
    );
    expect(inRow('omar', 'Temporary password'), findsOneWidget);
    expect(inRow('left', 'Deactivated'), findsOneWidget);
    expect(
      inRow(
        'jane',
        'Physiotherapist: Dr. Sarah Malik  ·  Has not signed in yet',
      ),
      findsOneWidget,
    );
    expect(inRow('jane', 'jane@example.test'), findsOneWidget);
    expect(inRow('marcus', 'Deactivated'), findsOneWidget);
    expect(
      find.descendant(
        of: row('jane'),
        matching: find.widgetWithText(Pill, 'Patient'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('search and filters narrow the list, and can be cleared', (
    tester,
  ) async {
    await openUsers(tester);

    // Matches a name or contact, not text that merely appears on a row.
    await fill(tester, 'user-search', 'sarah');
    expect(count(tester), '1 of 6 users');
    expect(row('sarah'), findsOneWidget);
    expect(row('jane'), findsNothing);

    await fill(tester, 'user-search', '');
    await choose(tester, 'user-role-filter', 'Patients');
    expect(count(tester), '2 of 6 users');
    await choose(tester, 'user-status-filter', 'Deactivated');
    expect(count(tester), '1 of 6 users');
    expect(row('marcus'), findsOneWidget);

    await fill(tester, 'user-search', 'nobody');
    expect(find.text('No users match these filters.'), findsOneWidget);
    await tapKey(tester, 'clear-user-filters');
    expect(count(tester), '6 users');
  });

  testWidgets('adding a physiotherapist shows the temporary password once', (
    tester,
  ) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final users = await openUsers(tester);

    await tapKey(tester, 'add-user');
    await fill(tester, 'new-user-name', 'Dr. Ayesha Khan');
    await fill(tester, 'new-user-identifier', 'ayesha@clinic.test');
    await tapKey(tester, 'dialog-submit');

    expect(users.calls, [
      'create Dr. Ayesha Khan ayesha@clinic.test physiotherapist null',
    ]);
    expect(find.text('Account created'), findsOneWidget);
    expect(find.text('Temp-4821-Kite'), findsOneWidget);
    expect(
      find.textContaining('the only time the password is shown'),
      findsOneWidget,
    );
    await tapKey(tester, 'copy-password');
    expect(copied, ['Temp-4821-Kite']);
    expect(find.text('Copied'), findsOneWidget);

    await tapKey(tester, 'password-dialog-done');
    expect(find.text('Temp-4821-Kite'), findsNothing);
    expect(count(tester), '7 users');
    expect(inRow('new-6', 'Temporary password'), findsOneWidget);
  });

  testWidgets('a new patient is always given a physiotherapist', (
    tester,
  ) async {
    final users = await openUsers(tester);

    await tapKey(tester, 'add-user');
    expect(find.byKey(const Key('new-user-physio')), findsNothing);
    await choose(tester, 'new-user-role', 'Patient');
    await fill(tester, 'new-user-name', 'Bilal Ahmed');
    await fill(tester, 'new-user-identifier', '0300 1234567');
    await tapKey(tester, 'dialog-submit');
    expect(find.text('Choose a physiotherapist.'), findsOneWidget);
    expect(users.calls, isEmpty);

    // Only physiotherapists who can still sign in are offered.
    await tapKey(tester, 'new-user-physio');
    expect(option('Dr. Sarah Malik'), findsOneWidget);
    expect(option('Dr. Hina Raza'), findsNothing);
    await tester.tap(find.text('Dr. Omar Farooq').last);
    await tester.pumpAndSettle();
    await tapKey(tester, 'dialog-submit');

    expect(users.calls, ['create Bilal Ahmed 0300 1234567 patient omar']);
    await tapKey(tester, 'password-dialog-done');
    expect(
      inRow(
        'new-6',
        'Physiotherapist: Dr. Omar Farooq  ·  Has not signed in yet',
      ),
      findsOneWidget,
    );
  });

  testWidgets('incomplete details are caught before anything is sent', (
    tester,
  ) async {
    final users = await openUsers(tester);
    await tapKey(tester, 'add-user');

    await tapKey(tester, 'dialog-submit');
    expect(find.text("Enter the person's full name."), findsOneWidget);
    expect(
      find.text('Enter an email address or mobile number.'),
      findsOneWidget,
    );

    await fill(tester, 'new-user-name', 'Dr. Ayesha Khan');
    await fill(tester, 'new-user-identifier', 'ayesha-at-clinic');
    await tapKey(tester, 'dialog-submit');
    expect(
      find.text('Enter a valid email address or mobile number.'),
      findsOneWidget,
    );
    expect(users.calls, isEmpty);
  });

  testWidgets('a refusal from the server stays in the dialog', (tester) async {
    final users = await openUsers(tester);
    users.failure = const ApiException(
      code: 'identifier_taken',
      message:
          'Another account already uses this email address or mobile number.',
      statusCode: 409,
    );

    await tapKey(tester, 'add-user');
    await fill(tester, 'new-user-name', 'Second Sarah');
    await fill(tester, 'new-user-identifier', 'sarah@example.test');
    await tapKey(tester, 'dialog-submit');

    expect(find.byKey(const Key('dialog-error')), findsOneWidget);
    expect(find.textContaining('Another account already uses'), findsOneWidget);
    expect(find.text('Add user'), findsWidgets); // the dialog is still open
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(count(tester), '6 users');
  });

  testWidgets('deactivating asks first and explains what happens', (
    tester,
  ) async {
    final users = await openUsers(tester);

    await act(tester, 'jane', 'deactivate');
    expect(find.text('Deactivate Jane Cooper?'), findsOneWidget);
    expect(find.textContaining('Their records are kept'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(users.calls, isEmpty);

    await act(tester, 'jane', 'deactivate');
    await tapKey(tester, 'dialog-submit');

    expect(users.calls, ['deactivate jane']);
    expect(inRow('jane', 'Deactivated'), findsOneWidget);
    expect(find.text('Jane Cooper was deactivated.'), findsOneWidget);
    // The same menu now offers the way back.
    await openMenu(tester, 'jane');
    expect(find.byKey(const Key('action-activate')), findsOneWidget);
    expect(find.byKey(const Key('action-deactivate')), findsNothing);
  });

  testWidgets('a physiotherapist with patients cannot be deactivated yet', (
    tester,
  ) async {
    final users = await openUsers(tester);
    users.failure = refused;

    await act(tester, 'sarah', 'deactivate');
    await tapKey(tester, 'dialog-submit');

    expect(find.byKey(const Key('dialog-error')), findsOneWidget);
    expect(find.textContaining('Reassign them before'), findsOneWidget);
    expect(find.text('Deactivate Dr. Sarah Malik?'), findsOneWidget);
  });

  testWidgets('a deactivated account can be reactivated', (tester) async {
    final users = await openUsers(tester);

    await act(tester, 'marcus', 'activate');
    expect(find.text('Reactivate Marcus Johnson?'), findsOneWidget);
    await tapKey(tester, 'dialog-submit');

    expect(users.calls, ['activate marcus']);
    expect(inRow('marcus', 'Deactivated'), findsNothing);
    expect(find.text('Marcus Johnson was reactivated.'), findsOneWidget);
  });

  testWidgets('a patient is reassigned to another active physiotherapist', (
    tester,
  ) async {
    final users = await openUsers(tester);

    await act(tester, 'jane', 'reassign');
    expect(find.text('Reassign Jane Cooper'), findsOneWidget);
    expect(
      find.textContaining('Dr. Sarah Malik loses access at once'),
      findsOneWidget,
    );
    await tapKey(tester, 'dialog-submit');
    expect(find.text('Choose a physiotherapist.'), findsOneWidget);

    // Not her current physiotherapist, and nobody who is deactivated.
    await tapKey(tester, 'reassign-physio');
    expect(option('Dr. Omar Farooq'), findsOneWidget);
    expect(option('Dr. Hina Raza'), findsNothing);
    expect(option('Dr. Sarah Malik'), findsNothing);
    await tester.tap(find.text('Dr. Omar Farooq').last);
    await tester.pumpAndSettle();
    await tapKey(tester, 'dialog-submit');

    expect(users.calls, ['reassign jane omar']);
    expect(
      inRow(
        'jane',
        'Physiotherapist: Dr. Omar Farooq  ·  Has not signed in yet',
      ),
      findsOneWidget,
    );
    expect(
      find.text('Jane Cooper is now with Dr. Omar Farooq.'),
      findsOneWidget,
    );
  });

  testWidgets('a staff role is changed between Physiotherapist and Admin', (
    tester,
  ) async {
    final users = await openUsers(tester);

    await act(tester, 'omar', 'role');
    expect(find.text('Change role of Dr. Omar Farooq'), findsOneWidget);
    expect(find.text('Currently Physiotherapist.'), findsOneWidget);
    expect(find.textContaining('signed out everywhere'), findsOneWidget);
    await tapKey(tester, 'dialog-submit');

    expect(users.calls, ['role omar admin']);
    expect(
      find.descendant(
        of: row('omar'),
        matching: find.widgetWithText(Pill, 'Admin'),
      ),
      findsOneWidget,
    );
    expect(find.text('Dr. Omar Farooq is now Admin.'), findsOneWidget);
  });

  testWidgets('each account only offers the actions that apply to it', (
    tester,
  ) async {
    await openUsers(tester);

    Future<Set<String>> offered(String id) async {
      await openMenu(tester, id);
      final found = {
        for (final action in [
          'edit',
          'reassign',
          'role',
          'reset',
          'deactivate',
          'activate',
        ])
          if (find.byKey(Key('action-$action')).evaluate().isNotEmpty) action,
      };
      await tester.tapAt(const Offset(5, 5)); // close the menu
      await tester.pumpAndSettle();
      return found;
    }

    // An admin never changes their own access.
    expect(await offered('id-admin'), {'edit'});
    expect(await offered('sarah'), {'edit', 'role', 'reset', 'deactivate'});
    expect(await offered('left'), {'edit', 'role', 'reset', 'activate'});
    // A patient is reassigned, never turned into staff.
    expect(await offered('jane'), {'edit', 'reassign', 'reset', 'deactivate'});
  });

  testWidgets('resetting a password issues a new temporary one', (
    tester,
  ) async {
    final users = await openUsers(tester);

    await act(tester, 'jane', 'reset');
    expect(find.text('Reset the password of Jane Cooper?'), findsOneWidget);
    await tapKey(tester, 'dialog-submit');

    expect(users.calls, ['reset jane']);
    expect(find.text('Temporary password issued'), findsOneWidget);
    expect(find.text('Temp-7733-Reed'), findsOneWidget);
    expect(
      find.textContaining('They sign in with jane@example.test'),
      findsOneWidget,
    );
    await tapKey(tester, 'password-dialog-done');
    expect(inRow('jane', 'Temporary password'), findsOneWidget);
  });

  testWidgets('details are corrected, and an account keeps a way to sign in', (
    tester,
  ) async {
    final users = await openUsers(tester);

    await act(tester, 'jane', 'edit');
    await fill(tester, 'edit-email', '');
    await tapKey(tester, 'dialog-submit');
    expect(
      find.text('Enter an email address or a mobile number.'),
      findsNWidgets(2),
    );
    await fill(tester, 'edit-email', 'jane.cooper');
    await tapKey(tester, 'dialog-submit');
    expect(find.text('Enter a valid email address.'), findsOneWidget);
    expect(users.calls, isEmpty);

    await fill(tester, 'edit-name', 'Jane A. Cooper');
    await fill(tester, 'edit-email', 'jane.cooper@example.test');
    await tapKey(tester, 'dialog-submit');

    expect(users.calls, [
      'update jane Jane A. Cooper jane.cooper@example.test ',
    ]);
    expect(inRow('jane', 'Jane A. Cooper'), findsOneWidget);
    expect(find.text("Jane A. Cooper's details were saved."), findsOneWidget);
  });

  testWidgets('the overview counts come from the same list', (tester) async {
    await pumpApp(
      tester,
      auth: FakeAuthRepository(saved: user(UserRole.admin, 'Alex Morgan')),
      users: FakeUserManagementRepository(people()),
    );

    String stat(String label) => tester
        .widget<Text>(
          find
              .descendant(
                of: find.ancestor(
                  of: find.text(label),
                  matching: find.byType(AppCard),
                ),
                matching: find.byType(Text),
              )
              .first,
        )
        .data!;

    expect(stat('Total users'), '6');
    expect(stat('Patients'), '2');
    expect(stat('Physiotherapists'), '3');
    expect(stat('Admins'), '1');
  });

  group('Audit log', () {
    AuditEntry entry(String action, [Map<String, dynamic> detail = const {}]) =>
        AuditEntry(
          id: action.hashCode,
          action: action,
          createdAt: DateTime(2026, 10, 9, 10),
          detail: detail,
        );

    test('every recorded action is described in plain words', () {
      expect(
        entry('account.role_changed', {
          'from': 'physiotherapist',
          'to': 'admin',
        }).description,
        'An admin changed a role from Physiotherapist to Admin',
      );
      expect(
        entry('account.created', {'role': 'patient'}).description,
        'An admin created a patient account',
      );
      expect(
        entry('account.deactivated', {'role': 'physiotherapist'}).description,
        'An admin deactivated a physiotherapist account',
      );
      for (final action in [
        'account.registered',
        'account.updated',
        'account.activated',
        'account.password_reset',
        'account.password_changed',
        'patient.reassigned',
        'invite_code.created',
        'consent.acknowledged',
        'plan.assigned',
        'exercise_template.created',
        'exercise_template.updated',
        'exercise_template.activated',
        'exercise_template.deactivated',
        'auth.lockout',
        'auth.session_revoked',
        'auth.refresh_token_reuse',
      ]) {
        expect(entry(action).description, isNot(action), reason: action);
      }
      // Something recorded by a newer server still shows, as its raw name.
      expect(entry('future.thing').description, 'future.thing');
    });

    testWidgets('is shown newest first with a description of each entry', (
      tester,
    ) async {
      await pumpApp(
        tester,
        auth: FakeAuthRepository(saved: user(UserRole.admin, 'Alex Morgan')),
        admin: FakeAdminRepository([
          entry('patient.reassigned'),
          entry('account.role_changed', {
            'from': 'physiotherapist',
            'to': 'admin',
          }),
        ]),
      );
      await tester.tap(find.text('Audit Log'));
      await tester.pumpAndSettle();

      expect(
        find.text('An admin moved a patient to another physiotherapist'),
        findsOneWidget,
      );
      expect(
        find.text('An admin changed a role from Physiotherapist to Admin'),
        findsOneWidget,
      );
      expect(find.text('9 Oct 2026, 10:00'), findsNWidgets(2));
    });
  });
}
