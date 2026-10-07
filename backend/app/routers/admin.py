from typing import Annotated

from fastapi import APIRouter, Query
from sqlalchemy import select

from app.deps import AdminUser, DbSession
from app.models import Account, AuditLog, Role
from app.schemas import AccountOut, AuditEntryOut

router = APIRouter(prefix="/admin", tags=["admin"])


@router.get("/users", response_model=list[AccountOut])
def list_users(_: AdminUser, db: DbSession, role: Role | None = None) -> list[Account]:
    query = select(Account).order_by(Account.created_at.desc())
    if role is not None:
        query = query.where(Account.role == role)
    return list(db.execute(query).scalars())


@router.get("/audit-log", response_model=list[AuditEntryOut])
def list_audit_log(
    _: AdminUser,
    db: DbSession,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
) -> list[AuditLog]:
    return list(db.execute(select(AuditLog).order_by(AuditLog.id.desc()).limit(limit)).scalars())
