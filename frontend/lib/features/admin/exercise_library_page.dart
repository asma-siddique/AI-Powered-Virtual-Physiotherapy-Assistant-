import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api/api_exception.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/common.dart';
import '../shell/page_widgets.dart';
import 'exercise_library_repository.dart';

/// The admin's exercise library: which exercises physiotherapists can prescribe,
/// and the way into each exercise's profile and thresholds.
class ExerciseLibraryPage extends ConsumerStatefulWidget {
  const ExerciseLibraryPage({super.key});

  @override
  ConsumerState<ExerciseLibraryPage> createState() =>
      _ExerciseLibraryPageState();
}

class _ExerciseLibraryPageState extends ConsumerState<ExerciseLibraryPage> {
  String? _busyId;
  String? _error;

  Future<void> _setActive(ExerciseTemplate exercise, bool active) async {
    if (!active && !await _confirmSwitchOff(exercise)) return;
    setState(() {
      _busyId = exercise.id;
      _error = null;
    });
    try {
      await ref
          .read(exerciseLibraryRepositoryProvider)
          .setActive(exercise.id, active: active);
      ref.invalidate(exerciseLibraryProvider);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<bool> _confirmSwitchOff(ExerciseTemplate exercise) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Switch off ${exercise.name}?'),
        content: const Text(
          'Physiotherapists will no longer be able to add it to new plans. '
          'Plans and session history that already use it are kept, and '
          'physiotherapists are warned on plans that include it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('confirm-switch-off'),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Switch off'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(exerciseLibraryProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageIntro(
          title: 'Exercise Library',
          subtitle:
              'Exercises that are switched on can be prescribed by physiotherapists.',
          action: FilledButton.icon(
            key: const Key('add-exercise'),
            onPressed: () => context.go('/admin/exercises/new'),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Add exercise'),
          ),
        ),
        if (_error != null) ...[
          InlineBanner(key: const Key('library-error'), message: _error!),
          const SizedBox(height: 16),
        ],
        AppCard(
          child: AsyncSection(
            value: library,
            onRetry: () => ref.invalidate(exerciseLibraryProvider),
            builder: (exercises) => exercises.isEmpty
                ? const EmptyState(
                    icon: Icons.fitness_center_outlined,
                    message: 'The library is empty. Add the first exercise.',
                  )
                : Column(
                    children: [
                      for (final (index, exercise) in exercises.indexed) ...[
                        if (index > 0)
                          const Divider(height: 1, color: AppColors.divider),
                        _ExerciseRow(
                          exercise: exercise,
                          busy: _busyId == exercise.id,
                          onToggle: _busyId == null
                              ? (active) => _setActive(exercise, active)
                              : null,
                        ),
                      ],
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

class _ExerciseRow extends StatelessWidget {
  const _ExerciseRow({
    required this.exercise,
    required this.busy,
    required this.onToggle,
  });

  final ExerciseTemplate exercise;
  final bool busy;
  final ValueChanged<bool>? onToggle;

  @override
  Widget build(BuildContext context) {
    final checks = exercise.checks.length;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 10,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      exercise.name,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    exercise.isActive
                        ? const Pill.success('On')
                        : const Pill.neutral('Off'),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${exercise.domain}  ·  ${exercise.primaryTargets}',
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textMuted,
                  ),
                ),
                Text(
                  '$checks check${checks == 1 ? '' : 's'}  ·  version ${exercise.version}  ·  '
                  'updated ${formatDate(exercise.updatedAt)}',
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          TextButton(
            key: Key('exercise-edit-${exercise.id}'),
            onPressed: () => context.go('/admin/exercises/${exercise.id}'),
            child: const Text('Edit'),
          ),
          const SizedBox(width: 4),
          if (busy)
            const SizedBox(
              width: 52,
              height: 32,
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              ),
            )
          else
            Semantics(
              label:
                  '${exercise.name} is switched ${exercise.isActive ? 'on' : 'off'}',
              child: Switch(
                key: Key('exercise-toggle-${exercise.id}'),
                value: exercise.isActive,
                onChanged: onToggle,
              ),
            ),
        ],
      ),
    );
  }
}
