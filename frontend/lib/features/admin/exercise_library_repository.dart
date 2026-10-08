import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';

/// One thing the system watches during an exercise, and how far it may deviate
/// before feedback is INFO, AMBER or RED.
class SeverityCheck {
  const SeverityCheck({
    required this.key,
    required this.label,
    required this.measure,
    required this.unit,
    required this.info,
    required this.amber,
    required this.correctiveMessage,
    this.red,
  });

  factory SeverityCheck.fromJson(Map<String, dynamic> json) => SeverityCheck(
    key: json['key'] as String,
    label: json['label'] as String,
    measure: json['measure'] as String,
    unit: json['unit'] as String,
    info: (json['info'] as num).toDouble(),
    amber: (json['amber'] as num).toDouble(),
    red: (json['red'] as num?)?.toDouble(),
    correctiveMessage: json['corrective_message'] as String,
  );

  final String key;
  final String label;
  final String measure;
  final String unit;
  final double info;
  final double amber;

  /// Empty for checks that must never pause a session.
  final double? red;
  final String correctiveMessage;
}

/// A full exercise template as an admin sees it, thresholds included.
class ExerciseTemplate {
  const ExerciseTemplate({
    required this.id,
    required this.name,
    required this.domain,
    required this.bodyArea,
    required this.primaryTargets,
    required this.targetJoints,
    required this.movementPattern,
    required this.instructions,
    required this.checks,
    required this.isActive,
    required this.version,
    required this.updatedAt,
  });

  factory ExerciseTemplate.fromJson(Map<String, dynamic> json) =>
      ExerciseTemplate(
        id: json['id'] as String,
        name: json['name'] as String,
        domain: json['domain'] as String,
        bodyArea: json['body_area'] as String,
        primaryTargets: json['primary_targets'] as String,
        targetJoints: [
          for (final joint in json['target_joints'] as List<dynamic>)
            joint as String,
        ],
        movementPattern: json['movement_pattern'] as String,
        instructions: json['instructions'] as String,
        checks: [
          for (final check in json['checks'] as List<dynamic>)
            SeverityCheck.fromJson(check as Map<String, dynamic>),
        ],
        isActive: json['is_active'] as bool,
        version: json['version'] as int,
        updatedAt: DateTime.parse(json['updated_at'] as String),
      );

  final String id;
  final String name;
  final String domain;
  final String bodyArea;
  final String primaryTargets;
  final List<String> targetJoints;
  final String movementPattern;
  final String instructions;
  final List<SeverityCheck> checks;
  final bool isActive;
  final int version;
  final DateTime updatedAt;
}

final exerciseLibraryRepositoryProvider = Provider<ExerciseLibraryRepository>(
  (ref) => ExerciseLibraryRepository(ref.watch(apiClientProvider)),
);

/// The whole library, including exercises that are switched off.
final exerciseLibraryProvider =
    FutureProvider.autoDispose<List<ExerciseTemplate>>(
      (ref) => ref.watch(exerciseLibraryRepositoryProvider).all(),
    );

class ExerciseLibraryRepository {
  ExerciseLibraryRepository(this._api);

  final ApiClient _api;

  Future<List<ExerciseTemplate>> all() async {
    final json = await _api.get('/admin/exercises') as List<dynamic>;
    return [
      for (final item in json)
        ExerciseTemplate.fromJson(item as Map<String, dynamic>),
    ];
  }

  /// New exercises are created switched off.
  Future<ExerciseTemplate> create(Map<String, dynamic> fields) async =>
      ExerciseTemplate.fromJson(
        await _api.post('/admin/exercises', body: fields)
            as Map<String, dynamic>,
      );

  /// Saves an edit as a new version of the template.
  Future<ExerciseTemplate> update(
    String id,
    Map<String, dynamic> fields,
  ) async => ExerciseTemplate.fromJson(
    await _api.patch('/admin/exercises/$id', body: fields)
        as Map<String, dynamic>,
  );

  Future<ExerciseTemplate> setActive(String id, {required bool active}) async =>
      ExerciseTemplate.fromJson(
        await _api.post(
              '/admin/exercises/$id/${active ? 'activate' : 'deactivate'}',
            )
            as Map<String, dynamic>,
      );
}
