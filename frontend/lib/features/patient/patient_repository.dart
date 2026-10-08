import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../exercises/exercise_models.dart';

final patientRepositoryProvider = Provider<PatientRepository>(
  (ref) => PatientRepository(ref.watch(apiClientProvider)),
);

/// The plan currently assigned to the signed-in patient, or null.
final patientPlanProvider = FutureProvider.autoDispose<ExercisePlan?>(
  (ref) => ref.watch(patientRepositoryProvider).currentPlan(),
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
}
