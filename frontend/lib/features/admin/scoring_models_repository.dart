import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';

String? _name(Object? person) =>
    (person as Map<String, dynamic>?)?['full_name'] as String?;

/// One model scored against one held-out set. Kept for good by the server.
class ModelEvaluation {
  const ModelEvaluation({
    required this.id,
    required this.evalSet,
    required this.agreement,
    this.balancedAccuracy,
    required this.repetitions,
    required this.source,
    required this.createdAt,
    this.recordedBy,
  });

  factory ModelEvaluation.fromJson(Map<String, dynamic> json) =>
      ModelEvaluation(
        id: json['id'] as String,
        evalSet: json['eval_set'] as String,
        agreement: (json['agreement'] as num).toDouble(),
        balancedAccuracy: (json['balanced_accuracy'] as num?)?.toDouble(),
        repetitions: json['repetitions'] as int,
        source: json['source'] as String,
        createdAt: DateTime.parse(json['created_at'] as String),
        recordedBy: _name(json['recorded_by']),
      );

  final String id;

  /// Names the held-out set, so two models can be compared on the same one.
  final String evalSet;

  /// Share of repetitions where the model agreed with the expert label.
  final double agreement;
  final double? balancedAccuracy;
  final int repetitions;

  /// training_record | uploaded
  final String source;
  final DateTime createdAt;
  final String? recordedBy;
}

/// Something that can score a session: the rule or a trained classifier.
class ScoringModel {
  const ScoringModel({
    required this.version,
    required this.kind,
    required this.status,
    required this.registeredAt,
    this.registeredBy,
    this.description,
    this.targetAgreement,
    this.exercises = const [],
    this.trainedOn,
    this.evaluations = const [],
  });

  factory ScoringModel.fromJson(Map<String, dynamic> json) {
    final data = json['training_data'] as Map<String, dynamic>?;
    return ScoringModel(
      version: json['version'] as String,
      kind: json['kind'] as String,
      status: json['status'] as String,
      registeredAt: DateTime.parse(json['registered_at'] as String),
      registeredBy: _name(json['registered_by']),
      description: json['description'] as String?,
      targetAgreement: (json['target_agreement'] as num?)?.toDouble(),
      exercises: [
        for (final slug in data?['exercises'] as List<dynamic>? ?? const [])
          slug as String,
      ],
      trainedOn: (data?['examples'] as Map<String, dynamic>?)?['train'] as int?,
      evaluations: [
        for (final item in json['evaluations'] as List<dynamic>? ?? const [])
          ModelEvaluation.fromJson(item as Map<String, dynamic>),
      ],
    );
  }

  final String version;

  /// rule | classifier
  final String kind;

  /// candidate | production | retired
  final String status;
  final DateTime registeredAt;
  final String? registeredBy;
  final String? description;

  /// The agreement the project asks of a classifier, from its record.
  final double? targetAgreement;

  /// The exercises a classifier was trained on, by slug.
  final List<String> exercises;

  /// How many repetitions it was trained on.
  final int? trainedOn;

  /// Newest first.
  final List<ModelEvaluation> evaluations;

  bool get isProduction => status == 'production';
  bool get isCandidate => status == 'candidate';

  /// It was the production model before, so it can be put back at once.
  bool get isRetired => status == 'retired';

  /// Its newest evaluation: the one a promotion would rest on.
  ModelEvaluation? get latest => evaluations.firstOrNull;

  ModelEvaluation? latestOn(String evalSet) =>
      evaluations.where((e) => e.evalSet == evalSet).firstOrNull;
}

/// A decision to promote a model or to go back to an earlier one.
class ModelDecision {
  const ModelDecision({
    required this.action,
    required this.modelVersion,
    this.previousVersion,
    required this.reason,
    this.decidedBy,
    required this.createdAt,
    this.agreement,
    this.incumbentAgreement,
  });

  factory ModelDecision.fromJson(Map<String, dynamic> json) => ModelDecision(
    action: json['action'] as String,
    modelVersion: json['model_version'] as String,
    previousVersion: json['previous_version'] as String?,
    reason: json['reason'] as String,
    decidedBy: _name(json['decided_by']),
    createdAt: DateTime.parse(json['created_at'] as String),
    agreement: (json['agreement'] as num?)?.toDouble(),
    incumbentAgreement: (json['incumbent_agreement'] as num?)?.toDouble(),
  );

  /// promote | rollback
  final String action;
  final String modelVersion;
  final String? previousVersion;
  final String reason;
  final String? decidedBy;
  final DateTime createdAt;

  /// What a promotion rested on: both models on the same held-out set.
  final double? agreement;
  final double? incumbentAgreement;

  bool get isRollback => action == 'rollback';
}

/// Every scoring model, which one is in production, and every decision.
class ScoringRegistry {
  const ScoringRegistry({
    required this.production,
    this.models = const [],
    this.history = const [],
  });

  factory ScoringRegistry.fromJson(Map<String, dynamic> json) =>
      ScoringRegistry(
        production: json['production'] as String,
        models: [
          for (final item in json['models'] as List<dynamic>)
            ScoringModel.fromJson(item as Map<String, dynamic>),
        ],
        history: [
          for (final item in json['history'] as List<dynamic>? ?? const [])
            ModelDecision.fromJson(item as Map<String, dynamic>),
        ],
      );

  final String production;
  final List<ScoringModel> models;

  /// Newest first.
  final List<ModelDecision> history;

  ScoringModel get current => models.firstWhere((m) => m.isProduction);

  /// The model a plain "roll back" returns to: the one the current model
  /// replaced. Null when nothing has been promoted yet.
  String? get rollbackTarget => history
      .where((d) => d.modelVersion == production)
      .firstOrNull
      ?.previousVersion;
}

final scoringModelsRepositoryProvider = Provider<ScoringModelsRepository>(
  (ref) => ScoringModelsRepository(ref.watch(apiClientProvider)),
);

final scoringRegistryProvider = FutureProvider.autoDispose<ScoringRegistry>(
  (ref) => ref.watch(scoringModelsRepositoryProvider).registry(),
);

class ScoringModelsRepository {
  ScoringModelsRepository(this._api);

  final ApiClient _api;

  ScoringRegistry _read(Object? json) =>
      ScoringRegistry.fromJson(json as Map<String, dynamic>);

  Future<ScoringRegistry> registry() async =>
      _read(await _api.get('/admin/models'));

  /// Registers a trained model as a candidate, from the file
  /// `python -m rehab.export` writes. It never changes what is in production.
  Future<ScoringRegistry> register(Map<String, dynamic> registration) async =>
      _read(await _api.post('/admin/models', body: registration));

  /// Records an evaluation, from the file `python -m rehab.evaluate` writes.
  Future<ScoringRegistry> addEvaluation(
    Map<String, dynamic> evaluation,
  ) async => _read(
    await _api.post(
      '/admin/models/${Uri.encodeComponent(evaluation['model_version'] as String)}/evaluations',
      body: evaluation,
    ),
  );

  /// Refused by the server unless the model does at least as well as the
  /// current one on the same held-out set.
  Future<ScoringRegistry> promote(String version, String reason) async => _read(
    await _api.post(
      '/admin/models/${Uri.encodeComponent(version)}/promote',
      body: {'reason': reason},
    ),
  );

  /// Puts an earlier production model back: [toVersion], or the one the
  /// current model replaced.
  Future<ScoringRegistry> rollback(String reason, {String? toVersion}) async =>
      _read(
        await _api.post(
          '/admin/models/rollback',
          body: {'reason': reason, 'to_version': ?toVersion},
        ),
      );
}
