from fastapi import APIRouter, Request, Response, status

from app import consent_service, disclaimer, errors, plan_service, reminders
from app.deps import DbSession, PatientUser, client_ip
from app.exercise_schemas import PlanOut
from app.schemas import ConsentRequest, ConsentStatusOut, ReminderIn, ReminderOut

router = APIRouter(prefix="/patient", tags=["patient"])


@router.get("/consent", response_model=ConsentStatusOut)
def get_consent(patient: PatientUser, db: DbSession) -> ConsentStatusOut:
    """The advisory text and whether this patient has acknowledged it. Also what
    the Help page shows, so the wording is the same in both places."""
    return consent_service.status(db, patient.id)


@router.post("/consent", response_model=ConsentStatusOut, status_code=status.HTTP_201_CREATED)
def acknowledge_consent(
    body: ConsentRequest, patient: PatientUser, request: Request, response: Response, db: DbSession
) -> ConsentStatusOut:
    if body.version != disclaimer.CURRENT_VERSION:
        raise errors.disclaimer_outdated()
    _, created = consent_service.acknowledge(
        db, patient, ip=client_ip(request), user_agent=request.headers.get("user-agent")
    )
    if not created:
        response.status_code = status.HTTP_200_OK
    return consent_service.status(db, patient.id)


@router.get("/plan", response_model=PlanOut | None)
def get_plan(patient: PatientUser, db: DbSession) -> PlanOut | None:
    """The plan currently in force for this patient, or null if none is assigned."""
    plan = plan_service.active_plan(db, patient.id)
    return plan_service.to_out(db, plan) if plan else None


@router.get("/reminders", response_model=ReminderOut)
def get_reminders(patient: PatientUser, db: DbSession) -> ReminderOut:
    """When this patient is reminded of their exercises, and the days their
    plan prescribes."""
    return reminders.to_out(db, patient)


@router.put("/reminders", response_model=ReminderOut)
def save_reminders(body: ReminderIn, patient: PatientUser, db: DbSession) -> ReminderOut:
    """Switches reminders on or off, sets their time, or records how far the
    patient's clock is from UTC. Only what is sent changes."""
    return reminders.save(db, patient, body)
