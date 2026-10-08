"""In-app notifications. Every notification is a row the recipient can read in
the app; push delivery (Firebase Cloud Messaging) will send the same rows to
the device when the notifications sprint adds it."""

import uuid

from sqlalchemy.orm import Session

from app import clock
from app.models import Notification, Role

PLAN_ASSIGNED = "plan_assigned"
PLAN_UPDATED = "plan_updated"
SECURITY_LOCKOUT = "security_lockout"
SECURITY_PASSWORD_CHANGED = "security_password_changed"
ACCOUNT_ROLE_CHANGED = "account_role_changed"
PHYSIOTHERAPIST_CHANGED = "physiotherapist_changed"
PATIENT_ASSIGNED = "patient_assigned"
PATIENT_UNASSIGNED = "patient_unassigned"

_HOME = {Role.patient: "/patient", Role.physiotherapist: "/physio", Role.admin: "/admin"}


def security_link(role: Role) -> str:
    """The app's Account & Security page for someone with this role."""
    return f"{_HOME[role]}/security"


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
