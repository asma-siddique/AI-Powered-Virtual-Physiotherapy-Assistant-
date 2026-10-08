import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_exception.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/common.dart';
import '../auth/auth_controller.dart';
import '../shell/page_widgets.dart';
import 'account_repository.dart';
import 'change_password_form.dart';

/// The signed-in person's own account: who they are signed in as, their
/// password, and every device the account is signed in on.
class SecurityPage extends ConsumerWidget {
  const SecurityPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final user = ref.watch(currentUserProvider);
    if (user == null) return const SizedBox.shrink();
    final account = user.account;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageIntro(
          title: 'Account & Security',
          subtitle: 'Your sign-in details and the devices using your account.',
        ),
        ResponsiveRow(
          breakpoint: 900,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Your details', style: text.titleLarge),
                      const SizedBox(height: 16),
                      _Detail(label: 'Name', value: account.fullName),
                      if (account.email != null)
                        _Detail(label: 'Email', value: account.email!),
                      if (account.mobile != null)
                        _Detail(label: 'Mobile', value: account.mobile!),
                      _Detail(label: 'Role', value: account.role.label),
                      if (user.physiotherapist != null)
                        _Detail(
                          label: 'Physiotherapist',
                          value: user.physiotherapist!.fullName,
                        ),
                      const SizedBox(height: 4),
                      Text(
                        'If any of this is wrong, ask your clinic to correct it.',
                        style: text.bodySmall?.copyWith(
                          color: AppColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('Password', style: text.titleLarge),
                      const SizedBox(height: 4),
                      Text(
                        'Changing your password signs you out on every other device.',
                        style: text.bodySmall?.copyWith(
                          color: AppColors.textMuted,
                        ),
                      ),
                      const SizedBox(height: 16),
                      ChangePasswordForm(
                        onChanged: () {
                          ref.invalidate(devicesProvider);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text(
                                'Your password was changed. Other devices were signed out.',
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const _DevicesCard(),
          ],
        ),
      ],
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 128,
            child: Text(
              label,
              style: const TextStyle(fontSize: 14, color: AppColors.textMuted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }
}

class _DevicesCard extends ConsumerStatefulWidget {
  const _DevicesCard();

  @override
  ConsumerState<_DevicesCard> createState() => _DevicesCardState();
}

class _DevicesCardState extends ConsumerState<_DevicesCard> {
  /// The device being signed out, or "others" for all of them.
  String? _busy;
  String? _error;

  Future<bool> _confirm({
    required String title,
    required String body,
    required String action,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirm-device-sign-out'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(action),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _run(
    String busy,
    Future<String> Function(AccountRepository) action,
  ) async {
    setState(() {
      _busy = busy;
      _error = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      final done = await action(ref.read(accountRepositoryProvider));
      ref.invalidate(devicesProvider);
      messenger.showSnackBar(SnackBar(content: Text(done)));
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
      // Someone may have signed it out already: show what is true now.
      ref.invalidate(devicesProvider);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _signOut(Device device) async {
    final confirmed = await _confirm(
      title: 'Sign out ${device.name}?',
      body:
          'That device will need your password to use your account again. '
          'Nothing on it is deleted.',
      action: 'Sign out',
    );
    if (!confirmed) return;
    await _run(device.id, (repository) async {
      await repository.signOutDevice(device.id);
      return '${device.name} was signed out.';
    });
  }

  Future<void> _signOutOthers() async {
    final confirmed = await _confirm(
      title: 'Sign out everywhere else?',
      body:
          'Every device except this one will need your password to use your '
          'account again.',
      action: 'Sign out others',
    );
    if (!confirmed) return;
    await _run('others', (repository) async {
      final count = await repository.signOutOtherDevices();
      return count == 1
          ? '1 other device was signed out.'
          : '$count other devices were signed out.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final devices = ref.watch(devicesProvider);
    final others = devices.valueOrNull?.where((d) => !d.current).length ?? 0;

    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Devices', style: text.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Where your account is signed in. Sign out any device you do not '
            'recognise, then change your password.',
            style: text.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            InlineBanner(key: const Key('devices-error'), message: _error!),
          ],
          const SizedBox(height: 8),
          AsyncSection(
            value: devices,
            onRetry: () => ref.invalidate(devicesProvider),
            builder: (devices) => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final (index, device) in devices.indexed) ...[
                  if (index > 0)
                    const Divider(height: 1, color: AppColors.divider),
                  _DeviceRow(
                    device: device,
                    busy: _busy == device.id,
                    onSignOut: _busy == null ? () => _signOut(device) : null,
                  ),
                ],
                if (others > 0) ...[
                  const SizedBox(height: 16),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      key: const Key('sign-out-others'),
                      onPressed: _busy == null ? _signOutOthers : null,
                      icon: const Icon(Icons.logout_rounded, size: 18),
                      label: const Text('Sign out everywhere else'),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.device,
    required this.busy,
    required this.onSignOut,
  });

  final Device device;
  final bool busy;
  final VoidCallback? onSignOut;

  IconData get _icon {
    final name = device.name;
    if (name.contains('iPhone') ||
        name.contains('Android') ||
        name == 'PhysioAI app') {
      return Icons.smartphone_rounded;
    }
    if (name.contains('iPad')) return Icons.tablet_mac_rounded;
    if (name == 'Unknown device') return Icons.devices_other_rounded;
    return Icons.laptop_mac_rounded;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      key: Key('device-${device.id}'),
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(_icon, size: 20, color: AppColors.textMuted),
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
                      device.name,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (device.current) const Pill.success('This device'),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  device.current
                      ? 'Signed in ${formatDateTime(device.signedInAt)}'
                      : 'Last active ${formatDateTime(device.lastActiveAt)}',
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textMuted,
                  ),
                ),
                if (device.ip != null)
                  Text(
                    'IP address ${device.ip}',
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.textMuted,
                    ),
                  ),
              ],
            ),
          ),
          if (!device.current) ...[
            const SizedBox(width: 12),
            if (busy)
              const SizedBox(
                width: 72,
                child: Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  ),
                ),
              )
            else
              TextButton(
                key: Key('device-sign-out-${device.id}'),
                onPressed: onSignOut,
                child: const Text('Sign out'),
              ),
          ],
        ],
      ),
    );
  }
}
