import '../auth/auth_models.dart';

enum Difficulty {
  easy('easy', 'Easy'),
  medium('medium', 'Medium'),
  hard('hard', 'Hard');

  const Difficulty(this.apiValue, this.label);

  final String apiValue;
  final String label;

  static Difficulty fromApi(String value) =>
      values.firstWhere((d) => d.apiValue == value, orElse: () => medium);
}

/// An exercise as a physiotherapist picks it and a patient reads it.
class ExerciseBrief {
  const ExerciseBrief({
    required this.id,
    required this.name,
    required this.domain,
    required this.bodyArea,
    required this.primaryTargets,
    required this.targetJoints,
    required this.instructions,
    this.isActive = true,
  });

  factory ExerciseBrief.fromJson(Map<String, dynamic> json) => ExerciseBrief(
    id: json['id'] as String,
    name: json['name'] as String,
    domain: json['domain'] as String,
    bodyArea: json['body_area'] as String,
    primaryTargets: json['primary_targets'] as String,
    targetJoints: [
      for (final joint in json['target_joints'] as List<dynamic>)
        joint as String,
    ],
    instructions: json['instructions'] as String,
    isActive: json['is_active'] as bool? ?? true,
  );

  final String id;
  final String name;
  final String domain;
  final String bodyArea;
  final String primaryTargets;
  final List<String> targetJoints;
  final String instructions;

  /// False once an admin has switched the exercise off.
  final bool isActive;
}

String _rest(int seconds) => seconds == 0 ? 'No rest' : '${seconds}s rest';

class PlanItem {
  const PlanItem({
    required this.id,
    required this.position,
    required this.exercise,
    required this.sets,
    required this.reps,
    required this.restSeconds,
    required this.difficulty,
    this.note,
  });

  factory PlanItem.fromJson(Map<String, dynamic> json) => PlanItem(
    id: json['id'] as String,
    position: json['position'] as int,
    exercise: ExerciseBrief.fromJson(json['exercise'] as Map<String, dynamic>),
    sets: json['sets'] as int,
    reps: json['reps'] as int,
    restSeconds: json['rest_seconds'] as int,
    difficulty: Difficulty.fromApi(json['difficulty'] as String),
    note: json['note'] as String?,
  );

  final String id;
  final int position;
  final ExerciseBrief exercise;
  final int sets;
  final int reps;
  final int restSeconds;
  final Difficulty difficulty;
  final String? note;

  /// "3 sets × 12 reps"
  String get prescription => '$sets sets × $reps reps';

  String get rest => _rest(restSeconds);
}

class ExercisePlan {
  const ExercisePlan({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.isActive,
    required this.assignedBy,
    required this.items,
    this.archivedAt,
    this.hasInactiveExercise = false,
  });

  factory ExercisePlan.fromJson(Map<String, dynamic> json) => ExercisePlan(
    id: json['id'] as String,
    name: json['name'] as String,
    createdAt: DateTime.parse(json['created_at'] as String),
    archivedAt: DateTime.tryParse(json['archived_at'] as String? ?? ''),
    isActive: json['is_active'] as bool,
    assignedBy: PersonRef.fromJson(json['assigned_by'] as Map<String, dynamic>),
    items: [
      for (final item in json['items'] as List<dynamic>)
        PlanItem.fromJson(item as Map<String, dynamic>),
    ],
    hasInactiveExercise: json['has_inactive_exercise'] as bool? ?? false,
  );

  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime? archivedAt;
  final bool isActive;
  final PersonRef assignedBy;
  final List<PlanItem> items;
  final bool hasInactiveExercise;

  List<String> get inactiveExerciseNames => [
    for (final item in items)
      if (!item.exercise.isActive) item.exercise.name,
  ];
}

/// One exercise being configured in the plan builder, before it is saved.
class PlanItemDraft {
  PlanItemDraft(this.exercise);

  final ExerciseBrief exercise;
  int sets = 3;
  int reps = 10;
  int restSeconds = 60;
  Difficulty difficulty = Difficulty.medium;
  String note = '';

  Map<String, dynamic> toJson() => {
    'exercise_id': exercise.id,
    'sets': sets,
    'reps': reps,
    'rest_seconds': restSeconds,
    'difficulty': difficulty.apiValue,
    if (note.trim().isNotEmpty) 'note': note.trim(),
  };
}
