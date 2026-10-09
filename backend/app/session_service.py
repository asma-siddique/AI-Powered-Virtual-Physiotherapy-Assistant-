"""Starting and ending a patient's exercise session (US 3.1). A session only
exists once the camera pre-check has passed, and it keeps its own copy of the
prescription and thresholds it was started with."""

import uuid

from fastapi import status
from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app import audit, clock, errors, pose
from app.exercise_schemas import ExerciseBrief
from app.models import (
    Account,
    ExercisePlan,
    ExerciseSession,
    ExerciseTemplate,
    PlanExercise,
)
from app.session_schemas import PrecheckEvidence, PrecheckRequirements, SessionOut

ACTIVE, COMPLETED, ABANDONED = "active", "completed", "abandoned"


def _current_item(db: Session, patient: Account, item_id: uuid.UUID) -> tuple[PlanExercise, ExerciseTemplate]:
    """An exercise of the plan in force for this patient. Anything else, such
    as another patient's exercise or one from an archived plan, is not found."""
    row = db.execute(
        select(PlanExercise, ExerciseTemplate)
        .join(ExercisePlan, ExercisePlan.id == PlanExercise.plan_id)
        .join(ExerciseTemplate, ExerciseTemplate.id == PlanExercise.exercise_template_id)
        .where(
            PlanExercise.id == item_id,
            ExercisePlan.patient_id == patient.id,
            ExercisePlan.archived_at.is_(None),
        )
    ).one_or_none()
    if row is None:
        raise errors.not_found("That exercise is not in your current plan.")
    item, template = row
    if not template.is_active:
        raise errors.conflict(
            "exercise_unavailable",
            "This exercise is not available at the moment. Your physiotherapist can update your plan.",
        )
    return item, template


def requirements(db: Session, patient: Account, item_id: uuid.UUID) -> PrecheckRequirements:
    item, template = _current_item(db, patient, item_id)
    return PrecheckRequirements(
        item_id=item.id,
        exercise=ExerciseBrief.model_validate(template),
        sets=item.sets,
        reps=item.reps,
        rest_seconds=item.rest_seconds,
        difficulty=item.difficulty.value,
        required_landmarks=pose.required_landmarks(template.target_joints),
        min_visibility=pose.MIN_VISIBILITY,
        min_brightness=pose.MIN_BRIGHTNESS,
        hold_ms=pose.HOLD_MS,
    )


def to_out(db: Session, session: ExerciseSession) -> SessionOut:
    template = db.get(ExerciseTemplate, session.exercise_template_id)
    return SessionOut(
        id=session.id,
        status=session.status,
        started_at=session.started_at,
        ended_at=session.ended_at,
        exercise=ExerciseBrief.model_validate(template),
        sets=session.sets,
        reps=session.reps,
        rest_seconds=session.rest_seconds,
        difficulty=session.difficulty,
        prescription_revision=session.prescription_revision,
        template_version=session.template_version,
        required_landmarks=pose.required_landmarks(template.target_joints),
    )


def start(
    db: Session, patient: Account, item_id: uuid.UUID, evidence: PrecheckEvidence, ip: str | None
) -> ExerciseSession:
    item, template = _current_item(db, patient, item_id)
    required = pose.required_landmarks(template.target_joints)
    problems = pose.precheck_problems(
        required,
        brightness=evidence.brightness,
        visibility=evidence.visibility,
        held_ms=evidence.held_ms,
    )
    if problems:
        # No session row is written, so nothing can ever be scored against a
        # camera setup that did not pass.
        raise errors.ApiError(
            status.HTTP_422_UNPROCESSABLE_CONTENT,
            "precheck_failed",
            "Your camera setup has not passed the check yet. Follow the guidance on screen and try again.",
            problems=problems,
        )

    now = clock.utcnow()
    # One session at a time: one left open (a closed tab, a lost connection) is
    # closed as abandoned rather than left running forever.
    for stale in db.execute(
        select(ExerciseSession)
        .where(ExerciseSession.patient_id == patient.id, ExerciseSession.status == ACTIVE)
        .with_for_update()
    ).scalars():
        stale.status = ABANDONED
        stale.ended_at = now
    db.flush()

    session = ExerciseSession(
        id=uuid.uuid4(),
        patient_id=patient.id,
        plan_id=item.plan_id,
        plan_exercise_id=item.id,
        exercise_template_id=template.id,
        # Copies, not references: editing the plan or the thresholds later
        # must never change what this session was performed and scored against.
        template_version=template.version,
        checks=template.checks,
        prescription_revision=item.revision,
        sets=item.sets,
        reps=item.reps,
        rest_seconds=item.rest_seconds,
        difficulty=item.difficulty.value,
        status=ACTIVE,
        started_at=now,
        precheck={
            "brightness": evidence.brightness,
            "held_ms": evidence.held_ms,
            "visibility": {name: evidence.visibility[name] for name in required},
            "min_visibility": pose.MIN_VISIBILITY,
            "min_brightness": pose.MIN_BRIGHTNESS,
            "hold_ms": pose.HOLD_MS,
        },
    )
    db.add(session)
    try:
        db.flush()
    except IntegrityError as exc:
        # Two starts at the same moment: only one session becomes the active one.
        db.rollback()
        raise errors.conflict(
            "session_conflict", "A session was just started on another device. Try again."
        ) from exc
    audit.record(
        db,
        "session.started",
        actor_id=patient.id,
        target_type="exercise_session",
        target_id=session.id,
        detail={
            "plan_exercise_id": str(item.id),
            "exercise_template_id": str(template.id),
            "template_version": template.version,
            "prescription_revision": item.revision,
        },
        ip=ip,
    )
    db.commit()
    return session


def own_session(
    db: Session, patient: Account, session_id: uuid.UUID, *, lock: bool = False
) -> ExerciseSession:
    query = select(ExerciseSession).where(
        ExerciseSession.id == session_id, ExerciseSession.patient_id == patient.id
    )
    session = db.execute(query.with_for_update() if lock else query).scalar_one_or_none()
    if session is None:
        raise errors.not_found("Session not found.")
    return session


def end(db: Session, patient: Account, session_id: uuid.UUID, ip: str | None) -> ExerciseSession:
    session = own_session(db, patient, session_id, lock=True)
    if session.status != ACTIVE:
        # Ending twice (a double tap, a retry after a lost reply) changes nothing.
        return session
    session.status = COMPLETED
    session.ended_at = clock.utcnow()
    audit.record(
        db,
        "session.ended",
        actor_id=patient.id,
        target_type="exercise_session",
        target_id=session.id,
        detail={"seconds": int((session.ended_at - session.started_at).total_seconds())},
        ip=ip,
    )
    db.commit()
    return session
