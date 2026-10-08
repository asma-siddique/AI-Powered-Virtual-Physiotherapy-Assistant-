import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'features/admin/admin_pages.dart';
import 'features/admin/exercise_form_page.dart';
import 'features/admin/exercise_library_page.dart';
import 'features/auth/auth_controller.dart';
import 'features/auth/auth_models.dart';
import 'features/auth/ui/choose_role_screen.dart';
import 'features/auth/ui/register_screen.dart';
import 'features/auth/ui/sign_in_screen.dart';
import 'features/auth/ui/welcome_screen.dart';
import 'features/consent/advisory_screen.dart';
import 'features/consent/help_page.dart';
import 'features/patient/exercise_plan_page.dart';
import 'features/patient/patient_home_page.dart';
import 'features/physio/plan_builder_page.dart';
import 'features/physio/physio_pages.dart';
import 'features/shell/page_widgets.dart';
import 'features/shell/role_shell.dart';

/// Full-screen advisory a patient must acknowledge before using the app.
const advisoryPath = '/patient/advisory';

bool _isPublic(String location) =>
    location == '/' ||
    location == '/register' ||
    location == '/sign-in' ||
    location.startsWith('/sign-in/');

UserRole? _roleFromPath(String? value) {
  for (final role in UserRole.values) {
    if (role.apiValue == value) return role;
  }
  return null;
}

/// Where a request for [location] should go instead, or null to allow it.
/// The server enforces access on every request; this only keeps the UI honest.
String? redirectFor(AuthState auth, String location) {
  // Still checking for a saved session: keep the address as it is, so a
  // refresh or a shared link lands on the same page once that finishes.
  if (auth is AuthLoading) return null;
  if (auth is! SignedIn) {
    return _isPublic(location) ? null : '/sign-in';
  }
  final home = auth.user.account.role.homePath;
  if (auth.user.needsAdvisory) {
    // Nothing else opens until the advisory has been acknowledged.
    return location == advisoryPath ? null : advisoryPath;
  }
  if (location == advisoryPath) return home;
  final insideOwnArea = location == home || location.startsWith('$home/');
  return insideOwnArea ? null : home;
}

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier(0);
  ref.listen(authControllerProvider, (_, _) => refresh.value++);
  ref.onDispose(refresh.dispose);

  ShellRoute area(UserRole role, List<GoRoute> routes) => ShellRoute(
    builder: (context, state, child) =>
        RoleShell(role: role, location: state.matchedLocation, child: child),
    routes: routes,
  );

  // Pages inside a shell appear at once (the sidebar stays put) and each one
  // has its own scrolling body.
  Page<void> shellPage(GoRouterState state, Widget child) => NoTransitionPage(
    key: state.pageKey,
    child: ShellPageBody(child: child),
  );

  GoRoute page(String path, Widget child) => GoRoute(
    path: path,
    pageBuilder: (context, state) => shellPage(state, child),
  );

  GoRoute soon(String path, String title, String description) =>
      page(path, ComingSoonPage(title: title, description: description));

  return GoRouter(
    initialLocation: '/',
    refreshListenable: refresh,
    redirect: (context, state) =>
        redirectFor(ref.read(authControllerProvider), state.matchedLocation),
    routes: [
      GoRoute(path: '/', builder: (context, state) => const WelcomeScreen()),
      GoRoute(
        path: '/sign-in',
        builder: (context, state) => const ChooseRoleScreen(),
        routes: [
          GoRoute(
            path: ':role',
            redirect: (context, state) =>
                _roleFromPath(state.pathParameters['role']) == null
                ? '/sign-in'
                : null,
            builder: (context, state) => SignInScreen(
              role: _roleFromPath(state.pathParameters['role'])!,
            ),
          ),
        ],
      ),
      GoRoute(
        path: '/register',
        builder: (context, state) => const RegisterScreen(),
      ),
      // Outside the patient shell on purpose: no sidebar, nowhere else to go.
      GoRoute(
        path: advisoryPath,
        builder: (context, state) => const AdvisoryScreen(),
      ),
      area(UserRole.patient, [
        page('/patient', const PatientHomePage()),
        page('/patient/plan', const ExercisePlanPage()),
        soon(
          '/patient/history',
          'Session History',
          'Your completed sessions will be listed here.',
        ),
        soon(
          '/patient/progress',
          'Progress',
          'Your form-score trend will be shown here.',
        ),
        soon(
          '/patient/chat',
          'Chat',
          'You will be able to message your physiotherapist here.',
        ),
        soon(
          '/patient/feedback',
          'Feedback',
          'You will be able to share feedback here.',
        ),
        page('/patient/help', const PatientHelpPage()),
      ]),
      area(UserRole.physiotherapist, [
        page('/physio', const PhysioDashboardPage()),
        page('/physio/patients', const PhysioPatientsPage()),
        GoRoute(
          path: '/physio/plan-builder',
          // ?patient=<id> opens the builder with that patient selected.
          pageBuilder: (context, state) => shellPage(
            state,
            PlanBuilderPage(
              initialPatientId: state.uri.queryParameters['patient'],
            ),
          ),
        ),
        soon(
          '/physio/flagged',
          'Flagged Sessions',
          'Sessions that need your review will appear here.',
        ),
        soon(
          '/physio/chat',
          'Chat',
          'You will be able to message your patients here.',
        ),
        soon(
          '/physio/feedback',
          'Patient Feedback',
          'Feedback from your patients will appear here.',
        ),
      ]),
      area(UserRole.admin, [
        page('/admin', const AdminOverviewPage()),
        page('/admin/users', const AdminUsersPage()),
        page('/admin/exercises', const ExerciseLibraryPage()),
        // "new" is listed before ":id" so it is not read as an exercise id.
        page('/admin/exercises/new', const ExerciseFormPage()),
        GoRoute(
          path: '/admin/exercises/:id',
          pageBuilder: (context, state) => shellPage(
            state,
            ExerciseFormPage(exerciseId: state.pathParameters['id']),
          ),
        ),
        soon(
          '/admin/feedback',
          'Patient Feedback',
          'Feedback from all patients will appear here.',
        ),
        page('/admin/audit-log', const AdminAuditLogPage()),
      ]),
    ],
  );
});
