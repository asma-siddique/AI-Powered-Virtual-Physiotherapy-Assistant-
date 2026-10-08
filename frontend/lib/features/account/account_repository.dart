import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../auth/auth_models.dart';

/// One place this account is signed in.
class Device {
  const Device({
    required this.id,
    required this.name,
    required this.signedInAt,
    required this.lastActiveAt,
    required this.current,
    this.ip,
  });

  factory Device.fromJson(Map<String, dynamic> json) => Device(
    id: json['id'] as String,
    name: json['device'] as String,
    signedInAt: DateTime.parse(json['created_at'] as String),
    lastActiveAt: DateTime.parse(json['last_seen_at'] as String),
    current: json['current'] as bool,
    ip: json['ip'] as String?,
  );

  final String id;

  /// For example "Chrome on Windows".
  final String name;
  final DateTime signedInAt;
  final DateTime lastActiveAt;

  /// The device this app is running on.
  final bool current;
  final String? ip;
}

final accountRepositoryProvider = Provider<AccountRepository>(
  (ref) => AccountRepository(ref.watch(apiClientProvider)),
);

/// Every device the signed-in account can still be used from.
final devicesProvider = FutureProvider.autoDispose<List<Device>>(
  (ref) => ref.watch(accountRepositoryProvider).devices(),
);

/// The signed-in person's own password and devices.
class AccountRepository {
  AccountRepository(this._api);

  final ApiClient _api;

  /// Replaces the password. Every other device is signed out by the server.
  Future<SessionUser> changePassword({
    required String current,
    required String next,
  }) async => SessionUser.fromJson(
    await _api.post(
          '/auth/change-password',
          body: {'current_password': current, 'new_password': next},
        )
        as Map<String, dynamic>,
  );

  Future<List<Device>> devices() async {
    final json = await _api.get('/auth/sessions') as List<dynamic>;
    return [
      for (final item in json) Device.fromJson(item as Map<String, dynamic>),
    ];
  }

  Future<void> signOutDevice(String id) => _api.delete('/auth/sessions/$id');

  /// Returns how many other devices were signed out.
  Future<int> signOutOtherDevices() async {
    final json =
        await _api.post('/auth/sessions/revoke-others') as Map<String, dynamic>;
    return json['signed_out'] as int;
  }
}
