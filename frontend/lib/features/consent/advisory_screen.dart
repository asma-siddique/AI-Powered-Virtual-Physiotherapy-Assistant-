import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_exception.dart';
import '../../core/theme/app_colors.dart';
import '../../core/widgets/common.dart';
import '../auth/auth_controller.dart';
import '../shell/page_widgets.dart';
import 'advisory_content.dart';
import 'consent_repository.dart';

/// The mandatory advisory. A patient who has not acknowledged it is kept here
/// by the router: there is no skip, close or "later", only the explicit
/// acknowledgment (or logging out).
class AdvisoryScreen extends ConsumerStatefulWidget {
  const AdvisoryScreen({super.key});

  @override
  ConsumerState<AdvisoryScreen> createState() => _AdvisoryScreenState();
}

class _AdvisoryScreenState extends ConsumerState<AdvisoryScreen> {
  bool _agreed = false;
  bool _busy = false;
  String? _error;

  Future<void> _submit(Disclaimer disclaimer) async {
    if (_busy || !_agreed) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(consentRepositoryProvider).acknowledge(disclaimer.version);
      // The router lets the patient into the app as soon as this is set.
      ref.read(authControllerProvider.notifier).advisoryAcknowledged();
    } on ApiException catch (error) {
      if (!mounted) return;
      if (error.code == 'disclaimer_outdated') {
        // The wording changed while this screen was open: show the new text
        // and ask again, rather than recording consent to something unseen.
        ref.invalidate(consentStatusProvider);
        _agreed = false;
      }
      setState(() {
        _error = error.message;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Already acknowledged elsewhere (another device): nothing to ask.
    ref.listen(consentStatusProvider, (_, next) {
      if (next.valueOrNull?.acknowledged ?? false) {
        ref.read(authControllerProvider.notifier).advisoryAcknowledged();
      }
    });
    final status = ref.watch(consentStatusProvider);
    final narrow = MediaQuery.sizeOf(context).width < 600;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Container(
              height: 64,
              padding: EdgeInsets.symmetric(horizontal: narrow ? 16 : 40),
              decoration: const BoxDecoration(
                color: AppColors.surface,
                border: Border(bottom: BorderSide(color: AppColors.divider)),
              ),
              child: Row(
                children: [
                  const PhysioAiLogo(),
                  const Spacer(),
                  TextButton(
                    key: const Key('advisory-sign-out'),
                    onPressed: _busy
                        ? null
                        : () => ref
                              .read(authControllerProvider.notifier)
                              .signOut(),
                    child: const Text('Log out'),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.symmetric(
                  horizontal: narrow ? 16 : 40,
                  vertical: narrow ? 24 : 40,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 680),
                    child: AppCard(
                      padding: EdgeInsets.all(narrow ? 20 : 32),
                      child: AsyncSection(
                        value: status,
                        onRetry: () => ref.invalidate(consentStatusProvider),
                        builder: _form,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _form(ConsentStatus status) {
    final text = Theme.of(context).textTheme;
    final disclaimer = status.disclaimer;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Align(
          alignment: Alignment.centerLeft,
          child: Pill(
            'Required once before you can start',
            foreground: AppColors.tealDark,
            background: AppColors.tealTint,
          ),
        ),
        const SizedBox(height: 16),
        Text(disclaimer.title, style: text.headlineSmall),
        const SizedBox(height: 6),
        AdvisoryContent(disclaimer: disclaimer),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Divider(height: 1),
        ),
        if (_error != null) ...[
          InlineBanner(key: const Key('advisory-error'), message: _error!),
          const SizedBox(height: 16),
        ],
        // The whole row toggles the box, so the target is large and the label
        // is read out with the checkbox.
        MergeSemantics(
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: _busy ? null : () => setState(() => _agreed = !_agreed),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Checkbox(
                    key: const Key('advisory-checkbox'),
                    value: _agreed,
                    onChanged: _busy
                        ? null
                        : (value) => setState(() => _agreed = value ?? false),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        disclaimer.acknowledgment,
                        style: text.bodyMedium,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        BusyButton(
          key: const Key('advisory-continue'),
          label: 'I Understand & Continue',
          busy: _busy,
          onPressed: _agreed ? () => _submit(disclaimer) : null,
        ),
        if (!_agreed) ...[
          const SizedBox(height: 8),
          Text(
            'Tick the box above to continue.',
            textAlign: TextAlign.center,
            style: text.bodySmall?.copyWith(color: AppColors.textMuted),
          ),
        ],
      ],
    );
  }
}
