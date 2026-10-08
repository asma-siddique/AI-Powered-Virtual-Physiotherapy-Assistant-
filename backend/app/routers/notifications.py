import uuid
from typing import Annotated

from fastapi import APIRouter, Query, Response, status
from sqlalchemy import func, select, update

from app import clock, errors
from app.deps import CurrentAuth, DbSession
from app.models import Notification
from app.schemas import NotificationList, NotificationOut

router = APIRouter(prefix="/notifications", tags=["notifications"])


@router.get("", response_model=NotificationList)
def list_notifications(
    auth: CurrentAuth, db: DbSession, limit: Annotated[int, Query(ge=1, le=100)] = 30
) -> NotificationList:
    """The signed-in person's own notifications, newest first."""
    mine = Notification.recipient_id == auth.account.id
    items = db.execute(
        select(Notification).where(mine).order_by(Notification.created_at.desc()).limit(limit)
    ).scalars()
    unread = db.execute(
        select(func.count()).select_from(Notification).where(mine, Notification.read_at.is_(None))
    ).scalar_one()
    return NotificationList(
        unread_count=unread, items=[NotificationOut.model_validate(item) for item in items]
    )


@router.post("/read-all", status_code=status.HTTP_204_NO_CONTENT)
def mark_all_read(auth: CurrentAuth, db: DbSession) -> Response:
    db.execute(
        update(Notification)
        .where(Notification.recipient_id == auth.account.id, Notification.read_at.is_(None))
        .values(read_at=clock.utcnow())
    )
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/{notification_id}/read", status_code=status.HTTP_204_NO_CONTENT)
def mark_read(notification_id: uuid.UUID, auth: CurrentAuth, db: DbSession) -> Response:
    notification = db.get(Notification, notification_id)
    # Someone else's notification looks exactly like one that does not exist.
    if notification is None or notification.recipient_id != auth.account.id:
        raise errors.not_found("Notification not found.")
    if notification.read_at is None:
        notification.read_at = clock.utcnow()
        db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
