"""In-app notifications. Every notification is a row the recipient can read in
the app; push delivery (Firebase Cloud Messaging) will send the same rows to
the device when the notifications sprint adds it."""

import uuid

from sqlalchemy.orm import Session

from app import clock
from app.models import Notification

PLAN_ASSIGNED = "plan_assigned"
SECURITY_LOCKOUT = "security_lockout"


def send(
    db: Session,
    recipient_id: uuid.UUID,
    kind: str,
    title: str,
    body: str,
    *,
    link: str | None = None,
) -> None:
    """Adds the notification to the caller's transaction, so it exists exactly
    when the change it describes was saved."""
    db.add(
        Notification(
            recipient_id=recipient_id,
            kind=kind,
            title=title,
            body=body,
            link=link,
            created_at=clock.utcnow(),
        )
    )
