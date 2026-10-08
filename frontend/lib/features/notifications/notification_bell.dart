import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_exception.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/common.dart';
import '../patient/patient_repository.dart';
import 'notifications_repository.dart';

/// Bell with an unread count. Checks for new notifications once a minute, which
/// is how a plan change reaches a patient who already has the app open.
class NotificationBell extends ConsumerStatefulWidget {
  const NotificationBell({super.key});

  @override
  ConsumerState<NotificationBell> createState() => _NotificationBellState();
}

class _NotificationBellState extends ConsumerState<NotificationBell> {
  static const _refreshEvery = Duration(seconds: 60);

  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(
      _refreshEvery,
      (_) => ref.invalidate(notificationsProvider),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _open() async {
    ref.invalidate(notificationsProvider);
    final link = await showDialog<String>(
      context: context,
      builder: (context) => const _NotificationsDialog(),
    );
    if (link != null && mounted) context.go(link);
  }

  @override
  Widget build(BuildContext context) {
    // A newly arrived plan notice means the plan on screen may be out of date.
    ref.listen(notificationsProvider, (previous, next) {
      final seen = {
        for (final n in previous?.valueOrNull?.items ?? const []) n.id,
      };
      final arrived = (next.valueOrNull?.items ?? const <AppNotification>[])
          .where((n) => !seen.contains(n.id) && n.kind == 'plan_assigned');
      if (previous?.valueOrNull != null && arrived.isNotEmpty) {
        ref.invalidate(patientPlanProvider);
      }
    });

    final unread =
        ref.watch(notificationsProvider).valueOrNull?.unreadCount ?? 0;
    return IconButton(
      key: const Key('notification-bell'),
      tooltip: unread == 0
          ? 'Notifications'
          : '$unread unread notification${unread == 1 ? '' : 's'}',
      onPressed: _open,
      icon: Badge(
        isLabelVisible: unread > 0,
        label: Text('$unread', key: const Key('notification-count')),
        backgroundColor: AppColors.primary,
        child: const Icon(Icons.notifications_none_rounded),
      ),
    );
  }
}

class _NotificationsDialog extends ConsumerStatefulWidget {
  const _NotificationsDialog();

  @override
  ConsumerState<_NotificationsDialog> createState() =>
      _NotificationsDialogState();
}

class _NotificationsDialogState extends ConsumerState<_NotificationsDialog> {
  String? _error;

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
      ref.invalidate(notificationsProvider);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    }
  }

  Future<void> _openItem(AppNotification item) async {
    final repository = ref.read(notificationsRepositoryProvider);
    if (item.isUnread) await _run(() => repository.markRead(item.id));
    // Close with the destination; the bell does the navigating.
    if (mounted && item.link != null) Navigator.of(context).pop(item.link);
  }

  @override
  Widget build(BuildContext context) {
    final feed = ref.watch(notificationsProvider);
    final text = Theme.of(context).textTheme;
    final unread = feed.valueOrNull?.unreadCount ?? 0;

    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text('Notifications', style: text.titleLarge),
                  ),
                  if (unread > 0)
                    TextButton(
                      key: const Key('notifications-read-all'),
                      onPressed: () => _run(
                        ref.read(notificationsRepositoryProvider).markAllRead,
                      ),
                      child: const Text('Mark all as read'),
                    ),
                  IconButton(
                    tooltip: 'Close',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                InlineBanner(message: _error!),
              ],
              const SizedBox(height: 8),
              Flexible(
                child: feed.when(
                  skipLoadingOnRefresh: true,
                  loading: () => const Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  error: (error, _) => InlineBanner(
                    message: error is ApiException
                        ? error.message
                        : 'Could not load your notifications.',
                  ),
                  data: (feed) => feed.items.isEmpty
                      ? const EmptyState(
                          icon: Icons.notifications_none_rounded,
                          message: 'You have no notifications.',
                        )
                      : ListView.separated(
                          shrinkWrap: true,
                          itemCount: feed.items.length,
                          separatorBuilder: (_, _) => const Divider(
                            height: 1,
                            color: AppColors.divider,
                          ),
                          itemBuilder: (context, index) => _NotificationTile(
                            item: feed.items[index],
                            onTap: () => _openItem(feed.items[index]),
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({required this.item, required this.onTap});

  final AppNotification item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: Key('notification-${item.id}'),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 6, right: 10),
              child: Icon(
                Icons.circle,
                size: 8,
                color: item.isUnread ? AppColors.primary : Colors.transparent,
                semanticLabel: item.isUnread ? 'Unread' : null,
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: item.isUnread
                          ? FontWeight.w600
                          : FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    item.body,
                    style: const TextStyle(
                      fontSize: 14,
                      height: 1.4,
                      color: AppColors.textMuted,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    formatDateTime(item.createdAt),
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            if (item.link != null)
              const Padding(
                padding: EdgeInsets.only(top: 4, left: 8),
                child: Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: AppColors.textMuted,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
