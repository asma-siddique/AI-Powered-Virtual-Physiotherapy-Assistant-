// US 7.1 exercise template management and 7.2 active exercise control, as
// the admin uses them.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:physioai/core/api/api_exception.dart';
import 'package:physioai/core/widgets/common.dart';
import 'package:physioai/features/admin/admin_pages.dart';
import 'package:physioai/features/admin/exercise_library_repository.dart';
import 'package:physioai/features/auth/auth_models.dart';
import 'package:physioai/features/shell/page_widgets.dart';

import 'auth_flow_test.dart';

ExerciseTemplate template(
  String id,
  String name, {
  bool active = true,
  int version = 1,
}) => ExerciseTemplate(
  id: id,
  name: name,
  domain: 'Functional, whole-body rehabilitation',
  bodyArea: 'whole_body',
  primaryTargets: 'Quadriceps, glutes, core',
  targetJoints: const ['hip', 'knee', 'ankle'],
  movementPattern: 'The hips and knees bend to lower the body, then stand.',
  instructions: 'Bend your knees and push your hips back, then stand up.',
  checks: const [
    SeverityCheck(
      key: 'knee_valgus',
      label: 'Knee alignment',
      measure: 'Inward deviation of the knees',
      unit: 'degrees',
      info: 5,
      amber: 10,
      red: 15,
      correctiveMessage: 'Keep your knees in line with your toes.',
    ),
    SeverityCheck(
      key: 'depth',
      label: 'Depth',
      measure: 'Knee angle short of the target depth',
      unit: 'degrees',
      info: 10,
      amber: 25,
      correctiveMessage: 'Lower a little further if it is comfortable.',
    ),
  ],
  isActive: active,
  version: version,
  updatedAt: DateTime(2026, 10, 1),
);

Future<FakeExerciseLibraryRepository> openLibrary(
  WidgetTester tester, {
  FakeExerciseLibraryRepository? library,
}) async {
  final repository =
      library ??
      FakeExerciseLibraryRepository([
        template('squats', 'Squats', version: 2),
        template('wall-sit', 'Wall Sit', active: false),
      ]);
  await pumpApp(
    tester,
    auth: FakeAuthRepository(saved: user(UserRole.admin, 'Alex Morgan')),
    library: repository,
  );
  await tester.tap(find.text('Exercise Library'));
  await tester.pumpAndSettle();
  return repository;
}

bool isOn(WidgetTester tester, String id) =>
    tester.widget<Switch>(find.byKey(Key('exercise-toggle-$id'))).value;

void main() {
  testWidgets('the library lists every exercise with its state and version', (
    tester,
  ) async {
    await openLibrary(tester);

    expect(find.text('Squats'), findsOneWidget);
    expect(find.text('Wall Sit'), findsOneWidget);
    expect(find.widgetWithText(Pill, 'On'), findsOneWidget);
    expect(find.widgetWithText(Pill, 'Off'), findsOneWidget);
    expect(find.textContaining('2 checks  ·  version 2'), findsOneWidget);
    expect(isOn(tester, 'squats'), isTrue);
    expect(isOn(tester, 'wall-sit'), isFalse);
  });

  testWidgets('switching an exercise off asks first and explains the effect', (
    tester,
  ) async {
    final library = await openLibrary(tester);

    await tapKey(tester, 'exercise-toggle-squats');
    expect(find.text('Switch off Squats?'), findsOneWidget);
    expect(
      find.textContaining('no longer be able to add it to new plans'),
      findsOneWidget,
    );

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(library.toggled, isEmpty);
    expect(isOn(tester, 'squats'), isTrue);

    await tapKey(tester, 'exercise-toggle-squats');
    await tapKey(tester, 'confirm-switch-off');
    expect(library.toggled.single, (id: 'squats', active: false));
    expect(isOn(tester, 'squats'), isFalse);
  });

  testWidgets('switching an exercise on needs no confirmation', (tester) async {
    final library = await openLibrary(tester);

    await tapKey(tester, 'exercise-toggle-wall-sit');

    expect(find.textContaining('Switch off'), findsNothing);
    expect(library.toggled.single, (id: 'wall-sit', active: true));
    expect(isOn(tester, 'wall-sit'), isTrue);
  });

  testWidgets('a failed switch is reported and nothing changes', (
    tester,
  ) async {
    final library =
        FakeExerciseLibraryRepository([template('squats', 'Squats')])
          ..failure = const ApiException(
            code: 'network_error',
            message:
                'Could not reach PhysioAI. Check your connection and try again.',
          );
    await openLibrary(tester, library: library);

    await tapKey(tester, 'exercise-toggle-squats');
    await tapKey(tester, 'confirm-switch-off');

    expect(find.byKey(const Key('library-error')), findsOneWidget);
    expect(isOn(tester, 'squats'), isTrue);
  });

  testWidgets(
    'editing thresholds saves a new version and says when it applies',
    (tester) async {
      final library = await openLibrary(tester);
      await tapKey(tester, 'exercise-edit-squats');

      expect(find.text('Edit Squats'), findsOneWidget);
      expect(
        find.textContaining('Past sessions are never rescored'),
        findsOneWidget,
      );
      // Existing values are loaded, with RED left empty where it never applies.
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('check-0-red')))
            .controller!
            .text,
        '15',
      );
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('check-1-red')))
            .controller!
            .text,
        '',
      );

      await fill(tester, 'check-0-amber', '8');
      await fill(tester, 'check-0-red', '12');
      await tapKey(tester, 'save-exercise');

      final saved = library.updated.single;
      expect(saved.id, 'squats');
      final checks = saved.fields['checks'] as List;
      expect(checks[0]['key'], 'knee_valgus');
      expect(
        (checks[0]['info'], checks[0]['amber'], checks[0]['red']),
        (5.0, 8.0, 12.0),
      );
      expect(checks[1]['red'], isNull);
      // Back on the library, showing the new version.
      expect(find.textContaining('2 checks  ·  version 3'), findsOneWidget);
      expect(find.textContaining('Squats saved as version 3'), findsOneWidget);
    },
  );

  testWidgets('thresholds that do not increase are refused before saving', (
    tester,
  ) async {
    final library = await openLibrary(tester);
    await tapKey(tester, 'exercise-edit-squats');

    await fill(tester, 'check-0-amber', '4'); // below INFO (5)
    await tapKey(tester, 'save-exercise');

    expect(find.text('Must be above 5.'), findsOneWidget);
    expect(find.byKey(const Key('exercise-error')), findsOneWidget);
    expect(library.updated, isEmpty);

    await fill(tester, 'check-0-amber', '10');
    await fill(tester, 'check-0-red', '10'); // not above AMBER
    await tapKey(tester, 'save-exercise');

    expect(find.text('Must be above 10.'), findsOneWidget);
    expect(library.updated, isEmpty);
  });

  testWidgets('required profile fields are checked', (tester) async {
    final library = await openLibrary(tester);
    await tapKey(tester, 'exercise-edit-squats');

    await fill(tester, 'ex-name', '');
    await fill(tester, 'ex-joints', ' , ');
    await fill(tester, 'check-0-message', '');
    await tapKey(tester, 'save-exercise');

    expect(find.text('Enter the exercise name.'), findsOneWidget);
    expect(find.text('Name at least one joint.'), findsOneWidget);
    expect(
      find.text('Write the message the patient will see.'),
      findsOneWidget,
    );
    expect(library.updated, isEmpty);
  });

  testWidgets('a new exercise is added switched off', (tester) async {
    final library = await openLibrary(tester);
    await tapKey(tester, 'add-exercise');
    expect(
      find.textContaining('New exercises start switched off'),
      findsOneWidget,
    );

    await fill(tester, 'ex-name', 'Glute Bridge');
    await fill(tester, 'ex-domain', 'Hip and gluteal rehabilitation');
    await fill(tester, 'ex-targets', 'Glutes, hamstrings');
    await fill(tester, 'ex-joints', 'Hip, Knee');
    await fill(
      tester,
      'ex-movement',
      'Lying on the back, the hips lift until the body is in a straight line.',
    );
    await fill(
      tester,
      'ex-instructions',
      'Lie on your back with your knees bent and lift your hips.',
    );
    await fill(tester, 'check-0-label', 'Hip height');
    await fill(tester, 'check-0-measure', 'Hip angle short of a straight line');
    await fill(tester, 'check-0-info', '5');
    await fill(tester, 'check-0-amber', '15');
    await fill(tester, 'check-0-message', 'Lift your hips a little higher.');
    await tapKey(tester, 'save-exercise');

    final sent = library.created.single;
    expect(sent['name'], 'Glute Bridge');
    expect(sent['target_joints'], ['hip', 'knee']);
    final check = (sent['checks'] as List).single;
    expect(check['key'], 'hip_height');
    expect((check['info'], check['amber'], check['red']), (5.0, 15.0, null));
    expect(find.text('Glute Bridge'), findsOneWidget);
    expect(isOn(tester, 'new-1'), isFalse);
    expect(
      find.textContaining('switched off until you turn it on'),
      findsOneWidget,
    );
  });

  testWidgets('checks can be added and removed, but one must remain', (
    tester,
  ) async {
    final library = await openLibrary(tester);
    await tapKey(tester, 'exercise-edit-squats');

    await tapKey(tester, 'remove-check-1');
    expect(find.byKey(const Key('check-1-label')), findsNothing);
    expect(find.byKey(const Key('remove-check-0')), findsNothing);

    await tapKey(tester, 'add-check');
    await fill(
      tester,
      'check-1-label',
      'Knee alignment',
    ); // same name as check 1
    await fill(tester, 'check-1-measure', 'Something else');
    await fill(tester, 'check-1-info', '1');
    await fill(tester, 'check-1-amber', '2');
    await fill(tester, 'check-1-message', 'Adjust your position.');
    await tapKey(tester, 'save-exercise');

    expect(find.text('Give each check a different name.'), findsOneWidget);
    expect(library.updated, isEmpty);
  });

  testWidgets('the server refusing a save keeps the form and shows why', (
    tester,
  ) async {
    final library = await openLibrary(tester);
    await tapKey(tester, 'exercise-edit-squats');
    library.failure = const ApiException(
      code: 'exercise_exists',
      message: 'An exercise with this name already exists.',
      statusCode: 409,
    );

    await fill(tester, 'ex-name', 'Wall Sit');
    await tapKey(tester, 'save-exercise');

    expect(
      find.text('An exercise with this name already exists.'),
      findsOneWidget,
    );
    expect(find.text('Edit Squats'), findsOneWidget);
  });

  testWidgets('leaving the form without saving changes nothing', (
    tester,
  ) async {
    final library = await openLibrary(tester);
    await tapKey(tester, 'exercise-edit-squats');
    await fill(tester, 'check-0-amber', '8');

    await tester.ensureVisible(find.text('Cancel'));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(library.updated, isEmpty);
    expect(find.text('Wall Sit'), findsOneWidget);
    expect(find.textContaining('2 checks  ·  version 2'), findsOneWidget);
  });

  testWidgets(
    'a page opens at the top, however far the last one was scrolled',
    (tester) async {
      await openLibrary(tester);
      await tapKey(tester, 'exercise-edit-squats');
      await tester.ensureVisible(find.byKey(const Key('save-exercise')));
      await tester.pumpAndSettle();
      final form = Scrollable.of(
        tester.element(find.byKey(const Key('save-exercise'))),
      );
      expect(form.position.pixels, greaterThan(0));

      await tester.tap(find.text('Audit Log'));
      await tester.pumpAndSettle();

      expect(find.byType(AdminAuditLogPage), findsOneWidget);
      final page = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(ShellPageBody),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(page.position.pixels, 0);
    },
  );

  testWidgets('the library is an admin screen only', (tester) async {
    for (final role in [UserRole.physiotherapist, UserRole.patient]) {
      await pumpApp(
        tester,
        auth: FakeAuthRepository(saved: user(role, 'Someone Else')),
      );
      expect(find.text('Exercise Library'), findsNothing, reason: role.label);
    }
  });
}
