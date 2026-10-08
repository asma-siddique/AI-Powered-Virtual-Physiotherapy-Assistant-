import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/api/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/common.dart';
import '../auth_controller.dart';
import '../validators.dart';
import 'auth_scaffold.dart';

/// Patient registration. The physiotherapist invite code is required: it is what
/// links the new account to the clinician responsible for it.
class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _identifier = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _invite = TextEditingController();

  bool _busy = false;
  ApiException? _error;

  @override
  void dispose() {
    for (final controller in [
      _name,
      _identifier,
      _password,
      _confirm,
      _invite,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || !_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(authControllerProvider.notifier)
          .register(
            fullName: _name.text.trim(),
            identifier: _identifier.text.trim(),
            password: _password.text,
            inviteCode: _invite.text.trim(),
          );
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final signInLink = Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          'Already have an account?',
          style: text.bodySmall?.copyWith(color: AppColors.textMuted),
        ),
        TextButton(
          onPressed: () => context.go('/sign-in/patient'),
          child: const Text('Sign In'),
        ),
      ],
    );

    final form = AppCard(
      child: AutofillGroup(
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Create your account', style: text.titleLarge),
              const SizedBox(height: 4),
              Text(
                'It takes about a minute.',
                style: text.bodySmall?.copyWith(color: AppColors.textMuted),
              ),
              const SizedBox(height: 20),
              if (_error != null) ...[
                InlineBanner(
                  key: const Key('register-error'),
                  message: _error!.message,
                ),
                const SizedBox(height: 16),
              ],
              LabeledField(
                label: 'Full name',
                child: TextFormField(
                  key: const Key('register-name'),
                  controller: _name,
                  textInputAction: TextInputAction.next,
                  textCapitalization: TextCapitalization.words,
                  autofillHints: const [AutofillHints.name],
                  validator: validateFullName,
                ),
              ),
              const SizedBox(height: 16),
              LabeledField(
                label: 'Email or mobile number',
                child: TextFormField(
                  key: const Key('register-identifier'),
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
                helper:
                    'At least 8 characters, including a letter and a number.',
                child: PasswordField(
                  fieldKey: const Key('register-password'),
                  controller: _password,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.newPassword],
                  validator: validateNewPassword,
                ),
              ),
              const SizedBox(height: 16),
              LabeledField(
                label: 'Confirm password',
                child: PasswordField(
                  fieldKey: const Key('register-confirm'),
                  controller: _confirm,
                  textInputAction: TextInputAction.next,
                  autofillHints: const [AutofillHints.newPassword],
                  validator: (value) => value == _password.text
                      ? null
                      : 'The passwords do not match.',
                ),
              ),
              const SizedBox(height: 16),
              LabeledField(
                label: 'Physiotherapist invite code',
                helper:
                    'Your invite code connects you with your physiotherapist.',
                child: TextFormField(
                  key: const Key('register-invite'),
                  controller: _invite,
                  textCapitalization: TextCapitalization.characters,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _submit(),
                  validator: (value) => validateRequired(
                    value,
                    'Enter the invite code from your physiotherapist.',
                  ),
                  decoration: const InputDecoration(
                    hintText: 'e.g. PHY-4K7M-9QXD',
                    prefixIcon: Icon(Icons.key_outlined, size: 20),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              BusyButton(
                key: const Key('register-submit'),
                label: 'Create Account',
                busy: _busy,
                onPressed: _submit,
              ),
              const SizedBox(height: 8),
              Center(child: signInLink),
            ],
          ),
        ),
      ),
    );

    return AuthScaffold(
      trailing: MediaQuery.sizeOf(context).width < 600 ? null : signInLink,
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 860) {
            return ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: form,
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Expanded(flex: 5, child: _InfoPanel()),
              const SizedBox(width: 32),
              Expanded(flex: 6, child: form),
            ],
          );
        },
      ),
    );
  }
}

class _InfoPanel extends StatelessWidget {
  const _InfoPanel();

  static const _points = [
    (
      Icons.assignment_ind_outlined,
      'Your physiotherapist assigns your exercises',
    ),
    (
      Icons.auto_awesome_outlined,
      'AI gives gentle, real-time feedback on your form',
    ),
    (
      Icons.lock_outline_rounded,
      'Your progress is shared only with your physiotherapist',
    ),
  ];

  static const _steps = [
    'Create account',
    'Read the advisory',
    'Start your first session',
  ];

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F3FF),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Start your guided recovery', style: text.headlineSmall),
          const SizedBox(height: 24),
          for (final (icon, label) in _points)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(icon, size: 20, color: AppColors.primary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(label, style: text.bodyMedium),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 8),
          const Divider(),
          const SizedBox(height: 16),
          for (var i = 0; i < _steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 12,
                    backgroundColor: i == 0 ? AppColors.primary : Colors.white,
                    child: Text(
                      '${i + 1}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: i == 0 ? Colors.white : AppColors.textMuted,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    _steps[i],
                    style: text.bodySmall?.copyWith(
                      fontWeight: i == 0 ? FontWeight.w600 : FontWeight.w400,
                      color: i == 0 ? AppColors.text : AppColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
