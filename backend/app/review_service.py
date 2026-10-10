"""A physiotherapist's view of their patients' sessions (US 5.2): the flagged
queue, a session's detail and marking it reviewed. Everything here is limited
to patients currently assigned to the physiotherapist asking."""

import uuid

from sqlalchemy import select
from sqlalchemy.orm import Session

from app import audit, clock, errors, session_service
from app.models import Account, ExerciseSession, ExerciseTemplate, PatientAssignment
from app.schemas import PersonRef
from app.session_schemas import FlaggedSession

UNREVIEWED, REVIEWED, ALL = "unreviewed", "reviewed", "all"


def _on_roster(physio_id: uuid.UUID):
    """The condition that a session's patient is assigned to this
    physiotherapist now."""
    return ExerciseSession.patient_id.in_(
        select(PatientAssignment.patient_id).where(
            PatientAssignment.physiotherapist_id == physio_id, PatientAssignment.ended_at.is_(None)
        )
    )


def flagged(db: Session, physio: Account, state: str = UNREVIEWED) -> list[FlaggedSession]:
    """Flagged sessions of this physiotherapist's patients, most recently
    flagged first. A session leaves the unreviewed list only by being marked
    reviewed; nothing else removes it."""
    query = (
        select(ExerciseSession, ExerciseTemplate, Account)
        .join(ExerciseTemplate, ExerciseTemplate.id == ExerciseSession.exercise_template_id)
        .join(Account, Account.id == ExerciseSession.patient_id)
        .where(ExerciseSession.flagged_at.is_not(None), _on_roster(physio.id))
    )
    if state == UNREVIEWED:
        query = query.where(ExerciseSession.reviewed_at.is_(None))
    elif state == REVIEWED:
        query = query.where(ExerciseSession.reviewed_at.is_not(None))
    rows = db.execute(query.order_by(ExerciseSession.flagged_at.desc()).limit(500)).all()
    reviewers = {
        account.id: account
        for account in db.execute(
            select(Account).where(Account.id.in_({s.reviewed_by for s, _, _ in rows if s.reviewed_by}))
        ).scalars()
    }
    return [
        FlaggedSession(
            session=session_service.brief(db, session, template),
            patient=PersonRef.model_validate(patient),
            flagged_at=session.flagged_at,
            flag_threshold=session.flag_threshold,
            reviewed_by=(
                PersonRef.model_validate(reviewers[session.reviewed_by]) if session.reviewed_by else None
            ),
        )
        for session, template, patient in rows
    ]


def session_of_patient(
    db: Session, physio: Account, session_id: uuid.UUID, *, lock: bool = False
) -> ExerciseSession:
    """A session of one of this physiotherapist's patients. Anyone else's is
    not found, the same as one that does not exist."""
    query = select(ExerciseSession).where(ExerciseSession.id == session_id, _on_roster(physio.id))
    session = db.execute(query.with_for_update() if lock else query).scalar_one_or_none()
    if session is None:
        raise errors.not_found("Session not found.")
    return session


def mark_reviewed(db: Session, physio: Account, session_id: uuid.UUID, ip: str | None) -> ExerciseSession:
    session = session_of_patient(db, physio, session_id, lock=True)
    if session.flagged_at is None:
        raise errors.conflict("not_flagged", "This session was not flagged for review.")
    if session.reviewed_at is not None:
        # Marking it twice (a double tap, a colleague a moment earlier) changes
        # nothing and keeps the first review.
        return session
    session.reviewed_at = clock.utcnow()
    session.reviewed_by = physio.id
    audit.record(
        db,
        "session.reviewed",
        actor_id=physio.id,
        target_type="exercise_session",
        target_id=session.id,
        detail={"patient_id": str(session.patient_id), "flag_reasons": session.flag_reasons or []},
        ip=ip,
    )
    db.commit()
    return session
