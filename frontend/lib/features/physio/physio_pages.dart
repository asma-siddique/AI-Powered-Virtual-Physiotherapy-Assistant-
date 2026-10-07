import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_exception.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/common.dart';
import '../auth/auth_controller.dart';
import '../shell/page_widgets.dart';
import 'physio_repository.dart';

class PhysioDashboardPage extends ConsumerWidget {
  const PhysioDashboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    if (user == null) return const SizedBox.shrink();
    final roster = ref.watch(rosterProvider);
    final invites = ref.watch(inviteCodesProvider);
    final patientCount = roster.valueOrNull?.length;
    final activeCodes = invites.valueOrNull
        ?.where((code) => code.isActive)
        .length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageIntro(
          title: '${greetingFor(DateTime.now())}, ${user.account.fullName}',
          subtitle: 'Invite patients and see who is on your roster.',
        ),
        ResponsiveRow(
          breakpoint: 560,
          children: [
            StatCard(
              icon: Icons.groups_outlined,
              value: patientCount?.toString() ?? '-',
              label: 'Active patients',
            ),
            StatCard(
              icon: Icons.key_outlined,
              value: activeCodes?.toString() ?? '-',
              label: 'Unused invite codes',
              accent: AppColors.tealDark,
            ),
          ],
        ),
        const SizedBox(height: 24),
        ResponsiveRow(
          breakpoint: 900,
          children: [
            const _InviteCard(),
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Your patients',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      TextButton(
                        onPressed: () => context.go('/physio/patients'),
                        child: const Text('View all'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  AsyncSection(
                    value: roster,
                    onRetry: () => ref.invalidate(rosterProvider),
                    builder: (patients) => patients.isEmpty
                        ? const EmptyState(
                            icon: Icons.person_add_alt_1_outlined,
                            message:
                                'No patients yet.\nGenerate an invite code and share it with a patient.',
                          )
                        : Column(
                            children: [
                              for (final patient in patients.take(5))
                                _PatientRow(patient: patient),
                            ],
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _InviteCard extends ConsumerStatefulWidget {
  const _InviteCard();

  @override
  ConsumerState<_InviteCard> createState() => _InviteCardState();
}

class _InviteCardState extends ConsumerState<_InviteCard> {
  bool _busy = false;
  String? _error;

  Future<void> _generate() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(physioRepositoryProvider).createInviteCode();
      ref.invalidate(inviteCodesProvider);
    } on ApiException catch (error) {
      _error = error.message;
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final invites = ref.watch(inviteCodesProvider);
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Invite a patient', style: text.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Each code links one new patient to you. It works once and expires after 7 days.',
            style: text.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: BusyButton(
              key: const Key('generate-invite'),
              label: 'Generate Invite Code',
              icon: Icons.add_rounded,
              busy: _busy,
              onPressed: _generate,
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            InlineBanner(message: _error!),
          ],
          const SizedBox(height: 16),
          AsyncSection(
            value: invites,
            onRetry: () => ref.invalidate(inviteCodesProvider),
            builder: (codes) => codes.isEmpty
                ? Text(
                    'No invite codes yet.',
                    style: text.bodySmall?.copyWith(color: AppColors.textMuted),
                  )
                : Column(
                    children: [
                      for (final code in codes.take(6))
                        _InviteRow(invite: code),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

class _InviteRow extends StatelessWidget {
  const _InviteRow({required this.invite});

  final InviteCode invite;

  @override
  Widget build(BuildContext context) {
    final detail = switch (invite.status) {
      'redeemed' => 'Used by ${invite.redeemedBy?.fullName ?? 'a patient'}',
      'expired' => 'Expired ${formatDate(invite.expiresAt)}',
      _ => 'Expires ${formatDate(invite.expiresAt)}',
    };
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.divider)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  invite.code,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1,
                    color: invite.isActive
                        ? AppColors.text
                        : AppColors.textMuted,
                  ),
                ),
                Text(
                  detail,
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          switch (invite.status) {
            'redeemed' => const Pill.neutral('Used'),
            'expired' => const Pill.warning('Expired'),
            _ => const Pill.success('Active'),
          },
          if (invite.isActive)
            IconButton(
              tooltip: 'Copy code',
              icon: const Icon(Icons.copy_rounded, size: 18),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: invite.code));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Invite code copied')),
                );
              },
            )
          else
            const SizedBox(width: 40),
        ],
      ),
    );
  }
}

class _PatientRow extends StatelessWidget {
  const _PatientRow({required this.patient});

  final PatientSummary patient;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.divider)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: AppColors.tealTint,
              child: Text(
                patient.fullName.isEmpty
                    ? '?'
                    : patient.fullName[0].toUpperCase(),
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.tealDark,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    patient.fullName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    patient.contact,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            // The start date is the first thing to go when the row gets narrow.
            if (constraints.maxWidth >= 440) ...[
              const SizedBox(width: 12),
              Text(
                'Since ${formatDate(patient.assignedAt)}',
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textMuted,
                ),
              ),
            ],
            const SizedBox(width: 12),
            patient.isActive
                ? const Pill.success('Active')
                : const Pill.neutral('Inactive'),
          ],
        ),
      ),
    );
  }
}

class PhysioPatientsPage extends ConsumerWidget {
  const PhysioPatientsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final roster = ref.watch(rosterProvider);
    return AppCard(
      child: AsyncSection(
        value: roster,
        onRetry: () => ref.invalidate(rosterProvider),
        builder: (patients) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${patients.length} active patient${patients.length == 1 ? '' : 's'}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            if (patients.isEmpty)
              const Center(
                child: EmptyState(
                  icon: Icons.person_add_alt_1_outlined,
                  message:
                      'No patients yet.\nGenerate an invite code on the Dashboard and share it with a patient.',
                ),
              )
            else
              for (final patient in patients) _PatientRow(patient: patient),
          ],
        ),
      ),
    );
  }
}
