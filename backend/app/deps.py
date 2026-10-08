from collections.abc import Callable
from dataclasses import dataclass
from datetime import timedelta
from typing import Annotated

from fastapi import Depends, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.orm import Session

from app import clock, consent_service, errors
from app.config import get_settings
from app.db import get_db
from app.models import Account, AuthSession, Role
from app.security import TokenError, decode_access_token

_bearer = HTTPBearer(auto_error=False)

DbSession = Annotated[Session, Depends(get_db)]


@dataclass
class AuthContext:
    account: Account
    session: AuthSession


def client_ip(request: Request) -> str | None:
    return request.client.host if request.client else None


def session_problem(session: AuthSession | None) -> str | None:
    """Why a session can no longer be used, or None if it is still good."""
    if session is None or session.revoked_at is not None:
        return "session_revoked"
    now = clock.utcnow()
    idle_limit = timedelta(minutes=get_settings().idle_timeout_minutes)
    if session.expires_at <= now or now - session.last_seen_at > idle_limit:
        return "session_expired"
    return None


def get_auth_context(
    db: DbSession,
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(_bearer)],
) -> AuthContext:
    if credentials is None:
        raise errors.unauthenticated()
    try:
        claims = decode_access_token(credentials.credentials)
    except TokenError as exc:
        raise errors.unauthenticated(exc.code) from exc

    session = db.get(AuthSession, claims.session_id)
    problem = session_problem(session)
    if problem or session is None or session.account_id != claims.account_id:
        raise errors.unauthenticated(problem or "token_invalid")

    # The role and active flag are read from the database on every request, so a
    # role change or deactivation takes effect immediately, not at token expiry.
    account = db.get(Account, session.account_id)
    if account is None or not account.is_active:
        raise errors.unauthenticated("session_revoked")

    now = clock.utcnow()
    if now - session.last_seen_at > timedelta(seconds=60):
        session.last_seen_at = now
        db.commit()
    return AuthContext(account=account, session=session)


CurrentAuth = Annotated[AuthContext, Depends(get_auth_context)]


def require_ready(auth: CurrentAuth) -> AuthContext:
    """While an account still has the temporary password an admin issued, it can
    only read its own profile, choose a new password or sign out."""
    if auth.account.must_change_password:
        raise errors.password_change_required()
    return auth


ReadyAuth = Annotated[AuthContext, Depends(require_ready)]


def require_role(*roles: Role) -> Callable[[AuthContext], Account]:
    def dependency(auth: ReadyAuth) -> Account:
        if auth.account.role not in roles:
            raise errors.forbidden()
        return auth.account

    return dependency


PatientUser = Annotated[Account, Depends(require_role(Role.patient))]
PhysioUser = Annotated[Account, Depends(require_role(Role.physiotherapist))]
AdminUser = Annotated[Account, Depends(require_role(Role.admin))]


def require_consent(patient: PatientUser, db: DbSession) -> Account:
    """For every endpoint that starts or records a live session: no session data
    may exist for a patient who has not acknowledged the current advisory."""
    if consent_service.current_consent(db, patient.id) is None:
        raise errors.consent_required()
    return patient


ConsentedPatient = Annotated[Account, Depends(require_consent)]
