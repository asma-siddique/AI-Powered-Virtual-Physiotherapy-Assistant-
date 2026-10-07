import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/common.dart';
import '../auth/auth_models.dart';
import '../shell/page_widgets.dart';
import 'admin_repository.dart';

class AdminOverviewPage extends ConsumerWidget {
  const AdminOverviewPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final users = ref.watch(adminUsersProvider);
    final audit = ref.watch(auditLogProvider);
    String count(UserRole? role) {
      final list = users.valueOrNull;
      if (list == null) return '-';
      return (role == null
              ? list.length
              : list.where((u) => u.role == role).length)
          .toString();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageIntro(
          title: 'System overview',
          subtitle: 'Accounts and recent activity across PhysioAI.',
        ),
        ResponsiveRow(
          breakpoint: 900,
          children: [
            StatCard(
              icon: Icons.group_outlined,
              value: count(null),
              label: 'Total users',
            ),
            StatCard(
              icon: UserRole.patient.icon,
              value: count(UserRole.patient),
              label: 'Patients',
              accent: UserRole.patient.accent,
            ),
            StatCard(
              icon: UserRole.physiotherapist.icon,
              value: count(UserRole.physiotherapist),
              label: 'Physiotherapists',
              accent: UserRole.physiotherapist.accent,
            ),
            StatCard(
              icon: UserRole.admin.icon,
              value: count(UserRole.admin),
              label: 'Admins',
              accent: UserRole.admin.accent,
            ),
          ],
        ),
        const SizedBox(height: 24),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Recent activity',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  TextButton(
                    onPressed: () => context.go('/admin/audit-log'),
                    child: const Text('View full audit log'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              AsyncSection(
                value: audit,
                onRetry: () => ref.invalidate(auditLogProvider),
                builder: (entries) => entries.isEmpty
                    ? const EmptyState(
                        icon: Icons.history_rounded,
                        message: 'No activity has been recorded yet.',
                      )
                    : Column(
                        children: [
                          for (final entry in entries.take(6))
                            _AuditRow(entry: entry),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AuditRow extends StatelessWidget {
  const _AuditRow({required this.entry});

  final AuditEntry entry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.divider)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(
              Icons.fiber_manual_record,
              size: 10,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.description,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  entry.action,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            formatDateTime(entry.createdAt),
            style: const TextStyle(fontSize: 13, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}

class AdminUsersPage extends ConsumerWidget {
  const AdminUsersPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final users = ref.watch(adminUsersProvider);
    return AppCard(
      child: AsyncSection(
        value: users,
        onRetry: () => ref.invalidate(adminUsersProvider),
        builder: (accounts) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${accounts.length} user${accounts.length == 1 ? '' : 's'}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              'Creating, deactivating and reassigning accounts arrives with user management.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
            ),
            const SizedBox(height: 8),
            for (final account in accounts)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: AppColors.divider)),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: account.role.tint,
                      child: Text(
                        account.initials,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: account.role.accent,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            account.fullName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            account.contact,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Pill(
                      account.role.label,
                      foreground: account.role.accent,
                      background: account.role.tint,
                    ),
                    const SizedBox(width: 12),
                    account.isActive
                        ? const Pill.success('Active')
                        : const Pill.neutral('Deactivated'),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class AdminAuditLogPage extends ConsumerWidget {
  const AdminAuditLogPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final audit = ref.watch(auditLogProvider);
    return AppCard(
      child: AsyncSection(
        value: audit,
        onRetry: () => ref.invalidate(auditLogProvider),
        builder: (entries) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'A read-only record of account and access activity.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            if (entries.isEmpty)
              const Center(
                child: EmptyState(
                  icon: Icons.history_rounded,
                  message: 'No activity has been recorded yet.',
                ),
              )
            else
              for (final entry in entries) _AuditRow(entry: entry),
          ],
        ),
      ),
    );
  }
}
