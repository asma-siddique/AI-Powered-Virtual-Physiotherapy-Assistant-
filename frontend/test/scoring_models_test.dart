// US 4.1 and 4.3 as the admin uses them: seeing what scores sessions,
// registering a trained model, promoting it only on evidence, rolling back.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:physioai/core/api/api_exception.dart';
import 'package:physioai/core/files/file_picker.dart';
import 'package:physioai/core/widgets/common.dart';
import 'package:physioai/features/admin/scoring_models_page.dart';
import 'package:physioai/features/admin/scoring_models_repository.dart';
import 'package:physioai/features/auth/auth_models.dart';

import 'auth_flow_test.dart';

const cnn = 'rehab-cnn-202610111200-aaaaaaaa';
const heldOut = 'REHAB24-6:test:0123456789abcdef:fedcba9876543210';

ModelEvaluation evaluation(double agreement, {String evalSet = heldOut}) =>
    ModelEvaluation(
      id: 'e-$agreement',
      evalSet: evalSet,
      agreement: agreement,
      balancedAccuracy: agreement - 0.02,
      repetitions: 183,
      source: 'training_record',
      createdAt: DateTime(2026, 10, 11, 12),
      recordedBy: 'Alex Morgan',
    );

ScoringModel rule({
  String status = 'production',
  List<ModelEvaluation> evaluations = const [],
}) => ScoringModel(
  version: 'rules-1',
  kind: 'rule',
  status: status,
  registeredAt: DateTime(2026, 10, 1),
  evaluations: evaluations,
);

ScoringModel classifier({
  String status = 'candidate',
  double agreement = 0.91,
}) => ScoringModel(
  version: cnn,
  kind: 'classifier',
  status: status,
  registeredAt: DateTime(2026, 10, 11),
  registeredBy: 'Alex Morgan',
  targetAgreement: 0.85,
  exercises: const ['arm-abduction', 'squats'],
  trainedOn: 505,
  evaluations: [evaluation(agreement)],
);

/// Holds the registry the way the server would and applies its rules.
class FakeScoringModelsRepository implements ScoringModelsRepository {
  FakeScoringModelsRepository(this.models);

  List<ScoringModel> models;
  final history = <ModelDecision>[];
  ApiException? failure;
  final registered = <Map<String, dynamic>>[];
  final evaluated = <Map<String, dynamic>>[];
  final promoted = <({String version, String reason})>[];
  final rolledBack = <({String reason, String? to})>[];

  ScoringRegistry get _registry => ScoringRegistry(
    production: models.firstWhere((m) => m.isProduction).version,
    models: models,
    history: history,
  );

  ScoringModel _as(ScoringModel model, String status) => ScoringModel(
    version: model.version,
    kind: model.kind,
    status: status,
    registeredAt: model.registeredAt,
    registeredBy: model.registeredBy,
    targetAgreement: model.targetAgreement,
    exercises: model.exercises,
    trainedOn: model.trainedOn,
    evaluations: model.evaluations,
  );

  void _makeProduction(String version, String action, String reason) {
    final previous = _registry.production;
    models = [
      for (final model in models)
        if (model.version == version)
          _as(model, 'production')
        else if (model.isProduction)
          _as(model, 'retired')
        else
          model,
    ];
    history.insert(
      0,
      ModelDecision(
        action: action,
        modelVersion: version,
        previousVersion: previous,
        reason: reason,
        decidedBy: 'Alex Morgan',
        createdAt: DateTime(2026, 10, 11, 13),
      ),
    );
  }

  @override
  Future<ScoringRegistry> registry() async => _registry;

  @override
  Future<ScoringRegistry> register(Map<String, dynamic> registration) async {
    if (failure != null) throw failure!;
    registered.add(registration);
    models = [classifier(), ...models];
    return _registry;
  }

  @override
  Future<ScoringRegistry> addEvaluation(Map<String, dynamic> sent) async {
    if (failure != null) throw failure!;
    evaluated.add(sent);
    return _registry;
  }

  @override
  Future<ScoringRegistry> promote(String version, String reason) async {
    if (failure != null) throw failure!;
    promoted.add((version: version, reason: reason));
    _makeProduction(version, 'promote', reason);
    return _registry;
  }

  @override
  Future<ScoringRegistry> rollback(String reason, {String? toVersion}) async {
    if (failure != null) throw failure!;
    rolledBack.add((reason: reason, to: toVersion));
    _makeProduction(toVersion ?? _registry.rollbackTarget!, 'rollback', reason);
    return _registry;
  }
}

/// A chooser that hands over [text] as the file the admin picked.
TextFilePicker picking(String? text, {String name = 'registration.json'}) =>
    (accept) async =>
        text == null ? null : PickedTextFile(name: name, text: text);

Future<FakeScoringModelsRepository> openModels(
  WidgetTester tester, {
  FakeScoringModelsRepository? models,
  TextFilePicker? picker,
}) async {
  final repository = models ?? FakeScoringModelsRepository([rule()]);
  await pumpApp(
    tester,
    auth: FakeAuthRepository(saved: user(UserRole.admin, 'Alex Morgan')),
    models: repository,
    picker: picker,
  );
  await tester.tap(find.text('Scoring Models'));
  await tester.pumpAndSettle();
  return repository;
}

Future<void> decide(WidgetTester tester, String reason) async {
  await fill(tester, 'decision-reason', reason);
  await tapKey(tester, 'confirm-decision');
}

String productionShown(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const Key('production-version'))).data!;

void main() {
  testWidgets('the rule scores sessions until something is promoted', (
    tester,
  ) async {
    await openModels(tester);

    expect(productionShown(tester), 'rules-1');
    expect(find.widgetWithText(Pill, 'In production'), findsOneWidget);
    expect(find.textContaining('Nothing has been promoted yet'), findsOne);
    // Nothing to go back to, so no way to roll back is offered.
    expect(find.byKey(const Key('roll-back')), findsNothing);
  });

  testWidgets('a candidate is listed with its held-out result and target', (
    tester,
  ) async {
    await openModels(
      tester,
      models: FakeScoringModelsRepository([classifier(), rule()]),
    );

    expect(find.widgetWithText(Pill, 'Candidate'), findsOneWidget);
    expect(find.text('91.0% agreement'), findsOneWidget);
    expect(find.widgetWithText(Pill, 'Meets the 85.0% target'), findsOne);
    expect(find.textContaining('505 training repetitions'), findsOneWidget);
    expect(
      find.textContaining('REHAB24-6 test subjects (split 01234567)'),
      findsOneWidget,
    );
    // Being registered changes nothing about what scores sessions.
    expect(productionShown(tester), 'rules-1');
  });

  testWidgets('a result below the target is marked as such', (tester) async {
    await openModels(
      tester,
      models: FakeScoringModelsRepository([
        classifier(agreement: 0.79),
        rule(),
      ]),
    );

    expect(find.widgetWithText(Pill, 'Below the 85.0% target'), findsOne);
  });

  testWidgets('registering a model sends the chosen file as it is', (
    tester,
  ) async {
    final registration = {
      'record': {'model_version': cnn},
      'splits': '{}',
      'weights_b64': 'AAAA',
      'weights_sha256': 'a' * 64,
    };
    final models = await openModels(
      tester,
      picker: picking(jsonEncode(registration)),
    );

    await tapKey(tester, 'register-model');

    expect(models.registered, [registration]);
    expect(find.textContaining('registered as a candidate'), findsOneWidget);
    expect(find.byKey(const Key('promote-$cnn')), findsOneWidget);
    expect(productionShown(tester), 'rules-1');
  });

  testWidgets('a file that is not a registration is never sent', (
    tester,
  ) async {
    final models = await openModels(
      tester,
      picker: picking('{"model_version": "x"}', name: 'notes.json'),
    );

    await tapKey(tester, 'register-model');

    expect(models.registered, isEmpty);
    expect(
      find.textContaining('notes.json is not a file made by'),
      findsOneWidget,
    );

    // Nor is something that is not JSON at all.
    await tapKey(tester, 'add-evaluation');
    expect(models.evaluated, isEmpty);
  });

  testWidgets('closing the chooser without a file does nothing', (
    tester,
  ) async {
    final models = await openModels(tester, picker: picking(null));

    await tapKey(tester, 'register-model');

    expect(models.registered, isEmpty);
    expect(find.byKey(const Key('models-error')), findsNothing);
  });

  testWidgets('the server refusing a model is shown in its own words', (
    tester,
  ) async {
    final models = await openModels(
      tester,
      picker: picking(
        jsonEncode({
          'record': {'model_version': cnn},
          'splits': '{}',
          'weights_b64': 'AAAA',
          'weights_sha256': 'a' * 64,
        }),
      ),
    );
    models.failure = const ApiException(
      code: 'subject_in_two_splits',
      message: 'Subject 3 is in both the train and the test split.',
      statusCode: 422,
    );

    await tapKey(tester, 'register-model');

    expect(
      find.text('Subject 3 is in both the train and the test split.'),
      findsOneWidget,
    );
    expect(find.widgetWithText(Pill, 'Candidate'), findsNothing);
  });

  testWidgets('an evaluation file is recorded against the model it names', (
    tester,
  ) async {
    final evaluation = {
      'model_version': 'rules-1',
      'eval_set': heldOut,
      'metrics': {'agreement': 0.7, 'repetitions': 183},
    };
    final models = await openModels(
      tester,
      picker: picking(jsonEncode(evaluation), name: 'rules-1.json'),
    );

    await tapKey(tester, 'add-evaluation');

    expect(models.evaluated, [evaluation]);
    expect(find.text('The evaluation of rules-1 is recorded.'), findsOneWidget);
  });

  testWidgets('promoting shows both models on the same set and needs a reason', (
    tester,
  ) async {
    final models = await openModels(
      tester,
      models: FakeScoringModelsRepository([
        classifier(),
        rule(evaluations: [evaluation(0.7)]),
      ]),
    );

    await tapKey(tester, 'promote-$cnn');

    expect(find.text('Promote $cnn?'), findsOneWidget);
    expect(
      find.textContaining(
        '$cnn agrees with the expert labels 91.0% of the time, rules-1 70.0%.',
      ),
      findsOneWidget,
    );
    // No reason, no decision.
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('confirm-decision')))
          .onPressed,
      isNull,
    );

    await decide(tester, 'Better on the held-out subjects.');

    expect(models.promoted, [
      (version: cnn, reason: 'Better on the held-out subjects.'),
    ]);
    expect(productionShown(tester), cnn);
    expect(find.text('Promoted $cnn over rules-1'), findsOneWidget);
    expect(find.widgetWithText(Pill, 'Was in production'), findsOneWidget);
  });

  testWidgets('cancelling a promotion changes nothing', (tester) async {
    final models = await openModels(
      tester,
      models: FakeScoringModelsRepository([
        classifier(),
        rule(evaluations: [evaluation(0.7)]),
      ]),
    );

    await tapKey(tester, 'promote-$cnn');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(models.promoted, isEmpty);
    expect(productionShown(tester), 'rules-1');
  });

  testWidgets('a candidate that cannot be compared yet says so first', (
    tester,
  ) async {
    await openModels(
      tester,
      models: FakeScoringModelsRepository([classifier(), rule()]),
    );

    await tapKey(tester, 'promote-$cnn');

    expect(find.byKey(const Key('promotion-comparison')), findsNothing);
    expect(
      find.textContaining(
        'rules-1 has not been evaluated on the same held-out set',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a worse candidate is warned about and the refusal is shown', (
    tester,
  ) async {
    final models = await openModels(
      tester,
      models: FakeScoringModelsRepository([
        classifier(agreement: 0.6),
        rule(evaluations: [evaluation(0.7)]),
      ]),
    );
    models.failure = const ApiException(
      code: 'not_better',
      message: 'A candidate must do at least as well to be promoted.',
      statusCode: 409,
    );

    await tapKey(tester, 'promote-$cnn');
    expect(
      find.textContaining('It does worse, so this will be refused.'),
      findsOneWidget,
    );
    expect(find.textContaining('below the 85.0% agreement'), findsOneWidget);
    await decide(tester, 'Trying it anyway.');

    expect(
      find.text('A candidate must do at least as well to be promoted.'),
      findsOneWidget,
    );
    expect(productionShown(tester), 'rules-1');
  });

  testWidgets('rolling back puts the previous model back with a reason', (
    tester,
  ) async {
    final models = FakeScoringModelsRepository([
      classifier(),
      rule(evaluations: [evaluation(0.7)]),
    ]);
    await models.promote(cnn, 'Better on the held-out subjects.');
    await openModels(tester, models: models);
    expect(productionShown(tester), cnn);

    await tapKey(tester, 'roll-back');
    expect(find.text('Go back to rules-1?'), findsOneWidget);
    expect(find.textContaining('Nothing is deleted.'), findsOneWidget);
    await decide(tester, 'Scores looked wrong in clinic.');

    expect(models.rolledBack, [
      (reason: 'Scores looked wrong in clinic.', to: 'rules-1'),
    ]);
    expect(productionShown(tester), 'rules-1');
    expect(find.text('Rolled back to rules-1 from $cnn'), findsOneWidget);
    // The model it replaced is kept and can be put back the same way.
    expect(find.byKey(const Key('put-back-$cnn')), findsOneWidget);
  });

  test('a held-out set is described in words', () {
    expect(
      describeEvalSet(heldOut),
      'REHAB24-6 test subjects (split 01234567)',
    );
    expect(describeEvalSet('something else'), 'something else');
    expect(percent(0.8497), '85.0%');
  });

  test('the registry is read as the server sends it', () {
    final registry = ScoringRegistry.fromJson({
      'production': cnn,
      'models': [
        {
          'version': cnn,
          'kind': 'classifier',
          'status': 'production',
          'registered_at': '2026-10-11T12:00:00Z',
          'registered_by': {'id': 'a-1', 'full_name': 'Alex Morgan'},
          'description': '1-D CNN',
          'training_data': {
            'exercises': ['arm-abduction', 'squats'],
            'examples': {'train': 505, 'val': 176, 'test': 183},
          },
          'target_agreement': 0.85,
          'evaluations': [
            {
              'id': 'e-1',
              'eval_set': heldOut,
              'agreement': 0.91,
              'balanced_accuracy': null,
              'repetitions': 183,
              'source': 'training_record',
              'created_at': '2026-10-11T12:00:00Z',
              'recorded_by': null,
            },
          ],
        },
        {
          'version': 'rules-1',
          'kind': 'rule',
          'status': 'retired',
          'registered_at': '2026-10-01T00:00:00Z',
          'registered_by': null,
          'description': null,
          'training_data': null,
          'target_agreement': null,
          'evaluations': [],
        },
      ],
      'history': [
        {
          'id': 'd-1',
          'action': 'promote',
          'model_version': cnn,
          'previous_version': 'rules-1',
          'reason': 'Better.',
          'decided_by': {'id': 'a-1', 'full_name': 'Alex Morgan'},
          'created_at': '2026-10-11T13:00:00Z',
          'eval_set': heldOut,
          'agreement': 0.91,
          'incumbent_agreement': 0.7,
        },
      ],
    });

    expect(registry.current.version, cnn);
    expect(registry.current.trainedOn, 505);
    expect(registry.current.latest!.agreement, 0.91);
    expect(registry.rollbackTarget, 'rules-1');
    expect(registry.history.single.incumbentAgreement, 0.7);
    expect(registry.models.last.isRetired, isTrue);
  });
}
