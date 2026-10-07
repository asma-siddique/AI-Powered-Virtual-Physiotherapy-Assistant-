import uuid
from typing import Any

from sqlalchemy.orm import Session

from app import clock
from app.models import AuditLog


def record(
    db: Session,
    action: str,
    *,
    actor_id: uuid.UUID | None = None,
    target_type: str | None = None,
    target_id: uuid.UUID | str | None = None,
    detail: dict[str, Any] | None = None,
    ip: str | None = None,
) -> None:
    """Adds an audit entry to the caller's transaction, so the entry and the
    change it describes commit or roll back together."""
    db.add(
        AuditLog(
            actor_id=actor_id,
            action=action,
            target_type=target_type,
            target_id=str(target_id) if target_id is not None else None,
            detail=detail or {},
            ip=ip,
            created_at=clock.utcnow(),
        )
    )
