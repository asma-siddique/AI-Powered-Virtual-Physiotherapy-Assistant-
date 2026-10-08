import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_exception.dart';
import '../../core/widgets/common.dart';
import '../auth/auth_controller.dart';
import '../auth/validators.dart';
import 'account_repository.dart';

/// Current password, new password, new password again. Used on the Account &
/// Security page and on the screen that replaces a temporary password.
class ChangePasswordForm extends ConsumerStatefulWidget {
  const ChangePasswordForm({
    super.key,
    this.currentLabel = 'Current password',
    this.submitLabel = 'Change Password',
    this.onChanged,
  });

  final String currentLabel;
  final String submitLabel;

  /// Called after the server has accepted the new password.
  final VoidCallback? onChanged;

  @override
  ConsumerState<ChangePasswordForm> createState() => _ChangePasswordFormState();
}

class _ChangePasswordFormState extends ConsumerState<ChangePasswordForm> {
  final _formKey = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final user = await ref
          .read(accountRepositoryProvider)
          .changePassword(current: _current.text, next: _next.text);
      if (!mounted) return;
      _current.clear();
      _next.clear();
      _confirm.clear();
      setState(() => _busy = false);
      widget.onChanged?.call();
      // Last: on the temporary-password screen this moves the app on.
      ref.read(authControllerProvider.notifier).passwordChanged(user);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: AutofillGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null) ...[
              InlineBanner(key: const Key('password-error'), message: _error!),
              const SizedBox(height: 16),
            ],
            LabeledField(
              label: widget.currentLabel,
              child: PasswordField(
                fieldKey: const Key('password-current'),
                controller: _current,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.password],
                validator: (v) =>
                    validateRequired(v, 'Enter the password you use now.'),
              ),
            ),
            const SizedBox(height: 16),
            LabeledField(
              label: 'New password',
              helper: 'At least 8 characters, including a letter and a number.',
              child: PasswordField(
                fieldKey: const Key('password-new'),
                controller: _next,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.newPassword],
                validator: (v) =>
                    validateNewPassword(v) ??
                    (v == _current.text
                        ? 'Choose a password that is different from your current one.'
                        : null),
              ),
            ),
            const SizedBox(height: 16),
            LabeledField(
              label: 'New password again',
              child: PasswordField(
                fieldKey: const Key('password-confirm'),
                controller: _confirm,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.newPassword],
                onSubmitted: (_) => _submit(),
                validator: (v) => v == _next.text
                    ? null
                    : 'The two new passwords do not match.',
              ),
            ),
            const SizedBox(height: 20),
            Align(
              alignment: Alignment.centerLeft,
              child: BusyButton(
                key: const Key('password-submit'),
                label: widget.submitLabel,
                busy: _busy,
                onPressed: _submit,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
