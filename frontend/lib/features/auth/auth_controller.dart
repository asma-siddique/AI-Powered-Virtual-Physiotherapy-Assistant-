import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/api_client.dart';
import '../../core/api/api_exception.dart';
import 'auth_models.dart';
import 'auth_repository.dart';

sealed class AuthState {
  const AuthState();
}

/// Checking whether this device already holds a session.
class AuthLoading extends AuthState {
  const AuthLoading();
}

class SignedOut extends AuthState {
  const SignedOut({this.notice});

  /// Shown once on the sign-in screen, e.g. after an idle timeout.
  final String? notice;
}

class SignedIn extends AuthState {
  const SignedIn(this.user);

  final SessionUser user;
}

final authControllerProvider = NotifierProvider<AuthController, AuthState>(
  AuthController.new,
);

/// The signed-in user, or null while signed out (including the single frame
/// between signing out and the router leaving the signed-in pages).
final currentUserProvider = Provider<SessionUser?>((ref) {
  final state = ref.watch(authControllerProvider);
  return state is SignedIn ? state.user : null;
});

class AuthController extends Notifier<AuthState> {
  AuthRepository get _repository => ref.read(authRepositoryProvider);

  @override
  AuthState build() {
    ref.read(apiClientProvider).onSessionEnded = _onSessionEnded;
    Future.microtask(_restore);
    return const AuthLoading();
  }

  Future<void> _restore() async {
    try {
      final user = await _repository.restore();
      state = user == null ? const SignedOut() : SignedIn(user);
    } on ApiException {
      // Offline at start-up: ask for sign-in rather than guessing who this is.
      state = const SignedOut();
    }
  }

  void _onSessionEnded(ApiException reason) {
    if (state is! SignedIn) return;
    state = SignedOut(notice: reason.message);
  }

  /// Throws [ApiException] with a message ready to show on the form.
  Future<void> signIn({
    required String identifier,
    required String password,
    required UserRole role,
  }) async {
    state = SignedIn(
      await _repository.signIn(
        identifier: identifier,
        password: password,
        role: role,
      ),
    );
  }

  Future<void> register({
    required String fullName,
    required String identifier,
    required String password,
    required String inviteCode,
  }) async {
    state = SignedIn(
      await _repository.register(
        fullName: fullName,
        identifier: identifier,
        password: password,
        inviteCode: inviteCode,
      ),
    );
  }

  Future<void> signOut() async {
    await _repository.signOut();
    state = const SignedOut();
  }
}
