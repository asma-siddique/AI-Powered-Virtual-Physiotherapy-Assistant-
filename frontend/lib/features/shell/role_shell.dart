import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_backdrop.dart';
import '../../core/widgets/common.dart';
import '../auth/auth_controller.dart';
import '../auth/auth_models.dart';
import '../exercises/exercise_models.dart';
import '../notifications/notification_bell.dart';
import '../patient/patient_repository.dart';
import 'page_widgets.dart';

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
    NavItem('Help', Icons.help_outline_rounded, '/patient/help'),
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
    NavItem(
      'Exercise Library',
      Icons.fitness_center_outlined,
      '/admin/exercises',
    ),
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
    final wide = MediaQuery.sizeOf(context).width >= shellWideBreakpoint;
    // Account & Security belongs to the person, not to the role's menu.
    final securityPath = '${role.homePath}/security';
    final onSecurity = location == securityPath;
    final title = onSecurity ? 'Account & Security' : active.label;

    final sidebar = _Sidebar(
      role: role,
      items: items,
      active: onSecurity ? null : active,
      account: account,
      securitySelected: onSecurity,
      onNavigate: (item) {
        if (!wide) Navigator.of(context).pop();
        context.go(item.path);
      },
      onOpenSecurity: () {
        if (!wide) Navigator.of(context).pop();
        context.go(securityPath);
      },
      onSignOut: () => ref.read(authControllerProvider.notifier).signOut(),
    );

    // The physiotherapist's portal wears navy: clinical, set apart from the
    // patient's teal.
    final clinical = role == UserRole.physiotherapist;
    final barColor = clinical ? AppColors.navy : AppColors.surface;
    final onBar = clinical ? Colors.white : AppColors.text;
    final barIcons = clinical ? Colors.white : AppColors.primary;
    Widget bell() => IconButtonTheme(
      data: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: barIcons),
      ),
      child: const NotificationBell(),
    );

    if (!wide) {
      return Scaffold(
        appBar: AppBar(
          backgroundColor: barColor,
          foregroundColor: onBar,
          iconTheme: IconThemeData(color: barIcons),
          title: Text(
            title,
            style: AppTheme.headingMedium.copyWith(color: onBar),
          ),
          actions: [bell(), const SizedBox(width: 8)],
          shape: Border(
            bottom: BorderSide(
              color: clinical ? AppColors.navy : AppColors.divider,
            ),
          ),
        ),
        drawer: Drawer(child: SafeArea(child: sidebar)),
        body: AppBackdrop(child: child),
        bottomNavigationBar: role == UserRole.patient
            ? _PatientNavBar(location: location)
            : null,
      );
    }

    return Scaffold(
      body: AppBackdrop(
        child: Row(
          children: [
            SizedBox(width: 256, child: sidebar),
            Expanded(
              child: Column(
                children: [
                  Container(
                    height: 64,
                    padding: const EdgeInsets.symmetric(horizontal: 40),
                    decoration: BoxDecoration(
                      // Frosted rather than solid, so the page's colour
                      // carries on behind the bar.
                      color: clinical ? null : barColor.withValues(alpha: 0.55),
                      gradient: clinical ? AppColors.cardGradient : null,
                      border: Border(
                        bottom: BorderSide(
                          color: clinical ? AppColors.navy : AppColors.divider,
                        ),
                      ),
                    ),
                    child: Row(
                      children: [
                        Text(
                          title,
                          style: AppTheme.headingMedium.copyWith(color: onBar),
                        ),
                        const Spacer(),
                        bell(),
                        const SizedBox(width: 8),
                        Tooltip(
                          message: 'Account & security',
                          child: InkWell(
                            key: const Key('open-account'),
                            borderRadius: BorderRadius.circular(8),
                            onTap: () => context.go(securityPath),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 4,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _Avatar(account: account, role: role),
                                  const SizedBox(width: 10),
                                  Text(
                                    account.fullName,
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelLarge
                                        ?.copyWith(color: onBar),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(child: child),
                ],
              ),
            ),
          ],
        ),
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
    return Container(
      width: 36,
      height: 36,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: role.accent,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: [
          BoxShadow(
            color: role.accent.withValues(alpha: 0.3),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Text(
        account.initials,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: Colors.white,
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
    required this.securitySelected,
    required this.onOpenSecurity,
    required this.onSignOut,
  });

  final UserRole role;
  final List<NavItem> items;

  /// Null while the page on screen is not one of the menu's own.
  final NavItem? active;
  final Account account;
  final ValueChanged<NavItem> onNavigate;
  final bool securitySelected;
  final VoidCallback onOpenSecurity;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface.withValues(alpha: 0.6),
        border: const Border(right: BorderSide(color: AppColors.divider)),
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
                      accent: role.accent,
                      tint: role.tint,
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
            key: const Key('account-security'),
            item: const NavItem(
              'Account & Security',
              Icons.shield_outlined,
              '',
            ),
            selected: securitySelected,
            accent: role.accent,
            tint: role.tint,
            onTap: onOpenSecurity,
          ),
          const SizedBox(height: 4),
          _NavTile(
            key: const Key('sign-out'),
            item: const NavItem('Log out', Icons.logout_rounded, ''),
            selected: false,
            accent: role.accent,
            tint: role.tint,
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
    required this.accent,
    required this.tint,
  });

  final NavItem item;
  final bool selected;
  final VoidCallback onTap;
  final Color accent;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    final color = selected ? accent : AppColors.text;
    return Material(
      color: selected ? tint : Colors.transparent,
      borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 3,
                height: 18,
                margin: const EdgeInsets.only(right: 9),
                decoration: BoxDecoration(
                  color: selected ? accent : Colors.transparent,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
              Icon(
                item.icon,
                size: 20,
                color: selected ? accent : AppColors.textMuted,
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

/// The patient's bottom navigation on a phone: four destinations and a
/// raised teal "Live" button in the middle that starts the next exercise.
class _PatientNavBar extends ConsumerWidget {
  const _PatientNavBar({required this.location});

  final String location;

  static const _items = [
    NavItem('Home', Icons.home_rounded, '/patient'),
    NavItem('Exercises', Icons.fitness_center_rounded, '/patient/plan'),
    NavItem('Progress', Icons.insights_rounded, '/patient/progress'),
    NavItem('Profile', Icons.person_outline_rounded, '/patient/security'),
  ];

  bool _active(NavItem item) => item.path == '/patient'
      ? location == item.path
      : location == item.path || location.startsWith('${item.path}/');

  void _goLive(BuildContext context, WidgetRef ref) {
    final plan = ref.read(patientPlanProvider).valueOrNull;
    for (final item in plan?.items ?? const <PlanItem>[]) {
      if (item.exercise.isActive) {
        context.go('/patient/session/${item.id}');
        return;
      }
    }
    context.go('/patient/plan');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Widget tab(NavItem item) {
      final active = _active(item);
      final color = active ? AppColors.primary : AppColors.textHint;
      return Expanded(
        child: InkResponse(
          onTap: () => context.go(item.path),
          radius: 32,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(item.icon, color: color, size: 24),
              const SizedBox(height: 3),
              Text(
                item.label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                  color: color,
                ),
              ),
              const SizedBox(height: 3),
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: active ? 5 : 0,
                height: 5,
                decoration: const BoxDecoration(
                  color: AppColors.primary,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        boxShadow: [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 16,
            offset: Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 72,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Row(
                children: [
                  tab(_items[0]),
                  tab(_items[1]),
                  const SizedBox(width: 76),
                  tab(_items[2]),
                  tab(_items[3]),
                ],
              ),
              Positioned(
                top: -20,
                child: Column(
                  children: [
                    Tooltip(
                      message: 'Start a live session',
                      child: Material(
                        color: Colors.transparent,
                        shape: const CircleBorder(),
                        child: InkWell(
                          key: const Key('nav-live'),
                          customBorder: const CircleBorder(),
                          onTap: () => _goLive(context, ref),
                          child: Ink(
                            width: 56,
                            height: 56,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: AppColors.heroGradient,
                              border: Border.all(color: Colors.white, width: 3),
                              boxShadow: AppTheme.elevatedShadow,
                            ),
                            child: const Icon(
                              Icons.videocam_rounded,
                              color: Colors.white,
                              size: 26,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Live',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
