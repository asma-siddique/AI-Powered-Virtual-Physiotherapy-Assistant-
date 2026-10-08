import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/common.dart';
import '../auth_controller.dart';
import '../auth_models.dart';
import 'auth_scaffold.dart';

/// Step one of signing in: choose a role. The sign-in form (and, for patients,
/// account creation) is on the next screen.
class ChooseRoleScreen extends ConsumerStatefulWidget {
  const ChooseRoleScreen({super.key});

  @override
  ConsumerState<ChooseRoleScreen> createState() => _ChooseRoleScreenState();
}

class _ChooseRoleScreenState extends ConsumerState<ChooseRoleScreen> {
  String? _notice;

  static const _descriptions = {
    UserRole.patient: 'Do your assigned exercises with real-time AI feedback.',
    UserRole.physiotherapist: 'Manage patients, plans and session reviews.',
    UserRole.admin: 'Manage users, roles and system activity.',
  };

  @override
  void initState() {
    super.initState();
    // Set when the server ended the previous session, e.g. after an idle timeout.
    final state = ref.read(authControllerProvider);
    if (state is SignedOut) _notice = state.notice;
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AuthScaffold(
      maxWidth: 920,
      child: Column(
        children: [
          Text(
            'Choose your role',
            style: text.headlineMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Select how you use PhysioAI to continue.',
            style: text.bodyMedium?.copyWith(color: AppColors.textMuted),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          if (_notice != null) ...[
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: InlineBanner(message: _notice!, tone: BannerTone.info),
            ),
            const SizedBox(height: 24),
          ],
          LayoutBuilder(
            builder: (context, constraints) {
              final cards = [
                for (final role in UserRole.values)
                  _RoleCard(
                    role: role,
                    description: _descriptions[role]!,
                    onTap: () => context.go('/sign-in/${role.apiValue}'),
                  ),
              ];
              if (constraints.maxWidth < 720) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final card in cards)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: card,
                      ),
                  ],
                );
              }
              return IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < cards.length; i++) ...[
                      if (i > 0) const SizedBox(width: 16),
                      Expanded(child: cards[i]),
                    ],
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({
    required this.role,
    required this.description,
    required this.onTap,
  });

  final UserRole role;
  final String description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Semantics(
      button: true,
      label: 'Login as ${role.label}',
      child: Material(
        color: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: Key('role-${role.apiValue}'),
          onTap: onTap,
          hoverColor: role.tint,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: role.tint,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(role.icon, color: role.accent, size: 26),
                ),
                const SizedBox(height: 20),
                ExcludeSemantics(
                  child: Text(
                    'Login as ${role.label}',
                    style: text.titleMedium,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: text.bodySmall?.copyWith(color: AppColors.textMuted),
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        role == UserRole.patient
                            ? 'Sign in or create an account'
                            : 'Sign in',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: role.accent,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      Icons.arrow_forward_rounded,
                      size: 18,
                      color: role.accent,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
