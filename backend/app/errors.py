from fastapi import HTTPException, status


class ApiError(HTTPException):
    """Every error body is {"detail": {"code", "message", ...}} so the client can
    branch on `code` and show `message` as written."""

    def __init__(
        self,
        status_code: int,
        code: str,
        message: str,
        *,
        headers: dict[str, str] | None = None,
        **extra: object,
    ) -> None:
        super().__init__(status_code, {"code": code, "message": message, **extra}, headers)


def invalid_credentials() -> ApiError:
    # Deliberately never says whether the identifier, the password or the chosen
    # role was the part that did not match.
    return ApiError(
        status.HTTP_401_UNAUTHORIZED,
        "invalid_credentials",
        "Those sign-in details are not correct. Check them and try again.",
    )


def account_locked(retry_after_seconds: int) -> ApiError:
    minutes = max(1, -(-retry_after_seconds // 60))
    return ApiError(
        status.HTTP_423_LOCKED,
        "account_locked",
        "Too many unsuccessful sign-in attempts. For your security, sign-in is paused. "
        f"Try again in about {minutes} minute{'s' if minutes != 1 else ''}.",
        headers={"Retry-After": str(retry_after_seconds)},
        retry_after_seconds=retry_after_seconds,
    )


def invite_invalid() -> ApiError:
    return ApiError(
        status.HTTP_400_BAD_REQUEST,
        "invite_invalid",
        "This invite code is not valid or has expired. Ask your physiotherapist for a new one.",
    )


def registration_failed() -> ApiError:
    return ApiError(
        status.HTTP_400_BAD_REQUEST,
        "registration_failed",
        "We could not create an account with these details. Check them and try again, "
        "or sign in if you already have an account.",
    )


def unauthenticated(code: str = "not_authenticated") -> ApiError:
    messages = {
        "not_authenticated": "Sign in to continue.",
        "token_expired": "Your access token has expired.",
        "token_invalid": "Sign in to continue.",
        "session_expired": "You were signed out after a period of inactivity. Sign in again.",
        "session_revoked": "This session was signed out. Sign in again.",
    }
    return ApiError(
        status.HTTP_401_UNAUTHORIZED,
        code,
        messages.get(code, "Sign in to continue."),
        headers={"WWW-Authenticate": "Bearer"},
    )


def forbidden() -> ApiError:
    return ApiError(status.HTTP_403_FORBIDDEN, "forbidden", "Your account cannot access this.")


def password_change_required() -> ApiError:
    return ApiError(
        status.HTTP_403_FORBIDDEN,
        "password_change_required",
        "Choose a new password to continue.",
    )


def conflict(code: str, message: str, **extra: object) -> ApiError:
    """The request is understood but cannot be carried out as things stand."""
    return ApiError(status.HTTP_409_CONFLICT, code, message, **extra)


def not_found(what: str = "Not found.") -> ApiError:
    return ApiError(status.HTTP_404_NOT_FOUND, "not_found", what)


def consent_required() -> ApiError:
    return ApiError(
        status.HTTP_403_FORBIDDEN,
        "consent_required",
        "Read and acknowledge the advisory before starting a session.",
    )


def disclaimer_outdated() -> ApiError:
    return ApiError(
        status.HTTP_409_CONFLICT,
        "disclaimer_outdated",
        "The advisory has been updated. Please read the latest version.",
    )
