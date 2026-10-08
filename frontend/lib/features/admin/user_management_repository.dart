import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../auth/auth_models.dart';

/// An account as an admin sees it.
class ManagedUser {
  const ManagedUser({
    required this.account,
    this.mustChangePassword = false,
    this.lastSeenAt,
    this.physiotherapist,
    this.patientCount,
  });

  factory ManagedUser.fromJson(Map<String, dynamic> json) => ManagedUser(
    account: Account.fromJson(json),
    mustChangePassword: json['must_change_password'] as bool? ?? false,
    lastSeenAt: DateTime.tryParse(json['last_seen_at'] as String? ?? ''),
    physiotherapist: json['physiotherapist'] == null
        ? null
        : PersonRef.fromJson(json['physiotherapist'] as Map<String, dynamic>),
    patientCount: json['patient_count'] as int?,
  );

  final Account account;

  /// Still on the temporary password an admin issued.
  final bool mustChangePassword;

  /// When the account last used the app; null if it never has.
  final DateTime? lastSeenAt;

  /// Patients only.
  final PersonRef? physiotherapist;

  /// Physiotherapists only: active patients they are responsible for.
  final int? patientCount;

  String get id => account.id;
  String get fullName => account.fullName;
  UserRole get role => account.role;
  bool get isActive => account.isActive;
}

/// A new or reset account together with the password to hand over. The
/// password is shown once and is not available from the server again.
typedef IssuedPassword = ({ManagedUser user, String temporaryPassword});

final userManagementRepositoryProvider = Provider<UserManagementRepository>(
  (ref) => UserManagementRepository(ref.watch(apiClientProvider)),
);

/// Every account, in name order.
final managedUsersProvider = FutureProvider.autoDispose<List<ManagedUser>>(
  (ref) => ref.watch(userManagementRepositoryProvider).users(),
);

class UserManagementRepository {
  UserManagementRepository(this._api);

  final ApiClient _api;

  ManagedUser _user(dynamic json) =>
      ManagedUser.fromJson(json as Map<String, dynamic>);

  Future<List<ManagedUser>> users() async {
    final json = await _api.get('/admin/users') as List<dynamic>;
    return [for (final item in json) _user(item)];
  }

  Future<IssuedPassword> create({
    required String fullName,
    required String identifier,
    required UserRole role,
    String? physiotherapistId,
  }) async {
    final json =
        await _api.post(
              '/admin/users',
              body: {
                'full_name': fullName,
                'identifier': identifier,
                'role': role.apiValue,
                'physiotherapist_id': ?physiotherapistId,
              },
            )
            as Map<String, dynamic>;
    return (
      user: _user(json['user']),
      temporaryPassword: json['temporary_password'] as String,
    );
  }

  /// An empty [email] or [mobile] removes it from the account.
  Future<ManagedUser> update(
    String id, {
    required String fullName,
    required String email,
    required String mobile,
  }) async => _user(
    await _api.patch(
      '/admin/users/$id',
      body: {'full_name': fullName, 'email': email, 'mobile': mobile},
    ),
  );

  Future<ManagedUser> setActive(String id, {required bool active}) async =>
      _user(
        await _api.post(
          '/admin/users/$id/${active ? 'activate' : 'deactivate'}',
        ),
      );

  Future<ManagedUser> changeRole(String id, UserRole role) async => _user(
    await _api.post('/admin/users/$id/role', body: {'role': role.apiValue}),
  );

  Future<ManagedUser> reassign(String id, String physiotherapistId) async =>
      _user(
        await _api.post(
          '/admin/users/$id/reassign',
          body: {'physiotherapist_id': physiotherapistId},
        ),
      );

  /// Returns the new temporary password.
  Future<String> resetPassword(String id) async {
    final json =
        await _api.post('/admin/users/$id/reset-password')
            as Map<String, dynamic>;
    return json['temporary_password'] as String;
  }
}
