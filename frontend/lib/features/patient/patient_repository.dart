import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../exercises/exercise_models.dart';
import '../session/precheck.dart';

final patientRepositoryProvider = Provider<PatientRepository>(
  (ref) => PatientRepository(ref.watch(apiClientProvider)),
);

/// The plan currently assigned to the signed-in patient, or null.
final patientPlanProvider = FutureProvider.autoDispose<ExercisePlan?>(
  (ref) => ref.watch(patientRepositoryProvider).currentPlan(),
);

/// What the camera must show before a session with this exercise starts.
final precheckRequirementsProvider = FutureProvider.autoDispose
    .family<PrecheckRequirements, String>(
      (ref, itemId) =>
          ref.watch(patientRepositoryProvider).precheckRequirements(itemId),
    );

class PatientRepository {
  PatientRepository(this._api);

  final ApiClient _api;

  Future<ExercisePlan?> currentPlan() async {
    final json = await _api.get('/patient/plan');
    return json == null
        ? null
        : ExercisePlan.fromJson(json as Map<String, dynamic>);
  }

  Future<PrecheckRequirements> precheckRequirements(String itemId) async =>
      PrecheckRequirements.fromJson(
        await _api.get('/patient/plan/items/$itemId/precheck')
            as Map<String, dynamic>,
      );

  /// Starts a session. [evidence] is what the camera check measured; the
  /// server refuses to start unless it passes.
  Future<ExerciseSession> startSession({
    required String itemId,
    required Map<String, dynamic> evidence,
  }) async => ExerciseSession.fromJson(
    await _api.post(
          '/patient/sessions',
          body: {'plan_exercise_id': itemId, 'precheck': evidence},
        )
        as Map<String, dynamic>,
  );

  Future<ExerciseSession> endSession(String id) async =>
      ExerciseSession.fromJson(
        await _api.post('/patient/sessions/$id/end') as Map<String, dynamic>,
      );
}
