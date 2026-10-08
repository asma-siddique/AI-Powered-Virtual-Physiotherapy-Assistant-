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

/// Step two of signing in: the form for the role chosen on the previous screen.
/// Patients can also start creating an account from here; physiotherapist and
/// admin accounts are created for them, so those roles only sign in.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key, required this.role});

  final UserRole role;

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  final _formKey = GlobalKey<FormState>();
  final _identifier = TextEditingController();
  final _password = TextEditingController();

  bool _busy = false;
  ApiException? _error;

  UserRole get _role => widget.role;

  @override
  void dispose() {
    _identifier.dispose();
    _password.dispose();
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
          'Ask your clinic to reset it. An administrator will give you a temporary '
          'password, and you will choose a new one the next time you sign in.',
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
    final isPatient = _role == UserRole.patient;

    return AuthScaffold(
      maxWidth: 440,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('change-role'),
              onPressed: _busy ? null : () => context.go('/sign-in'),
              icon: const Icon(Icons.arrow_back_rounded, size: 18),
              label: const Text('Change role'),
            ),
          ),
          const SizedBox(height: 12),
          AppCard(
            child: AutofillGroup(
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: _role.tint,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            _role.icon,
                            color: _role.accent,
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Sign in as ${_role.label}',
                            style: text.titleLarge,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
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
                            isPatient
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
                    if (isPatient) ...[
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 20),
                        child: Divider(height: 1),
                      ),
                      Text('New patient?', style: text.titleMedium),
                      const SizedBox(height: 4),
                      Text(
                        'Create an account with the invite code from your physiotherapist.',
                        style: text.bodySmall?.copyWith(
                          color: AppColors.textMuted,
                        ),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        key: const Key('create-account'),
                        onPressed: _busy ? null : () => context.go('/register'),
                        child: const Text('Create an account'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (!isPatient)
            Padding(
              padding: const EdgeInsets.only(top: 16),
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
