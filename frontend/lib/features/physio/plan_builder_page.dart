import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_exception.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/common.dart';
import '../exercises/exercise_models.dart';
import '../shell/page_widgets.dart';
import 'physio_repository.dart';

/// Where a physiotherapist builds a plan for one patient: pick exercises from
/// the active library, set sets, reps, rest and difficulty, then assign it.
/// Exercises can only be chosen here, never created or edited.
class PlanBuilderPage extends ConsumerStatefulWidget {
  const PlanBuilderPage({super.key, this.initialPatientId});

  final String? initialPatientId;

  @override
  ConsumerState<PlanBuilderPage> createState() => _PlanBuilderPageState();
}

class _PlanBuilderPageState extends ConsumerState<PlanBuilderPage> {
  static const _defaultName = 'Exercise plan';

  final _name = TextEditingController(text: _defaultName);
  final _items = <PlanItemDraft>[];
  late String? _patientId = widget.initialPatientId;
  bool _busy = false;
  String? _error;
  String? _success;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool _added(ExerciseBrief exercise) =>
      _items.any((item) => item.exercise.id == exercise.id);

  void _edit(VoidCallback change) => setState(() {
    change();
    _success = null;
  });

  Future<void> _assign(PatientSummary patient) async {
    final name = _name.text.trim();
    if (name.length < 2) {
      setState(() => _error = 'Give the plan a name.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _success = null;
    });
    try {
      await ref
          .read(physioRepositoryProvider)
          .assignPlan(patientId: patient.id, name: name, items: _items);
      ref.invalidate(patientPlansProvider(patient.id));
      if (!mounted) return;
      setState(() {
        // Start the next plan from a clean form.
        _items.clear();
        _name.text = _defaultName;
        _success =
            'Plan assigned to ${patient.fullName}. Their previous plan, if any, was archived.';
      });
    } on ApiException catch (error) {
      if (error.code == 'exercise_unavailable') {
        // An admin switched an exercise off while this plan was being built.
        ref.invalidate(activeExercisesProvider);
      }
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final roster = ref.watch(rosterProvider);
    return AsyncSection(
      value: roster,
      onRetry: () => ref.invalidate(rosterProvider),
      builder: (patients) {
        if (patients.isEmpty) {
          return const AppCard(
            child: EmptyState(
              icon: Icons.person_add_alt_1_outlined,
              message:
                  'You have no patients yet.\nInvite a patient from the Dashboard, then build their plan here.',
            ),
          );
        }
        final selected = patients.where((p) => p.id == _patientId).firstOrNull;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(patients, selected),
            const SizedBox(height: 24),
            ResponsiveRow(
              breakpoint: 900,
              flex: const [2, 3],
              children: [_picker(), _plan(selected)],
            ),
            if (selected != null) ...[
              const SizedBox(height: 24),
              _History(patient: selected),
            ],
          ],
        );
      },
    );
  }

  Widget _header(List<PatientSummary> patients, PatientSummary? selected) {
    return AppCard(
      child: ResponsiveRow(
        breakpoint: 640,
        gap: 16,
        children: [
          LabeledField(
            label: 'Patient',
            child: DropdownButtonFormField<String>(
              key: const Key('plan-patient'),
              initialValue: selected?.id,
              isExpanded: true,
              hint: const Text('Choose a patient'),
              items: [
                for (final patient in patients)
                  DropdownMenuItem(
                    value: patient.id,
                    child: Text(
                      patient.fullName,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (value) => setState(() {
                      _patientId = value;
                      _success = null;
                      _error = null;
                    }),
            ),
          ),
          LabeledField(
            label: 'Plan name',
            child: TextField(
              key: const Key('plan-name'),
              controller: _name,
              enabled: !_busy,
              textCapitalization: TextCapitalization.sentences,
            ),
          ),
        ],
      ),
    );
  }

  Widget _picker() {
    final exercises = ref.watch(activeExercisesProvider);
    final text = Theme.of(context).textTheme;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Choose exercises', style: text.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Only exercises the system can currently score are listed.',
            style: text.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
          const SizedBox(height: 8),
          AsyncSection(
            value: exercises,
            onRetry: () => ref.invalidate(activeExercisesProvider),
            builder: (list) => list.isEmpty
                ? const EmptyState(
                    icon: Icons.fitness_center_outlined,
                    message: 'No exercises are available right now.',
                  )
                : Column(
                    children: [
                      for (final exercise in list)
                        _ExerciseOption(
                          exercise: exercise,
                          added: _added(exercise),
                          onAdd: _busy
                              ? null
                              : () => _edit(
                                  () => _items.add(PlanItemDraft(exercise)),
                                ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _plan(PatientSummary? patient) {
    final text = Theme.of(context).textTheme;
    final ready = patient != null && _items.isNotEmpty;
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            patient == null ? 'New plan' : 'Plan for ${patient.fullName}',
            style: text.titleLarge,
          ),
          const SizedBox(height: 12),
          if (_success != null) ...[
            InlineBanner(
              key: const Key('plan-success'),
              message: _success!,
              tone: BannerTone.success,
            ),
            const SizedBox(height: 12),
          ],
          if (_error != null) ...[
            InlineBanner(key: const Key('plan-error'), message: _error!),
            const SizedBox(height: 12),
          ],
          if (_items.isEmpty)
            EmptyState(
              icon: Icons.playlist_add_rounded,
              message: patient == null
                  ? 'Choose a patient, then add exercises from the list.'
                  : 'Add exercises from the list to build this plan.',
            )
          else
            for (var i = 0; i < _items.length; i++)
              _DraftCard(
                key: ValueKey(_items[i].exercise.id),
                index: i,
                count: _items.length,
                draft: _items[i],
                enabled: !_busy,
                onChanged: () => _edit(() {}),
                onRemove: () => _edit(() => _items.removeAt(i)),
                onMove: (delta) => _edit(() {
                  final item = _items.removeAt(i);
                  _items.insert(i + delta, item);
                }),
              ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Text(
                  _items.isEmpty
                      ? 'No exercises added'
                      : '${_items.length} exercise${_items.length == 1 ? '' : 's'}',
                  style: text.bodySmall?.copyWith(color: AppColors.textMuted),
                ),
              ),
              BusyButton(
                key: const Key('assign-plan'),
                label: 'Assign Plan',
                busy: _busy,
                onPressed: ready ? () => _assign(patient) : null,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ExerciseOption extends StatelessWidget {
  const _ExerciseOption({
    required this.exercise,
    required this.added,
    required this.onAdd,
  });

  final ExerciseBrief exercise;
  final bool added;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.divider)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  exercise.name,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  exercise.domain,
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textMuted,
                  ),
                ),
                Text(
                  'Targets: ${exercise.primaryTargets}',
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textMuted,
                  ),
                ),
                const SizedBox(height: 4),
                // User story 2.3: each exercise shows its target and description.
                Text(
                  exercise.instructions,
                  style: const TextStyle(fontSize: 13, height: 1.4),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (added)
            const Pill.success('Added', icon: Icons.check_rounded)
          else
            OutlinedButton(
              key: Key('add-exercise-${exercise.id}'),
              onPressed: onAdd,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 36),
                padding: const EdgeInsets.symmetric(horizontal: 16),
              ),
              child: const Text('Add'),
            ),
        ],
      ),
    );
  }
}

class _DraftCard extends StatelessWidget {
  const _DraftCard({
    super.key,
    required this.index,
    required this.count,
    required this.draft,
    required this.enabled,
    required this.onChanged,
    required this.onRemove,
    required this.onMove,
  });

  final int index;
  final int count;
  final PlanItemDraft draft;
  final bool enabled;
  final VoidCallback onChanged;
  final VoidCallback onRemove;
  final ValueChanged<int> onMove;

  static const _restOptions = [0, 30, 45, 60, 90, 120];

  @override
  Widget build(BuildContext context) {
    void set(VoidCallback change) {
      change();
      onChanged();
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 13,
                backgroundColor: AppColors.primaryTint,
                child: Text(
                  '${index + 1}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.primary,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  draft.exercise.name,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Move up',
                icon: const Icon(Icons.arrow_upward_rounded, size: 18),
                onPressed: enabled && index > 0 ? () => onMove(-1) : null,
              ),
              IconButton(
                tooltip: 'Move down',
                icon: const Icon(Icons.arrow_downward_rounded, size: 18),
                onPressed: enabled && index < count - 1
                    ? () => onMove(1)
                    : null,
              ),
              IconButton(
                key: Key('remove-exercise-${draft.exercise.id}'),
                tooltip: 'Remove from plan',
                icon: const Icon(Icons.close_rounded, size: 18),
                onPressed: enabled ? onRemove : null,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 24,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.end,
            children: [
              _Stepper(
                label: 'Sets',
                idPrefix: 'sets-${draft.exercise.id}',
                value: draft.sets,
                min: 1,
                max: 10,
                enabled: enabled,
                onChanged: (value) => set(() => draft.sets = value),
              ),
              _Stepper(
                label: 'Reps',
                idPrefix: 'reps-${draft.exercise.id}',
                value: draft.reps,
                min: 1,
                max: 50,
                enabled: enabled,
                onChanged: (value) => set(() => draft.reps = value),
              ),
              SizedBox(
                width: 140,
                child: LabeledField(
                  label: 'Rest',
                  child: DropdownButtonFormField<int>(
                    initialValue: draft.restSeconds,
                    isDense: true,
                    isExpanded: true,
                    items: [
                      for (final seconds in _restOptions)
                        DropdownMenuItem(
                          value: seconds,
                          child: Text(seconds == 0 ? 'None' : '$seconds s'),
                        ),
                    ],
                    onChanged: enabled
                        ? (value) => set(() => draft.restSeconds = value ?? 60)
                        : null,
                  ),
                ),
              ),
              LabeledField(
                label: 'Difficulty',
                child: SegmentedButton<Difficulty>(
                  showSelectedIcon: false,
                  segments: [
                    for (final level in Difficulty.values)
                      ButtonSegment(value: level, label: Text(level.label)),
                  ],
                  selected: {draft.difficulty},
                  onSelectionChanged: enabled
                      ? (value) => set(() => draft.difficulty = value.first)
                      : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextFormField(
            initialValue: draft.note,
            enabled: enabled,
            maxLength: 200,
            decoration: const InputDecoration(
              hintText: 'Note for the patient (optional)',
              counterText: '',
            ),
            onChanged: (value) => draft.note = value,
          ),
        ],
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.label,
    required this.idPrefix,
    required this.value,
    required this.min,
    required this.max,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final String idPrefix;
  final int value;
  final int min;
  final int max;
  final bool enabled;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return LabeledField(
      label: label,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              key: Key('$idPrefix-minus'),
              tooltip: 'Fewer $label'.toLowerCase(),
              icon: const Icon(Icons.remove_rounded, size: 18),
              onPressed: enabled && value > min
                  ? () => onChanged(value - 1)
                  : null,
            ),
            SizedBox(
              width: 28,
              child: Text(
                '$value',
                key: Key('$idPrefix-value'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              key: Key('$idPrefix-plus'),
              tooltip: 'More $label'.toLowerCase(),
              icon: const Icon(Icons.add_rounded, size: 18),
              onPressed: enabled && value < max
                  ? () => onChanged(value + 1)
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// The selected patient's current plan and every plan before it.
class _History extends ConsumerWidget {
  const _History({required this.patient});

  final PatientSummary patient;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plans = ref.watch(patientPlansProvider(patient.id));
    return AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            "${patient.fullName}'s plans",
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          AsyncSection(
            value: plans,
            onRetry: () => ref.invalidate(patientPlansProvider(patient.id)),
            builder: (list) => list.isEmpty
                ? const EmptyState(
                    icon: Icons.assignment_outlined,
                    message: 'No plan has been assigned to this patient yet.',
                  )
                : Column(
                    children: [for (final plan in list) _PlanRow(plan: plan)],
                  ),
          ),
        ],
      ),
    );
  }
}

class _PlanRow extends StatelessWidget {
  const _PlanRow({required this.plan});

  final ExercisePlan plan;

  @override
  Widget build(BuildContext context) {
    final dates = plan.archivedAt == null
        ? 'Assigned ${formatDate(plan.createdAt)}'
        : '${formatDate(plan.createdAt)} to ${formatDate(plan.archivedAt!)}';
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.divider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  plan.name,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                dates,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textMuted,
                ),
              ),
              const SizedBox(width: 12),
              plan.isActive
                  ? const Pill.success('Current')
                  : const Pill.neutral('Archived'),
            ],
          ),
          const SizedBox(height: 6),
          for (final item in plan.items)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '${item.position}. ${item.exercise.name}  ·  ${item.prescription}  ·  '
                '${item.rest}  ·  ${item.difficulty.label}',
                style: const TextStyle(
                  fontSize: 14,
                  color: AppColors.textMuted,
                ),
              ),
            ),
          if (plan.isActive && plan.hasInactiveExercise) ...[
            const SizedBox(height: 10),
            InlineBanner(
              tone: BannerTone.warning,
              icon: Icons.warning_amber_rounded,
              message:
                  'No longer available: ${plan.inactiveExerciseNames.join(', ')}. '
                  'Assign an updated plan without ${plan.inactiveExerciseNames.length == 1 ? 'it' : 'them'}.',
            ),
          ],
        ],
      ),
    );
  }
}
