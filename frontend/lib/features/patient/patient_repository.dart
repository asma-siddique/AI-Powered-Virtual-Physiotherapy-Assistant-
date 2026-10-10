import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../exercises/exercise_models.dart';
import '../session/precheck.dart';
import '../session/repetitions.dart';
import '../session/session_records.dart';

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

/// Every session the signed-in patient has finished, most recent first.
final patientSessionsProvider = FutureProvider.autoDispose<List<SessionBrief>>(
  (ref) => ref.watch(patientRepositoryProvider).sessions(),
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

  /// Stores one counted repetition of a session that is under way. Sending
  /// the same [repetition] again after a lost reply is safe: its key makes
  /// the server answer with the repetition it already stored.
  Future<RecordedRepetition> recordRepetition({
    required String sessionId,
    required RepetitionDraft repetition,
  }) async => RecordedRepetition.fromJson(
    await _api.post(
          '/patient/sessions/$sessionId/repetitions',
          body: repetition.toJson(),
        )
        as Map<String, dynamic>,
  );

  /// The session as the server holds it now: its totals, and its pause if it
  /// is paused.
  Future<ExerciseSession> session(String id) async => ExerciseSession.fromJson(
    await _api.get('/patient/sessions/$id') as Map<String, dynamic>,
  );

  /// Tells the server the patient has read the corrective message of the RED
  /// repetition that paused the session, which lets it carry on.
  Future<ExerciseSession> acknowledgePause({
    required String sessionId,
    required String repetitionId,
  }) async => ExerciseSession.fromJson(
    await _api.post(
          '/patient/sessions/$sessionId/acknowledge',
          body: {'repetition_id': repetitionId},
        )
        as Map<String, dynamic>,
  );

  /// The patient's finished sessions, most recent first, optionally for one
  /// exercise and for sessions started from [since] and before [until].
  Future<List<SessionBrief>> sessions({
    String? exerciseId,
    DateTime? since,
    DateTime? until,
  }) async {
    final query = {
      'exercise_id': ?exerciseId,
      'since': ?since?.toUtc().toIso8601String(),
      'until': ?until?.toUtc().toIso8601String(),
    };
    final path = Uri(
      path: '/patient/sessions',
      queryParameters: query.isEmpty ? null : query,
    );
    return [
      for (final item in await _api.get('$path') as List<dynamic>)
        SessionBrief.fromJson(item as Map<String, dynamic>),
    ];
  }

  /// One of the patient's sessions with every repetition in it.
  Future<SessionDetail> sessionDetail(String id) async =>
      SessionDetail.fromJson(
        await _api.get('/patient/sessions/$id/detail') as Map<String, dynamic>,
      );

  Future<ExerciseSession> endSession(String id) async =>
      ExerciseSession.fromJson(
        await _api.post('/patient/sessions/$id/end') as Map<String, dynamic>,
      );
}
