import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';

class DisclaimerPoint {
  const DisclaimerPoint({required this.heading, required this.body});

  factory DisclaimerPoint.fromJson(Map<String, dynamic> json) =>
      DisclaimerPoint(
        heading: json['heading'] as String,
        body: json['body'] as String,
      );

  final String heading;
  final String body;
}

/// The advisory wording, as served by the API. The app never keeps its own
/// copy, so the acknowledgment screen and the Help page cannot drift apart.
class Disclaimer {
  const Disclaimer({
    required this.version,
    required this.title,
    required this.intro,
    required this.points,
    required this.caution,
    required this.acknowledgment,
  });

  factory Disclaimer.fromJson(Map<String, dynamic> json) => Disclaimer(
    version: json['version'] as String,
    title: json['title'] as String,
    intro: json['intro'] as String,
    points: [
      for (final point in json['points'] as List<dynamic>)
        DisclaimerPoint.fromJson(point as Map<String, dynamic>),
    ],
    caution: json['caution'] as String,
    acknowledgment: json['acknowledgment'] as String,
  );

  final String version;
  final String title;
  final String intro;
  final List<DisclaimerPoint> points;
  final String caution;
  final String acknowledgment;
}

class ConsentStatus {
  const ConsentStatus({
    required this.disclaimer,
    required this.acknowledged,
    this.acknowledgedAt,
  });

  factory ConsentStatus.fromJson(Map<String, dynamic> json) => ConsentStatus(
    disclaimer: Disclaimer.fromJson(json['disclaimer'] as Map<String, dynamic>),
    acknowledged: json['acknowledged'] as bool,
    acknowledgedAt: DateTime.tryParse(json['acknowledged_at'] as String? ?? ''),
  );

  final Disclaimer disclaimer;
  final bool acknowledged;
  final DateTime? acknowledgedAt;
}

final consentRepositoryProvider = Provider<ConsentRepository>(
  (ref) => ConsentRepository(ref.watch(apiClientProvider)),
);

final consentStatusProvider = FutureProvider.autoDispose<ConsentStatus>(
  (ref) => ref.watch(consentRepositoryProvider).status(),
);

class ConsentRepository {
  ConsentRepository(this._api);

  final ApiClient _api;

  Future<ConsentStatus> status() async => ConsentStatus.fromJson(
    await _api.get('/patient/consent') as Map<String, dynamic>,
  );

  /// Records the patient's explicit acknowledgment of [version], the wording
  /// they were shown.
  Future<ConsentStatus> acknowledge(String version) async =>
      ConsentStatus.fromJson(
        await _api.post(
              '/patient/consent',
              body: {'version': version, 'acknowledged': true},
            )
            as Map<String, dynamic>,
      );
}
