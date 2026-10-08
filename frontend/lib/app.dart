import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/theme/app_theme.dart';
import 'core/widgets/common.dart';
import 'features/auth/auth_controller.dart';
import 'router.dart';

class PhysioAiApp extends ConsumerWidget {
  const PhysioAiApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loading = ref.watch(
      authControllerProvider.select((state) => state is AuthLoading),
    );
    return MaterialApp.router(
      title: 'PhysioAI',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      routerConfig: ref.watch(routerProvider),
      // Until we know whether this device is signed in, show the logo instead
      // of the page, so a returning user never sees sign-in flash before home.
      // The router keeps the requested address meanwhile.
      builder: (context, child) => loading
          ? const Scaffold(body: Center(child: PhysioAiLogo(size: 40)))
          : child!,
    );
  }
}
