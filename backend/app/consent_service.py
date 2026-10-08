import uuid

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app import audit, clock, disclaimer
from app.models import Account, ConsentRecord
from app.schemas import ConsentStatusOut, DisclaimerOut


def current_consent(db: Session, account_id: uuid.UUID) -> ConsentRecord | None:
    """The patient's acknowledgment of the advisory as it is worded today.
    An acknowledgment of older wording does not count."""
    return db.execute(
        select(ConsentRecord).where(
            ConsentRecord.account_id == account_id,
            ConsentRecord.disclaimer_version == disclaimer.CURRENT_VERSION,
        )
    ).scalar_one_or_none()


def status(db: Session, account_id: uuid.UUID) -> ConsentStatusOut:
    record = current_consent(db, account_id)
    return ConsentStatusOut(
        disclaimer=DisclaimerOut(version=disclaimer.CURRENT_VERSION, **disclaimer.DISCLAIMER),
        acknowledged=record is not None,
        acknowledged_at=record.acknowledged_at if record else None,
    )


def acknowledge(
    db: Session, patient: Account, *, ip: str | None, user_agent: str | None
) -> tuple[ConsentRecord, bool]:
    """Records the acknowledgment once. Returns the record and whether it was
    created by this call; repeating the call never moves the original timestamp."""
    existing = current_consent(db, patient.id)
    if existing is not None:
        return existing, False

    record = ConsentRecord(
        account_id=patient.id,
        disclaimer_version=disclaimer.CURRENT_VERSION,
        acknowledged_at=clock.utcnow(),
        ip=ip,
        user_agent=(user_agent or "")[:255] or None,
    )
    db.add(record)
    try:
        db.flush()
    except IntegrityError:
        # Two requests at once: the other one recorded it first.
        db.rollback()
        existing = current_consent(db, patient.id)
        assert existing is not None
        return existing, False

    audit.record(
        db,
        "consent.acknowledged",
        actor_id=patient.id,
        target_type="consent",
        target_id=record.id,
        detail={"disclaimer_version": record.disclaimer_version},
        ip=ip,
    )
    db.commit()
    return record, True
