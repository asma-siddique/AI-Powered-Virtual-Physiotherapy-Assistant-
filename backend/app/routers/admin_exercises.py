import re
import uuid

from fastapi import APIRouter, Request, status
from sqlalchemy import select

from app import audit, clock, errors
from app.deps import AdminUser, DbSession, client_ip
from app.exercise_schemas import ExerciseCreate, ExerciseOut, ExerciseUpdate
from app.models import ExerciseTemplate

router = APIRouter(prefix="/admin/exercises", tags=["admin: exercise library"])


def _slug(name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


def _get(db: DbSession, exercise_id: uuid.UUID, *, lock: bool = False) -> ExerciseTemplate:
    query = select(ExerciseTemplate).where(ExerciseTemplate.id == exercise_id)
    template = db.execute(query.with_for_update() if lock else query).scalar_one_or_none()
    if template is None:
        raise errors.not_found("Exercise not found.")
    return template


@router.get("", response_model=list[ExerciseOut])
def list_exercises(_: AdminUser, db: DbSession) -> list[ExerciseTemplate]:
    """The whole library, including exercises that are currently switched off."""
    return list(db.execute(select(ExerciseTemplate).order_by(ExerciseTemplate.name)).scalars())


@router.post("", response_model=ExerciseOut, status_code=status.HTTP_201_CREATED)
def create_exercise(
    body: ExerciseCreate, admin: AdminUser, request: Request, db: DbSession
) -> ExerciseTemplate:
    """Adds a template. It starts switched off: turn it on once the scoring model
    supports it, so physiotherapists are never offered an exercise that cannot be scored."""
    slug = _slug(body.name)
    if db.execute(select(ExerciseTemplate.id).where(ExerciseTemplate.slug == slug)).first():
        raise errors.ApiError(
            status.HTTP_409_CONFLICT, "exercise_exists", "An exercise with this name already exists."
        )
    now = clock.utcnow()
    template = ExerciseTemplate(
        **body.model_dump(), slug=slug, is_active=False, version=1, created_at=now, updated_at=now
    )
    db.add(template)
    db.flush()
    audit.record(
        db,
        "exercise_template.created",
        actor_id=admin.id,
        target_type="exercise_template",
        target_id=template.id,
        detail={"name": template.name, "version": 1},
        ip=client_ip(request),
    )
    db.commit()
    return template


@router.patch("/{exercise_id}", response_model=ExerciseOut)
def update_exercise(
    exercise_id: uuid.UUID, body: ExerciseUpdate, admin: AdminUser, request: Request, db: DbSession
) -> ExerciseTemplate:
    """Edits the profile or thresholds. The new version applies to sessions that
    start afterwards; nothing already recorded is rescored."""
    template = _get(db, exercise_id, lock=True)
    changed = {
        field: {"from": getattr(template, field), "to": value}
        for field, value in body.model_dump(exclude_unset=True, exclude_none=True).items()
        if getattr(template, field) != value
    }
    if not changed:
        return template

    for field, change in changed.items():
        setattr(template, field, change["to"])
    template.version += 1
    template.updated_at = clock.utcnow()
    audit.record(
        db,
        "exercise_template.updated",
        actor_id=admin.id,
        target_type="exercise_template",
        target_id=template.id,
        detail={"version": template.version, "changed": changed},
        ip=client_ip(request),
    )
    db.commit()
    return template


def _set_active(
    exercise_id: uuid.UUID, active: bool, admin: AdminUser, request: Request, db: DbSession
) -> ExerciseTemplate:
    template = _get(db, exercise_id, lock=True)
    if template.is_active != active:
        template.is_active = active
        template.updated_at = clock.utcnow()
        audit.record(
            db,
            "exercise_template.activated" if active else "exercise_template.deactivated",
            actor_id=admin.id,
            target_type="exercise_template",
            target_id=template.id,
            detail={"name": template.name},
            ip=client_ip(request),
        )
        db.commit()
    return template


@router.post("/{exercise_id}/deactivate", response_model=ExerciseOut)
def deactivate_exercise(
    exercise_id: uuid.UUID, admin: AdminUser, request: Request, db: DbSession
) -> ExerciseTemplate:
    """Removes the exercise from the plan builder at once. Plans and sessions
    that already use it keep pointing at it; nothing is deleted."""
    return _set_active(exercise_id, False, admin, request, db)


@router.post("/{exercise_id}/activate", response_model=ExerciseOut)
def activate_exercise(
    exercise_id: uuid.UUID, admin: AdminUser, request: Request, db: DbSession
) -> ExerciseTemplate:
    return _set_active(exercise_id, True, admin, request, db)
