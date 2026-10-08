import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';

class AppNotification {
  const AppNotification({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.createdAt,
    this.link,
    this.readAt,
  });

  factory AppNotification.fromJson(Map<String, dynamic> json) =>
      AppNotification(
        id: json['id'] as String,
        kind: json['kind'] as String,
        title: json['title'] as String,
        body: json['body'] as String,
        link: json['link'] as String?,
        createdAt: DateTime.parse(json['created_at'] as String),
        readAt: DateTime.tryParse(json['read_at'] as String? ?? ''),
      );

  final String id;
  final String kind;
  final String title;
  final String body;

  /// Where in the app this notification leads, when it leads anywhere.
  final String? link;
  final DateTime createdAt;
  final DateTime? readAt;

  bool get isUnread => readAt == null;
}

class NotificationFeed {
  const NotificationFeed({required this.unreadCount, required this.items});

  factory NotificationFeed.fromJson(Map<String, dynamic> json) =>
      NotificationFeed(
        unreadCount: json['unread_count'] as int,
        items: [
          for (final item in json['items'] as List<dynamic>)
            AppNotification.fromJson(item as Map<String, dynamic>),
        ],
      );

  static const empty = NotificationFeed(unreadCount: 0, items: []);

  final int unreadCount;
  final List<AppNotification> items;
}

final notificationsRepositoryProvider = Provider<NotificationsRepository>(
  (ref) => NotificationsRepository(ref.watch(apiClientProvider)),
);

final notificationsProvider = FutureProvider.autoDispose<NotificationFeed>(
  (ref) => ref.watch(notificationsRepositoryProvider).feed(),
);

class NotificationsRepository {
  NotificationsRepository(this._api);

  final ApiClient _api;

  Future<NotificationFeed> feed() async => NotificationFeed.fromJson(
    await _api.get('/notifications') as Map<String, dynamic>,
  );

  Future<void> markRead(String id) => _api.post('/notifications/$id/read');

  Future<void> markAllRead() => _api.post('/notifications/read-all');
}
