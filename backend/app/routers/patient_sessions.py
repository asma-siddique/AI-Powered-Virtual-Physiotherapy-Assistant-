import uuid
from datetime import datetime

from fastapi import APIRouter, Request, Response, status

from app import session_service
from app.deps import ConsentedPatient, DbSession, client_ip
from app.session_schemas import (
    Acknowledge,
    PrecheckRequirements,
    RepetitionIn,
    RepetitionOut,
    SessionBrief,
    SessionDetail,
    SessionOut,
    SessionStart,
)

# Every endpoint here needs the advisory acknowledged: no session data may
# exist for a patient who has not read it.
router = APIRouter(prefix="/patient", tags=["patient: sessions"])


@router.get("/plan/items/{item_id}/precheck", response_model=PrecheckRequirements)
def get_precheck_requirements(
    item_id: uuid.UUID, patient: ConsentedPatient, db: DbSession
) -> PrecheckRequirements:
    """What the camera must show before a session with this exercise can start:
    the body landmarks its target joints need, and the lighting threshold."""
    return session_service.requirements(db, patient, item_id)


@router.post("/sessions", response_model=SessionOut, status_code=status.HTTP_201_CREATED)
def start_session(
    body: SessionStart, patient: ConsentedPatient, request: Request, db: DbSession
) -> SessionOut:
    """Starts a session, but only when the submitted camera check passes. The
    session records the prescription and thresholds in force at this moment."""
    session = session_service.start(db, patient, body.plan_exercise_id, body.precheck, client_ip(request))
    return session_service.to_out(db, session)


@router.get("/sessions", response_model=list[SessionBrief])
def list_sessions(
    patient: ConsentedPatient,
    db: DbSession,
    exercise_id: uuid.UUID | None = None,
    since: datetime | None = None,
    until: datetime | None = None,
) -> list[SessionBrief]:
    """The patient's own ended sessions, most recent first, optionally for one
    exercise and a range of start times (from `since`, before `until`)."""
    return session_service.history(db, patient.id, exercise_id=exercise_id, since=since, until=until)


@router.get("/sessions/{session_id}/detail", response_model=SessionDetail)
def get_session_detail(session_id: uuid.UUID, patient: ConsentedPatient, db: DbSession) -> SessionDetail:
    """One of the patient's own sessions with every repetition in it."""
    return session_service.detail(db, session_service.own_session(db, patient, session_id))


@router.get("/sessions/{session_id}", response_model=SessionOut)
def get_session(session_id: uuid.UUID, patient: ConsentedPatient, db: DbSession) -> SessionOut:
    return session_service.to_out(db, session_service.own_session(db, patient, session_id))


@router.post("/sessions/{session_id}/end", response_model=SessionOut)
def end_session(
    session_id: uuid.UUID, patient: ConsentedPatient, request: Request, db: DbSession
) -> SessionOut:
    session = session_service.end(db, patient, session_id, client_ip(request))
    return session_service.to_out(db, session)


@router.post(
    "/sessions/{session_id}/repetitions",
    response_model=RepetitionOut,
    status_code=status.HTTP_201_CREATED,
    responses={
        status.HTTP_200_OK: {"description": "The same repetition was sent again; nothing new was stored."}
    },
)
def record_repetition(
    session_id: uuid.UUID,
    body: RepetitionIn,
    patient: ConsentedPatient,
    request: Request,
    response: Response,
    db: DbSession,
) -> RepetitionOut:
    """Stores one counted repetition with what was measured during it. The
    server classifies it against the thresholds the session started with; a RED
    result pauses the session in the same step."""
    stored, replayed = session_service.record_repetition(db, patient, session_id, body, client_ip(request))
    if replayed:
        response.status_code = status.HTTP_200_OK
    return stored


@router.post("/sessions/{session_id}/acknowledge", response_model=SessionOut)
def acknowledge_pause(
    session_id: uuid.UUID, body: Acknowledge, patient: ConsentedPatient, request: Request, db: DbSession
) -> SessionOut:
    """The patient has read the corrective message of the RED repetition that
    paused the session, which lets it carry on."""
    session = session_service.acknowledge(db, patient, session_id, body.repetition_id, client_ip(request))
    return session_service.to_out(db, session)
