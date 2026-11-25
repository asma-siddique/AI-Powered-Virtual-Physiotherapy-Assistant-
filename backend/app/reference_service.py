"""A patient's own reference for an exercise (app.personal): made by their
physiotherapist from two repetitions they saw done correctly, and the thing
later sessions of that exercise are judged against."""

import uuid

from fastapi import status
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app import audit, clock, errors, personal, plan_service
from app.exercise_schemas import ExerciseBrief
from app.models import Account, ExerciseReference, ExerciseSession, ExerciseTemplate, SessionRepetition
from app.schemas import PersonRef
from app.session_schemas import ReferenceOut, ReferenceRepetition


def current(db: Session, patient_id: uuid.UUID, template_id: uuid.UUID) -> ExerciseReference | None:
    """The reference in force for this patient and exercise, if any."""
    return db.execute(
        select(ExerciseReference).where(
            ExerciseReference.patient_id == patient_id,
            ExerciseReference.exercise_template_id == template_id,
            ExerciseReference.retired_at.is_(None),
        )
    ).scalar_one_or_none()


def _out(db: Session, reference: ExerciseReference) -> ReferenceOut:
    rows = db.execute(
        select(SessionRepetition, ExerciseSession.started_at)
        .join(ExerciseSession, ExerciseSession.id == SessionRepetition.session_id)
        .where(SessionRepetition.id.in_([uuid.UUID(i) for i in reference.repetition_ids]))
        .order_by(ExerciseSession.started_at, SessionRepetition.set_number, SessionRepetition.rep_number)
    ).all()
    judged = db.execute(
        select(func.count()).select_from(ExerciseSession).where(ExerciseSession.reference_id == reference.id)
    ).scalar_one()
    return ReferenceOut(
        id=reference.id,
        exercise=ExerciseBrief.model_validate(db.get(ExerciseTemplate, reference.exercise_template_id)),
        repetitions=[
            ReferenceRepetition(
                id=repetition.id,
                session_id=repetition.session_id,
                session_started_at=started_at,
                set_number=repetition.set_number,
                rep_number=repetition.rep_number,
            )
            for repetition, started_at in rows
        ],
        created_at=reference.created_at,
        created_by=PersonRef.model_validate(db.get(Account, reference.created_by)),
        sessions_judged=judged,
    )


def listing(db: Session, physio: Account, patient_id: uuid.UUID) -> list[ReferenceOut]:
    """The references in force for one of the physiotherapist's own patients."""
    patient = plan_service.patient_on_roster(db, physio.id, patient_id)
    references = db.execute(
        select(ExerciseReference)
        .where(ExerciseReference.patient_id == patient.id, ExerciseReference.retired_at.is_(None))
        .order_by(ExerciseReference.created_at)
    ).scalars()
    return [_out(db, reference) for reference in references]


def _refuse(code: str, message: str) -> errors.ApiError:
    return errors.ApiError(status.HTTP_422_UNPROCESSABLE_CONTENT, code, message)


def set_reference(
    db: Session, physio: Account, patient_id: uuid.UUID, repetition_ids: list[uuid.UUID], ip: str | None
) -> ReferenceOut:
    """Makes the patient's reference for an exercise from two of their
    repetitions. One already in force for that exercise is retired, not
    deleted, so the sessions it judged can still be traced to it."""
    patient = plan_service.patient_on_roster(db, physio.id, patient_id)
    rows = db.execute(
        select(SessionRepetition, ExerciseSession.exercise_template_id, SessionRepetition.series)
        .join(ExerciseSession, ExerciseSession.id == SessionRepetition.session_id)
        .where(SessionRepetition.id.in_(repetition_ids), ExerciseSession.patient_id == patient.id)
    ).all()
    if len(rows) != len(repetition_ids):
        # The same answer for a repetition that does not exist and for one of
        # another patient.
        raise errors.not_found("Repetition not found.")
    templates = {template_id for _, template_id, _ in rows}
    if len(templates) != 1:
        raise _refuse("reference_mixed_exercises", "Choose two repetitions of the same exercise.")
    template = db.get(ExerciseTemplate, templates.pop())
    if template.slug not in personal.CUTS:
        raise _refuse(
            "reference_unsupported",
            f"{template.name} cannot be judged against a reference yet: there is no cut for it.",
        )
    if any(series is None for _, _, series in rows):
        raise _refuse(
            "reference_no_series",
            f"Only the first {personal.STORED_SERIES} repetitions of a session keep the joint angles "
            "a reference is made of. Choose two of those.",
        )
    if any(repetition.tier == "red" for repetition, _, _ in rows):
        raise _refuse(
            "reference_red",
            "A repetition that crossed a safety threshold cannot be a reference.",
        )

    now = clock.utcnow()
    replaced = current(db, patient.id, template.id)
    if replaced is not None:
        replaced.retired_at = now
        replaced.retired_by = physio.id
        db.flush()  # the old one stops being current before the new one is
    values, mask = personal.reference_of([personal.decode(series) for _, _, series in rows])
    reference = ExerciseReference(
        id=uuid.uuid4(),
        patient_id=patient.id,
        exercise_template_id=template.id,
        repetition_ids=[str(i) for i in repetition_ids],
        series=personal.encode(values, mask),
        created_by=physio.id,
        created_at=now,
    )
    db.add(reference)
    audit.record(
        db,
        "exercise_reference.set",
        actor_id=physio.id,
        target_type="exercise_reference",
        target_id=reference.id,
        detail={
            "patient_id": str(patient.id),
            "exercise": template.slug,
            "repetition_ids": reference.repetition_ids,
            "replaced": str(replaced.id) if replaced is not None else None,
        },
        ip=ip,
    )
    db.commit()
    return _out(db, reference)


def retire(
    db: Session, physio: Account, patient_id: uuid.UUID, reference_id: uuid.UUID, ip: str | None
) -> None:
    """Stops judging the patient against this reference. It is kept."""
    patient = plan_service.patient_on_roster(db, physio.id, patient_id)
    reference = db.get(ExerciseReference, reference_id)
    if reference is None or reference.patient_id != patient.id or reference.retired_at is not None:
        raise errors.not_found("Reference not found.")
    reference.retired_at = clock.utcnow()
    reference.retired_by = physio.id
    audit.record(
        db,
        "exercise_reference.retired",
        actor_id=physio.id,
        target_type="exercise_reference",
        target_id=reference.id,
        detail={"patient_id": str(patient.id)},
        ip=ip,
    )
    db.commit()
