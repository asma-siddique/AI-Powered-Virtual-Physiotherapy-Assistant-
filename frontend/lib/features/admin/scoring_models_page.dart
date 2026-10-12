import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_exception.dart';
import '../../core/files/file_picker.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/common.dart';
import '../shell/page_widgets.dart';
import 'scoring_models_repository.dart';

/// "91.3%": a share from 0 to 1 as people read it.
String percent(double share) => '${(share * 100).toStringAsFixed(1)}%';

/// A held-out set's name as the server builds it
/// (`REHAB24-6:test:<split>:<build>`), in words.
String describeEvalSet(String evalSet) {
  final parts = evalSet.split(':');
  if (parts.length != 4 || parts[1] != 'test') return evalSet;
  final split = parts[2].length > 8 ? parts[2].substring(0, 8) : parts[2];
  return '${parts[0]} test subjects (split $split)';
}

/// The admin's view of what scores patients' sessions (US 4.1 and 4.3):
/// every model, how each did against held-out data, and every decision to
/// promote one or to go back. Nothing here changes by itself.
class ScoringModelsPage extends ConsumerStatefulWidget {
  const ScoringModelsPage({super.key});

  @override
  ConsumerState<ScoringModelsPage> createState() => _ScoringModelsPageState();
}

class _ScoringModelsPageState extends ConsumerState<ScoringModelsPage> {
  bool _busy = false;
  String? _error;
  String? _done;

  /// Runs one change, then shows the registry as the server now holds it.
  Future<void> _run(
    Future<ScoringRegistry> Function(ScoringModelsRepository) change,
    String done,
  ) async {
    setState(() {
      _busy = true;
      _error = null;
      _done = null;
    });
    try {
      await change(ref.read(scoringModelsRepositoryProvider));
      ref.invalidate(scoringRegistryProvider);
      if (mounted) setState(() => _done = done);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The JSON object a file holds; null when it holds anything else.
  static Map<String, dynamic>? _decoded(String text) {
    try {
      final content = jsonDecode(text);
      return content is Map<String, dynamic> ? content : null;
    } on FormatException {
      return null;
    }
  }

  /// Lets the admin choose a JSON file and returns what it holds, or null
  /// (with the reason on screen) when there is nothing usable.
  Future<Map<String, dynamic>?> _pickJson(
    List<String> needs,
    String madeBy,
  ) async {
    setState(() {
      _error = null;
      _done = null;
    });
    try {
      final file = await ref.read(textFilePickerProvider)('.json');
      if (file == null) return null;
      final content = _decoded(file.text);
      if (content == null || needs.any((key) => !content.containsKey(key))) {
        setState(
          () => _error =
              '${file.name} is not a file made by $madeBy. Nothing was sent.',
        );
        return null;
      }
      return content;
    } on PickedFileTooLarge catch (error) {
      setState(() => _error = '${error.name} is too large to be a model.');
    } on FilePickingUnsupported {
      setState(
        () => _error = 'Choosing a file is only available in the browser.',
      );
    }
    return null;
  }

  Future<void> _register() async {
    final registration = await _pickJson(const [
      'record',
      'splits',
      'weights_b64',
      'weights_sha256',
    ], 'python -m rehab.export');
    if (registration == null) return;
    final version =
        (registration['record'] as Map<String, dynamic>?)?['model_version'];
    await _run(
      (repository) => repository.register(registration),
      '$version is registered as a candidate. It scores nothing until it is promoted.',
    );
  }

  Future<void> _addEvaluation() async {
    final evaluation = await _pickJson(const [
      'model_version',
      'eval_set',
      'metrics',
    ], 'python -m rehab.evaluate');
    if (evaluation == null) return;
    await _run(
      (repository) => repository.addEvaluation(evaluation),
      'The evaluation of ${evaluation['model_version']} is recorded.',
    );
  }

  Future<void> _promote(ScoringRegistry registry, ScoringModel model) async {
    final own = model.latest;
    final current = registry.current;
    final theirs = own == null ? null : current.latestOn(own.evalSet);
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => _DecisionDialog(
        title: 'Promote ${model.version}?',
        confirmLabel: 'Promote',
        body: [
          Text(
            'New sessions will be scored by this model instead of '
            '${current.version}. Sessions already under way keep the model '
            'they started with.',
          ),
          const SizedBox(height: 12),
          if (own != null && theirs != null)
            _Comparison(
              model: model,
              own: own,
              current: current,
              theirs: theirs,
            )
          else
            InlineBanner(
              key: const Key('promotion-not-comparable'),
              tone: BannerTone.warning,
              icon: Icons.balance_rounded,
              message: own == null
                  ? 'This model has no evaluation against held-out data, so '
                        'it cannot be promoted.'
                  : '${current.version} has not been evaluated on the same '
                        'held-out set, so the two cannot be compared yet. Add '
                        'that evaluation first; until then this will be refused.',
            ),
        ],
      ),
    );
    if (reason == null) return;
    await _run(
      (repository) => repository.promote(model.version, reason),
      '${model.version} is now the production model.',
    );
  }

  Future<void> _rollback(ScoringRegistry registry, String target) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => _DecisionDialog(
        title: 'Go back to $target?',
        confirmLabel: 'Roll back',
        body: [
          Text(
            '$target was the production model before and is put back at once. '
            'New sessions are scored by it instead of ${registry.production}; '
            'sessions already under way keep the model they started with. '
            'Nothing is deleted.',
          ),
        ],
      ),
    );
    if (reason == null) return;
    await _run(
      (repository) => repository.rollback(reason, toVersion: target),
      '$target is the production model again.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final registry = ref.watch(scoringRegistryProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageIntro(
          title: 'Scoring models',
          subtitle:
              "What scores patients' sessions, how each model did on people "
              'it was not trained on, and every decision to change it.',
          action: Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                key: const Key('add-evaluation'),
                onPressed: _busy ? null : _addEvaluation,
                icon: const Icon(Icons.fact_check_outlined, size: 18),
                label: const Text('Add an evaluation'),
              ),
              FilledButton.icon(
                key: const Key('register-model'),
                onPressed: _busy ? null : _register,
                icon: const Icon(Icons.upload_file_rounded, size: 18),
                label: const Text('Register a model'),
              ),
            ],
          ),
        ),
        if (_error != null) ...[
          InlineBanner(key: const Key('models-error'), message: _error!),
          const SizedBox(height: 16),
        ],
        if (_done != null) ...[
          InlineBanner(
            key: const Key('models-done'),
            message: _done!,
            tone: BannerTone.success,
          ),
          const SizedBox(height: 16),
        ],
        AsyncSection(
          value: registry,
          onRetry: () => ref.invalidate(scoringRegistryProvider),
          builder: (registry) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _ProductionCard(
                registry: registry,
                onRollback: _busy || registry.rollbackTarget == null
                    ? null
                    : () => _rollback(registry, registry.rollbackTarget!),
              ),
              const SizedBox(height: 24),
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'All models',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'A model is promoted only by an admin, and only if it '
                      'agrees with the expert labels at least as often as the '
                      'current model on the same held-out people.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    for (final model in registry.models)
                      _ModelRow(
                        model: model,
                        onPromote: _busy || !model.isCandidate
                            ? null
                            : () => _promote(registry, model),
                        onPutBack: _busy || !model.isRetired
                            ? null
                            : () => _rollback(registry, model.version),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Decisions',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Every promotion and rollback, kept for good.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 8),
                    if (registry.history.isEmpty)
                      const Center(
                        child: EmptyState(
                          icon: Icons.gavel_rounded,
                          message:
                              'Nothing has been promoted yet. Sessions are '
                              'scored by the rule the app shipped with.',
                        ),
                      )
                    else
                      for (final decision in registry.history)
                        _DecisionRow(decision: decision),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ProductionCard extends StatelessWidget {
  const _ProductionCard({required this.registry, required this.onRollback});

  final ScoringRegistry registry;
  final VoidCallback? onRollback;

  @override
  Widget build(BuildContext context) {
    final current = registry.current;
    final target = registry.rollbackTarget;
    return AppCard(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.successTint,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.verified_outlined,
              color: AppColors.success,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Scoring new sessions now',
                  style: TextStyle(fontSize: 13, color: AppColors.textMuted),
                ),
                Text(
                  current.version,
                  key: const Key('production-version'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                Text(
                  current.kind == 'rule'
                      ? 'The rule the app shipped with: a score from each '
                            "repetition's severity tier. Not trained on data."
                      : 'A classifier trained on REHAB24-6. The severity '
                            'tiers and the safety pause still come from the '
                            'thresholds, never from the model.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
          if (target != null) ...[
            const SizedBox(width: 16),
            OutlinedButton.icon(
              key: const Key('roll-back'),
              onPressed: onRollback,
              icon: const Icon(Icons.undo_rounded, size: 18),
              label: Text('Roll back to $target'),
            ),
          ],
        ],
      ),
    );
  }
}

class _ModelRow extends StatelessWidget {
  const _ModelRow({
    required this.model,
    required this.onPromote,
    required this.onPutBack,
  });

  final ScoringModel model;
  final VoidCallback? onPromote;
  final VoidCallback? onPutBack;

  @override
  Widget build(BuildContext context) {
    final target = model.targetAgreement;
    final facts = [
      model.kind == 'rule' ? 'Rule' : 'Trained classifier',
      if (model.trainedOn != null) '${model.trainedOn} training repetitions',
      if (model.exercises.isNotEmpty) '${model.exercises.length} exercises',
      'registered ${formatDate(model.registeredAt)}'
          '${model.registeredBy == null ? '' : ' by ${model.registeredBy}'}',
    ];
    return Container(
      key: Key('model-${model.version}'),
      width: double.infinity,
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.only(top: 16),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.divider)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                model.version,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              switch (model.status) {
                'production' => const Pill.success(
                  'In production',
                  icon: Icons.verified_outlined,
                ),
                'candidate' => const Pill.warning('Candidate'),
                _ => const Pill.neutral('Was in production'),
              },
              if (model.isCandidate)
                FilledButton(
                  key: Key('promote-${model.version}'),
                  onPressed: onPromote,
                  child: const Text('Promote'),
                ),
              if (model.isRetired)
                TextButton.icon(
                  key: Key('put-back-${model.version}'),
                  onPressed: onPutBack,
                  icon: const Icon(Icons.undo_rounded, size: 18),
                  label: const Text('Put back'),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            facts.join(' · '),
            style: const TextStyle(fontSize: 13, color: AppColors.textMuted),
          ),
          const SizedBox(height: 8),
          if (model.evaluations.isEmpty)
            const Text(
              'Not yet evaluated against held-out data.',
              style: TextStyle(fontSize: 14, color: AppColors.textMuted),
            )
          else
            for (final evaluation in model.evaluations)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '${percent(evaluation.agreement)} agreement',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (target != null)
                      evaluation.agreement >= target
                          ? Pill.success('Meets the ${percent(target)} target')
                          : Pill.warning('Below the ${percent(target)} target'),
                    Text(
                      [
                        'over ${evaluation.repetitions} repetitions',
                        if (evaluation.balancedAccuracy != null)
                          'balanced ${percent(evaluation.balancedAccuracy!)}',
                        describeEvalSet(evaluation.evalSet),
                        formatDate(evaluation.createdAt),
                      ].join(' · '),
                      style: const TextStyle(
                        fontSize: 13,
                        color: AppColors.textMuted,
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

/// Both models on the same held-out set: what a promotion rests on.
class _Comparison extends StatelessWidget {
  const _Comparison({
    required this.model,
    required this.own,
    required this.current,
    required this.theirs,
  });

  final ScoringModel model;
  final ModelEvaluation own;
  final ScoringModel current;
  final ModelEvaluation theirs;

  @override
  Widget build(BuildContext context) {
    final better = own.agreement >= theirs.agreement;
    final target = model.targetAgreement;
    return Column(
      key: const Key('promotion-comparison'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InlineBanner(
          tone: better ? BannerTone.info : BannerTone.warning,
          icon: Icons.balance_rounded,
          message:
              'On ${describeEvalSet(own.evalSet)}: ${model.version} agrees '
              'with the expert labels ${percent(own.agreement)} of the time, '
              '${current.version} ${percent(theirs.agreement)}.'
              '${better ? '' : ' It does worse, so this will be refused.'}',
        ),
        if (target != null && own.agreement < target) ...[
          const SizedBox(height: 8),
          InlineBanner(
            tone: BannerTone.warning,
            message:
                'It is below the ${percent(target)} agreement the project '
                'aims for. Say in your reason why it should score sessions '
                'anyway.',
          ),
        ],
      ],
    );
  }
}

/// Asks for the reason a decision is recorded with. Pops with it, or with
/// null when the admin backs out.
class _DecisionDialog extends StatefulWidget {
  const _DecisionDialog({
    required this.title,
    required this.confirmLabel,
    required this.body,
  });

  final String title;
  final String confirmLabel;
  final List<Widget> body;

  @override
  State<_DecisionDialog> createState() => _DecisionDialogState();
}

class _DecisionDialogState extends State<_DecisionDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reason = _reason.text.trim();
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ...widget.body,
              const SizedBox(height: 16),
              TextField(
                key: const Key('decision-reason'),
                controller: _reason,
                maxLength: 300,
                minLines: 2,
                maxLines: 4,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Reason',
                  helperText: 'Recorded with your name and kept for good.',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('confirm-decision'),
          onPressed: reason.length < 5
              ? null
              : () => Navigator.of(context).pop(reason),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

class _DecisionRow extends StatelessWidget {
  const _DecisionRow({required this.decision});

  final ModelDecision decision;

  @override
  Widget build(BuildContext context) {
    final evidence =
        decision.agreement == null || decision.incumbentAgreement == null
        ? null
        : '${percent(decision.agreement!)} against '
              '${percent(decision.incumbentAgreement!)} on the same held-out set';
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.divider)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            decision.isRollback
                ? Icons.undo_rounded
                : Icons.arrow_upward_rounded,
            size: 18,
            color: decision.isRollback ? AppColors.warning : AppColors.success,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  decision.isRollback
                      ? 'Rolled back to ${decision.modelVersion} from '
                            '${decision.previousVersion}'
                      : 'Promoted ${decision.modelVersion} over '
                            '${decision.previousVersion}',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  [
                    '"${decision.reason}"',
                    ?evidence,
                    if (decision.decidedBy != null) 'by ${decision.decidedBy}',
                  ].join(' · '),
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            formatDateTime(decision.createdAt),
            style: const TextStyle(fontSize: 13, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }
}
