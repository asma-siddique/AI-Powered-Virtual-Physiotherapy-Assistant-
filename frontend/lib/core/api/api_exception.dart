import 'dart:convert';

import 'package:http/http.dart' as http;

/// An error the UI can show as-is: [message] is written for the person using
/// the app, and [code] lets screens react to specific cases.
class ApiException implements Exception {
  const ApiException({
    required this.code,
    required this.message,
    this.statusCode,
    this.retryAfterSeconds,
  });

  final String code;
  final String message;
  final int? statusCode;
  final int? retryAfterSeconds;

  bool get isAccountLocked => code == 'account_locked';

  static const network = ApiException(
    code: 'network_error',
    message: 'Could not reach PhysioAI. Check your connection and try again.',
  );

  factory ApiException.fromResponse(http.Response response) {
    const fallback = 'Something went wrong. Please try again.';
    try {
      final detail =
          (jsonDecode(utf8.decode(response.bodyBytes))
              as Map<String, dynamic>)['detail'];
      if (detail is Map<String, dynamic>) {
        return ApiException(
          code: detail['code'] as String? ?? 'error',
          message: detail['message'] as String? ?? fallback,
          statusCode: response.statusCode,
          retryAfterSeconds: detail['retry_after_seconds'] as int?,
        );
      }
      if (detail is List && detail.isNotEmpty) {
        // Field validation errors from the API: show the first one.
        final message =
            (detail.first as Map<String, dynamic>)['msg'] as String? ??
            fallback;
        return ApiException(
          code: 'validation_error',
          message: message.replaceFirst('Value error, ', ''),
          statusCode: response.statusCode,
        );
      }
    } catch (_) {
      // Not JSON (for example a proxy error page): fall through to the generic message.
    }
    return ApiException(
      code: 'error',
      message: fallback,
      statusCode: response.statusCode,
    );
  }

  @override
  String toString() => 'ApiException($code, $statusCode): $message';
}
