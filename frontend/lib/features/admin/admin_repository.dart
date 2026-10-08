import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';

class AuditEntry {
  const AuditEntry({
    required this.id,
    required this.action,
    required this.createdAt,
    required this.detail,
    this.actorId,
    this.targetType,
  });

  factory AuditEntry.fromJson(Map<String, dynamic> json) => AuditEntry(
    id: json['id'] as int,
    action: json['action'] as String,
    createdAt: DateTime.parse(json['created_at'] as String),
    detail: (json['detail'] as Map<String, dynamic>?) ?? const {},
    actorId: json['actor_id'] as String?,
    targetType: json['target_type'] as String?,
  );

  final int id;
  final String action;
  final DateTime createdAt;
  final Map<String, dynamic> detail;
  final String? actorId;
  final String? targetType;

  String get _role => switch (detail['role']) {
    'patient' => 'patient',
    'physiotherapist' => 'physiotherapist',
    'admin' => 'admin',
    _ => 'user',
  };

  static String _roleName(Object? value) => switch (value) {
    'physiotherapist' => 'Physiotherapist',
    'admin' => 'Admin',
    'patient' => 'Patient',
    _ => 'another role',
  };

  /// Plain-language description of the recorded action.
  String get description => switch (action) {
    'account.registered' =>
      'A patient registered and was linked to a physiotherapist',
    'account.seeded' => 'Demo $_role account created',
    'account.created' => 'An admin created a $_role account',
    'account.updated' => "An admin corrected an account's details",
    'account.deactivated' => 'An admin deactivated a $_role account',
    'account.activated' => 'An admin reactivated a $_role account',
    'account.role_changed' =>
      'An admin changed a role from ${_roleName(detail['from'])} to ${_roleName(detail['to'])}',
    'account.password_reset' => 'An admin reset a password',
    'account.password_changed' => 'Someone changed their own password',
    'patient.reassigned' =>
      'An admin moved a patient to another physiotherapist',
    'invite_code.created' => 'A physiotherapist generated an invite code',
    'consent.acknowledged' => 'A patient acknowledged the advisory',
    'plan.assigned' => 'A physiotherapist assigned an exercise plan',
    'plan.prescription_edited' =>
      "A physiotherapist edited a patient's prescription",
    'exercise_template.created' => 'An admin added an exercise',
    'exercise_template.updated' =>
      "An admin edited an exercise's profile or thresholds",
    'exercise_template.activated' => 'An admin switched an exercise on',
    'exercise_template.deactivated' => 'An admin switched an exercise off',
    'auth.lockout' => 'Sign-in paused after repeated unsuccessful attempts',
    'auth.session_revoked' => 'Someone signed a device out of their account',
    'auth.refresh_token_reuse' =>
      'A session was ended after a reused refresh token',
    _ => action,
  };
}

final adminRepositoryProvider = Provider<AdminRepository>(
  (ref) => AdminRepository(ref.watch(apiClientProvider)),
);

final auditLogProvider = FutureProvider.autoDispose<List<AuditEntry>>(
  (ref) => ref.watch(adminRepositoryProvider).auditLog(),
);

class AdminRepository {
  AdminRepository(this._api);

  final ApiClient _api;

  Future<List<AuditEntry>> auditLog({int limit = 50}) async {
    final json =
        await _api.get('/admin/audit-log?limit=$limit') as List<dynamic>;
    return [
      for (final item in json)
        AuditEntry.fromJson(item as Map<String, dynamic>),
    ];
  }
}
