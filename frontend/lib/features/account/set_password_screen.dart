import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/common.dart';
import '../auth/auth_controller.dart';
import 'change_password_form.dart';

/// Shown to someone who signed in with a temporary password from an admin.
/// The router keeps them here until they have chosen their own: the only
/// other thing they can do is log out.
class SetPasswordScreen extends ConsumerWidget {
  const SetPasswordScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final user = ref.watch(currentUserProvider);

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Container(
              height: 64,
              padding: EdgeInsets.symmetric(horizontal: narrow ? 16 : 40),
              decoration: const BoxDecoration(
                color: AppColors.surface,
                border: Border(bottom: BorderSide(color: AppColors.divider)),
              ),
              child: Row(
                children: [
                  const PhysioAiLogo(),
                  const Spacer(),
                  TextButton(
                    key: const Key('set-password-sign-out'),
                    onPressed: () =>
                        ref.read(authControllerProvider.notifier).signOut(),
                    child: const Text('Log out'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.symmetric(
                  horizontal: narrow ? 16 : 40,
                  vertical: narrow ? 24 : 40,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: AppCard(
                      padding: EdgeInsets.all(narrow ? 20 : 32),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Container(
                              width: 48,
                              height: 48,
                              alignment: Alignment.center,
                              decoration: const BoxDecoration(
                                color: AppColors.primaryTint,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.lock_reset_rounded,
                                color: AppColors.primary,
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Choose your own password',
                            style: text.headlineSmall,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${user == null ? 'Welcome' : 'Welcome, ${user.account.firstName}'}. '
                            'You signed in with a temporary password from your clinic. '
                            'Replace it with one only you know to continue.',
                            style: text.bodyMedium?.copyWith(
                              color: AppColors.textMuted,
                            ),
                          ),
                          const SizedBox(height: 24),
                          const ChangePasswordForm(
                            currentLabel: 'Temporary password',
                            submitLabel: 'Save and Continue',
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
