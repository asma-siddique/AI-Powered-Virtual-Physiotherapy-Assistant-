import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import 'api_exception.dart';
import 'token_store.dart';

final tokenStoreProvider = Provider<TokenStore>((ref) => SecureTokenStore());

final apiClientProvider = Provider<ApiClient>((ref) {
  final client = ApiClient(
    baseUrl: apiBaseUrl,
    tokens: ref.watch(tokenStoreProvider),
  );
  ref.onDispose(client.close);
  return client;
});

class ApiClient {
  ApiClient({
    required this.baseUrl,
    required this.tokens,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final String baseUrl;
  final TokenStore tokens;
  final http.Client _http;

  /// Called when the server says the session can no longer be used (signed out
  /// elsewhere, idle too long, account deactivated).
  void Function(ApiException reason)? onSessionEnded;

  Future<bool>? _refreshing;

  Future<dynamic> get(String path, {bool auth = true}) =>
      _send('GET', path, auth: auth);

  Future<dynamic> post(String path, {Object? body, bool auth = true}) =>
      _send('POST', path, body: body, auth: auth);

  Future<dynamic> patch(String path, {Object? body}) =>
      _send('PATCH', path, body: body);

  Future<dynamic> delete(String path) => _send('DELETE', path);

  void close() => _http.close();

  Future<dynamic> _send(
    String method,
    String path, {
    Object? body,
    bool auth = true,
    bool retried = false,
  }) async {
    final request = http.Request(method, Uri.parse('$baseUrl$path'))
      ..headers['Accept'] = 'application/json';
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    if (auth) {
      final current = await tokens.read();
      if (current != null) {
        request.headers['Authorization'] = 'Bearer ${current.accessToken}';
      }
    }

    final http.Response response;
    try {
      response = await _http
          .send(request)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      throw _unreachable();
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return response.bodyBytes.isEmpty
          ? null
          : jsonDecode(utf8.decode(response.bodyBytes));
    }

    final error = ApiException.fromResponse(response);
    if (auth && response.statusCode == 401) {
      if (!retried && error.code == 'token_expired' && await _refresh()) {
        return _send(method, path, body: body, auth: auth, retried: true);
      }
      await tokens.clear();
      onSessionEnded?.call(error);
    }
    throw error;
  }

  ApiException _unreachable() {
    if (!kDebugMode) return ApiException.network;
    // While developing, the usual cause is simply that the API is not running,
    // so say where the app was looking.
    return ApiException(
      code: ApiException.network.code,
      message:
          '${ApiException.network.message} '
          'Developer note: nothing answered at $baseUrl. Is the backend running?',
    );
  }

  /// Swaps the refresh token for a new pair. Concurrent callers share one request,
  /// because a refresh token can only be used once.
  Future<bool> _refresh() =>
      _refreshing ??= _doRefresh().whenComplete(() => _refreshing = null);

  Future<bool> _doRefresh() async {
    final current = await tokens.read();
    if (current == null) return false;
    try {
      final json = await _send(
        'POST',
        '/auth/refresh',
        body: {'refresh_token': current.refreshToken},
        auth: false,
      );
      await tokens.write(AuthTokens.fromJson(json as Map<String, dynamic>));
      return true;
    } on ApiException catch (error) {
      // Being offline is not the same as being signed out: keep the session.
      if (error.code == ApiException.network.code) rethrow;
      return false;
    }
  }
}
