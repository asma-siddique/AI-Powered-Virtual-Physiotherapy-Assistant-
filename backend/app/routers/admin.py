import uuid
from typing import Annotated

from fastapi import APIRouter, Query
from sqlalchemy import select

from app.deps import AdminUser, DbSession
from app.models import Account, AuditLog, ConsentRecord
from app.schemas import AuditEntryOut, ConsentRecordOut, PersonRef

router = APIRouter(prefix="/admin", tags=["admin"])


@router.get("/audit-log", response_model=list[AuditEntryOut])
def list_audit_log(
    _: AdminUser,
    db: DbSession,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
) -> list[AuditLog]:
    return list(db.execute(select(AuditLog).order_by(AuditLog.id.desc()).limit(limit)).scalars())


@router.get("/consents", response_model=list[ConsentRecordOut])
def list_consents(
    _: AdminUser,
    db: DbSession,
    account_id: uuid.UUID | None = None,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
) -> list[ConsentRecordOut]:
    """Advisory acknowledgments, newest first, for audit."""
    query = (
        select(ConsentRecord, Account)
        .join(Account, Account.id == ConsentRecord.account_id)
        .order_by(ConsentRecord.acknowledged_at.desc())
        .limit(limit)
    )
    if account_id is not None:
        query = query.where(ConsentRecord.account_id == account_id)
    return [
        ConsentRecordOut(
            id=record.id,
            account=PersonRef.model_validate(account),
            disclaimer_version=record.disclaimer_version,
            acknowledged_at=record.acknowledged_at,
        )
        for record, account in db.execute(query).all()
    ]
