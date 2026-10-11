"""Session reminders (US 6.1): on the days a plan prescribes, at the time the
patient chose, they are told their exercises are due, with a link straight
to the first one left to do.

Whether a reminder is due is worked out from the plan as it is at that moment,
so a plan that has been replaced or a patient whose account is switched off
never gets one. One row per plan and day makes a reminder impossible to send
twice, even with more than one copy of the API running.
"""

import logging
import uuid
from datetime import date, datetime, timedelta

from sqlalchemy import select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app import clock, notifications, rls
from app.db import get_engine
from app.models import (
    Account,
    ExercisePlan,
    ExerciseSession,
    ExerciseTemplate,
    PlanExercise,
    ReminderSettings,
    Role,
    SessionReminder,
)
from app.schemas import ReminderIn, ReminderOut

log = logging.getLogger("physioai.reminders")

# Six in the evening, until the patient chooses otherwise.
DEFAULT_MINUTES = 18 * 60
EVERY_DAY = [0, 1, 2, 3, 4, 5, 6]
# A reminder that could not go out on time (the server was down) is still
# sent if it is no more than this late; after that it would only confuse.
GRACE = timedelta(hours=3)


def _clock_time(minutes: int) -> str:
    return f"{minutes // 60:02d}:{minutes % 60:02d}"


def _minutes(clock_time: str) -> int:
    hours, minutes = clock_time.split(":")
    return int(hours) * 60 + int(minutes)


def to_out(db: Session, patient: Account) -> ReminderOut:
    row = db.get(ReminderSettings, patient.id)
    plan = db.execute(
        select(ExercisePlan).where(ExercisePlan.patient_id == patient.id, ExercisePlan.archived_at.is_(None))
    ).scalar_one_or_none()
    return ReminderOut(
        enabled=row.enabled if row else True,
        time=_clock_time(row.time_minutes if row else DEFAULT_MINUTES),
        utc_offset_minutes=row.utc_offset_minutes if row else None,
        days=sorted(plan.frequency_days) if plan else [],
    )


def save(db: Session, patient: Account, sent: ReminderIn) -> ReminderOut:
    """Changes only what was sent; the rest keeps its value."""
    row = db.get(ReminderSettings, patient.id)
    if row is None:
        row = ReminderSettings(patient_id=patient.id, enabled=True, time_minutes=DEFAULT_MINUTES)
        db.add(row)
    if sent.enabled is not None:
        row.enabled = sent.enabled
    if sent.time is not None:
        row.time_minutes = _minutes(sent.time)
    if sent.utc_offset_minutes is not None:
        row.utc_offset_minutes = sent.utc_offset_minutes
    row.updated_at = clock.utcnow()
    db.commit()
    return to_out(db, patient)


def _next_exercise(
    db: Session, plan: ExercisePlan, day_start: datetime
) -> tuple[PlanExercise, str, int] | None:
    """The first exercise of the plan not yet completed today, its name, and
    how many are left. None when there is nothing left to do today."""
    rows = db.execute(
        select(PlanExercise, ExerciseTemplate)
        .join(ExerciseTemplate, ExerciseTemplate.id == PlanExercise.exercise_template_id)
        .where(PlanExercise.plan_id == plan.id, ExerciseTemplate.is_active)
        .order_by(PlanExercise.position)
    ).all()
    done = set(
        db.execute(
            select(ExerciseSession.plan_exercise_id).where(
                ExerciseSession.plan_id == plan.id,
                ExerciseSession.status == "completed",
                ExerciseSession.started_at >= day_start,
            )
        ).scalars()
    )
    left = [(item, template.name) for item, template in rows if item.id not in done]
    if not left:
        return None
    return left[0][0], left[0][1], len(left)


def send_due(db: Session, now: datetime | None = None) -> int:
    """Sends every reminder that has fallen due and has not been sent, and
    returns how many went out."""
    now = now or clock.utcnow()
    rows = db.execute(
        select(ExercisePlan, ReminderSettings)
        .join(ReminderSettings, ReminderSettings.patient_id == ExercisePlan.patient_id)
        .join(Account, Account.id == ExercisePlan.patient_id)
        .where(
            # Only the plan in force: one that was replaced gets nothing.
            ExercisePlan.archived_at.is_(None),
            Account.is_active,
            Account.role == Role.patient,
            ReminderSettings.enabled,
            # Without the patient's clock there is no "six in the evening".
            ReminderSettings.utc_offset_minutes.is_not(None),
        )
    ).all()
    sent = 0
    for plan, settings in rows:
        local = now + timedelta(minutes=settings.utc_offset_minutes)
        if local.weekday() not in plan.frequency_days:
            continue
        due_at = local.replace(hour=0, minute=0, second=0, microsecond=0) + timedelta(
            minutes=settings.time_minutes
        )
        if not due_at <= local < due_at + GRACE:
            continue
        # The patient's midnight, as a moment on the server's clock.
        day_start = local.replace(hour=0, minute=0, second=0, microsecond=0) - timedelta(
            minutes=settings.utc_offset_minutes
        )
        if _send(db, plan, local.date(), day_start):
            sent += 1
    return sent


def _send(db: Session, plan: ExercisePlan, local_date: date, day_start: datetime) -> bool:
    already = db.execute(
        select(SessionReminder.id).where(
            SessionReminder.plan_id == plan.id, SessionReminder.local_date == local_date
        )
    ).first()
    if already:
        return False
    upcoming = _next_exercise(db, plan, day_start)
    if upcoming is None:
        # Everything is done for today: nothing to be reminded of.
        return False
    item, name, left = upcoming
    db.add(
        SessionReminder(
            id=uuid.uuid4(),
            plan_id=plan.id,
            patient_id=plan.patient_id,
            local_date=local_date,
            sent_at=clock.utcnow(),
        )
    )
    try:
        db.flush()
    except IntegrityError:
        # Another copy of the API sent it a moment ago.
        db.rollback()
        return False
    notifications.send(
        db,
        plan.patient_id,
        notifications.SESSION_REMINDER,
        "Time for your exercises",
        f"{name} is next." if left == 1 else f"{left} exercises to do today, starting with {name}.",
        # Straight to the exercise, not to the home page.
        link=f"/patient/session/{item.id}",
    )
    db.commit()
    return True


def tick() -> None:
    """One pass of the scheduler, on its own database session."""
    # Nobody is signed in here: the scheduler works for every patient.
    with rls.as_system(Session(get_engine(), expire_on_commit=False)) as db:
        count = send_due(db, clock.utcnow())
        if count:
            log.info("Sent %d session reminder%s", count, "" if count == 1 else "s")
