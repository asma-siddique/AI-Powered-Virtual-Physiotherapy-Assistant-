import secrets
import uuid
from datetime import timedelta

from fastapi import APIRouter, Request, status
from sqlalchemy import select

from app import audit, clock, errors
from app.config import get_settings
from app.deps import DbSession, PhysioUser, client_ip
from app.models import Account, InviteCode, PatientAssignment
from app.schemas import InviteCodeOut, PatientSummary, PersonRef

router = APIRouter(prefix="/physio", tags=["physiotherapist"])

# No 0/O, 1/I/L: codes are read out and typed by hand.
_ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"


def _new_code() -> str:
    chars = "".join(secrets.choice(_ALPHABET) for _ in range(8))
    return f"PHY-{chars[:4]}-{chars[4:]}"


def _invite_out(invite: InviteCode, redeemed_by: Account | None) -> InviteCodeOut:
    if invite.redeemed_at is not None:
        state = "redeemed"
    elif invite.expires_at <= clock.utcnow():
        state = "expired"
    else:
        state = "active"
    return InviteCodeOut(
        id=invite.id,
        code=invite.code,
        created_at=invite.created_at,
        expires_at=invite.expires_at,
        status=state,
        redeemed_by=PersonRef.model_validate(redeemed_by) if redeemed_by else None,
    )


@router.post("/invite-codes", response_model=InviteCodeOut, status_code=status.HTTP_201_CREATED)
def create_invite_code(physio: PhysioUser, request: Request, db: DbSession) -> InviteCodeOut:
    now = clock.utcnow()
    invite = InviteCode(
        code=_new_code(),
        physiotherapist_id=physio.id,
        created_at=now,
        expires_at=now + timedelta(days=get_settings().invite_code_ttl_days),
    )
    db.add(invite)
    db.flush()
    audit.record(
        db,
        "invite_code.created",
        actor_id=physio.id,
        target_type="invite_code",
        target_id=invite.id,
        detail={"expires_at": invite.expires_at.isoformat()},
        ip=client_ip(request),
    )
    db.commit()
    return _invite_out(invite, None)


@router.get("/invite-codes", response_model=list[InviteCodeOut])
def list_invite_codes(physio: PhysioUser, db: DbSession) -> list[InviteCodeOut]:
    rows = db.execute(
        select(InviteCode, Account)
        .outerjoin(Account, Account.id == InviteCode.redeemed_by)
        .where(InviteCode.physiotherapist_id == physio.id)
        .order_by(InviteCode.created_at.desc())
    ).all()
    return [_invite_out(invite, patient) for invite, patient in rows]


def _roster_query(physio_id: uuid.UUID):
    return (
        select(Account, PatientAssignment.assigned_at)
        .join(PatientAssignment, PatientAssignment.patient_id == Account.id)
        .where(
            PatientAssignment.physiotherapist_id == physio_id,
            PatientAssignment.ended_at.is_(None),
        )
    )


def _summary(account: Account, assigned_at) -> PatientSummary:
    return PatientSummary(
        id=account.id,
        full_name=account.full_name,
        email=account.email,
        mobile=account.mobile,
        is_active=account.is_active,
        assigned_at=assigned_at,
    )


@router.get("/patients", response_model=list[PatientSummary])
def list_patients(physio: PhysioUser, db: DbSession) -> list[PatientSummary]:
    rows = db.execute(_roster_query(physio.id).order_by(Account.full_name)).all()
    return [_summary(account, assigned_at) for account, assigned_at in rows]


@router.get("/patients/{patient_id}", response_model=PatientSummary)
def get_patient(patient_id: uuid.UUID, physio: PhysioUser, db: DbSession) -> PatientSummary:
    row = db.execute(_roster_query(physio.id).where(Account.id == patient_id)).one_or_none()
    if row is None:
        # Same answer for "no such patient" and "another physiotherapist's
        # patient", so the roster of a colleague cannot be probed.
        raise errors.not_found("Patient not found.")
    return _summary(*row)
