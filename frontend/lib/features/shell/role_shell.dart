import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/common.dart';
import '../auth/auth_controller.dart';
import '../auth/auth_models.dart';

class NavItem {
  const NavItem(this.label, this.icon, this.path);

  final String label;
  final IconData icon;
  final String path;
}

/// One navigation list per role, shared by the sidebar and the router.
const navigationByRole = <UserRole, List<NavItem>>{
  UserRole.patient: [
    NavItem('Home', Icons.home_outlined, '/patient'),
    NavItem('My Exercise Plan', Icons.assignment_outlined, '/patient/plan'),
    NavItem('Session History', Icons.history_rounded, '/patient/history'),
    NavItem('Progress', Icons.trending_up_rounded, '/patient/progress'),
    NavItem('Chat', Icons.chat_bubble_outline_rounded, '/patient/chat'),
    NavItem('Feedback', Icons.rate_review_outlined, '/patient/feedback'),
  ],
  UserRole.physiotherapist: [
    NavItem('Dashboard', Icons.dashboard_outlined, '/physio'),
    NavItem('Patients', Icons.groups_outlined, '/physio/patients'),
    NavItem('Plan Builder', Icons.assignment_outlined, '/physio/plan-builder'),
    NavItem('Flagged Sessions', Icons.flag_outlined, '/physio/flagged'),
    NavItem('Chat', Icons.chat_bubble_outline_rounded, '/physio/chat'),
    NavItem('Patient Feedback', Icons.rate_review_outlined, '/physio/feedback'),
  ],
  UserRole.admin: [
    NavItem('Overview', Icons.dashboard_outlined, '/admin'),
    NavItem('Users & Roles', Icons.manage_accounts_outlined, '/admin/users'),
    NavItem('Patient Feedback', Icons.rate_review_outlined, '/admin/feedback'),
    NavItem('Audit Log', Icons.history_rounded, '/admin/audit-log'),
  ],
};

/// Signed-in page frame: sidebar and top bar on wide screens, drawer on narrow ones.
class RoleShell extends ConsumerWidget {
  const RoleShell({
    super.key,
    required this.role,
    required this.location,
    required this.child,
  });

  final UserRole role;
  final String location;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider);
    // For one frame after signing out the shell is still mounted with no user.
    if (auth is! SignedIn) return const Scaffold(body: SizedBox.shrink());
    final account = auth.user.account;

    final items = navigationByRole[role]!;
    final active = items
        .where(
          (item) =>
              location == item.path || location.startsWith('${item.path}/'),
        )
        .fold<NavItem>(
          items.first,
          (best, item) => item.path.length > best.path.length ? item : best,
        );
    final wide = MediaQuery.sizeOf(context).width >= 1000;

    final sidebar = _Sidebar(
      role: role,
      items: items,
      active: active,
      account: account,
      onNavigate: (item) {
        if (!wide) Navigator.of(context).pop();
        context.go(item.path);
      },
      onSignOut: () => ref.read(authControllerProvider.notifier).signOut(),
    );

    final content = SingleChildScrollView(
      padding: EdgeInsets.all(wide ? 40 : 16),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1200),
          child: child,
        ),
      ),
    );

    if (!wide) {
      return Scaffold(
        appBar: AppBar(
          title: Text(
            active.label,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          shape: const Border(bottom: BorderSide(color: AppColors.divider)),
        ),
        drawer: Drawer(child: SafeArea(child: sidebar)),
        body: content,
      );
    }

    return Scaffold(
      body: Row(
        children: [
          SizedBox(width: 256, child: sidebar),
          Expanded(
            child: Column(
              children: [
                Container(
                  height: 64,
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  decoration: const BoxDecoration(
                    color: AppColors.surface,
                    border: Border(
                      bottom: BorderSide(color: AppColors.divider),
                    ),
                  ),
                  child: Row(
                    children: [
                      Text(
                        active.label,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const Spacer(),
                      _Avatar(account: account, role: role),
                      const SizedBox(width: 10),
                      Text(
                        account.fullName,
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ],
                  ),
                ),
                Expanded(child: content),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.account, required this.role});

  final Account account;
  final UserRole role;

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: 18,
      backgroundColor: role.tint,
      child: Text(
        account.initials,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: role.accent,
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.role,
    required this.items,
    required this.active,
    required this.account,
    required this.onNavigate,
    required this.onSignOut,
  });

  final UserRole role;
  final List<NavItem> items;
  final NavItem active;
  final Account account;
  final ValueChanged<NavItem> onNavigate;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(right: BorderSide(color: AppColors.divider)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const PhysioAiLogo(size: 30),
                const SizedBox(height: 10),
                Pill(
                  role.label,
                  foreground: role.accent,
                  background: role.tint,
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                for (final item in items)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: _NavTile(
                      item: item,
                      selected: item == active,
                      onTap: () => onNavigate(item),
                    ),
                  ),
              ],
            ),
          ),
          const Divider(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                _Avatar(account: account, role: role),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        account.fullName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        role.label,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          _NavTile(
            key: const Key('sign-out'),
            item: const NavItem('Log out', Icons.logout_rounded, ''),
            selected: false,
            onTap: onSignOut,
          ),
        ],
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({
    super.key,
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final NavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.primary : AppColors.text;
    return Material(
      color: selected ? AppColors.primaryTint : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(
            children: [
              Icon(
                item.icon,
                size: 20,
                color: selected ? AppColors.primary : AppColors.textMuted,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  item.label,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: color,
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
