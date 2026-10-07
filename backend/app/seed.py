"""Creates local demo accounts: `python -m app.seed`.

Reads the SEED_* values from .env (see .env.example). Safe to run repeatedly;
existing accounts are left untouched. Refuses to run in production."""

import uuid

from sqlalchemy import select
from sqlalchemy.orm import Session

from app import audit, clock
from app.config import get_settings
from app.db import get_engine
from app.models import Account, PatientAssignment, Role
from app.security import hash_password


def _ensure(db: Session, name: str, email: str | None, password: str | None, role: Role) -> Account | None:
    if not email or not password:
        print(f"  skipped {role.value}: SEED_* email/password not set")
        return None
    email = email.strip().lower()
    existing = db.execute(select(Account).where(Account.email == email)).scalar_one_or_none()
    if existing:
        print(f"  exists  {role.value}: {email}")
        return existing
    account = Account(
        id=uuid.uuid4(),
        full_name=name,
        email=email,
        password_hash=hash_password(password),
        role=role,
        created_at=clock.utcnow(),
    )
    db.add(account)
    db.flush()
    audit.record(
        db,
        "account.seeded",
        target_type="account",
        target_id=account.id,
        detail={"role": role.value},
    )
    print(f"  created {role.value}: {email}")
    return account


def main() -> None:
    settings = get_settings()
    if settings.is_production:
        raise SystemExit("Refusing to seed demo accounts in production.")
    with Session(get_engine()) as db:
        _ensure(
            db, settings.seed_admin_name, settings.seed_admin_email, settings.seed_admin_password, Role.admin
        )
        physio = _ensure(
            db,
            settings.seed_physio_name,
            settings.seed_physio_email,
            settings.seed_physio_password,
            Role.physiotherapist,
        )
        patient = _ensure(
            db,
            settings.seed_patient_name,
            settings.seed_patient_email,
            settings.seed_patient_password,
            Role.patient,
        )
        if physio and patient:
            linked = db.execute(
                select(PatientAssignment).where(
                    PatientAssignment.patient_id == patient.id, PatientAssignment.ended_at.is_(None)
                )
            ).scalar_one_or_none()
            if linked is None:
                db.add(
                    PatientAssignment(
                        patient_id=patient.id, physiotherapist_id=physio.id, assigned_at=clock.utcnow()
                    )
                )
        db.commit()
    print("Seed complete.")


if __name__ == "__main__":
    main()
