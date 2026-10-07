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
    final theme = buildAppTheme();
    // Routes are only built once we know whether this device is signed in, so a
    // returning user never sees the sign-in screen flash before their home.
    final loading = ref.watch(
      authControllerProvider.select((state) => state is AuthLoading),
    );
    if (loading) {
      return MaterialApp(
        title: 'PhysioAI',
        debugShowCheckedModeBanner: false,
        theme: theme,
        home: const Scaffold(body: Center(child: PhysioAiLogo(size: 40))),
      );
    }
    return MaterialApp.router(
      title: 'PhysioAI',
      debugShowCheckedModeBanner: false,
      theme: theme,
      routerConfig: ref.watch(routerProvider),
    );
  }
}
