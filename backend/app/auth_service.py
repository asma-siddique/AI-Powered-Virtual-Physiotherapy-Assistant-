import logging
import uuid
from datetime import datetime, timedelta

from sqlalchemy import select
from sqlalchemy.orm import Session

from app import audit, clock, consent_service
from app.config import get_settings
from app.models import Account, AuthSession, LoginAttempt, PatientAssignment, Role
from app.schemas import AccountOut, AuthResponse, MeResponse, PersonRef, TokenPair
from app.security import create_access_token, new_refresh_token, sha256_hex

log = logging.getLogger("physioai.auth")


def find_account(db: Session, kind: str, value: str) -> Account | None:
    column = Account.email if kind == "email" else Account.mobile
    return db.execute(select(Account).where(column == value)).scalar_one_or_none()


def subject_key_for(account: Account | None, normalized_identifier: str) -> str:
    return f"acct:{account.id}" if account else f"ident:{sha256_hex(normalized_identifier)}"


def locked_until(db: Session, subject_key: str) -> datetime | None:
    """Locked when the most recent `threshold` failures since the last successful
    sign-in all fall inside one window. Counted per account, never per IP."""
    settings = get_settings()
    now = clock.utcnow()
    last_success = db.execute(
        select(LoginAttempt.created_at)
        .where(LoginAttempt.subject_key == subject_key, LoginAttempt.succeeded.is_(True))
        .order_by(LoginAttempt.created_at.desc())
        .limit(1)
    ).scalar_one_or_none()

    query = (
        select(LoginAttempt.created_at)
        .where(LoginAttempt.subject_key == subject_key, LoginAttempt.succeeded.is_(False))
        .order_by(LoginAttempt.created_at.desc())
        .limit(settings.lockout_threshold)
    )
    if last_success is not None:
        query = query.where(LoginAttempt.created_at > last_success)
    failures = list(db.execute(query).scalars())

    if len(failures) < settings.lockout_threshold:
        return None
    newest, oldest = failures[0], failures[-1]
    if newest - oldest > timedelta(minutes=settings.lockout_window_minutes):
        return None
    until = newest + timedelta(minutes=settings.lockout_duration_minutes)
    return until if until > now else None


def record_attempt(db: Session, subject_key: str, succeeded: bool, ip: str | None) -> None:
    db.add(LoginAttempt(subject_key=subject_key, succeeded=succeeded, ip=ip, created_at=clock.utcnow()))
    db.flush()


def notify_account_locked(account: Account) -> None:
    # Push/email delivery arrives with the notifications sprint (FCM). Until then
    # the lockout is written to the audit log and the server log only.
    log.warning("Account %s locked after repeated failed sign-in attempts", account.id)


def register_lockout(db: Session, account: Account | None, subject_key: str, ip: str | None) -> None:
    audit.record(
        db,
        "auth.lockout",
        actor_id=None,
        target_type="account" if account else "identifier",
        # For an identifier with no account, only its hash is ever stored.
        target_id=account.id if account else subject_key.removeprefix("ident:"),
        detail={"threshold": get_settings().lockout_threshold},
        ip=ip,
    )
    if account:
        notify_account_locked(account)


def open_session(db: Session, account: Account, user_agent: str | None, ip: str | None) -> TokenPair:
    settings = get_settings()
    now = clock.utcnow()
    refresh_token, refresh_hash = new_refresh_token()
    session = AuthSession(
        id=uuid.uuid4(),
        account_id=account.id,
        refresh_token_hash=refresh_hash,
        created_at=now,
        last_seen_at=now,
        expires_at=now + timedelta(days=settings.refresh_token_days),
        user_agent=(user_agent or "")[:255] or None,
        ip=ip,
    )
    db.add(session)
    db.flush()
    access_token, expires_in = create_access_token(account.id, session.id)
    return TokenPair(access_token=access_token, refresh_token=refresh_token, expires_in=expires_in)


def current_physiotherapist(db: Session, patient_id: uuid.UUID) -> Account | None:
    return db.execute(
        select(Account)
        .join(PatientAssignment, PatientAssignment.physiotherapist_id == Account.id)
        .where(PatientAssignment.patient_id == patient_id, PatientAssignment.ended_at.is_(None))
    ).scalar_one_or_none()


def me_response(db: Session, account: Account) -> MeResponse:
    is_patient = account.role == Role.patient
    physio = current_physiotherapist(db, account.id) if is_patient else None
    return MeResponse(
        account=AccountOut.model_validate(account),
        physiotherapist=PersonRef.model_validate(physio) if physio else None,
        advisory_acknowledged=(
            consent_service.current_consent(db, account.id) is not None if is_patient else None
        ),
    )


def auth_response(db: Session, account: Account, tokens: TokenPair) -> AuthResponse:
    me = me_response(db, account)
    return AuthResponse(**me.model_dump(), tokens=tokens)
