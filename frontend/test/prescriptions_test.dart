// US 2.2: a physiotherapist adjusts a patient's prescription mid-plan, and the
// earlier values stay readable in the plan's change history.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:physioai/core/api/api_exception.dart';
import 'package:physioai/features/auth/auth_models.dart';
import 'package:physioai/features/exercises/exercise_models.dart';
import 'package:physioai/features/physio/physio_repository.dart';

import 'auth_flow_test.dart';
import 'plans_test.dart';

/// Jane has "Week 2" in force (Squats with a note, Leg Lunge) and "Week 1"
/// archived.
Future<FakePhysioRepository> openJanesPlans(
  WidgetTester tester, {
  PatientSummary? patient,
}) async {
  final who = patient ?? jane;
  final physio = FakePhysioRepository()
    ..roster.add(who)
    ..exercises.addAll([lunge, squats])
    ..plansByPatient[who.id] = [
      plan('Week 2', [squats, lunge]),
      plan('Week 1', [squats], active: false),
    ];
  await openPlanBuilder(tester, physio: physio);
  await choosePatient(tester, who.fullName);
  return physio;
}

String itemLine(WidgetTester tester, String id) =>
    tester.widget<Text>(find.byKey(Key('plan-item-$id')).first).data!;

Future<void> choose(WidgetTester tester, String key, String label) async {
  await tapKey(tester, key);
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('only the plan in force offers "Edit"', (tester) async {
    await openJanesPlans(tester);

    // Week 2 has two exercises; archived Week 1 reuses the id "item-0" but
    // has no Edit of its own, so each key is found exactly once.
    expect(find.byKey(const Key('edit-item-item-0')), findsOneWidget);
    expect(find.byKey(const Key('edit-item-item-1')), findsOneWidget);
    expect(find.byKey(const Key('plan-history-plan-Week 2')), findsNothing);
  });

  testWidgets('the dialog opens with the current prescription', (tester) async {
    await openJanesPlans(tester);

    await tapKey(tester, 'edit-item-item-0');

    expect(find.text('Edit Squats'), findsOneWidget);
    String field(String key) =>
        tester.widget<TextFormField>(find.byKey(Key(key))).controller!.text;
    expect((field('rx-sets'), field('rx-reps')), ('3', '12'));
    expect(field('rx-note'), 'Go slowly.');
    expect(
      find.textContaining('Applies to sessions Jane Cooper starts from now on'),
      findsOneWidget,
    );
    expect(
      find.textContaining('keep the prescription they were done with'),
      findsOneWidget,
    );
  });

  testWidgets('saving an edit updates the plan and tells the physiotherapist '
      'the patient was notified', (tester) async {
    final physio = await openJanesPlans(tester);

    await tapKey(tester, 'edit-item-item-0');
    await fill(tester, 'rx-sets', '4');
    await fill(tester, 'rx-reps', '10');
    await choose(tester, 'rx-rest', '90 s');
    await choose(tester, 'rx-difficulty', 'Hard');
    await fill(tester, 'rx-note', 'Pause at the bottom.');
    await tapKey(tester, 'rx-save');

    expect(physio.prescriptionEditsMade, [
      'item-0 4 x 10 rest 90 hard "Pause at the bottom."',
    ]);
    expect(find.text('Edit Squats'), findsNothing);
    expect(
      itemLine(tester, 'item-0'),
      '1. Squats  ·  4 sets × 10 reps  ·  90s rest  ·  Hard  ·  edited 9 Oct 2026',
    );
    expect(
      find.text('Squats was updated. Jane Cooper has been notified.'),
      findsOneWidget,
    );
    // Still one current plan: an edit never assigns a new one.
    expect(physio.assigned, isEmpty);
    expect(find.text('Current'), findsOneWidget);
  });

  testWidgets('the change history shows each edit with its time and the '
      'values it replaced', (tester) async {
    await openJanesPlans(tester);
    await tapKey(tester, 'edit-item-item-0');
    await fill(tester, 'rx-sets', '4');
    await fill(tester, 'rx-note', '');
    await tapKey(tester, 'rx-save');
    await tapKey(tester, 'edit-item-item-1');
    await choose(tester, 'rx-rest', 'None');
    await tapKey(tester, 'rx-save');

    await tapKey(tester, 'plan-history-plan-Week 2');

    expect(find.text('Change history: Week 2'), findsOneWidget);
    expect(find.text('Plan assigned by Dr. Sarah Malik'), findsOneWidget);
    expect(find.text('1 Oct 2026, 00:00'), findsOneWidget);
    expect(find.text('Squats edited by Dr. Sarah Malik'), findsOneWidget);
    expect(find.text('Sets: 3 to 4'), findsOneWidget);
    expect(find.text('Note removed (was "Go slowly.")'), findsOneWidget);
    expect(find.text('Leg Lunge edited by Dr. Sarah Malik'), findsOneWidget);
    expect(find.text('Rest: 60s to none'), findsOneWidget);
    expect(find.text('9 Oct 2026, 15:00'), findsNWidgets(2));
    // Oldest first, as the edits were made.
    final squatsEdit = tester.getTopLeft(find.text('Sets: 3 to 4')).dy;
    final lungeEdit = tester.getTopLeft(find.text('Rest: 60s to none')).dy;
    expect(squatsEdit, lessThan(lungeEdit));

    await tapKey(tester, 'history-close');
    expect(find.text('Change history: Week 2'), findsNothing);
  });

  testWidgets('values outside the allowed range are caught before saving', (
    tester,
  ) async {
    final physio = await openJanesPlans(tester);
    await tapKey(tester, 'edit-item-item-0');

    await fill(tester, 'rx-sets', '0');
    await fill(tester, 'rx-reps', '51');
    await tapKey(tester, 'rx-save');
    expect(find.text('Enter sets from 1 to 10.'), findsOneWidget);
    expect(find.text('Enter reps from 1 to 50.'), findsOneWidget);

    await fill(tester, 'rx-sets', '');
    await tapKey(tester, 'rx-save');
    expect(find.text('Enter sets from 1 to 10.'), findsOneWidget);
    expect(physio.prescriptionEditsMade, isEmpty);
  });

  testWidgets('saving without changing anything sends nothing', (tester) async {
    final physio = await openJanesPlans(tester);

    await tapKey(tester, 'edit-item-item-0');
    await tapKey(tester, 'rx-save');

    expect(physio.prescriptionEditsMade, isEmpty);
    expect(find.text('Edit Squats'), findsNothing);
    expect(find.textContaining('has been notified'), findsNothing);
    expect(find.byKey(const Key('plan-history-plan-Week 2')), findsNothing);
  });

  testWidgets('cancelling leaves the prescription as it was', (tester) async {
    final physio = await openJanesPlans(tester);

    await tapKey(tester, 'edit-item-item-0');
    await fill(tester, 'rx-sets', '9');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(physio.prescriptionEditsMade, isEmpty);
    expect(itemLine(tester, 'item-0'), contains('3 sets × 12 reps'));
  });

  testWidgets('a refusal from the server stays in the dialog', (tester) async {
    final physio = await openJanesPlans(tester);
    physio.editFailure = const ApiException(
      code: 'plan_archived',
      message:
          "This is no longer the patient's current plan, so it cannot be edited.",
      statusCode: 409,
    );

    await tapKey(tester, 'edit-item-item-0');
    await fill(tester, 'rx-sets', '4');
    await tapKey(tester, 'rx-save');

    expect(find.byKey(const Key('rx-error')), findsOneWidget);
    expect(find.textContaining('no longer the patient'), findsOneWidget);
    expect(find.text('Edit Squats'), findsOneWidget);
  });

  testWidgets("a deactivated patient's plan cannot be edited", (tester) async {
    await openJanesPlans(
      tester,
      patient: PatientSummary(
        id: 'patient-gone',
        fullName: 'Bilal Ahmed',
        email: 'bilal@example.test',
        isActive: false,
        assignedAt: DateTime(2026, 9, 2),
      ),
    );

    final edit = tester.widget<TextButton>(
      find.byKey(const Key('edit-item-item-0')),
    );
    expect(edit.onPressed, isNull);
  });

  testWidgets('the patient sees when a prescription was last updated', (
    tester,
  ) async {
    final edited = ExercisePlan(
      id: 'plan-1',
      name: 'Knee plan',
      createdAt: DateTime(2026, 10, 1),
      isActive: true,
      assignedBy: const PersonRef(id: 'physio-1', fullName: 'Dr. Sarah Malik'),
      items: [
        PlanItem(
          id: 'item-0',
          position: 1,
          exercise: squats,
          sets: 4,
          reps: 10,
          restSeconds: 90,
          difficulty: Difficulty.hard,
          revision: 2,
          updatedAt: DateTime(2026, 10, 9, 15),
        ),
        const PlanItem(
          id: 'item-1',
          position: 2,
          exercise: lunge,
          sets: 3,
          reps: 12,
          restSeconds: 60,
          difficulty: Difficulty.medium,
        ),
      ],
    );
    await pumpApp(
      tester,
      auth: FakeAuthRepository(
        saved: user(
          UserRole.patient,
          'Jane Cooper',
          physiotherapist: 'Dr. Sarah Malik',
        ),
      ),
      patient: FakePatientRepository()..plan = edited,
    );
    await tester.tap(find.text('My Exercise Plan'));
    await tester.pumpAndSettle();

    expect(find.text('4 sets × 10 reps'), findsOneWidget);
    expect(
      find.text('Updated by your physiotherapist on 9 Oct 2026'),
      findsOneWidget,
    );
  });

  test('each kind of change reads naturally in the history', () {
    String describe(String field, Object? before, Object? after) =>
        FieldChange(field: field, before: before, after: after).description;

    expect(describe('sets', 3, 4), 'Sets: 3 to 4');
    expect(describe('reps', 12, 10), 'Reps: 12 to 10');
    expect(describe('rest_seconds', 0, 45), 'Rest: none to 45s');
    expect(describe('difficulty', 'easy', 'hard'), 'Difficulty: Easy to Hard');
    expect(describe('note', null, 'Slowly.'), 'Note added: "Slowly."');
    expect(describe('note', 'Slowly.', null), 'Note removed (was "Slowly.")');
    expect(
      describe('note', 'Slowly.', 'Faster.'),
      'Note: "Slowly." to "Faster."',
    );
  });
}
