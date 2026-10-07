import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/common.dart';
import '../auth_controller.dart';
import '../auth_models.dart';
import '../validators.dart';
import 'auth_scaffold.dart';

/// "Choose Your Role": the single sign-in screen for all three roles.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _formKey = GlobalKey<FormState>();
  final _identifier = TextEditingController();
  final _password = TextEditingController();

  UserRole _role = UserRole.patient;
  bool _busy = false;
  ApiException? _error;
  String? _notice;

  static const _descriptions = {
    UserRole.patient: 'Do your assigned exercises with real-time AI feedback.',
    UserRole.physiotherapist: 'Manage patients, plans and session reviews.',
    UserRole.admin: 'Manage users, roles and system activity.',
  };

  @override
  void initState() {
    super.initState();
    final state = ref.read(authControllerProvider);
    if (state is SignedOut) _notice = state.notice;
  }

  @override
  void dispose() {
    _identifier.dispose();
    _password.dispose();
    super.dispose();
  }

  void _selectRole(UserRole role) => setState(() {
    _role = role;
    _error = null;
  });

  Future<void> _submit() async {
    if (_busy || !_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await ref
          .read(authControllerProvider.notifier)
          .signIn(
            identifier: _identifier.text.trim(),
            password: _password.text,
            role: _role,
          );
      // On success the router sends the user to their role's home.
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _busy = false;
      });
    }
  }

  void _forgotPassword() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset your password'),
        content: const Text(
          'Self-service password reset is not available yet. Ask your physiotherapist or '
          'clinic administrator to help you regain access.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AuthScaffold(
      maxWidth: 920,
      child: Column(
        children: [
          Text(
            'Welcome back',
            style: text.headlineMedium,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            'Choose how you want to sign in to PhysioAI.',
            style: text.bodyMedium?.copyWith(color: AppColors.textMuted),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          LayoutBuilder(
            builder: (context, constraints) {
              final cards = [
                for (final role in UserRole.values)
                  _RoleCard(
                    role: role,
                    description: _descriptions[role]!,
                    selected: role == _role,
                    onTap: _busy ? null : () => _selectRole(role),
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
          const SizedBox(height: 24),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: AppCard(
              child: AutofillGroup(
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Sign in as ${_role.label}',
                              style: text.titleLarge,
                            ),
                          ),
                          Pill(
                            _role.label,
                            foreground: _role.accent,
                            background: _role.tint,
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      if (_notice != null) ...[
                        InlineBanner(message: _notice!, tone: BannerTone.info),
                        const SizedBox(height: 16),
                      ],
                      if (_error != null) ...[
                        InlineBanner(
                          key: const Key('sign-in-error'),
                          message: _error!.message,
                          tone: _error!.isAccountLocked
                              ? BannerTone.warning
                              : BannerTone.error,
                        ),
                        const SizedBox(height: 16),
                      ],
                      LabeledField(
                        label: 'Email or mobile number',
                        child: TextFormField(
                          key: const Key('sign-in-identifier'),
                          controller: _identifier,
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.next,
                          autofillHints: const [AutofillHints.username],
                          validator: validateIdentifier,
                          decoration: const InputDecoration(
                            hintText: 'you@example.com',
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      LabeledField(
                        label: 'Password',
                        child: PasswordField(
                          fieldKey: const Key('sign-in-password'),
                          controller: _password,
                          textInputAction: TextInputAction.done,
                          autofillHints: const [AutofillHints.password],
                          validator: (value) =>
                              validateRequired(value, 'Enter your password.'),
                          onSubmitted: (_) => _submit(),
                        ),
                      ),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: _forgotPassword,
                          child: const Text('Forgot password?'),
                        ),
                      ),
                      const SizedBox(height: 4),
                      BusyButton(
                        key: const Key('sign-in-submit'),
                        label: 'Sign In',
                        busy: _busy,
                        onPressed: _submit,
                      ),
                      const SizedBox(height: 16),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(
                            Icons.lock_outline_rounded,
                            size: 16,
                            color: AppColors.textMuted,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _role == UserRole.patient
                                  ? 'Your health data is only shared with your physiotherapist.'
                                  : 'Sign-in is paused after repeated unsuccessful attempts.',
                              style: text.bodySmall?.copyWith(
                                color: AppColors.textMuted,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          if (_role == UserRole.patient)
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              alignment: WrapAlignment.center,
              children: [
                Text(
                  'New patient?',
                  style: text.bodySmall?.copyWith(color: AppColors.textMuted),
                ),
                TextButton(
                  onPressed: () => context.go('/register'),
                  child: const Text('Create an account'),
                ),
              ],
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                '${_role.label} accounts are created by your clinic administrator.',
                style: text.bodySmall?.copyWith(color: AppColors.textMuted),
                textAlign: TextAlign.center,
              ),
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
    required this.selected,
    required this.onTap,
  });

  final UserRole role;
  final String description;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: 'Login as ${role.label}',
      child: Material(
        color: selected ? role.tint : AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: selected ? role.accent : AppColors.border,
            width: selected ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: Key('role-${role.apiValue}'),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: selected ? Colors.white : role.tint,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(role.icon, color: role.accent, size: 24),
                    ),
                    const Spacer(),
                    Icon(
                      selected
                          ? Icons.check_circle_rounded
                          : Icons.radio_button_unchecked_rounded,
                      color: selected ? role.accent : AppColors.border,
                      size: 22,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                ExcludeSemantics(
                  child: Text(
                    'Login as ${role.label}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: AppColors.textMuted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
