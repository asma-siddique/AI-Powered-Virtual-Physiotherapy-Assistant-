import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../auth/auth_models.dart';
import '../exercises/exercise_models.dart';

class InviteCode {
  const InviteCode({
    required this.id,
    required this.code,
    required this.createdAt,
    required this.expiresAt,
    required this.status,
    this.redeemedBy,
  });

  factory InviteCode.fromJson(Map<String, dynamic> json) => InviteCode(
    id: json['id'] as String,
    code: json['code'] as String,
    createdAt: DateTime.parse(json['created_at'] as String),
    expiresAt: DateTime.parse(json['expires_at'] as String),
    status: json['status'] as String,
    redeemedBy: json['redeemed_by'] == null
        ? null
        : PersonRef.fromJson(json['redeemed_by'] as Map<String, dynamic>),
  );

  final String id;
  final String code;
  final DateTime createdAt;
  final DateTime expiresAt;

  /// active | redeemed | expired
  final String status;
  final PersonRef? redeemedBy;

  bool get isActive => status == 'active';
}

class PatientSummary {
  const PatientSummary({
    required this.id,
    required this.fullName,
    required this.isActive,
    required this.assignedAt,
    this.email,
    this.mobile,
  });

  factory PatientSummary.fromJson(Map<String, dynamic> json) => PatientSummary(
    id: json['id'] as String,
    fullName: json['full_name'] as String,
    email: json['email'] as String?,
    mobile: json['mobile'] as String?,
    isActive: json['is_active'] as bool,
    assignedAt: DateTime.parse(json['assigned_at'] as String),
  );

  final String id;
  final String fullName;
  final String? email;
  final String? mobile;
  final bool isActive;
  final DateTime assignedAt;

  String get contact => email ?? mobile ?? '';
}

final physioRepositoryProvider = Provider<PhysioRepository>(
  (ref) => PhysioRepository(ref.watch(apiClientProvider)),
);

final inviteCodesProvider = FutureProvider.autoDispose<List<InviteCode>>(
  (ref) => ref.watch(physioRepositoryProvider).inviteCodes(),
);

final rosterProvider = FutureProvider.autoDispose<List<PatientSummary>>(
  (ref) => ref.watch(physioRepositoryProvider).patients(),
);

/// Exercises an admin currently has switched on: the only ones a plan may use.
final activeExercisesProvider = FutureProvider.autoDispose<List<ExerciseBrief>>(
  (ref) => ref.watch(physioRepositoryProvider).activeExercises(),
);

/// Every plan a patient has had, the one in force first.
final patientPlansProvider = FutureProvider.autoDispose
    .family<List<ExercisePlan>, String>(
      (ref, patientId) => ref.watch(physioRepositoryProvider).plans(patientId),
    );

class PhysioRepository {
  PhysioRepository(this._api);

  final ApiClient _api;

  Future<List<InviteCode>> inviteCodes() async {
    final json = await _api.get('/physio/invite-codes') as List<dynamic>;
    return [
      for (final item in json)
        InviteCode.fromJson(item as Map<String, dynamic>),
    ];
  }

  Future<InviteCode> createInviteCode() async => InviteCode.fromJson(
    await _api.post('/physio/invite-codes') as Map<String, dynamic>,
  );

  Future<List<PatientSummary>> patients() async {
    final json = await _api.get('/physio/patients') as List<dynamic>;
    return [
      for (final item in json)
        PatientSummary.fromJson(item as Map<String, dynamic>),
    ];
  }

  Future<List<ExerciseBrief>> activeExercises() async {
    final json = await _api.get('/physio/exercises') as List<dynamic>;
    return [
      for (final item in json)
        ExerciseBrief.fromJson(item as Map<String, dynamic>),
    ];
  }

  /// Assigns a new plan; the patient's previous plan is archived by the server.
  Future<ExercisePlan> assignPlan({
    required String patientId,
    required String name,
    required List<PlanItemDraft> items,
  }) async => ExercisePlan.fromJson(
    await _api.post(
          '/physio/patients/$patientId/plans',
          body: {
            'name': name,
            'items': [for (final item in items) item.toJson()],
          },
        )
        as Map<String, dynamic>,
  );

  Future<List<ExercisePlan>> plans(String patientId) async {
    final json =
        await _api.get('/physio/patients/$patientId/plans') as List<dynamic>;
    return [
      for (final item in json)
        ExercisePlan.fromJson(item as Map<String, dynamic>),
    ];
  }
}
