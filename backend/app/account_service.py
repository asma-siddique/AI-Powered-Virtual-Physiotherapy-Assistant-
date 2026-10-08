"""What an admin can do to accounts (US 7.3 and the role change of US 1.3).
Every change is written to the audit log in the same transaction."""

import uuid
from typing import Any

from fastapi import status
from sqlalchemy import func, or_, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app import audit, auth_service, clock, errors, notifications
from app.admin_schemas import AdminUserOut, UserCreate, UserUpdate
from app.identifiers import normalize_identifier
from app.models import Account, AuthSession, PatientAssignment, Role
from app.schemas import PersonRef
from app.security import hash_password, new_temporary_password

_STAFF = {Role.physiotherapist, Role.admin}


def _identifier_taken() -> errors.ApiError:
    return errors.conflict(
        "identifier_taken", "Another account already uses this email address or mobile number."
    )


def _not_own_account(actor: Account, user: Account, action: str) -> None:
    # Also what keeps the system from ever losing its last admin: the admin
    # making a change is, by definition, still an active admin afterwards.
    if actor.id == user.id:
        raise errors.conflict("own_account", f"You cannot {action} your own account.")


def get_user(db: Session, user_id: uuid.UUID, *, lock: bool = False) -> Account:
    query = select(Account).where(Account.id == user_id)
    user = db.execute(query.with_for_update() if lock else query).scalar_one_or_none()
    if user is None:
        raise errors.not_found("User not found.")
    return user


def active_patient_count(db: Session, physiotherapist_id: uuid.UUID) -> int:
    return db.execute(
        select(func.count())
        .select_from(PatientAssignment)
        .join(Account, Account.id == PatientAssignment.patient_id)
        .where(
            PatientAssignment.physiotherapist_id == physiotherapist_id,
            PatientAssignment.ended_at.is_(None),
            Account.is_active.is_(True),
        )
    ).scalar_one()


def _has_patients(count: int, what: str) -> errors.ApiError:
    people = "1 active patient" if count == 1 else f"{count} active patients"
    return errors.conflict(
        "has_active_patients",
        f"This physiotherapist is responsible for {people}. Reassign them before you {what}.",
        patient_count=count,
    )


def _active_physiotherapist(db: Session, physiotherapist_id: uuid.UUID) -> Account:
    physio = db.get(Account, physiotherapist_id)
    if physio is None or physio.role != Role.physiotherapist or not physio.is_active:
        raise errors.ApiError(
            status.HTTP_422_UNPROCESSABLE_CONTENT,
            "physiotherapist_invalid",
            "Choose a physiotherapist whose account is active.",
        )
    return physio


def to_out(db: Session, accounts: list[Account]) -> list[AdminUserOut]:
    ids = [a.id for a in accounts]
    physios = dict(
        db.execute(
            select(PatientAssignment.patient_id, Account)
            .join(Account, Account.id == PatientAssignment.physiotherapist_id)
            .where(PatientAssignment.patient_id.in_(ids), PatientAssignment.ended_at.is_(None))
        ).all()
    )
    patient = Account.__table__.alias("patient")
    counts = dict(
        db.execute(
            select(PatientAssignment.physiotherapist_id, func.count())
            .join(patient, patient.c.id == PatientAssignment.patient_id)
            .where(
                PatientAssignment.physiotherapist_id.in_(ids),
                PatientAssignment.ended_at.is_(None),
                patient.c.is_active.is_(True),
            )
            .group_by(PatientAssignment.physiotherapist_id)
        ).all()
    )
    last_seen = dict(
        db.execute(
            select(AuthSession.account_id, func.max(AuthSession.last_seen_at))
            .where(AuthSession.account_id.in_(ids))
            .group_by(AuthSession.account_id)
        ).all()
    )
    return [
        AdminUserOut(
            id=a.id,
            full_name=a.full_name,
            email=a.email,
            mobile=a.mobile,
            role=a.role,
            is_active=a.is_active,
            created_at=a.created_at,
            must_change_password=a.must_change_password,
            last_seen_at=last_seen.get(a.id),
            physiotherapist=PersonRef.model_validate(physios[a.id]) if a.id in physios else None,
            patient_count=counts.get(a.id, 0) if a.role == Role.physiotherapist else None,
        )
        for a in accounts
    ]


def one_out(db: Session, account: Account) -> AdminUserOut:
    return to_out(db, [account])[0]


def search(db: Session, *, role: Role | None, active: bool | None, text: str | None) -> list[Account]:
    query = select(Account).order_by(func.lower(Account.full_name), Account.created_at)
    if role is not None:
        query = query.where(Account.role == role)
    if active is not None:
        query = query.where(Account.is_active.is_(active))
    if text and text.strip():
        # The search text is matched literally: % and _ are not wildcards here.
        escaped = text.strip().replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
        pattern = f"%{escaped}%"
        query = query.where(
            or_(
                Account.full_name.ilike(pattern, escape="\\"),
                Account.email.ilike(pattern, escape="\\"),
                Account.mobile.ilike(pattern, escape="\\"),
            )
        )
    return list(db.execute(query).scalars())


def create(db: Session, actor: Account, body: UserCreate, ip: str | None) -> tuple[Account, str]:
    identifier = normalize_identifier(body.identifier)
    if identifier is None:
        raise errors.ApiError(
            status.HTTP_422_UNPROCESSABLE_CONTENT,
            "identifier_invalid",
            "Enter a valid email address or mobile number.",
        )
    kind, value = identifier
    physio = _active_physiotherapist(db, body.physiotherapist_id) if body.physiotherapist_id else None
    if auth_service.find_account(db, kind, value) is not None:
        raise _identifier_taken()

    now = clock.utcnow()
    password = new_temporary_password()
    account = Account(
        id=uuid.uuid4(),
        full_name=body.full_name,
        email=value if kind == "email" else None,
        mobile=value if kind == "mobile" else None,
        password_hash=hash_password(password),
        role=body.role,
        must_change_password=True,
        created_at=now,
    )
    db.add(account)
    try:
        db.flush()
    except IntegrityError as exc:
        db.rollback()
        raise _identifier_taken() from exc
    detail: dict[str, Any] = {"role": body.role.value}
    if physio is not None:
        db.add(PatientAssignment(patient_id=account.id, physiotherapist_id=physio.id, assigned_at=now))
        detail["physiotherapist_id"] = str(physio.id)
        notifications.send(
            db,
            physio.id,
            notifications.PATIENT_ASSIGNED,
            "A patient was assigned to you",
            f"{account.full_name} is now one of your patients.",
            link="/physio/patients",
        )
    audit.record(
        db,
        "account.created",
        actor_id=actor.id,
        target_type="account",
        target_id=account.id,
        detail=detail,
        ip=ip,
    )
    return account, password


def update(db: Session, actor: Account, user: Account, body: UserUpdate, ip: str | None) -> None:
    changes: dict[str, dict[str, str | None]] = {}

    def change(field: str, new: str | None) -> None:
        old = getattr(user, field)
        if new != old:
            changes[field] = {"from": old, "to": new}
            setattr(user, field, new)

    if "full_name" in body.model_fields_set and body.full_name is not None:
        change("full_name", body.full_name)
    for field in ("email", "mobile"):
        if field not in body.model_fields_set:
            continue
        raw = (getattr(body, field) or "").strip()
        if not raw:
            change(field, None)
            continue
        identifier = normalize_identifier(raw)
        if identifier is None or identifier[0] != field:
            raise errors.ApiError(
                status.HTTP_422_UNPROCESSABLE_CONTENT,
                "identifier_invalid",
                "Enter a valid email address." if field == "email" else "Enter a valid mobile number.",
            )
        change(field, identifier[1])
    if user.email is None and user.mobile is None:
        raise errors.ApiError(
            status.HTTP_422_UNPROCESSABLE_CONTENT,
            "identifier_required",
            "An account needs an email address or a mobile number to sign in with.",
        )
    if not changes:
        return
    try:
        db.flush()
    except IntegrityError as exc:
        db.rollback()
        raise _identifier_taken() from exc
    audit.record(
        db,
        "account.updated",
        actor_id=actor.id,
        target_type="account",
        target_id=user.id,
        detail={"changes": changes},
        ip=ip,
    )


def set_active(db: Session, actor: Account, user: Account, active: bool, ip: str | None) -> None:
    if user.is_active == active:
        return
    if not active:
        _not_own_account(actor, user, "deactivate")
        if user.role == Role.physiotherapist:
            count = active_patient_count(db, user.id)
            if count:
                raise _has_patients(count, "deactivate this account")
    elif user.role == Role.patient:
        physio = auth_service.current_physiotherapist(db, user.id)
        if physio is None or not physio.is_active:
            raise errors.conflict(
                "physiotherapist_inactive",
                "This patient's physiotherapist is no longer active. "
                "Reassign the patient before reactivating the account.",
            )
    user.is_active = active
    signed_out = 0 if active else auth_service.revoke_sessions(db, user.id)
    audit.record(
        db,
        "account.activated" if active else "account.deactivated",
        actor_id=actor.id,
        target_type="account",
        target_id=user.id,
        detail={"role": user.role.value} | ({} if active else {"devices_signed_out": signed_out}),
        ip=ip,
    )


def change_role(db: Session, actor: Account, user: Account, role: Role, ip: str | None) -> None:
    previous = user.role
    if previous == role:
        return
    _not_own_account(actor, user, "change the role of")
    if previous not in _STAFF or role not in _STAFF:
        # A patient account carries a physiotherapist link, consent and clinical
        # records that mean nothing on a staff account, and the other way round.
        raise errors.conflict(
            "role_change_not_allowed",
            "A patient account cannot become a staff account, or a staff account a patient. "
            "Create a separate account instead.",
        )
    if previous == Role.physiotherapist:
        count = active_patient_count(db, user.id)
        if count:
            raise _has_patients(count, "change this role")
    user.role = role
    # Signing the person out is what makes the new role take effect at once:
    # their next request fails and the app returns them to sign-in.
    auth_service.revoke_sessions(db, user.id)
    audit.record(
        db,
        "account.role_changed",
        actor_id=actor.id,
        target_type="account",
        target_id=user.id,
        detail={"from": previous.value, "to": role.value},
        ip=ip,
    )
    label = "Admin" if role == Role.admin else "Physiotherapist"
    notifications.send(
        db,
        user.id,
        notifications.ACCOUNT_ROLE_CHANGED,
        f"Your role is now {label}",
        "An admin changed the role of your account. Choose this role when you sign in.",
    )


def reassign(
    db: Session, actor: Account, patient: Account, physiotherapist_id: uuid.UUID, ip: str | None
) -> None:
    if patient.role != Role.patient:
        raise errors.conflict("not_a_patient", "Only a patient is assigned to a physiotherapist.")
    new_physio = _active_physiotherapist(db, physiotherapist_id)
    current = db.execute(
        select(PatientAssignment)
        .where(PatientAssignment.patient_id == patient.id, PatientAssignment.ended_at.is_(None))
        .with_for_update()
    ).scalar_one_or_none()
    if current is not None and current.physiotherapist_id == new_physio.id:
        return
    now = clock.utcnow()
    old_physio = db.get(Account, current.physiotherapist_id) if current else None
    if current is not None:
        current.ended_at = now
        # The old row must be closed before the new one may exist.
        db.flush()
    db.add(PatientAssignment(patient_id=patient.id, physiotherapist_id=new_physio.id, assigned_at=now))
    audit.record(
        db,
        "patient.reassigned",
        actor_id=actor.id,
        target_type="account",
        target_id=patient.id,
        detail={
            "from_physiotherapist_id": str(old_physio.id) if old_physio else None,
            "to_physiotherapist_id": str(new_physio.id),
        },
        ip=ip,
    )
    notifications.send(
        db,
        patient.id,
        notifications.PHYSIOTHERAPIST_CHANGED,
        "You have a new physiotherapist",
        f"{new_physio.full_name} now looks after your exercise plan.",
        link="/patient",
    )
    notifications.send(
        db,
        new_physio.id,
        notifications.PATIENT_ASSIGNED,
        "A patient was assigned to you",
        f"{patient.full_name} is now one of your patients.",
        link="/physio/patients",
    )
    if old_physio is not None:
        notifications.send(
            db,
            old_physio.id,
            notifications.PATIENT_UNASSIGNED,
            "A patient was moved to a colleague",
            f"{patient.full_name} is no longer one of your patients.",
            link="/physio/patients",
        )


def reset_password(db: Session, actor: Account, user: Account, ip: str | None) -> str:
    _not_own_account(actor, user, "reset the password of")
    password = new_temporary_password()
    user.password_hash = hash_password(password)
    user.must_change_password = True
    signed_out = auth_service.revoke_sessions(db, user.id)
    auth_service.clear_lockout(db, user)
    audit.record(
        db,
        "account.password_reset",
        actor_id=actor.id,
        target_type="account",
        target_id=user.id,
        detail={"devices_signed_out": signed_out},
        ip=ip,
    )
    return password
