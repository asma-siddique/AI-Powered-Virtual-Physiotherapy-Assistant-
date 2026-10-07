import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import '../../core/api/token_store.dart';
import 'auth_models.dart';

final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepository(ref.watch(apiClientProvider)),
);

class AuthRepository {
  AuthRepository(this._api);

  final ApiClient _api;

  Future<SessionUser> signIn({
    required String identifier,
    required String password,
    required UserRole role,
  }) => _authenticate('/auth/login', {
    'identifier': identifier,
    'password': password,
    'role': role.apiValue,
  });

  Future<SessionUser> register({
    required String fullName,
    required String identifier,
    required String password,
    required String inviteCode,
  }) => _authenticate('/auth/register', {
    'full_name': fullName,
    'identifier': identifier,
    'password': password,
    'invite_code': inviteCode,
  });

  /// The session saved on this device, or null when nobody is signed in.
  Future<SessionUser?> restore() async {
    if (await _api.tokens.read() == null) return null;
    try {
      return SessionUser.fromJson(
        await _api.get('/auth/me') as Map<String, dynamic>,
      );
    } on ApiException catch (error) {
      if (error.statusCode == 401) return null;
      rethrow;
    }
  }

  Future<void> signOut() async {
    try {
      await _api.post('/auth/logout');
    } on ApiException {
      // Signing out locally must always work, even offline or with a dead session.
    }
    await _api.tokens.clear();
  }

  Future<SessionUser> _authenticate(
    String path,
    Map<String, dynamic> body,
  ) async {
    final json =
        await _api.post(path, body: body, auth: false) as Map<String, dynamic>;
    await _api.tokens.write(
      AuthTokens.fromJson(json['tokens'] as Map<String, dynamic>),
    );
    return SessionUser.fromJson(json);
  }
}
