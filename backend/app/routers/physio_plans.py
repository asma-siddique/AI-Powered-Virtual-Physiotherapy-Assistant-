import uuid

from fastapi import APIRouter, Request, status
from sqlalchemy import select

from app import plan_service
from app.deps import DbSession, PhysioUser, client_ip
from app.exercise_schemas import ExerciseBrief, PlanCreate, PlanOut
from app.models import ExerciseTemplate

router = APIRouter(prefix="/physio", tags=["physiotherapist: plans"])


@router.get("/exercises", response_model=list[ExerciseBrief])
def list_active_exercises(_: PhysioUser, db: DbSession) -> list[ExerciseTemplate]:
    """The plan builder's picker: only exercises an admin currently has switched
    on, which are the ones the system can score."""
    return list(
        db.execute(
            select(ExerciseTemplate).where(ExerciseTemplate.is_active).order_by(ExerciseTemplate.name)
        ).scalars()
    )


@router.post("/patients/{patient_id}/plans", response_model=PlanOut, status_code=status.HTTP_201_CREATED)
def assign_plan(
    patient_id: uuid.UUID, body: PlanCreate, physio: PhysioUser, request: Request, db: DbSession
) -> PlanOut:
    """Assigns a new plan. The patient's previous plan, if any, is archived."""
    patient = plan_service.patient_on_roster(db, physio.id, patient_id)
    plan = plan_service.assign(db, physio, patient, body, client_ip(request))
    return plan_service.to_out(db, plan)


@router.get("/patients/{patient_id}/plans", response_model=list[PlanOut])
def list_plans(patient_id: uuid.UUID, physio: PhysioUser, db: DbSession) -> list[PlanOut]:
    patient = plan_service.patient_on_roster(db, physio.id, patient_id)
    return [plan_service.to_out(db, plan) for plan in plan_service.history(db, patient.id)]
