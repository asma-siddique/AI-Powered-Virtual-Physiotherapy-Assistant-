import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/widgets/common.dart';
import '../auth/auth_controller.dart';
import '../auth/auth_models.dart';
import '../shell/page_widgets.dart';
import 'user_dialogs.dart';
import 'user_management_repository.dart';

enum _Action { edit, reassign, changeRole, resetPassword, deactivate, activate }

/// Users & Roles: every account, and what an admin can do to each one.
class AdminUsersPage extends ConsumerStatefulWidget {
  const AdminUsersPage({super.key});

  @override
  ConsumerState<AdminUsersPage> createState() => _AdminUsersPageState();
}

class _AdminUsersPageState extends ConsumerState<AdminUsersPage> {
  final _search = TextEditingController();
  UserRole? _role;
  bool? _active;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool get _filtered =>
      _role != null || _active != null || _search.text.trim().isNotEmpty;

  List<ManagedUser> _matching(List<ManagedUser> users) {
    final query = _search.text.trim().toLowerCase();
    return [
      for (final user in users)
        if ((_role == null || user.role == _role) &&
            (_active == null || user.isActive == _active) &&
            (query.isEmpty ||
                user.fullName.toLowerCase().contains(query) ||
                (user.account.email ?? '').toLowerCase().contains(query) ||
                (user.account.mobile ?? '').contains(query)))
          user,
    ];
  }

  void _done(String message) {
    ref.invalidate(managedUsersProvider);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _showPassword(
    ManagedUser user,
    String password, {
    required bool isNewAccount,
  }) => showDialog<void>(
    context: context,
    // Closing by accident would lose a password that cannot be shown again.
    barrierDismissible: false,
    builder: (context) => TemporaryPasswordDialog(
      user: user,
      password: password,
      isNewAccount: isNewAccount,
    ),
  );

  List<ManagedUser> _physiotherapists(
    List<ManagedUser> users, {
    String? except,
  }) => [
    for (final user in users)
      if (user.role == UserRole.physiotherapist &&
          user.isActive &&
          user.id != except)
        user,
  ];

  Future<void> _add(List<ManagedUser> users) async {
    final issued = await showDialog<IssuedPassword>(
      context: context,
      builder: (context) =>
          AddUserDialog(physiotherapists: _physiotherapists(users)),
    );
    if (issued == null || !mounted) return;
    _done('${issued.user.fullName} was added.');
    await _showPassword(
      issued.user,
      issued.temporaryPassword,
      isNewAccount: true,
    );
  }

  Future<void> _perform(
    _Action action,
    ManagedUser user,
    List<ManagedUser> users,
  ) async {
    final name = user.fullName;
    switch (action) {
      case _Action.edit:
        final saved = await showDialog<ManagedUser>(
          context: context,
          builder: (context) => EditUserDialog(user: user),
        );
        if (saved != null && mounted) {
          _done("${saved.fullName}'s details were saved.");
        }
      case _Action.reassign:
        final saved = await showDialog<ManagedUser>(
          context: context,
          builder: (context) => ReassignDialog(
            patient: user,
            physiotherapists: _physiotherapists(
              users,
              except: user.physiotherapist?.id,
            ),
          ),
        );
        if (saved != null && mounted) {
          _done('$name is now with ${saved.physiotherapist?.fullName}.');
        }
      case _Action.changeRole:
        final saved = await showDialog<ManagedUser>(
          context: context,
          builder: (context) => ChangeRoleDialog(user: user),
        );
        if (saved != null && mounted) {
          _done('$name is now ${saved.role.label}.');
        }
      case _Action.resetPassword:
        final password = await showDialog<String>(
          context: context,
          builder: (context) => ConfirmUserActionDialog<String>(
            title: 'Reset the password of $name?',
            body:
                'Their current password stops working and they are signed out '
                'everywhere. You get a temporary password to pass on.',
            actionLabel: 'Reset Password',
            onConfirm: (repository) => repository.resetPassword(user.id),
          ),
        );
        if (password == null || !mounted) return;
        _done("$name's password was reset.");
        await _showPassword(user, password, isNewAccount: false);
      case _Action.deactivate:
        final saved = await showDialog<ManagedUser>(
          context: context,
          builder: (context) => ConfirmUserActionDialog<ManagedUser>(
            title: 'Deactivate $name?',
            body:
                'They are signed out at once and can no longer sign in. '
                'Their records are kept, and the account can be reactivated later.',
            actionLabel: 'Deactivate',
            onConfirm: (repository) =>
                repository.setActive(user.id, active: false),
          ),
        );
        if (saved != null && mounted) _done('$name was deactivated.');
      case _Action.activate:
        final saved = await showDialog<ManagedUser>(
          context: context,
          builder: (context) => ConfirmUserActionDialog<ManagedUser>(
            title: 'Reactivate $name?',
            body: 'They will be able to sign in again with their password.',
            actionLabel: 'Reactivate',
            onConfirm: (repository) =>
                repository.setActive(user.id, active: true),
          ),
        );
        if (saved != null && mounted) _done('$name was reactivated.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final users = ref.watch(managedUsersProvider);
    final me = ref.watch(currentUserProvider)?.account.id;
    final all = users.valueOrNull;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageIntro(
          title: 'Users & Roles',
          subtitle:
              'Create accounts, control who can sign in, and move patients '
              'between physiotherapists.',
          action: FilledButton.icon(
            key: const Key('add-user'),
            onPressed: all == null ? null : () => _add(all),
            icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
            label: const Text('Add user'),
          ),
        ),
        AppCard(
          child: AsyncSection(
            value: users,
            onRetry: () => ref.invalidate(managedUsersProvider),
            builder: (all) {
              final shown = _matching(all);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ResponsiveRow(
                    breakpoint: 720,
                    gap: 12,
                    flex: const [2, 1, 1],
                    children: [
                      TextField(
                        key: const Key('user-search'),
                        controller: _search,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(
                          hintText: 'Search by name, email or mobile',
                          prefixIcon: const Icon(
                            Icons.search_rounded,
                            size: 20,
                          ),
                          suffixIcon: _search.text.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: 'Clear search',
                                  icon: const Icon(
                                    Icons.close_rounded,
                                    size: 18,
                                  ),
                                  onPressed: () => setState(_search.clear),
                                ),
                        ),
                      ),
                      DropdownButtonFormField<UserRole?>(
                        key: const Key('user-role-filter'),
                        initialValue: _role,
                        isExpanded: true,
                        items: [
                          const DropdownMenuItem(child: Text('All roles')),
                          for (final role in UserRole.values)
                            DropdownMenuItem(
                              value: role,
                              child: Text('${role.label}s'),
                            ),
                        ],
                        onChanged: (role) => setState(() => _role = role),
                      ),
                      DropdownButtonFormField<bool?>(
                        key: const Key('user-status-filter'),
                        initialValue: _active,
                        isExpanded: true,
                        items: const [
                          DropdownMenuItem(child: Text('Any status')),
                          DropdownMenuItem(value: true, child: Text('Active')),
                          DropdownMenuItem(
                            value: false,
                            child: Text('Deactivated'),
                          ),
                        ],
                        onChanged: (active) => setState(() => _active = active),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _filtered
                        ? '${shown.length} of ${all.length} users'
                        : '${all.length} user${all.length == 1 ? '' : 's'}',
                    key: const Key('user-count'),
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.textMuted,
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (shown.isEmpty)
                    EmptyState(
                      icon: Icons.person_search_outlined,
                      message: 'No users match these filters.',
                      action: OutlinedButton(
                        key: const Key('clear-user-filters'),
                        onPressed: () => setState(() {
                          _search.clear();
                          _role = null;
                          _active = null;
                        }),
                        child: const Text('Clear filters'),
                      ),
                    )
                  else
                    for (final (index, user) in shown.indexed) ...[
                      if (index > 0)
                        const Divider(height: 1, color: AppColors.divider),
                      _UserRow(
                        user: user,
                        isMe: user.id == me,
                        onAction: (action) => _perform(action, user, all),
                      ),
                    ],
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _UserRow extends StatelessWidget {
  const _UserRow({
    required this.user,
    required this.isMe,
    required this.onAction,
  });

  final ManagedUser user;
  final bool isMe;
  final ValueChanged<_Action> onAction;

  String get _about {
    final seen = user.lastSeenAt == null
        ? 'Has not signed in yet'
        : 'Last active ${formatDateTime(user.lastSeenAt!)}';
    return switch (user.role) {
      UserRole.patient =>
        'Physiotherapist: ${user.physiotherapist?.fullName ?? 'none'}  ·  $seen',
      UserRole.physiotherapist =>
        '${user.patientCount ?? 0} active patient${user.patientCount == 1 ? '' : 's'}  ·  $seen',
      UserRole.admin => seen,
    };
  }

  @override
  Widget build(BuildContext context) {
    final account = user.account;
    final staff = user.role != UserRole.patient;
    const muted = TextStyle(fontSize: 13, color: AppColors.textMuted);

    return Padding(
      key: Key('user-row-${user.id}'),
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        children: [
          Opacity(
            opacity: user.isActive ? 1 : 0.5,
            child: CircleAvatar(
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
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      account.fullName,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Pill(
                      account.role.label,
                      foreground: account.role.accent,
                      background: account.role.tint,
                    ),
                    if (isMe) const Pill.neutral('You'),
                    if (!user.isActive)
                      const Pill.neutral('Deactivated')
                    else if (user.mustChangePassword)
                      const Pill.warning('Temporary password'),
                  ],
                ),
                const SizedBox(height: 2),
                Text(account.contact, style: muted),
                Text(_about, style: muted),
              ],
            ),
          ),
          PopupMenuButton<_Action>(
            key: Key('user-menu-${user.id}'),
            // Over the whole window, so a click anywhere else closes it.
            useRootNavigator: true,
            tooltip: 'Actions for ${account.fullName}',
            icon: const Icon(Icons.more_vert_rounded),
            onSelected: onAction,
            itemBuilder: (context) => [
              const PopupMenuItem(
                key: Key('action-edit'),
                value: _Action.edit,
                child: Text('Edit details'),
              ),
              if (!staff)
                const PopupMenuItem(
                  key: Key('action-reassign'),
                  value: _Action.reassign,
                  child: Text('Reassign physiotherapist'),
                ),
              // An admin never changes their own access: a colleague does.
              if (!isMe) ...[
                if (staff)
                  const PopupMenuItem(
                    key: Key('action-role'),
                    value: _Action.changeRole,
                    child: Text('Change role'),
                  ),
                const PopupMenuItem(
                  key: Key('action-reset'),
                  value: _Action.resetPassword,
                  child: Text('Reset password'),
                ),
                const PopupMenuDivider(),
                if (user.isActive)
                  const PopupMenuItem(
                    key: Key('action-deactivate'),
                    value: _Action.deactivate,
                    child: Text(
                      'Deactivate account',
                      style: TextStyle(color: AppColors.error),
                    ),
                  )
                else
                  const PopupMenuItem(
                    key: Key('action-activate'),
                    value: _Action.activate,
                    child: Text('Reactivate account'),
                  ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
