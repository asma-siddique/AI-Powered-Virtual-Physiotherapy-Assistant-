import uuid

from fastapi import APIRouter, Request, Response, status
from sqlalchemy import or_, select, update
from sqlalchemy.exc import IntegrityError

from app import audit, auth_service, clock, errors
from app.deps import CurrentAuth, DbSession, client_ip, session_problem
from app.identifiers import normalize_identifier
from app.models import Account, AuthSession, InviteCode, PatientAssignment, Role
from app.schemas import (
    AuthResponse,
    LoginRequest,
    MeResponse,
    RefreshRequest,
    RegisterRequest,
    SessionOut,
    TokenPair,
)
from app.security import (
    burn_password_check,
    create_access_token,
    hash_password,
    new_refresh_token,
    sha256_hex,
    verify_password,
)

router = APIRouter(prefix="/auth", tags=["auth"])


@router.post("/register", response_model=AuthResponse, status_code=status.HTTP_201_CREATED)
def register(body: RegisterRequest, request: Request, db: DbSession) -> AuthResponse:
    """Patient self-registration. An account is only ever created together with
    its physiotherapist link, taken from a valid single-use invite code."""
    identifier = normalize_identifier(body.identifier)
    if identifier is None:
        raise errors.ApiError(
            status.HTTP_422_UNPROCESSABLE_CONTENT,
            "identifier_invalid",
            "Enter a valid email address or mobile number.",
        )
    kind, value = identifier
    now = clock.utcnow()
    ip = client_ip(request)

    code = body.invite_code.strip().upper()
    # Row lock: two people submitting the same code at once are handled one after
    # the other, and the second sees it already redeemed.
    invite = db.execute(
        select(InviteCode).where(InviteCode.code == code).with_for_update()
    ).scalar_one_or_none()
    if invite is None or invite.redeemed_at is not None or invite.expires_at <= now:
        raise errors.invite_invalid()
    physio = db.get(Account, invite.physiotherapist_id)
    if physio is None or not physio.is_active or physio.role != Role.physiotherapist:
        raise errors.invite_invalid()

    if auth_service.find_account(db, kind, value) is not None:
        db.rollback()
        raise errors.registration_failed()

    account = Account(
        id=uuid.uuid4(),
        full_name=body.full_name,
        email=value if kind == "email" else None,
        mobile=value if kind == "mobile" else None,
        password_hash=hash_password(body.password),
        role=Role.patient,
        created_at=now,
    )
    db.add(account)
    try:
        db.flush()
    except IntegrityError as exc:
        db.rollback()
        raise errors.registration_failed() from exc

    invite.redeemed_at = now
    invite.redeemed_by = account.id
    db.add(PatientAssignment(patient_id=account.id, physiotherapist_id=physio.id, assigned_at=now))
    audit.record(
        db,
        "account.registered",
        actor_id=account.id,
        target_type="account",
        target_id=account.id,
        detail={
            "role": Role.patient.value,
            "physiotherapist_id": str(physio.id),
            "invite_code_id": str(invite.id),
        },
        ip=ip,
    )
    tokens = auth_service.open_session(db, account, request.headers.get("user-agent"), ip)
    db.commit()
    return auth_service.auth_response(db, account, tokens)


@router.post("/login", response_model=AuthResponse)
def login(body: LoginRequest, request: Request, db: DbSession) -> AuthResponse:
    ip = client_ip(request)
    identifier = normalize_identifier(body.identifier)
    account = auth_service.find_account(db, *identifier) if identifier else None
    normalized = identifier[1] if identifier else body.identifier.strip().lower()
    subject_key = auth_service.subject_key_for(account, normalized)

    until = auth_service.locked_until(db, subject_key)
    if until is not None:
        # While locked the password is not even checked and nothing is recorded,
        # so guessing cannot continue and the lock cannot be extended forever.
        raise errors.account_locked(int((until - clock.utcnow()).total_seconds()) + 1)

    if account is not None:
        password_ok = verify_password(account.password_hash, body.password)
    else:
        burn_password_check(body.password)
        password_ok = False
    succeeded = (
        account is not None
        and password_ok
        and account.is_active
        and (body.role is None or body.role == account.role)
    )

    auth_service.record_attempt(db, subject_key, succeeded, ip)
    if not succeeded or account is None:
        until = auth_service.locked_until(db, subject_key)
        if until is not None:
            auth_service.register_lockout(db, account, subject_key, ip)
            db.commit()
            raise errors.account_locked(int((until - clock.utcnow()).total_seconds()) + 1)
        db.commit()
        raise errors.invalid_credentials()

    tokens = auth_service.open_session(db, account, request.headers.get("user-agent"), ip)
    db.commit()
    return auth_service.auth_response(db, account, tokens)


@router.post("/refresh", response_model=TokenPair)
def refresh(body: RefreshRequest, db: DbSession) -> TokenPair:
    token_hash = sha256_hex(body.refresh_token)
    session = db.execute(
        select(AuthSession)
        .where(
            or_(
                AuthSession.refresh_token_hash == token_hash,
                AuthSession.previous_refresh_token_hash == token_hash,
            )
        )
        .with_for_update()
    ).scalar_one_or_none()
    if session is None:
        raise errors.unauthenticated("session_revoked")

    now = clock.utcnow()
    if session.refresh_token_hash != token_hash:
        # A refresh token that was already rotated away is being replayed: treat
        # the session as stolen and end it.
        if session.revoked_at is None:
            session.revoked_at = now
            audit.record(
                db,
                "auth.refresh_token_reuse",
                actor_id=session.account_id,
                target_type="auth_session",
                target_id=session.id,
            )
            db.commit()
        raise errors.unauthenticated("session_revoked")

    problem = session_problem(session)
    account = db.get(Account, session.account_id)
    if problem or account is None or not account.is_active:
        raise errors.unauthenticated(problem or "session_revoked")

    new_token, new_hash = new_refresh_token()
    session.previous_refresh_token_hash = session.refresh_token_hash
    session.refresh_token_hash = new_hash
    session.last_seen_at = now
    access_token, expires_in = create_access_token(account.id, session.id)
    db.commit()
    return TokenPair(access_token=access_token, refresh_token=new_token, expires_in=expires_in)


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
def logout(auth: CurrentAuth, db: DbSession) -> Response:
    auth.session.revoked_at = clock.utcnow()
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/me", response_model=MeResponse)
def me(auth: CurrentAuth, db: DbSession) -> MeResponse:
    return auth_service.me_response(db, auth.account)


@router.get("/sessions", response_model=list[SessionOut])
def list_sessions(auth: CurrentAuth, db: DbSession) -> list[SessionOut]:
    """The account's own device list: every session that can still be used."""
    sessions = db.execute(
        select(AuthSession)
        .where(AuthSession.account_id == auth.account.id, AuthSession.revoked_at.is_(None))
        .order_by(AuthSession.last_seen_at.desc())
    ).scalars()
    return [
        SessionOut(
            id=s.id,
            created_at=s.created_at,
            last_seen_at=s.last_seen_at,
            user_agent=s.user_agent,
            ip=s.ip,
            current=s.id == auth.session.id,
        )
        for s in sessions
        if session_problem(s) is None
    ]


@router.delete("/sessions/{session_id}", status_code=status.HTTP_204_NO_CONTENT)
def revoke_session(session_id: uuid.UUID, auth: CurrentAuth, db: DbSession) -> Response:
    result = db.execute(
        update(AuthSession)
        .where(
            AuthSession.id == session_id,
            AuthSession.account_id == auth.account.id,
            AuthSession.revoked_at.is_(None),
        )
        .values(revoked_at=clock.utcnow())
    )
    if result.rowcount == 0:
        raise errors.not_found("That session does not exist or is already signed out.")
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
