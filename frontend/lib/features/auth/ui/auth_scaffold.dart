import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/common.dart';

/// Page frame for the signed-out screens: slim top bar with the logo, content
/// centred on the canvas, no sidebar.
class AuthScaffold extends StatelessWidget {
  const AuthScaffold({
    super.key,
    required this.child,
    this.trailing,
    this.maxWidth = 1100,
  });

  final Widget child;
  final Widget? trailing;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 600;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Container(
              height: 64,
              decoration: const BoxDecoration(
                color: AppColors.surface,
                border: Border(bottom: BorderSide(color: AppColors.divider)),
              ),
              padding: EdgeInsets.symmetric(horizontal: narrow ? 16 : 40),
              child: Row(
                children: [
                  InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => context.go('/'),
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: PhysioAiLogo(),
                    ),
                  ),
                  const Spacer(),
                  ?trailing,
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.symmetric(
                  horizontal: narrow ? 16 : 40,
                  vertical: narrow ? 24 : 48,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxWidth),
                    child: child,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
