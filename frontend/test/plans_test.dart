// US 2.1 plan creation and assignment, 2.3 library selection, and the
// patient's view of their plan.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:physioai/core/api/api_exception.dart';
import 'package:physioai/core/widgets/common.dart';
import 'package:physioai/features/auth/auth_models.dart';
import 'package:physioai/features/exercises/exercise_models.dart';
import 'package:physioai/features/physio/physio_repository.dart';

import 'auth_flow_test.dart';

const squats = ExerciseBrief(
  id: 'ex-squats',
  name: 'Squats',
  domain: 'Functional, whole-body rehabilitation',
  bodyArea: 'whole_body',
  primaryTargets: 'Quadriceps, glutes, core',
  targetJoints: ['hip', 'knee', 'ankle'],
  instructions: 'Bend your knees and push your hips back, then stand.',
);
const lunge = ExerciseBrief(
  id: 'ex-lunge',
  name: 'Leg Lunge',
  domain: 'Knee and functional rehabilitation',
  bodyArea: 'knee',
  primaryTargets: 'Quadriceps, hip stabilisers',
  targetJoints: ['hip', 'knee', 'ankle'],
  instructions: 'Step forward and lower until your front knee is bent.',
);
const retired = ExerciseBrief(
  id: 'ex-wall-sit',
  name: 'Wall Sit',
  domain: 'Knee rehabilitation',
  bodyArea: 'knee',
  primaryTargets: 'Quadriceps',
  targetJoints: ['knee'],
  instructions: 'Slide down a wall and hold.',
  isActive: false,
);

final jane = PatientSummary(
  id: 'patient-jane',
  fullName: 'Jane Cooper',
  email: 'jane@example.test',
  isActive: true,
  assignedAt: DateTime(2026, 9, 2),
);
final marcus = PatientSummary(
  id: 'patient-marcus',
  fullName: 'Marcus Johnson',
  email: 'marcus@example.test',
  isActive: true,
  assignedAt: DateTime(2026, 9, 20),
);

ExercisePlan plan(
  String name,
  List<ExerciseBrief> exercises, {
  bool active = true,
}) => ExercisePlan(
  id: 'plan-$name',
  name: name,
  createdAt: DateTime(2026, 10, 1),
  archivedAt: active ? null : DateTime(2026, 10, 5),
  isActive: active,
  assignedBy: const PersonRef(id: 'physio-1', fullName: 'Dr. Sarah Malik'),
  items: [
    for (var i = 0; i < exercises.length; i++)
      PlanItem(
        id: 'item-$i',
        position: i + 1,
        exercise: exercises[i],
        sets: 3,
        reps: 12,
        restSeconds: 60,
        difficulty: Difficulty.medium,
        note: i == 0 ? 'Go slowly.' : null,
      ),
  ],
  hasInactiveExercise: exercises.any((exercise) => !exercise.isActive),
);

FakePhysioRepository physioWithLibrary() => FakePhysioRepository()
  ..roster.addAll([jane, marcus])
  ..exercises.addAll([lunge, squats, retired]);

Future<FakePhysioRepository> openPlanBuilder(
  WidgetTester tester, {
  FakePhysioRepository? physio,
}) async {
  final repository = physio ?? physioWithLibrary();
  await pumpApp(
    tester,
    auth: FakeAuthRepository(
      saved: user(UserRole.physiotherapist, 'Dr. Sarah Malik'),
    ),
    physio: repository,
  );
  await tester.tap(find.text('Plan Builder'));
  await tester.pumpAndSettle();
  return repository;
}

Future<void> choosePatient(WidgetTester tester, String name) async {
  await tester.tap(find.byKey(const Key('plan-patient')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(name).last);
  await tester.pumpAndSettle();
}

bool assignEnabled(WidgetTester tester) =>
    tester
        .widget<FilledButton>(
          find.descendant(
            of: find.byKey(const Key('assign-plan')),
            matching: find.byType(FilledButton),
          ),
        )
        .onPressed !=
    null;

void main() {
  testWidgets('the picker offers only active exercises, with their targets', (
    tester,
  ) async {
    await openPlanBuilder(tester);

    expect(find.text('Squats'), findsOneWidget);
    expect(find.text('Leg Lunge'), findsOneWidget);
    expect(find.text('Targets: Quadriceps, glutes, core'), findsOneWidget);
    expect(find.text(squats.instructions), findsOneWidget);
    expect(find.text('Wall Sit'), findsNothing);
    // Exercises are chosen here, never created or edited.
    for (final label in ['New exercise', 'Create exercise', 'Edit template']) {
      expect(find.text(label), findsNothing);
    }
  });

  testWidgets('a plan needs both a patient and at least one exercise', (
    tester,
  ) async {
    await openPlanBuilder(tester);
    expect(assignEnabled(tester), isFalse);

    await tapKey(tester, 'add-exercise-ex-squats');
    expect(assignEnabled(tester), isFalse);

    await choosePatient(tester, 'Jane Cooper');
    expect(assignEnabled(tester), isTrue);

    await tapKey(tester, 'remove-exercise-ex-squats');
    expect(assignEnabled(tester), isFalse);
  });

  testWidgets('building and assigning a plan sends the prescription as set', (
    tester,
  ) async {
    final physio = await openPlanBuilder(tester);
    await choosePatient(tester, 'Jane Cooper');
    await tester.enterText(
      find.byKey(const Key('plan-name')),
      'Knee rehabilitation plan',
    );

    await tapKey(tester, 'add-exercise-ex-squats');
    await tapKey(tester, 'add-exercise-ex-lunge');
    // Squats: 3 sets -> 2, 10 reps -> 12. Lunge keeps the defaults.
    await tapKey(tester, 'sets-ex-squats-minus');
    await tapKey(tester, 'reps-ex-squats-plus');
    await tapKey(tester, 'reps-ex-squats-plus');
    expect(
      tester.widget<Text>(find.byKey(const Key('sets-ex-squats-value'))).data,
      '2',
    );

    await tapKey(tester, 'assign-plan');

    final sent = physio.assigned.single;
    expect(sent.patientId, 'patient-jane');
    expect(sent.name, 'Knee rehabilitation plan');
    expect(sent.items, [
      {
        'exercise_id': 'ex-squats',
        'sets': 2,
        'reps': 12,
        'rest_seconds': 60,
        'difficulty': 'medium',
      },
      {
        'exercise_id': 'ex-lunge',
        'sets': 3,
        'reps': 10,
        'rest_seconds': 60,
        'difficulty': 'medium',
      },
    ]);
    expect(find.byKey(const Key('plan-success')), findsOneWidget);
    // The saved plan now shows in the patient's plans, marked current.
    expect(find.text('Knee rehabilitation plan'), findsOneWidget);
    expect(find.widgetWithText(Pill, 'Current'), findsOneWidget);
    expect(
      find.textContaining('1. Squats  ·  2 sets × 12 reps'),
      findsOneWidget,
    );
  });

  testWidgets('an exercise can be added to a plan only once', (tester) async {
    await openPlanBuilder(tester);

    await tapKey(tester, 'add-exercise-ex-squats');

    expect(find.byKey(const Key('add-exercise-ex-squats')), findsNothing);
    expect(find.widgetWithText(Pill, 'Added'), findsOneWidget);
  });

  testWidgets(
    'assigning again archives the earlier plan instead of losing it',
    (tester) async {
      final physio = physioWithLibrary()
        ..plansByPatient['patient-jane'] = [
          plan('Week 1', [squats]),
        ];
      await openPlanBuilder(tester, physio: physio);
      await choosePatient(tester, 'Jane Cooper');
      expect(find.text('Week 1'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('plan-name')), 'Week 2');
      await tapKey(tester, 'add-exercise-ex-lunge');
      await tapKey(tester, 'assign-plan');

      expect(find.text('Week 2'), findsOneWidget);
      expect(find.text('Week 1'), findsOneWidget);
      expect(find.widgetWithText(Pill, 'Current'), findsOneWidget);
      expect(find.widgetWithText(Pill, 'Archived'), findsOneWidget);
    },
  );

  testWidgets('a current plan with a switched-off exercise carries a warning', (
    tester,
  ) async {
    final physio = physioWithLibrary()
      ..plansByPatient['patient-jane'] = [
        plan('Knee plan', [squats, retired]),
      ];
    await openPlanBuilder(tester, physio: physio);

    await choosePatient(tester, 'Jane Cooper');

    expect(
      find.textContaining('No longer available: Wall Sit'),
      findsOneWidget,
    );
  });

  testWidgets('a refused plan stays on screen with the reason', (tester) async {
    final physio = physioWithLibrary()
      ..assignFailure = const ApiException(
        code: 'exercise_unavailable',
        message:
            'One or more of these exercises is no longer available. Refresh the list and choose again.',
        statusCode: 409,
      );
    await openPlanBuilder(tester, physio: physio);
    await choosePatient(tester, 'Jane Cooper');
    await tapKey(tester, 'add-exercise-ex-squats');

    await tapKey(tester, 'assign-plan');

    expect(find.byKey(const Key('plan-error')), findsOneWidget);
    expect(find.byKey(const Key('plan-success')), findsNothing);
    expect(find.byKey(const Key('remove-exercise-ex-squats')), findsOneWidget);
  });

  testWidgets('"Plan" on a patient opens the builder for that patient', (
    tester,
  ) async {
    await pumpApp(
      tester,
      auth: FakeAuthRepository(
        saved: user(UserRole.physiotherapist, 'Dr. Sarah Malik'),
      ),
      physio: physioWithLibrary(),
    );
    await tester.tap(find.text('Patients'));
    await tester.pumpAndSettle();

    await tapKey(tester, 'plan-for-patient-marcus');

    expect(find.text('Plan for Marcus Johnson'), findsOneWidget);
  });

  testWidgets('a patient sees their assigned exercises on Home and in full', (
    tester,
  ) async {
    await pumpApp(
      tester,
      auth: FakeAuthRepository(
        saved: user(
          UserRole.patient,
          'Jane Cooper',
          physiotherapist: 'Dr. Sarah Malik',
        ),
      ),
      patient: FakePatientRepository()
        ..plan = plan('Knee rehabilitation plan', [squats, lunge]),
    );

    expect(find.text('You have 2 exercises in your plan.'), findsOneWidget);
    expect(find.text('Squats'), findsOneWidget);
    expect(find.text('3 sets × 12 reps'), findsNWidgets(2));

    await tester.tap(find.text('View full plan'));
    await tester.pumpAndSettle();

    expect(find.text('Knee rehabilitation plan'), findsOneWidget);
    expect(
      find.text('Assigned by Dr. Sarah Malik on 1 Oct 2026'),
      findsOneWidget,
    );
    expect(find.text(squats.instructions), findsOneWidget);
    expect(find.text(lunge.instructions), findsOneWidget);
    expect(
      find.text('Note from your physiotherapist: Go slowly.'),
      findsOneWidget,
    );
  });

  testWidgets('a patient with no plan is told one is coming', (tester) async {
    await pumpApp(
      tester,
      auth: FakeAuthRepository(saved: user(UserRole.patient, 'Jane Cooper')),
    );

    expect(
      find.textContaining('No exercises have been assigned yet.'),
      findsOneWidget,
    );

    await tester.tap(find.text('My Exercise Plan'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('No exercises have been assigned yet.'),
      findsOneWidget,
    );
  });
}
