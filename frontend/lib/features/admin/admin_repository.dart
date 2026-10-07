import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../auth/auth_models.dart';

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

  /// Plain-language description of the recorded action.
  String get description => switch (action) {
    'account.registered' =>
      'A patient registered and was linked to a physiotherapist',
    'account.seeded' => 'Demo ${detail['role'] ?? ''} account created',
    'invite_code.created' => 'A physiotherapist generated an invite code',
    'auth.lockout' => 'Sign-in paused after repeated unsuccessful attempts',
    'auth.refresh_token_reuse' =>
      'A session was ended after a reused refresh token',
    _ => action,
  };
}

final adminRepositoryProvider = Provider<AdminRepository>(
  (ref) => AdminRepository(ref.watch(apiClientProvider)),
);

final adminUsersProvider = FutureProvider.autoDispose<List<Account>>(
  (ref) => ref.watch(adminRepositoryProvider).users(),
);

final auditLogProvider = FutureProvider.autoDispose<List<AuditEntry>>(
  (ref) => ref.watch(adminRepositoryProvider).auditLog(),
);

class AdminRepository {
  AdminRepository(this._api);

  final ApiClient _api;

  Future<List<Account>> users() async {
    final json = await _api.get('/admin/users') as List<dynamic>;
    return [
      for (final item in json) Account.fromJson(item as Map<String, dynamic>),
    ];
  }

  Future<List<AuditEntry>> auditLog({int limit = 50}) async {
    final json =
        await _api.get('/admin/audit-log?limit=$limit') as List<dynamic>;
    return [
      for (final item in json)
        AuditEntry.fromJson(item as Map<String, dynamic>),
    ];
  }
}
