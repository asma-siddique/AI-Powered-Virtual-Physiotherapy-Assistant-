import uuid

from fastapi import status
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app import audit, clock, errors, notifications
from app.exercise_schemas import (
    ExerciseBrief,
    FieldChange,
    PlanCreate,
    PlanItemOut,
    PlanOut,
    PrescriptionEditOut,
    PrescriptionUpdate,
)
from app.models import (
    Account,
    Difficulty,
    ExercisePlan,
    ExerciseTemplate,
    PatientAssignment,
    PlanExercise,
    PrescriptionEdit,
)
from app.schemas import PersonRef


def patient_on_roster(db: Session, physio_id: uuid.UUID, patient_id: uuid.UUID) -> Account:
    """The patient, if currently assigned to this physiotherapist. Otherwise the
    same "not found" whether the patient exists or belongs to a colleague."""
    patient = db.execute(
        select(Account)
        .join(PatientAssignment, PatientAssignment.patient_id == Account.id)
        .where(
            Account.id == patient_id,
            PatientAssignment.physiotherapist_id == physio_id,
            PatientAssignment.ended_at.is_(None),
        )
    ).scalar_one_or_none()
    if patient is None:
        raise errors.not_found("Patient not found.")
    return patient


def to_out(db: Session, plan: ExercisePlan) -> PlanOut:
    rows = db.execute(
        select(PlanExercise, ExerciseTemplate)
        .join(ExerciseTemplate, ExerciseTemplate.id == PlanExercise.exercise_template_id)
        .where(PlanExercise.plan_id == plan.id)
        .order_by(PlanExercise.position)
    ).all()
    physio = db.get(Account, plan.physiotherapist_id)
    return PlanOut(
        id=plan.id,
        name=plan.name,
        created_at=plan.created_at,
        archived_at=plan.archived_at,
        is_active=plan.archived_at is None,
        assigned_by=PersonRef.model_validate(physio),
        items=[
            PlanItemOut(
                id=item.id,
                position=item.position,
                exercise=ExerciseBrief.model_validate(template),
                sets=item.sets,
                reps=item.reps,
                rest_seconds=item.rest_seconds,
                difficulty=item.difficulty,
                note=item.note,
                revision=item.revision,
                updated_at=item.updated_at,
            )
            for item, template in rows
        ],
        has_inactive_exercise=any(not template.is_active for _, template in rows),
    )


def active_plan(db: Session, patient_id: uuid.UUID) -> ExercisePlan | None:
    return db.execute(
        select(ExercisePlan).where(ExercisePlan.patient_id == patient_id, ExercisePlan.archived_at.is_(None))
    ).scalar_one_or_none()


def history(db: Session, patient_id: uuid.UUID) -> list[ExercisePlan]:
    """Every plan the patient has had, the one in force first, then newest first."""
    return list(
        db.execute(
            select(ExercisePlan)
            .where(ExercisePlan.patient_id == patient_id)
            .order_by(ExercisePlan.archived_at.is_not(None), ExercisePlan.created_at.desc())
        ).scalars()
    )


def assign(db: Session, physio: Account, patient: Account, body: PlanCreate, ip: str | None) -> ExercisePlan:
    if not patient.is_active:
        raise errors.conflict(
            "patient_inactive",
            "This patient's account has been deactivated, so their plan cannot be changed.",
        )
    exercise_ids = [item.exercise_id for item in body.items]
    # Shared row locks: an admin deactivating one of these exercises at the same
    # moment waits until this plan is saved, or this request sees it inactive.
    templates = {
        template.id: template
        for template in db.execute(
            select(ExerciseTemplate).where(ExerciseTemplate.id.in_(exercise_ids)).with_for_update(read=True)
        ).scalars()
    }
    unavailable = [
        str(exercise_id)
        for exercise_id in exercise_ids
        if exercise_id not in templates or not templates[exercise_id].is_active
    ]
    if unavailable:
        db.rollback()
        raise errors.ApiError(
            status.HTTP_409_CONFLICT,
            "exercise_unavailable",
            "One or more of these exercises is no longer available. Refresh the list and choose again.",
            exercise_ids=unavailable,
        )

    now = clock.utcnow()
    previous = db.execute(
        select(ExercisePlan)
        .where(ExercisePlan.patient_id == patient.id, ExercisePlan.archived_at.is_(None))
        .with_for_update()
    ).scalar_one_or_none()
    if previous is not None:
        previous.archived_at = now
        db.flush()

    plan = ExercisePlan(
        id=uuid.uuid4(),
        patient_id=patient.id,
        physiotherapist_id=physio.id,
        name=body.name,
        created_at=now,
    )
    db.add(plan)
    try:
        db.flush()
    except IntegrityError as exc:
        # Two plans assigned to the same patient at once: only one becomes active.
        db.rollback()
        raise errors.ApiError(
            status.HTTP_409_CONFLICT,
            "plan_conflict",
            "This patient's plan was just changed by someone else. Reload and try again.",
        ) from exc

    for position, item in enumerate(body.items, start=1):
        db.add(
            PlanExercise(
                plan_id=plan.id,
                exercise_template_id=item.exercise_id,
                position=position,
                sets=item.sets,
                reps=item.reps,
                rest_seconds=item.rest_seconds,
                difficulty=item.difficulty,
                note=item.note,
            )
        )
    audit.record(
        db,
        "plan.assigned",
        actor_id=physio.id,
        target_type="exercise_plan",
        target_id=plan.id,
        detail={
            "patient_id": str(patient.id),
            "archived_plan_id": str(previous.id) if previous else None,
            "exercise_ids": [str(exercise_id) for exercise_id in exercise_ids],
        },
        ip=ip,
    )
    count = len(body.items)
    exercises = f"{count} exercise{'' if count == 1 else 's'}"
    notifications.send(
        db,
        patient.id,
        notifications.PLAN_ASSIGNED,
        "Your exercise plan was updated" if previous else "You have a new exercise plan",
        f'{physio.full_name} assigned you "{plan.name}" with {exercises}.',
        link="/patient/plan",
    )
    db.commit()
    return plan


_EDITABLE = ("sets", "reps", "rest_seconds", "difficulty", "note")


def plan_of(db: Session, patient: Account, plan_id: uuid.UUID) -> ExercisePlan:
    """One of this patient's plans, current or archived."""
    plan = db.execute(
        select(ExercisePlan).where(ExercisePlan.id == plan_id, ExercisePlan.patient_id == patient.id)
    ).scalar_one_or_none()
    if plan is None:
        raise errors.not_found("Plan not found.")
    return plan


def _plain(value: object) -> int | str | None:
    return value.value if isinstance(value, Difficulty) else value  # type: ignore[return-value]


def _in_words(changes: dict[str, dict[str, int | str | None]]) -> str:
    """ "sets 3 to 4, rest 60s to 90s" for the patient's notification. A note
    is only mentioned, never quoted."""
    parts = []
    for field, change in changes.items():
        before, after = change["from"], change["to"]
        if field == "note":
            parts.append("the note")
        elif field == "rest_seconds":
            parts.append(f"rest {before}s to {after}s")
        elif field == "difficulty":
            parts.append(f"difficulty {before} to {after}")
        else:
            parts.append(f"{field} {before} to {after}")
    return ", ".join(parts)


def edit_item(
    db: Session,
    physio: Account,
    patient: Account,
    plan: ExercisePlan,
    item_id: uuid.UUID,
    body: PrescriptionUpdate,
    ip: str | None,
) -> None:
    """Changes one exercise's prescription in the patient's current plan. What
    it was before is kept in prescription_edits; nothing is overwritten
    without a record."""
    if plan.archived_at is not None:
        raise errors.conflict(
            "plan_archived",
            "This is no longer the patient's current plan, so it cannot be edited.",
        )
    if not patient.is_active:
        raise errors.conflict(
            "patient_inactive",
            "This patient's account has been deactivated, so their plan cannot be changed.",
        )
    item = db.execute(
        select(PlanExercise)
        .where(PlanExercise.id == item_id, PlanExercise.plan_id == plan.id)
        .with_for_update()
    ).scalar_one_or_none()
    if item is None:
        raise errors.not_found("That exercise is not part of this plan.")

    changes: dict[str, dict[str, int | str | None]] = {}
    for field in _EDITABLE:
        if field not in body.model_fields_set:
            continue
        new, old = getattr(body, field), getattr(item, field)
        if new != old:
            changes[field] = {"from": _plain(old), "to": _plain(new)}
            setattr(item, field, new)
    if not changes:
        return

    now = clock.utcnow()
    item.revision += 1
    item.updated_at = now
    db.add(
        PrescriptionEdit(
            plan_id=plan.id,
            plan_exercise_id=item.id,
            edited_by=physio.id,
            edited_at=now,
            revision=item.revision,
            changes=changes,
        )
    )
    audit.record(
        db,
        "plan.prescription_edited",
        actor_id=physio.id,
        target_type="plan_exercise",
        target_id=item.id,
        detail={
            "patient_id": str(patient.id),
            "plan_id": str(plan.id),
            "revision": item.revision,
            # What a physiotherapist writes to a patient stays out of the audit
            # log: it records that the note changed, not what it says.
            "changes": {
                field: ({"changed": True} if field == "note" else change) for field, change in changes.items()
            },
        },
        ip=ip,
    )
    exercise = db.get(ExerciseTemplate, item.exercise_template_id)
    notifications.send(
        db,
        patient.id,
        notifications.PLAN_UPDATED,
        "Your exercise plan was updated",
        f"{physio.full_name} changed {exercise.name}: {_in_words(changes)}.",
        link="/patient/plan",
    )
    db.commit()


def edits(db: Session, plan: ExercisePlan) -> list[PrescriptionEditOut]:
    """Every edit made to the plan's prescriptions, oldest first."""
    rows = db.execute(
        select(PrescriptionEdit, Account, ExerciseTemplate.name)
        .join(Account, Account.id == PrescriptionEdit.edited_by)
        .join(PlanExercise, PlanExercise.id == PrescriptionEdit.plan_exercise_id)
        .join(ExerciseTemplate, ExerciseTemplate.id == PlanExercise.exercise_template_id)
        .where(PrescriptionEdit.plan_id == plan.id)
        .order_by(PrescriptionEdit.edited_at, PrescriptionEdit.id)
    ).all()
    return [
        PrescriptionEditOut(
            id=edit.id,
            item_id=edit.plan_exercise_id,
            exercise_name=exercise_name,
            edited_at=edit.edited_at,
            edited_by=PersonRef.model_validate(editor),
            revision=edit.revision,
            changes=[
                FieldChange(field=field, before=edit.changes[field]["from"], after=edit.changes[field]["to"])
                for field in _EDITABLE
                if field in edit.changes
            ],
        )
        for edit, editor, exercise_name in rows
    ]
