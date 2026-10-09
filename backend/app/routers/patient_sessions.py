import uuid

from fastapi import APIRouter, Request, status

from app import session_service
from app.deps import ConsentedPatient, DbSession, client_ip
from app.session_schemas import PrecheckRequirements, SessionOut, SessionStart

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


@router.get("/sessions/{session_id}", response_model=SessionOut)
def get_session(session_id: uuid.UUID, patient: ConsentedPatient, db: DbSession) -> SessionOut:
    return session_service.to_out(db, session_service.own_session(db, patient, session_id))


@router.post("/sessions/{session_id}/end", response_model=SessionOut)
def end_session(
    session_id: uuid.UUID, patient: ConsentedPatient, request: Request, db: DbSession
) -> SessionOut:
    session = session_service.end(db, patient, session_id, client_ip(request))
    return session_service.to_out(db, session)
