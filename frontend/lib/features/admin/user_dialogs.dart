import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_exception.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/common.dart';
import '../auth/auth_models.dart';
import '../auth/validators.dart';
import 'user_management_repository.dart';

/// A dialog that carries out one change: it stays open with the reason when
/// the server refuses, and closes with the result when the change is saved.
class _ActionDialog<T> extends ConsumerStatefulWidget {
  const _ActionDialog({
    super.key,
    required this.title,
    required this.actionLabel,
    required this.onSubmit,
    required this.child,
    this.formKey,
    this.canSubmit = true,
  });

  final String title;
  final String actionLabel;
  final Future<T> Function(UserManagementRepository repository) onSubmit;
  final Widget child;
  final GlobalKey<FormState>? formKey;
  final bool canSubmit;

  @override
  ConsumerState<_ActionDialog<T>> createState() => _ActionDialogState<T>();
}

class _ActionDialogState<T> extends ConsumerState<_ActionDialog<T>> {
  bool _busy = false;
  String? _error;

  Future<void> _submit() async {
    if (_busy) return;
    if (!(widget.formKey?.currentState?.validate() ?? true)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.onSubmit(
        ref.read(userManagementRepositoryProvider),
      );
      if (mounted) Navigator.of(context).pop(result);
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
    return AlertDialog(
      title: Text(widget.title),
      scrollable: true,
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null) ...[
              InlineBanner(key: const Key('dialog-error'), message: _error!),
              const SizedBox(height: 16),
            ],
            widget.child,
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        BusyButton(
          key: const Key('dialog-submit'),
          label: widget.actionLabel,
          busy: _busy,
          onPressed: widget.canSubmit ? _submit : null,
        ),
      ],
    );
  }
}

Widget _explanation(String text) => Text(
  text,
  style: const TextStyle(fontSize: 15, height: 1.5, color: AppColors.textMuted),
);

/// Creates an account. Closes with the new user and their temporary password.
class AddUserDialog extends StatefulWidget {
  const AddUserDialog({super.key, required this.physiotherapists});

  /// Active physiotherapists a new patient can be assigned to.
  final List<ManagedUser> physiotherapists;

  @override
  State<AddUserDialog> createState() => _AddUserDialogState();
}

class _AddUserDialogState extends State<AddUserDialog> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _identifier = TextEditingController();
  UserRole _role = UserRole.physiotherapist;
  String? _physiotherapistId;

  @override
  void dispose() {
    _name.dispose();
    _identifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isPatient = _role == UserRole.patient;
    final noPhysiotherapist = isPatient && widget.physiotherapists.isEmpty;
    return _ActionDialog<IssuedPassword>(
      title: 'Add user',
      actionLabel: 'Create Account',
      formKey: _formKey,
      canSubmit: !noPhysiotherapist,
      onSubmit: (repository) => repository.create(
        fullName: _name.text.trim(),
        identifier: _identifier.text.trim(),
        role: _role,
        physiotherapistId: isPatient ? _physiotherapistId : null,
      ),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LabeledField(
              label: 'Role',
              child: DropdownButtonFormField<UserRole>(
                key: const Key('new-user-role'),
                initialValue: _role,
                isExpanded: true,
                items: [
                  for (final role in UserRole.values)
                    DropdownMenuItem(value: role, child: Text(role.label)),
                ],
                onChanged: (role) => setState(() => _role = role ?? _role),
              ),
            ),
            const SizedBox(height: 16),
            LabeledField(
              label: 'Full name',
              child: TextFormField(
                key: const Key('new-user-name'),
                controller: _name,
                textCapitalization: TextCapitalization.words,
                validator: (v) => (v ?? '').trim().length < 2
                    ? "Enter the person's full name."
                    : null,
              ),
            ),
            const SizedBox(height: 16),
            LabeledField(
              label: 'Email or mobile number',
              helper: 'What they will sign in with.',
              child: TextFormField(
                key: const Key('new-user-identifier'),
                controller: _identifier,
                keyboardType: TextInputType.emailAddress,
                validator: (v) => (v ?? '').trim().isEmpty
                    ? 'Enter an email address or mobile number.'
                    : validateIdentifier(v),
              ),
            ),
            if (isPatient) ...[
              const SizedBox(height: 16),
              if (noPhysiotherapist)
                const InlineBanner(
                  tone: BannerTone.info,
                  message:
                      'There is no active physiotherapist to assign a patient to. '
                      'Add a physiotherapist first.',
                )
              else
                LabeledField(
                  label: 'Physiotherapist',
                  helper:
                      'Every patient is looked after by one physiotherapist.',
                  child: DropdownButtonFormField<String>(
                    key: const Key('new-user-physio'),
                    initialValue: _physiotherapistId,
                    isExpanded: true,
                    hint: const Text('Choose a physiotherapist'),
                    items: [
                      for (final physio in widget.physiotherapists)
                        DropdownMenuItem(
                          value: physio.id,
                          child: Text(physio.fullName),
                        ),
                    ],
                    validator: (v) =>
                        v == null ? 'Choose a physiotherapist.' : null,
                    onChanged: (id) => setState(() => _physiotherapistId = id),
                  ),
                ),
            ],
            const SizedBox(height: 16),
            _explanation(
              'The account gets a temporary password, shown to you once. '
              'The person chooses their own the first time they sign in.',
            ),
          ],
        ),
      ),
    );
  }
}

/// Corrects a name, email or mobile number. Closes with the saved user.
class EditUserDialog extends StatefulWidget {
  const EditUserDialog({super.key, required this.user});

  final ManagedUser user;

  @override
  State<EditUserDialog> createState() => _EditUserDialogState();
}

class _EditUserDialogState extends State<EditUserDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.user.fullName);
  late final _email = TextEditingController(text: widget.user.account.email);
  late final _mobile = TextEditingController(text: widget.user.account.mobile);

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _mobile.dispose();
    super.dispose();
  }

  String? _contact(String? value, {required bool email}) {
    final text = (value ?? '').trim();
    final other = (email ? _mobile : _email).text.trim();
    if (text.isEmpty) {
      return other.isEmpty
          ? 'Enter an email address or a mobile number.'
          : null;
    }
    if (email != text.contains('@')) {
      return email
          ? 'Enter a valid email address.'
          : 'Enter a valid mobile number.';
    }
    final problem = validateIdentifier(text);
    if (problem == null) return null;
    return email
        ? 'Enter a valid email address.'
        : 'Enter a valid mobile number.';
  }

  @override
  Widget build(BuildContext context) {
    return _ActionDialog<ManagedUser>(
      title: 'Edit details',
      actionLabel: 'Save Changes',
      formKey: _formKey,
      onSubmit: (repository) => repository.update(
        widget.user.id,
        fullName: _name.text.trim(),
        email: _email.text.trim(),
        mobile: _mobile.text.trim(),
      ),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LabeledField(
              label: 'Full name',
              child: TextFormField(
                key: const Key('edit-name'),
                controller: _name,
                validator: (v) => (v ?? '').trim().length < 2
                    ? "Enter the person's full name."
                    : null,
              ),
            ),
            const SizedBox(height: 16),
            LabeledField(
              label: 'Email',
              child: TextFormField(
                key: const Key('edit-email'),
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                validator: (v) => _contact(v, email: true),
              ),
            ),
            const SizedBox(height: 16),
            LabeledField(
              label: 'Mobile number',
              helper: 'They can sign in with either one.',
              child: TextFormField(
                key: const Key('edit-mobile'),
                controller: _mobile,
                keyboardType: TextInputType.phone,
                validator: (v) => _contact(v, email: false),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Moves a patient to another physiotherapist. Closes with the saved user.
class ReassignDialog extends StatefulWidget {
  const ReassignDialog({
    super.key,
    required this.patient,
    required this.physiotherapists,
  });

  final ManagedUser patient;

  /// Active physiotherapists other than the current one.
  final List<ManagedUser> physiotherapists;

  @override
  State<ReassignDialog> createState() => _ReassignDialogState();
}

class _ReassignDialogState extends State<ReassignDialog> {
  final _formKey = GlobalKey<FormState>();
  String? _physiotherapistId;

  @override
  Widget build(BuildContext context) {
    final current = widget.patient.physiotherapist?.fullName;
    final nobody = widget.physiotherapists.isEmpty;
    return _ActionDialog<ManagedUser>(
      title: 'Reassign ${widget.patient.fullName}',
      actionLabel: 'Reassign',
      formKey: _formKey,
      canSubmit: !nobody,
      onSubmit: (repository) =>
          repository.reassign(widget.patient.id, _physiotherapistId!),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (nobody)
              const InlineBanner(
                tone: BannerTone.info,
                message:
                    'There is no other active physiotherapist to move this patient to.',
              )
            else
              LabeledField(
                label: 'New physiotherapist',
                child: DropdownButtonFormField<String>(
                  key: const Key('reassign-physio'),
                  initialValue: _physiotherapistId,
                  isExpanded: true,
                  hint: const Text('Choose a physiotherapist'),
                  items: [
                    for (final physio in widget.physiotherapists)
                      DropdownMenuItem(
                        value: physio.id,
                        child: Text(physio.fullName),
                      ),
                  ],
                  validator: (v) =>
                      v == null ? 'Choose a physiotherapist.' : null,
                  onChanged: (id) => setState(() => _physiotherapistId = id),
                ),
              ),
            const SizedBox(height: 16),
            _explanation(
              '${current == null ? 'The new physiotherapist' : '$current loses access at once and the new physiotherapist'} '
              'sees this patient and their current plan straight away. '
              'Everyone involved is notified.',
            ),
          ],
        ),
      ),
    );
  }
}

/// Switches a staff account between Physiotherapist and Admin.
class ChangeRoleDialog extends StatefulWidget {
  const ChangeRoleDialog({super.key, required this.user});

  final ManagedUser user;

  @override
  State<ChangeRoleDialog> createState() => _ChangeRoleDialogState();
}

class _ChangeRoleDialogState extends State<ChangeRoleDialog> {
  late UserRole _role = widget.user.role == UserRole.admin
      ? UserRole.physiotherapist
      : UserRole.admin;

  @override
  Widget build(BuildContext context) {
    return _ActionDialog<ManagedUser>(
      title: 'Change role of ${widget.user.fullName}',
      actionLabel: 'Change Role',
      onSubmit: (repository) => repository.changeRole(widget.user.id, _role),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LabeledField(
            label: 'New role',
            helper: 'Currently ${widget.user.role.label}.',
            child: DropdownButtonFormField<UserRole>(
              key: const Key('role-choice'),
              initialValue: _role,
              isExpanded: true,
              items: [
                for (final role in [UserRole.physiotherapist, UserRole.admin])
                  if (role != widget.user.role)
                    DropdownMenuItem(value: role, child: Text(role.label)),
              ],
              onChanged: (role) => setState(() => _role = role ?? _role),
            ),
          ),
          const SizedBox(height: 16),
          _explanation(
            'They are signed out everywhere and choose the new role the next '
            'time they sign in. The change is recorded in the audit log.',
          ),
        ],
      ),
    );
  }
}

/// A yes/no question in front of a change that is carried out on "yes".
class ConfirmUserActionDialog<T> extends StatelessWidget {
  const ConfirmUserActionDialog({
    super.key,
    required this.title,
    required this.body,
    required this.actionLabel,
    required this.onConfirm,
  });

  final String title;
  final String body;
  final String actionLabel;
  final Future<T> Function(UserManagementRepository repository) onConfirm;

  @override
  Widget build(BuildContext context) {
    return _ActionDialog<T>(
      title: title,
      actionLabel: actionLabel,
      onSubmit: onConfirm,
      child: _explanation(body),
    );
  }
}

/// Shows a temporary password once, with a way to copy it.
class TemporaryPasswordDialog extends StatefulWidget {
  const TemporaryPasswordDialog({
    super.key,
    required this.user,
    required this.password,
    required this.isNewAccount,
  });

  final ManagedUser user;
  final String password;
  final bool isNewAccount;

  @override
  State<TemporaryPasswordDialog> createState() =>
      _TemporaryPasswordDialogState();
}

class _TemporaryPasswordDialogState extends State<TemporaryPasswordDialog> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.password));
    if (mounted) setState(() => _copied = true);
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.user.account.firstName;
    return AlertDialog(
      title: Text(
        widget.isNewAccount ? 'Account created' : 'Temporary password issued',
      ),
      scrollable: true,
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _explanation(
              'Give this temporary password to $name. They sign in with '
              '${widget.user.account.contact} and are asked to choose their own '
              'password straight away.',
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              decoration: BoxDecoration(
                color: AppColors.background,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.divider),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: SelectableText(
                      widget.password,
                      key: const Key('temporary-password'),
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 1.2,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  TextButton.icon(
                    key: const Key('copy-password'),
                    onPressed: _copy,
                    icon: Icon(
                      _copied ? Icons.check_rounded : Icons.copy_rounded,
                      size: 18,
                    ),
                    label: Text(_copied ? 'Copied' : 'Copy'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const InlineBanner(
              tone: BannerTone.warning,
              icon: Icons.visibility_off_outlined,
              message:
                  'This is the only time the password is shown. If it is lost, '
                  'reset the password again.',
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          key: const Key('password-dialog-done'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
