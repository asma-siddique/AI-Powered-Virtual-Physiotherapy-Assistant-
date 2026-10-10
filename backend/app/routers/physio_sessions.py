import uuid
from datetime import datetime
from typing import Literal

from fastapi import APIRouter, Request

from app import plan_service, review_service, session_service
from app.deps import DbSession, PhysioUser, client_ip
from app.session_schemas import FlaggedSession, SessionBrief, SessionDetail

router = APIRouter(prefix="/physio", tags=["physiotherapist: sessions"])


@router.get("/flagged-sessions", response_model=list[FlaggedSession])
def list_flagged_sessions(
    physio: PhysioUser,
    db: DbSession,
    state: Literal["unreviewed", "reviewed", "all"] = "unreviewed",
) -> list[FlaggedSession]:
    """Sessions of the physiotherapist's own patients that had a RED
    repetition or scored below the threshold, most recently flagged first."""
    return review_service.flagged(db, physio, state)


@router.get("/sessions/{session_id}", response_model=SessionDetail)
def get_session(session_id: uuid.UUID, physio: PhysioUser, db: DbSession) -> SessionDetail:
    return session_service.detail(db, review_service.session_of_patient(db, physio, session_id))


@router.post("/sessions/{session_id}/review", response_model=SessionDetail)
def review_session(
    session_id: uuid.UUID, physio: PhysioUser, request: Request, db: DbSession
) -> SessionDetail:
    """Marks a flagged session as reviewed, which is the only thing that takes
    it out of the unreviewed queue."""
    session = review_service.mark_reviewed(db, physio, session_id, client_ip(request))
    return session_service.detail(db, session)


@router.get("/patients/{patient_id}/sessions", response_model=list[SessionBrief])
def list_patient_sessions(
    patient_id: uuid.UUID,
    physio: PhysioUser,
    db: DbSession,
    exercise_id: uuid.UUID | None = None,
    since: datetime | None = None,
    until: datetime | None = None,
) -> list[SessionBrief]:
    """The ended sessions of one of the physiotherapist's own patients."""
    patient = plan_service.patient_on_roster(db, physio.id, patient_id)
    return session_service.history(db, patient.id, exercise_id=exercise_id, since=since, until=until)
